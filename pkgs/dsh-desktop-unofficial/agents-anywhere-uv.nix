{
  lib,
  stdenv,
  writeShellApplication,
  uv,
  python312,
  patchelf,
  ncurses,
  coreutils,
  findutils,
}:

# Wrapper that DSH Desktop hands to the Agents Anywhere plugin as `uvPath`.
#
# The plugin launches the Connector as `uv run --directory <payload> ...`, where
# the payload sits in the read-only store. agents-anywhere-uv.sh repairs the
# three things that makes impossible on NixOS -- a read-only project directory,
# uv's python-build-standalone interpreter, and vendored generic-Linux ELF
# binaries -- without requiring host-level nix-ld. Read its header for the full
# rationale.
#
# This is the runtime counterpart of the autoPatchelfHook that
# dsh-subagent-claude-code applies at build time: the same interpreter fix,
# applied to wheels that only exist after `uv sync` has run.
writeShellApplication {
  name = "agents-anywhere-uv";
  runtimeInputs = [
    uv
    coreutils
    findutils
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ patchelf ];
  text =
    builtins.replaceStrings
      [ "@loader@" "@python@" "@ncurses@" ]
      [
        # Empty on Darwin, where there is no /lib64 stub to work around.
        (lib.optionalString stdenv.hostPlatform.isLinux stdenv.cc.bintools.dynamicLinker)
        "${python312}/bin/python3"
        "${lib.getLib ncurses}"
      ]
      (builtins.readFile ./agents-anywhere-uv.sh);
}
