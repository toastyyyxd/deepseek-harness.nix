#!/usr/bin/env bash
# agents-anywhere-uv -- NixOS shim for the Agents Anywhere DSH plugin.
#
# The plugin configures DSH to launch the Connector as
#
#     uv run --directory <bundled payload> anywhere-cli rpc --config <...>
#
# where <bundled payload> is inside the read-only Nix store. Three things about
# that cannot work on NixOS for an unprivileged, nix-ld-less user, so this shim
# -- which is handed to the plugin as its `uvPath` -- repairs each one at
# runtime. It is the runtime equivalent of the autoPatchelfHook treatment the
# dsh-subagent-claude-code / dsh-subagent-codex bundles already apply at build
# time; the difference is that these files are downloaded after the build.
#
# 1. `uv run` writes `uv.lock` into the project directory, which is read-only:
#       error: failed to write to file `.../bundled-connector/uv.lock`:
#       Permission denied (os error 13)
#    Mirror the payload into a writable per-user directory, keyed on the store
#    path, and point --directory at the mirror.
#
# 2. uv's managed CPython is a python-build-standalone build and is refused by
#    stub-ld: "Could not start dynamically linked executable". Pin the nixpkgs
#    interpreter instead so nothing needs downloading.
#
# 3. The wheels vendor generic-Linux executables -- Claude Code
#    (claude_agent_sdk/_bundled/claude), codex's bundled zsh and ruff -- whose
#    PT_INTERP is /lib64/ld-linux-x86-64.so.2. The kernel resolves PT_INTERP
#    before any library lookup, so LD_LIBRARY_PATH cannot fix these; repoint
#    the interpreter at the nixpkgs loader. Only the interpreter may be
#    touched: these are Node single-executable-application binaries, and
#    patchelf --add-rpath corrupts them (the Claude CLI segfaults).
#
# Nothing here may write to stdout: the plugin parses this process's stdout as
# the Connector's JSON-RPC stream. All diagnostics go to stderr.

set -euo pipefail

# Filled in by the Nix wrapper; every value is overridable for testing.
REAL_UV="${AA_REAL_UV:-}"
[ -n "$REAL_UV" ] || REAL_UV="$(command -v uv || true)"
PYTHON="${AA_PYTHON:-@python@}"
[ -n "$PYTHON" ] || PYTHON="$(command -v python3 || true)"
PATCHELF="${AA_PATCHELF:-}"
[ -n "$PATCHELF" ] || PATCHELF="$(command -v patchelf || true)"
# Empty on Darwin, where there is no /lib64 stub to work around.
LOADER="${AA_LOADER:-@loader@}"
NCURSES_LIB="${AA_NCURSES_LIB:-@ncurses@/lib}"
STATE_ROOT="${AA_CONNECTOR_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/agents-anywhere/connector-src}"

if [ -z "$REAL_UV" ] || [ ! -x "$REAL_UV" ]; then
  echo "agents-anywhere-uv: cannot find uv" >&2
  exit 127
fi

# `uv --version` is the plugin's preflight; forward anything that is not `run`.
if [ "${1:-}" != "run" ]; then
  exec "$REAL_UV" "$@"
fi

args=("$@")
src=""
dir_index=-1
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = "--directory" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
    src="${args[$((i + 1))]}"
    dir_index=$((i + 1))
  fi
done

# ---- 1. mirror the read-only Connector payload ------------------------------

if [ -n "$src" ] && [ -f "$src/pyproject.toml" ]; then
  stamp="$STATE_ROOT/.source"
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$src" ]; then
    mkdir -p "$(dirname "$STATE_ROOT")"
    tmp="$(mktemp -d "${STATE_ROOT}.tmp.XXXXXX")"
    cp -rL "$src/." "$tmp/"
    chmod -R u+w "$tmp"
    rm -rf "$STATE_ROOT"
    mv "$tmp" "$STATE_ROOT"
    printf '%s' "$src" >"$stamp"
  fi
  args[dir_index]="$STATE_ROOT"
fi

# ---- 2. environment ---------------------------------------------------------

if [ -n "$PYTHON" ]; then
  export UV_PYTHON_DOWNLOADS="${UV_PYTHON_DOWNLOADS:-never}"
  export UV_PYTHON="${UV_PYTHON:-$PYTHON}"
fi
# Copies, never hardlinks, so patching a file in the venv cannot corrupt the
# shared uv cache and vice versa.
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"
# codex's bundled zsh needs libtinfo; the Connector inherits this.
if [ -d "$NCURSES_LIB" ]; then
  export LD_LIBRARY_PATH="$NCURSES_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

venv="${UV_PROJECT_ENVIRONMENT:-$STATE_ROOT/.venv}"
sync_stamp="$STATE_ROOT/.venv-stamp"

# ---- 3. sync only when something actually changed ---------------------------

# uv verifies installed files against the wheel RECORD, so the interpreter edit
# below reads as "modified" and an unconditional `uv sync` on every start would
# reinstall the payload and undo it. Gate the sync on the environment already
# matching this source and lock, then leave the environment alone.
lock_hash=""
if [ -f "$STATE_ROOT/uv.lock" ]; then
  lock_hash="$(sha256sum "$STATE_ROOT/uv.lock" 2>/dev/null | cut -d' ' -f1 || true)"
fi
want="$(printf '%s\n%s' "$src" "$lock_hash" | sha256sum | cut -d' ' -f1)"

if [ -f "$STATE_ROOT/pyproject.toml" ] \
  && { [ ! -d "$venv" ] || [ "$(cat "$sync_stamp" 2>/dev/null || true)" != "$want" ]; }; then
  "$REAL_UV" sync --directory "$STATE_ROOT" 1>&2

  if [ -n "$LOADER" ] && [ -e "$LOADER" ] && [ -n "$PATCHELF" ] && [ -x "$PATCHELF" ] && [ -d "$venv" ]; then
    while IFS= read -r -d '' candidate; do
      # Only ELF files carry a PT_INTERP; skip everything else cheaply.
      [ "$(head -c4 "$candidate" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
      current="$("$PATCHELF" --print-interpreter "$candidate" 2>/dev/null || true)"
      [ -n "$current" ] || continue
      [ "$current" = "$LOADER" ] && continue
      echo "agents-anywhere-uv: $candidate: $current -> $LOADER" >&2
      "$PATCHELF" --set-interpreter "$LOADER" "$candidate" 1>&2 || true
    done < <(find "$venv" -type f -perm -u+x -print0 2>/dev/null || true)
  fi

  # Stamp from the post-sync lock so a non-syncing start computes the same value.
  lock_hash=""
  if [ -f "$STATE_ROOT/uv.lock" ]; then
    lock_hash="$(sha256sum "$STATE_ROOT/uv.lock" 2>/dev/null | cut -d' ' -f1 || true)"
  fi
  printf '%s\n%s' "$src" "$lock_hash" | sha256sum | cut -d' ' -f1 >"$sync_stamp"
fi

# ---- run --------------------------------------------------------------------

exec "$REAL_UV" run --no-sync "${args[@]:1}"
