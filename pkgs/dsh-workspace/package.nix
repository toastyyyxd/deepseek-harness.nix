{
  lib,
  bashInteractive,
  buildNpmPackage,
  fetchFromGitHub,
  fetchurl,
  fontconfig,
  importPnpmLock,
  jq,
  dshWorkspacePatchHook,
  makeWrapper,
  nodejs,
  nodejs-slim,
  patch,
  pnpmConfigHook,
  pnpmWorkspaceDeploy,
  python3,
  runCommand,
  stdenv,
  dsh-system,
  writers,
  yq-go,
}:

let
  platformKey = with stdenv.hostPlatform.node; "${platform}-${arch}";
  dshSystemIsAvailable = lib.meta.availableOn stdenv.hostPlatform dsh-system;
  inherit (stdenv.hostPlatform) isLinux isDarwin;

  # `sharp`/`libvips` bundle a private `glib` inside `libvips-cpp.so` but do not
  # hide its symbols. Electron's Linux binary dynamically links the system `glib`
  # for GTK integration, so the two copies collide inside one process and the
  # desktop host dies with SIGSEGV (exit 139) the first time an image is decoded:
  # `read_image`, or attaching an image. No configuration flag avoids it; it is
  # electron/electron#46323, unresolved upstream.
  #
  # `@janhapke/sharp-electron` is the same sharp release rebuilt with the
  # collision fixed at the linker level -- `libvips-cpp.so` sits beside the addon
  # and the addon's RUNPATH is `$ORIGIN`. It is a drop-in package, so it can
  # substitute for `sharp` without touching DSH code. Verified to decode under
  # this desktop's Electron runtime where stock sharp 0.35.3 segfaults.
  #
  # Its shim keeps a `sharp-upstream` fallback for non-Linux platforms. Those
  # never reach it (the shim's non-Linux branch is not taken here, and this
  # override is Linux-only), so it stays in the tarball unvendored and unused.
  sharpElectronSafeSrc = fetchurl {
    url = "https://registry.npmjs.org/@janhapke/sharp-electron/-/sharp-electron-0.35.4-electron.1.tgz";
    hash = "sha256-r5Z8zJ4wbjapLNAXvGEhqwZSHI/E07xkLT6Q9i4+RMY=";
  };
