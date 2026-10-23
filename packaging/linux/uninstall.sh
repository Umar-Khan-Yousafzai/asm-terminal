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

# Is $1 ours to remove: a link to asm-terminal or an older ASM Terminal copy?
# Another program named asm (pwntools) stays.
asm_is_ours() {
    if [ -L "$1" ]; then
        case "$(readlink "$1")" in asm-terminal|*/asm-terminal) return 0 ;; *) return 1 ;; esac
    fi
    [ -f "$1" ] && grep -aq 'ASM Terminal v' "$1"
}

for f in \
    "$PREFIX/bin/asm-terminal" \
    "$PREFIX/bin/asm-terminal-launch" \
    "$PREFIX/share/applications/asm-terminal.desktop" \
    "$PREFIX/share/icons/hicolor/scalable/apps/asm-terminal.svg" \
    "$PREFIX"/share/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg \
    "$PREFIX"/share/icons/hicolor/*x*/apps/asm-terminal.png; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        $SUDO rm -f "$f"
        echo "removed $f"
    fi
done

if asm_is_ours "$PREFIX/bin/asm"; then
    $SUDO rm -f "$PREFIX/bin/asm"
    echo "removed $PREFIX/bin/asm"
fi

if have update-desktop-database; then $SUDO update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true; fi
if have gtk-update-icon-cache;   then $SUDO gtk-update-icon-cache "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true; fi

echo "ASM Terminal uninstalled."
