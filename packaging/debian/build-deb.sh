#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build a .deb package for ASM Terminal (per-user OR system install).
# Produces dist/asm-terminal_<version>_amd64.deb in the repo root.
# Requires: dpkg-deb  (apt-get install dpkg-dev)
# ---------------------------------------------------------------------------
set -euo pipefail
umask 022   # dpkg-deb refuses control directories that are not 0755

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VERSION="${APP_VERSION:-$(sed -n 's/.*ASM_VERSION "\(.*\)".*/\1/p' "$REPO/version.inc")}"
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

install -m 0755 "$BIN"                                   "$STAGE/usr/bin/asm-terminal"
ln -sf asm-terminal                                      "$STAGE/usr/bin/asm"
install -m 0755 "$HERE/../linux/asm-terminal-launch"     "$STAGE/usr/bin/asm-terminal-launch"
install -m 0644 "$HERE/../linux/asm-terminal.desktop"    "$STAGE/usr/share/applications/asm-terminal.desktop"
install -m 0644 "$HERE/../linux/asm-terminal.svg"        "$STAGE/usr/share/icons/hicolor/scalable/apps/asm-terminal.svg"
cp -r "$HERE/../linux/icons/hicolor/."                   "$STAGE/usr/share/icons/hicolor/"

if [ -f "$REPO/README.md" ]; then cp "$REPO/README.md" "$STAGE/usr/share/doc/$PKG/README.md"; fi

# Debian copyright file (machine-readable format) from the repository LICENSE
{
    printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n'
    printf 'Upstream-Name: asm-terminal\n'
    printf 'Source: https://github.com/Umar-Khan-Yousafzai/asm-terminal\n\n'
    printf 'Files: *\n'
    printf 'Copyright: %s\n' "$(sed -n 's/^Copyright (c) //p' "$REPO/LICENSE")"
    printf 'License: MIT\n\nLicense: MIT\n'
    sed -e '1,4d' -e 's/^$/./' -e 's/^/ /' "$REPO/LICENSE"
} > "$STAGE/usr/share/doc/$PKG/copyright"

# Whatever the checkout's umask was, installed files must be world-readable
chmod -R u+rwX,go+rX,go-w "$STAGE"

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
 assembly. Built-in commands, pipelines, scripting, history, tab completion,
 job control and themes. A single statically linked ELF64 binary.
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
