{
  lib,
  dsh-workspace,
  nodejs-slim,
  pnpmWorkspaceDeploy,
  python3,
  python3Packages,
  stdenvNoCC,
  writers,
}:

# The Desktop "primary runtime": the bundled Python/Node.js/pnpm payload the
# Office skills and the `load_workspace_dependencies` tool use.
#
# The payload layout follows @deepseek-ai/dsh-tool-workspace-dependencies:
# a flat `runtime.json` beside `dependencies/{python,node,pnpm}`. The sibling
# `office-skills` asset tree is *not* part of this package: those skill bodies
# belong to the Desktop shell's own bundled harness version, so the desktop
# package assembles them next to this payload (see its `primaryRuntime` logic).
# The Desktop shell mounts the result through `DSH_DESKTOP_PRIMARY_RUNTIME_DIR`;
# this branch's shell patch keeps it a read-only carrier, so the tool validates
# the payload in place and returns its Store paths instead of copying it into
# the Harness home (a copy would inherit read-only directory modes and break
# the tool's own staging cleanup).
#
# Building it from nixpkgs (rather than shipping upstream's downloaded
# python-build-standalone carrier) keeps it rebuildable and glibc-clean on
# NixOS, which is why the expected `bin/python3 -> python3.14` relative alias
# is constructed from `python.withPackages` instead of an upstream archive.
let
  inherit (stdenvNoCC.hostPlatform) isAarch64 isDarwin;

  platform = if isDarwin then "darwin" else "linux";
  arch = if isAarch64 then "arm64" else "x64";

  # `python.withPackages` yields exactly the layout the Host's alias check
  # expects: `bin/python3` and `bin/python` are relative links to the regular
  # versioned interpreter, and `lib/pythonX.Y/site-packages` holds the
  # distributions named in `runtime.json`.
  pythonEnv = python3.withPackages (
    ps: with ps; [
      numpy
      pandas
      python-docx
      python-pptx
      openpyxl
      pillow
      lxml
      xlsxwriter
      python-dateutil
      six
      tzdata
      typing-extensions
      et-xmlfile
    ]
  );

  # The Host documents this as the canonical flat manifest: platform/arch are
  # rejected when they do not match the running process, and every distribution
  # here must also be importable from the payload's site-packages.
  manifest = writers.writeJSON "dsh-primary-runtime.json" {
    # Informational only; a payload is reused while the rest of the manifest is
    # unchanged, so this stays stable across desktop-version bumps.
    desktopVersion = "nix";
    inherit platform arch;
    python = python3.version;
    node = nodejs-slim.version;
    pnpm = pnpmWorkspaceDeploy.version;
    pythonPackages = {
      numpy = python3Packages.numpy.version;
      pandas = python3Packages.pandas.version;
      python-docx = python3Packages.python-docx.version;
      python-pptx = python3Packages.python-pptx.version;
      openpyxl = python3Packages.openpyxl.version;
      Pillow = python3Packages.pillow.version;
      lxml = python3Packages.lxml.version;
      XlsxWriter = python3Packages.xlsxwriter.version;
      python-dateutil = python3Packages.python-dateutil.version;
      six = python3Packages.six.version;
      tzdata = python3Packages.tzdata.version;
      typing-extensions = python3Packages.typing-extensions.version;
      et_xmlfile = python3Packages.et-xmlfile.version;
    };
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dsh-primary-runtime";
  inherit (dsh-workspace) version;

  src = null;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    payload="$out/runtime/primary-runtime"
    mkdir -p "$payload/dependencies/node/bin" "$payload/dependencies/node/node_modules"

    ln -s ${nodejs-slim}/bin/node "$payload/dependencies/node/bin/node"
    printf '%s\n' 'Reserved for bundled Node packages.' \
      > "$payload/dependencies/node/node_modules/README.txt"

    # `libexec/pnpm` keeps `dist/` beside `bin/pnpm.mjs`, so the payload's
    # `pnpm --version` through its own Node works in place.
    ln -s ${pnpmWorkspaceDeploy}/libexec/pnpm "$payload/dependencies/pnpm"

    # `cp -a`, not a symlink to the environment root: the Host's alias check
    # reads `bin/python3` with lstat and requires it to be a relative link to
    # the versioned regular interpreter. Keeping the environment's own links
    # also keeps this store output small while the payload is used in place.
    mkdir -p "$payload/dependencies/python"
    cp -a ${pythonEnv}/. "$payload/dependencies/python/"

    install -Dm644 ${manifest} "$payload/runtime.json"

    runHook postInstall
  '';

  meta = {
    description = "Bundled Python/Node.js/pnpm primary runtime for DSH Desktop Office skills";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
