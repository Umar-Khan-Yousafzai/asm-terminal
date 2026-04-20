#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ASM Terminal installer (Linux)
# GUI via zenity when available, text prompts otherwise.
#
# Installs:
#   <bindir>/asm                       - the shell
#   <bindir>/asm-terminal-launch       - emulator-wrapping launcher
#   <share>/applications/asm-terminal.desktop
#   <share>/icons/hicolor/scalable/apps/asm-terminal.svg
#
# Default: per-user install into $HOME/.local, no sudo required.
# System-wide: run as root (sudo) to install into /usr/local.
# ---------------------------------------------------------------------------
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_BIN="${ASM_TERMINAL_BIN:-$HERE/../../terminal}"
SRC_LAUNCH="$HERE/asm-terminal-launch"
SRC_DESKTOP="$HERE/asm-terminal.desktop"
SRC_ICON="$HERE/asm-terminal.svg"

have() { command -v "$1" >/dev/null 2>&1; }
ui()   { [ -z "${ASM_NOGUI:-}" ] && have zenity; }

info() {
    if ui; then zenity --info --no-wrap --title="ASM Terminal" --text="$1" 2>/dev/null || true
    else        printf '[info] %s\n' "$1"; fi
}
err() {
    if ui; then zenity --error --no-wrap --title="ASM Terminal" --text="$1" 2>/dev/null || true
    else        printf '[error] %s\n' "$1" >&2; fi
    exit 1
}

if [ ! -f "$SRC_BIN" ]; then
    err "Binary not found at $SRC_BIN.\nBuild it first with 'make' in the repo root."
fi

# -----------------------------------------------------------------------------
# Choose install scope
# -----------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    DEFAULT_SCOPE="system"
    DEFAULT_PREFIX="/usr/local"
else
    DEFAULT_SCOPE="user"
    DEFAULT_PREFIX="$HOME/.local"
fi

SCOPE="${ASM_SCOPE:-$DEFAULT_SCOPE}"
if ui && [ -z "${ASM_SCOPE:-}" ]; then
    choice=$(zenity --list --title="ASM Terminal — Install" \
        --text="Choose install scope" \
        --column="Scope" --column="Description" \
        "user"   "Current user only  (~/.local,   no sudo)" \
        "system" "All users          (/usr/local, requires root)" \
        --height=200 --width=420 2>/dev/null) || exit 0
    SCOPE="$choice"
fi

case "$SCOPE" in
    user)   PREFIX="${ASM_PREFIX:-$HOME/.local}" ;;
    system) PREFIX="${ASM_PREFIX:-/usr/local}" ;;
    *)      err "Unknown scope: $SCOPE" ;;
esac

BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share"
APPDIR="$SHAREDIR/applications"
ICONDIR="$SHAREDIR/icons/hicolor/scalable/apps"

# Privilege escalation for system scope
SUDO=""
if [ "$SCOPE" = "system" ] && [ "$(id -u)" != "0" ]; then
    if have pkexec && ui; then SUDO="pkexec"
    elif have sudo;             then SUDO="sudo"
    else err "System install requires root. Re-run as root or install sudo/pkexec."; fi
fi

mkdirp()  { $SUDO mkdir -p "$1"; }
copy()    { $SUDO install -m "$1" "$2" "$3"; }

# -----------------------------------------------------------------------------
# Install files
# -----------------------------------------------------------------------------
mkdirp "$BINDIR"
mkdirp "$APPDIR"
mkdirp "$ICONDIR"

copy 0755 "$SRC_BIN"     "$BINDIR/asm"
copy 0755 "$SRC_LAUNCH"  "$BINDIR/asm-terminal-launch"
copy 0644 "$SRC_DESKTOP" "$APPDIR/asm-terminal.desktop"
copy 0644 "$SRC_ICON"    "$ICONDIR/asm-terminal.svg"

# Refresh caches (ignore failures — purely a UX improvement)
if have update-desktop-database; then $SUDO update-desktop-database "$APPDIR" >/dev/null 2>&1 || true; fi
if have gtk-update-icon-cache;   then $SUDO gtk-update-icon-cache "$SHAREDIR/icons/hicolor" >/dev/null 2>&1 || true; fi

info "ASM Terminal installed.\n\nBinary:    $BINDIR/asm\nLauncher:  $BINDIR/asm-terminal-launch\nDesktop:   $APPDIR/asm-terminal.desktop\n\nLaunch from your app menu or run 'asm' directly.\nIf the icon doesn't appear, log out and back in."
