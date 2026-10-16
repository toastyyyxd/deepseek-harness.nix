{
  lib,
  callPackage,
  stdenv,
  stdenvNoCC,
  darwin,
  electron,
  makeWrapper,
  # `readelf` (binutils) and `patchelf` drive the postFixup RPATH pass.
  binutils,
  patchelf,
  wrapGAppsHook3,
  writeShellScriptBin,
  gsettings-desktop-schemas,
  glib,
  gtk3,
  makeDesktopItem,
  copyDesktopItems,
  nix-update,
  writeShellScript,
  nix,
  coreutils,
  gawk,
  yarn-berry_4,
  git,
  imagemagick,
  libGL,

  copyTree,
  dsh,
  # Composed dsh backing resources/host; override with a preset or dsh.override.
  dshHost ? dsh,
  # systemd package providing systemd-run for the Linux containment shim.
  systemd ? null,
  # BrowserSkill CLI (`bsk`), from `pkgs.dsh.bsk`. When set, it is put on the
  # wrapper PATH so the BrowserSkill dsh plugin finds it without extra
  # configuration, and its self-update check is disabled because the store path
  # is immutable.
  browserSkill ? null,
}:

let
  inherit (stdenvNoCC.hostPlatform) isLinux isDarwin;

  # DSH's Linux Electron runner is spawned through `systemd-run`, but upstream
  # only sets ELECTRON_RUN_AS_NODE=1 on Windows, so the scope starts the
  # Electron binary in GUI mode instead of Node mode. Shadow systemd-run in the
  # wrapper PATH with this shim: the private runner launched by
  # `runnerEnvironment()` (marked by DSH_SUBPROCESS_RUNNER and the runner entry)
  # gets ELECTRON_RUN_AS_NODE=1; every other systemd-run invocation is
  # untouched.
  useSystemdShim = isLinux && systemd != null;
  systemdRunShim = writeShellScriptBin "systemd-run" ''
    # Every private runner launch needs Electron's Node mode.
    runner=0
    if [ -n "''${DSH_SUBPROCESS_RUNNER-}" ]; then
      case " $* " in
        *" -- "*"/dsh-subprocess-local/"*"/runner.js "*)
          runner=1
          ;;
      esac
    fi
    if [ "$runner" -eq 1 ]; then
      export ELECTRON_RUN_AS_NODE=1
    fi
    exec ${systemd}/bin/systemd-run "$@"
  '';

  # Hosts the Agents Anywhere Connector's `uv` invocation on NixOS without
  # requiring host-level nix-ld; see agents-anywhere-uv.nix.
  agentsAnywhereUv = callPackage ./agents-anywhere-uv.nix { };

  # Electron-safe `sharp`; see that file for why the packaged one crashes the
  # Host under Electron on Linux.
  sharpElectronSafe = callPackage ../sharp-electron-safe.nix { };
