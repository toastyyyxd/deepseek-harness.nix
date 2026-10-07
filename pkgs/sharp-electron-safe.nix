{ runCommand, fetchurl, jq }:

# The electron-safe `sharp`, unpacked as `<out>/package`.
#
# `sharp`/`libvips` bundle a private `glib` inside `libvips-cpp.so` but do not hide
# its symbols. Electron's Linux binary dynamically links the system `glib` for GTK
# integration, so the two copies collide inside one process and the host dies with
# SIGSEGV (exit 139) the first time an image is decoded -- `read_image`, or
# attaching an image. No configuration flag avoids it; it is
# electron/electron#46323, unresolved upstream.
#
# `@janhapke/sharp-electron` is the same sharp release rebuilt with the collision
# fixed at the linker level: `libvips-cpp.so` sits beside the addon and the addon's
# RUNPATH is `$ORIGIN`. This derivation makes it a drop-in for a `node_modules/sharp`
# directory.
#
# The manifest is relabelled to plain `sharp@0.35.3` and the shim's runtime and type
# entry points are pointed at the bundled `linux-x64/sharp` tree, so the package is
# self-contained: its published `sharp-upstream` fallback dependency is not vendored
# here, and consumers type-check with `import type { Sharp } from 'sharp'`.
#
# Kept in step with the `sharp@0.35.3` entry in `pkgs/dsh-workspace/package.nix`,
# which solves the same problem for the vendored pnpm tree by substituting the
# published tarball. That override covers `resources/host`; this one covers every
# copy in the assembled app tree, which is where the Host actually resolves `sharp`
# from (its entry script lives under `resources/app/node_modules/dsh-plugin-desktop`).
runCommand "sharp-electron-safe"
  {
    src = fetchurl {
      url = "https://registry.npmjs.org/@janhapke/sharp-electron/-/sharp-electron-0.35.4-electron.1.tgz";
      hash = "sha256-r5Z8zJ4wbjapLNAXvGEhqwZSHI/E07xkLT6Q9i4+RMY=";
    };
    nativeBuildInputs = [ jq ];
  }
  ''
    mkdir -p "$out"
    tar -xzf "$src" -C "$out"

    jq '.name = "sharp"
      | .version = "0.35.3"
      | del(.dependencies."sharp-upstream")' \
      "$out/package/package.json" > "$out/package/package.json.tmp"
    mv "$out/package/package.json.tmp" "$out/package/package.json"

    cat > "$out/package/index.js" <<'EOF'
    module.exports = require('./linux-x64/sharp/dist/index.cjs');
    EOF

    cat > "$out/package/index.d.ts" <<'EOF'
    import sharp = require('./linux-x64/sharp/dist/index.cjs');
    export = sharp;
    EOF
  ''
