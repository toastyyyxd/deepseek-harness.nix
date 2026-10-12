{
  lib,
  fetchzip,
  stdenvNoCC,
}:

let
  # Release assets live under the tag `cli-v<version>`, not a bare `<version>`,
  # and the binary is a single statically linked musl build, so there is no
  # local Rust toolchain or build step involved.
  assetUrl =
    version: triple:
    "https://github.com/Tencent/BrowserSkill/releases/download/cli-v${version}/bsk-v${version}-${triple}.tar.gz";

  # Per-platform hash of that tarball. `fetchzip` hashes the unpacked tree, so
  # these are the recursive hashes of the extracted `bsk` binary.
  hashes = {
    x86_64-linux = "sha256-BlAsQPdQtTgiGrgf/JPoaMwPB5bHLGTKiKxxPB9PCco=";
    aarch64-linux = "sha256-iSEMoDQv1G/AovbIES9lw0oHw0ZAHx5gxBg6GT/rT80=";
    x86_64-darwin = "sha256-vfzT7S9KvJMyqhSbB70c5ZeD2fNSVW1lF5cEKsXk/ss=";
    aarch64-darwin = "sha256-kHnVyw7FPFkgiiLs5+QMVLY8ecbj2TJYAj1gZVNNmj4=";
  };

  triples = {
    x86_64-linux = "x86_64-unknown-linux-musl";
    aarch64-linux = "aarch64-unknown-linux-musl";
    x86_64-darwin = "x86_64-apple-darwin";
    aarch64-darwin = "aarch64-apple-darwin";
  };

  system = stdenvNoCC.hostPlatform.system;
  unsupported = throw "bsk: unsupported platform ${system}";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "bsk";
  version = "0.3.2";

  # `fetchzip` rather than `fetchurl`: the tarball is unpacked at fetch time.
  # It has no top-level directory, so `stripRoot` is disabled.
  src = fetchzip {
    url = assetUrl finalAttrs.version finalAttrs.triple;
    hash = finalAttrs.passthru.hash;
    stripRoot = false;
  };

  triple = triples.${system} or unsupported;

  strictDeps = true;
  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bsk "$out/bin/bsk"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    # Deriving the version from the tag means a wrong tag fails here rather than
    # silently installing a differently versioned binary.
    got="$($out/bin/bsk --version)"
    if [ "$got" != "bsk ${finalAttrs.version}" ]; then
      echo "expected 'bsk ${finalAttrs.version}', got '$got'" >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  passthru = {
    inherit (finalAttrs) triple;
    hash = hashes.${system} or unsupported;
  };

  meta = {
    description = "Drive your browser from AI agents (BrowserSkill CLI and daemon)";
    longDescription = ''
      `bsk` is the CLI and background daemon for BrowserSkill. It talks to the
      BrowserSkill browser extension to let an agent read pages, fill forms and
      capture screenshots in the browser profile you are already signed in to.

      This package installs the prebuilt upstream release binary. Its self-update
      path writes next to the executable, which a store path does not allow, so
      updates come from this flake instead; see `BSK_AUTO_UPDATE`.
    '';
    homepage = "https://github.com/Tencent/BrowserSkill";
    changelog = "https://github.com/Tencent/BrowserSkill/releases/tag/cli-v${finalAttrs.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "bsk";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})
