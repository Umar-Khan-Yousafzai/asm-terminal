#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build a .deb package for ASM Terminal (per-user OR system install).
# Produces dist/asm-terminal_<version>_amd64.deb in the repo root.
# Requires: dpkg-deb  (apt-get install dpkg-dev)
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VERSION="${APP_VERSION:-2.0.0}"
PKG="asm-terminal"
STAGE="$HERE/_stage"
DEB="$REPO/dist/${PKG}_${VERSION}_amd64.deb"

BIN="$REPO/terminal"
[ -x "$BIN" ] || { echo "build terminal first: (cd $REPO && make)" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN"
mkdir -p "$STAGE/usr/bin"
mkdir -p "$STAGE/usr/share/applications"
mkdir -p "$STAGE/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$STAGE/usr/share/doc/$PKG"

install -m 0755 "$BIN"                                   "$STAGE/usr/bin/asm"
install -m 0755 "$HERE/../linux/asm-terminal-launch"     "$STAGE/usr/bin/asm-terminal-launch"
install -m 0644 "$HERE/../linux/asm-terminal.desktop"    "$STAGE/usr/share/applications/asm-terminal.desktop"
install -m 0644 "$HERE/../linux/asm-terminal.svg"        "$STAGE/usr/share/icons/hicolor/scalable/apps/asm-terminal.svg"

if [ -f "$REPO/README.md" ]; then cp "$REPO/README.md" "$STAGE/usr/share/doc/$PKG/README.md"; fi

INSTALLED_SIZE=$(du -sk "$STAGE" | awk '{print $1}')

cat >"$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Umar Khan Yousafzai <ionkhan@gmail.com>
Installed-Size: $INSTALLED_SIZE
Homepage: https://github.com/Umar-Khan-Yousafzai/asm-terminal
Description: x86-64 assembly shell (no libc, raw syscalls)
 ASM Terminal is a full-featured shell written entirely in x86-64 NASM
 assembly. 30+ built-in commands, history, tab completion, job control,
 themes, and Linux/Windows cross-platform support. Statically linked ELF64,
 ~73 KB.
EOF

cat >"$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod +x "$STAGE/DEBIAN/postinst"

cat >"$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "purge" ] || [ "$1" = "remove" ]; then
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q /usr/share/icons/hicolor || true
    fi
fi
EOF
chmod +x "$STAGE/DEBIAN/postrm"

mkdir -p "$REPO/dist"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
echo "Built: $DEB"
dpkg-deb -I "$DEB"
sha256sum "$DEB"