in
stdenvNoCC.mkDerivation (
  finalAttrs:
  let
    runtimePathArgs = lib.optionalString (
      finalAttrs.passthru.runtimeDeps != [ ]
    ) "--prefix PATH : ${lib.makeBinPath finalAttrs.passthru.runtimeDeps} ";

    # The store path cannot be written next to, so bsk's self-update could only
    # ever report "cannot install it next to its executable"; drive updates
    # through this flake instead.
    browserSkillArgs = lib.optionalString (
      finalAttrs.passthru.browserSkill != null
    ) "--set BSK_AUTO_UPDATE off ";
  in
  {
    pname = "dsh-desktop";
    inherit (finalAttrs.passthru.shell) version;

    src = null;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontPatchShebangs = true;

    nativeBuildInputs = [
      makeWrapper
    ]
    ++ lib.optionals isDarwin [
      darwin.autoSignDarwinBinariesHook
    ]
    ++ lib.optionals isLinux [
      wrapGAppsHook3
      copyDesktopItems
      imagemagick
      # Used by the postFixup RPATH pass below.
      binutils
      patchelf
    ];

    buildInputs = lib.optionals isLinux [
      gsettings-desktop-schemas
      glib
      gtk3
    ];

    dontWrapGApps = isLinux;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin"
    ''
    + lib.optionalString isLinux ''
      appDir="$out/lib/dsh-desktop"
      ${copyTree.preserve {
        src = finalAttrs.passthru.shell;
        dest = "$appDir";
      }}

      ${copyTree.preserve {
        src = finalAttrs.passthru.runtime;
        dest = "$appDir/resources/host";
      }}

      # Replace every `sharp` in the assembled trees with the electron-safe build.
      #
      # The Host resolves `sharp` from the *app* tree, not from `resources/host`:
      # its entry script is
      # `resources/app/node_modules/dsh-plugin-desktop/lib/host-process-entry.js`,
      # so a bare `import "sharp"` from the bundled
      # `dsh-plugin-desktop/node_modules/@deepseek-ai/dsh-attachment-local` walks up
      # to `dsh-plugin-desktop/node_modules/sharp`. Verified against a running
      # instance, whose Host had mapped exactly that copy's
      # `@img/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.18.3` -- which is why
      # fixing only the vendored `resources/host` tree left the crash in place.
      #
      # `dsh-community-market` carries a second nested copy, so match on
      # `*/node_modules/sharp`; that covers both without descending into the
      # replacement, whose bundled tree lives at `sharp/linux-x64/sharp`.
      # Collect the list first: the loop rewrites the tree `find` is walking.
      sharpDirs=$(find "$appDir" -type d -path '*/node_modules/sharp')
      while IFS= read -r sharpDir; do
        [ -n "$sharpDir" ] || continue
        echo "dsh-desktop: replacing $sharpDir with the electron-safe sharp"
        rm -rf "$sharpDir"
        cp -r ${sharpElectronSafe}/package "$sharpDir"
        chmod -R u+w "$sharpDir"
      done <<< "$sharpDirs"

      gappsWrapperArgsHook

      # Experimental: force ANGLE onto its Vulkan backend (RADV) instead of
      # Mesa GL (radeonsi), to test whether that avoids the amdgpu gfxhub
      # page fault + GPU mode1 reset this process triggers.
      #
      # libGL is still exported, but the gcc-15.3.0 libstdc++ that used to
      # travel with it is not: the wrapper's environment is inherited by every
      # child process, and LD_LIBRARY_PATH is searched before a child's own
      # RUNPATH, so that libstdc++ (GLIBCXX_3.4.34) shadowed the newer one a
      # child resolves through its RUNPATH -- Hyprland 0.56.2's `hyprctl`
      # failed with "version `GLIBCXX_3.4.35' not found" in every shell DSH
      # spawned. The native modules that link libstdc++ now carry it as an
      # RPATH instead (postFixup below), so nothing needs it exported.
      # Suffixing keeps any LD_LIBRARY_PATH the session already exported ahead
      # of the app's own entry.
      makeWrapper "$appDir/DeepSeek Harness" "$out/bin/dsh-desktop" \
        "''${gappsWrapperArgs[@]}" \
        --suffix LD_LIBRARY_PATH : ${
          lib.makeLibraryPath [
            libGL
          ]
        } \
        ${runtimePathArgs}\
        ${browserSkillArgs}\
        --set CHROME_DEVEL_SANDBOX "${electron.unwrapped}/libexec/electron/chrome-sandbox" \
        --set UV_PATH "${agentsAnywhereUv}/bin/agents-anywhere-uv" \
        --add-flags "--use-angle=vulkan" \
        --inherit-argv0

      for size in 16 22 24 32 48 64 128 256 512; do
        mkdir -p "$out/share/icons/hicolor/''${size}x''${size}/apps"
        magick "$appDir/icon.png" -resize "''${size}x''${size}" \
          "$out/share/icons/hicolor/''${size}x''${size}/apps/deepseek-harness.png"
      done
    ''
    + lib.optionalString isDarwin ''
      appBundle="$out/Applications/DeepSeek Harness.app"
      mkdir -p "$out/Applications"
      ${copyTree.preserve {
        src = "${finalAttrs.passthru.shell}/DeepSeek Harness.app";
        dest = "$appBundle";
      }}

      ${copyTree.preserve {
        src = finalAttrs.passthru.runtime;
        dest = "$appBundle/Contents/Resources/host";
      }}

      makeWrapper "$appBundle/Contents/MacOS/DeepSeek Harness" "$out/bin/dsh-desktop" \
        ${runtimePathArgs}\
        ${browserSkillArgs}\
        --set UV_PATH "${agentsAnywhereUv}/bin/agents-anywhere-uv" \
        --inherit-argv0
    ''
    + ''
      runHook postInstall
    '';

    # The shell and the DSH runtime ship prebuilt native modules (`node-pty`,
    # `koffi`, `sharp`/libvips, sherpa-onnx, onnxruntime, ...) that link
    # libstdc++ but carry no RPATH for it. The wrapper used to cover that by
    # exporting `${stdenv.cc.cc.lib}/lib` on LD_LIBRARY_PATH; that export is
    # what broke `hyprctl` in every shell DSH spawned (see the makeWrapper
    # comment in installPhase), so the modules get the path themselves
    # instead. This is what makes dropping the export safe.
    #
    # Walking the assembled tree rather than a fixed file list means prebuilt
    # addons shipped by a future shell or runtime release are covered too. The
    # magic check skips non-ELF files, `--add-rpath` appends (so an RPATH an
    # addon already ships keeps its precedence), and the membership test keeps
    # a repeated fixup idempotent.
    postFixup = lib.optionalString isLinux ''
      libstdcxxDir="${stdenv.cc.cc.lib}/lib"
      rpathPatched=0

      while IFS= read -r -d "" f; do
        # ELF magic: 7f 45 4c 46.
        case "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" in
          7f454c46) ;;
          *) continue ;;
        esac

        readelf -d "$f" 2>/dev/null | grep -q 'libstdc++' || continue

        currentRpath="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
        case ":$currentRpath:" in
          *":$libstdcxxDir:"*) continue ;;
        esac

        chmod u+w "$f"
        patchelf --add-rpath "$libstdcxxDir" "$f"
        rpathPatched=$((rpathPatched + 1))
      done < <(find "$out/lib/dsh-desktop" -type f -print0)

      echo "dsh-desktop: added $libstdcxxDir to the RPATH of $rpathPatched native modules"
    '';

    desktopItems = lib.optionals isLinux [
      (makeDesktopItem {
        name = "deepseek-harness";
        desktopName = "DeepSeek Harness";
        exec = "dsh-desktop %U";
        terminal = false;
        icon = "deepseek-harness";
        startupWMClass = "DeepSeek Harness";
        categories = [ "Development" ];
      })
    ];

    passthru = {
      variant = "unofficial";
      inherit agentsAnywhereUv browserSkill;
      shell = callPackage ./shell.nix { };
      runtime = callPackage ./runtime.nix { inherit dshHost; };
      runtimeDeps =
        lib.optional useSystemdShim systemdRunShim
        ++ dshHost.passthru.runtimeDeps
        ++ lib.optional (browserSkill != null) browserSkill;

      updateScript = writeShellScript "dsh-desktop-update" ''
        PATH=${
          lib.makeBinPath [
            coreutils
            gawk
            git
            nix
            nix-update
            yarn-berry_4.yarn-berry-fetcher
          ]
        }
        export PATH

        set -euo pipefail

        shell_attr="''${UPDATE_NIX_ATTR_PATH:?}.shell"
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT

        nix-update --flake --version=branch --src-only "$shell_attr"

        src="$(nix build --no-link --print-out-paths .#dsh-desktop-unofficial.shell.src)"
        awk '
          /^".*@file:/ { skip = 1; next }
          skip && /^$/ { skip = 0; next }
          !skip { print }
        ' "$src/yarn.lock" > "$tmp/yarn.lock"

        yarn-berry-fetcher missing-hashes "$tmp/yarn.lock" \
          > "$PWD/pkgs/dsh-desktop-unofficial/missing-hashes.json"

        nix-update --flake --version=skip --no-src "$shell_attr"
      '';
    };

    meta = {
      description = "Unofficial DeepSeek Harness desktop application";
      homepage = "https://github.com/anywhere-labs/deepseek-harness-desktop";
      license = lib.licenses.mit;
      mainProgram = "dsh-desktop";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
)
