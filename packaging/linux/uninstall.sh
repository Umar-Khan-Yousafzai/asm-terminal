#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ASM Terminal uninstaller (Linux)
# ---------------------------------------------------------------------------
set -eu

have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" = "0" ]; then PREFIX="${ASM_PREFIX:-/usr/local}"
else                           PREFIX="${ASM_PREFIX:-$HOME/.local}"; fi

SUDO=""
[ "$(id -u)" != "0" ] && [ -w "$PREFIX" ] || SUDO="${SUDO:-sudo}"
[ "$(id -u)" = "0" ] && SUDO=""

for f in \
    "$PREFIX/bin/asm" \
    "$PREFIX/bin/asm-terminal-launch" \
    "$PREFIX/share/applications/asm-terminal.desktop" \
    "$PREFIX/share/icons/hicolor/scalable/apps/asm-terminal.svg"; do
    if [ -e "$f" ]; then
        $SUDO rm -f "$f"
        echo "removed $f"
    fi
done

if have update-desktop-database; then $SUDO update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true; fi
if have gtk-update-icon-cache;   then $SUDO gtk-update-icon-cache "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true; fi

echo "ASM Terminal uninstalled."
