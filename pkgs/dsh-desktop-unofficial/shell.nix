{
  lib,
  stdenv,
  fetchFromGitHub,
  fontconfig,
  patch,
  yarn-berry_4,
  nodejs_22,
  electron_43,
  jq,
  writers,
  copyTree,
}:

let
  inherit (stdenv.hostPlatform) isLinux;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "dsh-desktop-shell";
  version = "2.0.18-next-unstable-2026-10-17";

  src = fetchFromGitHub {
    owner = "anywhere-labs";
    repo = "deepseek-harness-desktop";
    rev = "44084bdae0d44cac56948a223048d9c31541d0d0";
    hash = "sha256-O194qqZ6dujyy1d1QTUdcpOQsdpROOKaWKKDf7gKOrI=";
  };

  postPatch = lib.optionalString isLinux ''
    # `current` is sufficient on native Linux; Darwin keeps both for universal builds.
    sed -i -E '/^    - (x64|arm64)$/d' .yarnrc.yml
  '';

  missingHashes = ./missing-hashes.json;

  passthru = {
    packageJson = {
      name = "dsh-desktop";
      version = finalAttrs.version;
      type = "module";
      main = "node_modules/dsh-plugin-desktop/lib/main.js";
    };
  };

  offlineCache =
    (yarn-berry_4.fetchYarnBerryDeps {
      inherit (finalAttrs) src missingHashes postPatch;
      hash = "sha256-HlW+8vQAMc7JADI+Xh5SYogAfRirbglDzlx8EqTMe9g=";
    }).overrideAttrs
      (_: {
        buildPhase = ''
          runHook preBuild

          yarnLock=''${yarnLock:=$PWD/yarn.lock}
          filteredLock=$(mktemp)
          awk '
            /^".*@file:/ { skip = 1; next }
            skip && /^$/ { skip = 0; next }
            !skip { print }
          ' "$yarnLock" > "$filteredLock"
          yarn-berry-fetcher fetch "$filteredLock" "$missingHashes"
          cp "$yarnLock" "$out/yarn.lock"

          runHook postBuild
        '';
      });

  nativeBuildInputs = [
    yarn-berry_4
    yarn-berry_4.yarnBerryConfigHook
    nodejs_22
    jq
    patch
  ];

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    YARN_ENABLE_SCRIPTS = "0";
    CI = "true";

    # The upstream desktop lockfile is Yarn format v10, which only the Yarn that
    # ships with a recent nixpkgs accepts. Consumers whose nixpkgs is older get
    # an older Yarn (4.14 expects v9), and because `CI` is set the config hook's
    # `yarn install` runs immutable, so the version migration aborts the build:
    #
    #   YN0028: -  version: 10
    #           +  version: 9
    #   YN0028: The lockfile would have been modified by this install, which is
    #           explicitly forbidden.
    #
    # Allow that migration. It only rewrites the lockfile's format version --
    # the resolved entries are identical, so the prebuilt offline cache still
    # satisfies the install -- and the hook's src/cache lockfile diff still
    # catches genuinely stale dependencies. Newer Yarn needs no migration, so
    # this is a no-op there rather than a downgrade.
    YARN_ENABLE_IMMUTABLE_INSTALLS = "0";
  };

  buildPhase = ''
    runHook preBuild

    # Give the Host `--expose-internals`.
    #
    # The Host runs as an Electron utility process, and Node internals are the only
    # way to reach the ESM loader. The bundled `node-addon-require-builtin` refuses
    # this Electron build: its fingerprint check allows Electron 43.0.0, 44.0.0 and
    # 45.0.0-alpha.6, while this is 43.6.0 --
    #
    #   node-addon-require-builtin unsupported: Unsupported/no-context (unsupported
    #   Electron runtime fingerprint: Node 24.20.0, V8 15.0.245.31-electron.0
    #   (supported Electron versions: 43.0.0, 44.0.0, 45.0.0-alpha.6))
    #
    # so internals have to come from `--expose-internals`, which is exactly what the
    # `expose-internals-loader.patch` carried by this fork already assumes. The
    # desktop forks the Host with no `execArgv` at all, so the flag never arrives
    # and `ModuleLoader.fromInternal()` returns undefined. Harness 0.2.1 added
    # `resolvePluginResource`, which throws on that -- surfacing as, for every plugin
    # whose metadata resolves resources,
    #
    #   Error: Plugin metadata requires the Node module resolver
    #
    # (absent in 0.1.6, which is why bumping the bundled harness exposed it).
    # `utilityProcess.fork` forwards `execArgv` to the child, so setting it here is
    # enough; verified to make `fromInternal()` return the v2 loader.
    substituteInPlace dsh-plugin-desktop/src/host-process.ts \
      --replace-fail \
        "serviceName: 'DSH Host', stdio: 'pipe', cwd: process.cwd(), env: { ...process.env }," \
        "serviceName: 'DSH Host', stdio: 'pipe', cwd: process.cwd(), env: { ...process.env }, execArgv: ['--expose-internals'],"

    # The 2.0.18-next shell grew an Office composition whose primary runtime --
    # a bundled Node/Python/pnpm payload under `resources/runtime/<arch>` -- a
    # packaged app normally carries beside itself. The Nix packaging supplies
    # one through `DSH_DESKTOP_PRIMARY_RUNTIME_DIR` instead (the desktop
    # package's `primaryRuntime` argument), but a shell built without it must
    # still start: `desktopPrimaryRuntime` marks the payload `required` for a
    # packaged app, and the Host aborts when it is missing. Mark it optional, as
    # on the 2.0.17 shell, so that build only warns that Office skills are
    # unavailable.
    substituteInPlace dsh-plugin-desktop/src/desktop-office.ts \
      --replace-fail \
        "return { source, required: location.packaged }" \
        "return { source, required: false }"

    # Use the payload where it lies when it is a read-only carrier.
    #
    # `load_workspace_dependencies` normally copies the payload under
    # `$DSH_HOME/dsh-runtimes` on the first tool call. A copy of a Nix store
    # payload inherits the store's read-only directory modes, so the tool then
    # fails to remove its staging tree -- the first Office tool call dies with
    # EACCES. The tool has a read-only-carrier mode for exactly this case (its
    # optional `root`), in which it validates and returns paths into the payload
    # itself, so drop the installation root. This keeps the store payload out of
    # the home directory entirely and makes payload updates follow the store path.
    substituteInPlace dsh-plugin-desktop/src/desktop-office.ts \
      --replace-fail \
        "  readonly root: string" \
        "  readonly root?: string" \
      --replace-fail \
        "export function resolveDesktopOfficeConfig(runtime: DesktopPrimaryRuntime | undefined, home: string): Config | undefined {" \
        "export function resolveDesktopOfficeConfig(runtime: DesktopPrimaryRuntime | undefined, _home: string): Config | undefined {" \
      --replace-fail \
        "return { source: runtime.source, root: join(home, 'dsh-runtimes', PRIMARY_RUNTIME_INSTALL_NAME) }" \
        "return { source: runtime.source }"

    # The root build resolves dshmarket@latest from npm, outside the lockfile.
    yarn workspace dsh-community-market build
    yarn workspace dsh-plugin-desktop build

    jq '.workspaces = ["dsh-plugin-desktop", "dsh-community-market"]' \
      package.json > package.json.tmp
    mv package.json.tmp package.json
    for workspace in dsh-plugin-desktop dsh-community-market; do
      jq 'del(.devDependencies)' "$workspace/package.json" \
        > "$workspace/package.json.tmp"
      mv "$workspace/package.json.tmp" "$workspace/package.json"
    done
    YARN_ENABLE_SCRIPTS=0 YARN_ENABLE_IMMUTABLE_INSTALLS=0 \
      yarn install --mode=skip-build

    # Teach the shell's bundled LibreOffice kit to discover fonts through
    # fontconfig. The kit (0.1.1 here) only looks under `$XDG_DATA_DIRS/fonts`,
    # `~/.fonts` and `~/.local/share/fonts`, none of which holds NixOS's store
    # fonts, so every Office conversion, recalculation and render failed with
    #
    #   {"code":"unavailable","error":"No usable fonts were found. ..."}
    #
    # The harness workspace already carries the same fix for the kit version it
    # ships (0.1.5); this applies the equivalent patch to the shell's copy. See
    # the patch header for why it is a separate file rather than the upstream
    # one. The placeholder the patch inserts is replaced with fc-list's store
    # path, so the kit consults the system font configuration at runtime.
    kitDirs=$(
      {
        find node_modules -type d -path '*/@deepseek-ai/libreoffice-kit' 2>/dev/null || true
        find dsh-plugin-desktop/node_modules -type d -path '*/@deepseek-ai/libreoffice-kit' 2>/dev/null || true
      } | sort -u
    )
    [ -n "$kitDirs" ] || {
      echo "dsh-desktop-shell: bundled @deepseek-ai/libreoffice-kit not found" >&2
      exit 1
    }
    for kit in $kitDirs; do
      if grep -q 'fc-list' "$kit/lib/cli.js"; then
        echo "dsh-desktop-shell: $kit already discovers fonts; skipping patch"
        continue
      fi
      chmod -R u+w "$kit"
      patch -p1 -d "$kit" < ${./libreoffice-kit-fontconfig-0.1.1.patch}
      substituteInPlace "$kit/lib/index.js" "$kit/lib/cli.js" \
        --replace-fail '@fc-list@' '${lib.getExe' fontconfig "fc-list"}'
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    cp -a ${electron_43.dist}/. "$out/"
    chmod -R u+w "$out"
    if [ -d "$out/Electron.app" ]; then
      mv "$out/Electron.app" "$out/DeepSeek Harness.app"
      mv "$out/DeepSeek Harness.app/Contents/MacOS/Electron" "$out/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"
      appResources="$out/DeepSeek Harness.app/Contents/Resources"

      substituteInPlace "$out/DeepSeek Harness.app/Contents/Info.plist" \
        --replace '<string>Electron</string>' '<string>DeepSeek Harness</string>' \
        --replace '<string>com.github.Electron</string>' '<string>ai.deepseek.harness.desktop</string>'
    else
      mv "$out/electron" "$out/DeepSeek Harness"
      appResources="$out/resources"
    fi

    # The yarn workspace links its packages into the project tree.
    ${copyTree.followLinks {
      src = "node_modules";
      dest = "$appResources/app/node_modules";
    }}

    rm -rf "$appResources/app/node_modules/dsh-plugin-desktop"
    ${copyTree.followLinks {
      src = "dsh-plugin-desktop";
      dest = "$appResources/app/node_modules/dsh-plugin-desktop";
    }}
    rm -rf "$appResources/app/node_modules/electron"
    find "$appResources/app/node_modules" -type d \
      \( -name 'test' -o -name 'tests' -o -name '__tests__' \) \
      -prune -exec rm -rf {} +
    cp ${writers.writeJSON "package.json" finalAttrs.passthru.packageJson} \
      "$appResources/app/package.json"

    cp dsh-plugin-desktop/build/app-icon.png "$out/icon.png"

    runHook postInstall
  '';

  meta = {
    description = "DeepSeek Harness Electron shell, uncombined";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ [ "aarch64-darwin" ];
  };
})