in
buildNpmPackage (finalAttrs: {
  pname = "dsh-workspace";
  version = "0.2.1-alpha.1";

  __structuredAttrs = true;
  strictDeps = true;
  outputs = [
    "out"
    "cohort"
    "kernel"
    "desktop"
  ];

  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "deepseek-harness";
    tag = "dsh-v${finalAttrs.version}";
    hash = "sha256-/mScgSeh7/1HdIeWGAnxkzlXTjZsxscpnWkwnhR8hsU=";
  };

  patches = [
    ./desktop-nix-profile.patch
    # The prebuilt require-builtin addon only accepts upstream Electron builds, so
    # the desktop host reads Node internals through `--expose-internals` instead.
    ./expose-internals-loader.patch
    # Client CSS virtual ids would otherwise carry the build directory, and the
    # module export map arrives in hash order; the patch rebases ids onto the
    # build cwd and sorts the export map behind the injected class map.
    ./client-bundle-determinism.patch
    # The login-shell read only skips win32 upstream, so on Linux it would replace
    # the wrapper PATH that carries the bundled node and office runtimes.
    # https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/apps/desktop/src/login-shell-environment.ts#L176
    ./desktop-login-shell-macos-only.patch
    # Remove when upstream routes Linux terminal signals through graceful shutdown and isolates the Host process group.
    ./desktop-signal-shutdown.patch
  ];

  env = {
    DSH_CLIENT_COMMIT_HASH = "5badb15009ae1756c3afe0ae0cef1faafc290ccc";
    PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS = "false";
    # Rendered at evaluation time so the workspace patch hook does not have to
    # re-parse pnpm-workspace.yaml in the build sandbox.
    DSH_WORKSPACE_OVERRIDES = "${writers.writeJSON "dsh-workspace-overrides.json" (
      finalAttrs.pnpmDeps.passthru.workspaceConfig.overrides or { }
    )}";
  };

  nodejs = nodejs-slim;
  disallowedReferences = [
    nodejs
    pnpmWorkspaceDeploy
    python3
  ];

  postPatch = ''
    substituteInPlace "packages/terminal/terminal-bash/src/config.ts" \
      --replace-fail \
      "export const DEFAULT_BASH_SHELL = '/bin/bash'" \
      "export const DEFAULT_BASH_SHELL = '${lib.getExe bashInteractive}'"
  ''
  + lib.optionalString (dshSystemIsAvailable && isLinux) ''
    install -Dm755 ${dsh-system}/bin/landlock-run native/system/packages/${platformKey}/bin/landlock-run
    install -Dm644 ${dsh-system}/bin/glibc/system.node native/system/packages/${platformKey}/bin/glibc/system.node
    install -Dm644 ${dsh-system}/bin/musl/system.node native/system/packages/${platformKey}/bin/musl/system.node
  ''
  + lib.optionalString (dshSystemIsAvailable && isDarwin) ''
    install -Dm644 ${dsh-system}/bin/system.node native/system/packages/${platformKey}/bin/system.node
  '';

  preConfigure = ''
    patchDshWorkspace kernel
  ''
  + lib.optionalString isLinux ''
    # The offline dependency store is populated from a rewritten lockfile that
    # already points at these patched tarballs, but this build tree carries the
    # upstream lockfile -- so without the same rewrite here pnpm resolves the
    # registry URL, misses the (absent) stock tarball in the store and fails with
    # ERR_PNPM_NO_OFFLINE_TARBALL. Keep both in step with `packageSourceOverrides`.
    yq -i '
      .packages."sharp@0.35.3".resolution = load("${
        writers.writeJSON "sharp-resolution.json"
          finalAttrs.pnpmDeps.passthru.rewrittenLockfileData.packages."sharp@0.35.3".resolution
      }")
    ' pnpm-lock.yaml

    # Match the patched tarball used to populate the offline dependency store.
    yq -i '
      .packages."@deepseek-ai/libreoffice-kit@0.1.5".resolution = load("${
        writers.writeJSON "libreoffice-kit-resolution.json"
          finalAttrs.pnpmDeps.passthru.rewrittenLockfileData.packages."@deepseek-ai/libreoffice-kit@0.1.5".resolution
      }")
    ' pnpm-lock.yaml
  '';

  pnpmDeps = importPnpmLock {
    inherit (finalAttrs) pname version;
    pnpm = pnpmWorkspaceDeploy;
    lockfileJson = ./pnpm-lock.json;
    workspaceJson = lib.importJSON ./pnpm-workspace.json;
    workspaceRoot = finalAttrs.src;
    packageSourceOverrides = lib.optionalAttrs isLinux {
      "@deepseek-ai/libreoffice-kit@0.1.5" =
        { previousSource, ... }:
        runCommand "libreoffice-kit-0.1.5-fontconfig.tgz"
          {
            src = previousSource;
            nativeBuildInputs = [ patch ];
          }
          ''
            tar -xzf "$src"
            patch -d package -p1 < ${./libreoffice-kit-fontconfig.patch}
            substituteInPlace package/lib/index.js package/lib/cli.js \
              --replace-fail '@fc-list@' '${lib.getExe' fontconfig "fc-list"}'
            tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
              -czf "$out" package
          '';

      # Rewrite the published manifest to claim the identity the lockfile expects.
      # pnpm's prepopulated store is keyed by `name@version` and refuses a
      # mismatch ("Package name or version mismatch found while reading from the
      # store"), so the electron-safe build is relabelled to plain `sharp@0.35.3`.
      #
      # Its shim exists to serve non-Linux platforms from an aliased
      # `sharp-upstream` dependency, and its bundled types re-export that alias.
      # That dependency is not vendored here, so both are pointed at the bundled
      # linux-x64 tree instead, which ships its own `dist/` and type declarations
      # and leaves the tarball self-contained. (Consumer code does
      # `import type { Sharp } from 'sharp'` and is compiled by the workspace
      # build, so the type entry point has to resolve.)
      #
      # NOTE: upstream has no `linux-arm64` build and throws for that arch, so an
      # aarch64-linux desktop would need its own rebuild.
      "sharp@0.35.3" =
        { ... }:
        runCommand "sharp-0.35.3-electron.tgz"
          {
            src = sharpElectronSafeSrc;
            nativeBuildInputs = [
              jq
              bashInteractive
            ];
          }
          ''
            tar -xzf "$src"

            jq '.name = "sharp"
              | .version = "0.35.3"
              | del(.dependencies."sharp-upstream")' \
              package/package.json > package/package.json.tmp
            mv package/package.json.tmp package/package.json

            # Runtime: always the bundled build, so the shim needs no fallback.
            cat > package/index.js <<'EOF'
            module.exports = require('./linux-x64/sharp/dist/index.cjs');
            EOF

            # Types: same target, keeping the shim's `export =` shape so the
            # entry point works with or without esModuleInterop.
            cat > package/index.d.ts <<'EOF'
            import sharp = require('./linux-x64/sharp/dist/index.cjs');
            export = sharp;
            EOF

            tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
              -czf "$out" package
          '';
    };
    targetPlatform =
      if stdenv.buildPlatform == stdenv.hostPlatform then stdenv.targetPlatform else null;
  };

  nativeBuildInputs = [
    jq
    makeWrapper
    nodejs-slim.npm
    pnpmWorkspaceDeploy
    python3
    dshWorkspacePatchHook
    yq-go
  ];

  npmDeps = null;
  dontNpmInstall = true;
  npmInstallFlags = finalAttrs.pnpmDeps.passthru.pnpmInstallFlags;
  npmConfigHook = pnpmConfigHook;
  npmBuildScript = "build:official";

  # node-pty's postinstall can't run before deploy assembles the composition.
  preInstall = ''
    pnpm config set --location=project inject-workspace-packages true
    yq -i 'del(.scripts.postinstall)' packages/subprocess/subprocess-local/package.json
  '';

  installPhase = ''
    runHook preInstall

    PNPM_CONFIG_OFFLINE=true PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false \
      pnpm --filter @deepseek-ai/dsh-desktop-host deploy \
        --prod --config.node-linker=hoisted --config.link-workspace-packages=true \
        "$desktop/host"
    PNPM_CONFIG_OFFLINE=true PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false \
      pnpm --filter @deepseek-ai/dsh-desktop deploy \
        --prod --config.node-linker=hoisted --config.link-workspace-packages=true \
        "$desktop/app"
    cp -r apps/desktop/lib apps/desktop/renderer "$desktop/app/"

    PNPM_CONFIG_OFFLINE=true \
      PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false \
      pnpm run release:pack --family dsh --out "$cohort"

    workspaceDir="$out/lib/dsh-workspace"
    appDir="$workspaceDir/kernel"
    kernelApp="$kernel/lib/deepseek-harness"
    mkdir -p "$workspaceDir"

    cp -r apps/cli/lib apps/nix-kernel/lib
    pnpm --filter @deepseek-ai/dsh-nix-kernel deploy \
      --prod \
      --config.node-linker=hoisted \
      --config.link-workspace-packages=true \
      "$appDir"

    cp -r apps/cli/config "$appDir/config"

    find "$appDir/node_modules" -type f \( -name "config.gypi" -o -name "Makefile" -o -name "*.target.mk" -o -name "binding.Makefile" -o -name "*.o" \) -delete
    find "$appDir/node_modules" -depth -type d \( -name ".deps" -o -name "obj.target" \) -exec rm -rf {} +
    sed -i '1{/^#!/d;}' "$appDir/lib/bin.js"
    ${lib.getExe nodejs-slim} "$appDir/node_modules/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs"

    mkdir -p "$kernelApp"
    cp -r "$appDir/lib" "$kernelApp/lib"
    cp -r "$appDir/config" "$kernelApp/config"
    cp "$appDir/package.json" "$kernelApp/package.json"
    # Keep the public kernel self-contained; do not symlink back into the workspace.
    cp -r "$appDir/node_modules" "$kernelApp/node_modules"

    jq '.name = "@deepseek-ai/dsh"' "$kernelApp/package.json" > "$kernelApp/package.json.tmp"
    mv "$kernelApp/package.json.tmp" "$kernelApp/package.json"

    mkdir -p "$kernel/bin"
    makeWrapper ${lib.getExe nodejs-slim} "$kernel/bin/dsh" \
      --add-flags "--expose-internals" \
      --add-flags "$kernelApp/lib/bin.js"

    runtimeBundlesDir="$workspaceDir/runtime-bundles"
    for packageJson in packages/*/*/package.json; do
      [ -f "$packageJson" ] || continue
      bundlePatchTag=$(yq -r '.dsh.bundle.patch | tag' "$packageJson")
      bundlePatches=()
      case "$bundlePatchTag" in
        "!!null")
          continue
          ;;
        "!!str")
          bundlePatches+=("$(yq -r '.dsh.bundle.patch' "$packageJson")")
          ;;
        "!!seq")
          bundlePatchCount=$(yq -r '.dsh.bundle.patch | length' "$packageJson")
          [ "$bundlePatchCount" -gt 0 ] || {
            printf 'dsh-workspace: bundle patch array is empty: %s\n' "$packageJson" >&2
            exit 1
          }
          for ((bundlePatchIndex = 0; bundlePatchIndex < bundlePatchCount; bundlePatchIndex++)); do
            bundlePatchItemTag=$(yq -r ".dsh.bundle.patch[$bundlePatchIndex] | tag" "$packageJson")
            [ "$bundlePatchItemTag" = "!!str" ] || {
              printf 'dsh-workspace: bundle patch array entry must be a string: %s[%s]\n' "$packageJson" "$bundlePatchIndex" >&2
              exit 1
            }
            bundlePatches+=("$(yq -r ".dsh.bundle.patch[$bundlePatchIndex]" "$packageJson")")
          done
          ;;
        *)
          printf 'dsh-workspace: bundle patch must be a string or array: %s\n' "$packageJson" >&2
          exit 1
          ;;
      esac

      packageName=$(yq -r '.name // ""' "$packageJson")
      [ -n "$packageName" ] || {
        printf 'dsh-workspace: bundle package has no name: %s\n' "$packageJson" >&2
        exit 1
      }
      [ "''${#bundlePatches[@]}" -gt 0 ] || {
        printf 'dsh-workspace: bundle patch is missing: %s\n' "$packageJson" >&2
        exit 1
      }

      bundleDir="$runtimeBundlesDir/$packageName"
      mkdir -p "$(dirname "$bundleDir")"
      pnpm --filter "$packageName" deploy \
        --prod \
        --config.node-linker=hoisted \
        --config.link-workspace-packages=true \
        "$bundleDir"

      for artifact in package.json lib; do
        [ -e "$bundleDir/$artifact" ] || {
          printf 'dsh-workspace: deployed bundle artifact is missing: %s\n' "$bundleDir/$artifact" >&2
          exit 1
        }
      done
      for bundlePatch in "''${bundlePatches[@]}"; do
        case "$bundlePatch" in
          ./*)
            ;;
          *)
            printf "dsh-workspace: bundle patch must be a relative './...' path: %s\n" "$packageJson" >&2
            exit 1
            ;;
        esac
        case "$bundlePatch" in
          *\\*)
            printf 'dsh-workspace: bundle patch must not contain backslashes: %s\n' "$packageJson" >&2
            exit 1
            ;;
        esac
        [ -n "''${bundlePatch#./}" ] || {
          printf 'dsh-workspace: bundle patch is empty: %s\n' "$packageJson" >&2
          exit 1
        }
        [ -f "$bundleDir/''${bundlePatch#./}" ] || {
          printf 'dsh-workspace: deployed bundle patch is missing: %s\n' "$bundleDir/''${bundlePatch#./}" >&2
          exit 1
        }
      done
    done

    mkdir -p "$workspaceDir/frontends/web"
    cp apps/web/package.json "$workspaceDir/frontends/web/package.json"
    cp -r apps/web/dist "$workspaceDir/frontends/web/dist"

    find "$out" "$kernel" -type f \( -name "config.gypi" -o -name "Makefile" -o -name "*.target.mk" -o -name "binding.Makefile" -o -name "*.o" \) -delete
    find "$out" "$kernel" -depth -type d \( -name ".deps" -o -name "obj.target" \) -exec rm -rf {} +

    runHook postInstall
  '';

  passthru = {
    # Used by the update script to validate the dependency fetcher.
    fetchPnpmDeps = finalAttrs.pnpmDeps.passthru.fetchPnpmDeps;
    updateScript = ./update.sh;
  };

  meta = {
    description = "Built DeepSeek Harness workspace artifacts";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
