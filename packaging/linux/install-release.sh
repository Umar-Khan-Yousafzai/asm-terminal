#!/bin/sh
# ---------------------------------------------------------------------------
# ASM Terminal: install from a GitHub release (no build tools needed).
#
#   curl -fsSL https://github.com/Umar-Khan-Yousafzai/asm-terminal/releases/latest/download/install.sh | sh
#
# Downloads the release binary and desktop files, checks them against the
# release's SHA256SUMS, and installs:
#   <prefix>/bin/asm-terminal              the shell
#   <prefix>/bin/asm                       symlink to asm-terminal
#   <prefix>/bin/asm-terminal-launch       opens a terminal window running it
#   <prefix>/share/applications/asm-terminal.desktop
#   <prefix>/share/icons/hicolor/.../asm-terminal.{svg,png}
#
# <prefix> is ~/.local, or /usr/local when run as root.
#
# Options (environment variables):
#   ASM_VERSION=v2.1.0   install that release instead of the latest
#   ASM_PREFIX=/opt/asm  install somewhere else
#   ASM_NO_DESKTOP=1     binary only, no app-menu entry
#
# Uninstall:  curl -fsSL .../install.sh | sh -s -- --uninstall
# ---------------------------------------------------------------------------
set -eu

REPO="Umar-Khan-Yousafzai/asm-terminal"
BIN_ASSET="asm-terminal-linux-x86_64"
DESKTOP_ASSET="asm-terminal-linux-desktop.tar.gz"

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" = "0" ]; then PREFIX="${ASM_PREFIX:-/usr/local}"
else                           PREFIX="${ASM_PREFIX:-$HOME/.local}"; fi
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share"
APPDIR="$SHAREDIR/applications"
ICONROOT="$SHAREDIR/icons/hicolor"

refresh_caches() {
    if have update-desktop-database; then update-desktop-database "$APPDIR" >/dev/null 2>&1 || true; fi
    if have gtk-update-icon-cache;   then gtk-update-icon-cache "$ICONROOT" >/dev/null 2>&1 || true; fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    for f in "$BINDIR/asm-terminal" "$BINDIR/asm-terminal-launch" \
             "$APPDIR/asm-terminal.desktop" \
             "$ICONROOT/scalable/apps/asm-terminal.svg" \
             "$ICONROOT/symbolic/apps/asm-terminal-symbolic.svg" \
             "$ICONROOT"/*x*/apps/asm-terminal.png; do
        if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f"; say "removed $f"; fi
    done
    # Only remove `asm` if it is our symlink, never someone else's program.
    if [ -L "$BINDIR/asm" ] && [ "$(readlink "$BINDIR/asm")" = "asm-terminal" ]; then
        rm -f "$BINDIR/asm"; say "removed $BINDIR/asm"
    fi
    refresh_caches
    say "ASM Terminal uninstalled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ]   || die "this installer is for Linux (Windows: use the setup.exe from the release page)"
[ "$(uname -m)" = "x86_64" ]  || die "ASM Terminal is x86-64 only (this machine is $(uname -m))"

if have curl;   then fetch() { curl -fsSL -o "$2" "$1"; }
elif have wget; then fetch() { wget -q -O "$2" "$1"; }
else die "need curl or wget"; fi

if have sha256sum;  then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif have shasum;   then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif have openssl;  then sha256() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }
else die "need sha256sum, shasum or openssl to verify the download"; fi

if [ -n "${ASM_RELEASE_BASE:-}" ]; then
    BASE="$ASM_RELEASE_BASE"            # mirror or local test server
elif [ -n "${ASM_VERSION:-}" ]; then
    case "$ASM_VERSION" in v*) tag="$ASM_VERSION" ;; *) tag="v$ASM_VERSION" ;; esac
    BASE="https://github.com/$REPO/releases/download/$tag"
else
    BASE="https://github.com/$REPO/releases/latest/download"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------
say "Downloading ASM Terminal from $BASE ..."
fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" \
    || die "no SHA256SUMS in that release (releases before v2.1.0 can't be installed this way)"
fetch "$BASE/$BIN_ASSET" "$TMP/$BIN_ASSET" || die "could not download $BIN_ASSET"

verify() {
    want="$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")"
    [ -n "$want" ] || die "$1 is not listed in SHA256SUMS"
    got="$(sha256 "$TMP/$1")"
    [ "$want" = "$got" ] || die "checksum mismatch for $1 (download corrupted or tampered)"
}
verify "$BIN_ASSET"

DESKTOP=1
[ -n "${ASM_NO_DESKTOP:-}" ] && DESKTOP=0
if [ "$DESKTOP" = 1 ]; then
    if fetch "$BASE/$DESKTOP_ASSET" "$TMP/$DESKTOP_ASSET"; then
        verify "$DESKTOP_ASSET"
        mkdir -p "$TMP/d"
        tar -xzf "$TMP/$DESKTOP_ASSET" -C "$TMP/d"
    else
        say "note: this release has no $DESKTOP_ASSET; installing the binary only."
        DESKTOP=0
    fi
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
mkdir -p "$BINDIR"
install -m 0755 "$TMP/$BIN_ASSET" "$BINDIR/asm-terminal"
if [ -e "$BINDIR/asm" ] && [ ! -L "$BINDIR/asm" ] && ! cmp -s "$BINDIR/asm" "$BINDIR/asm-terminal"; then
    # An older ASM Terminal install copied the binary here as `asm`. Replace it.
    rm -f "$BINDIR/asm"
fi
ln -sf asm-terminal "$BINDIR/asm"
say "Installed $BINDIR/asm-terminal (and $BINDIR/asm)"

if [ "$DESKTOP" = 1 ]; then
    D="$TMP/d"
    mkdir -p "$APPDIR" "$ICONROOT/scalable/apps"
    install -m 0755 "$D/asm-terminal-launch" "$BINDIR/asm-terminal-launch"
    # Absolute Exec path: the desktop session's PATH often lacks ~/.local/bin.
    sed -e "s|^TryExec=.*|TryExec=$BINDIR/asm-terminal-launch|" \
        -e "s|^Exec=.*|Exec=$BINDIR/asm-terminal-launch|" \
        "$D/asm-terminal.desktop" > "$APPDIR/asm-terminal.desktop"
    chmod 0644 "$APPDIR/asm-terminal.desktop"
    install -m 0644 "$D/asm-terminal.svg" "$ICONROOT/scalable/apps/asm-terminal.svg"
    for png in "$D"/icons/hicolor/*/apps/asm-terminal.png; do
        [ -f "$png" ] || continue
        size="$(basename "$(dirname "$(dirname "$png")")")"
        mkdir -p "$ICONROOT/$size/apps"
        install -m 0644 "$png" "$ICONROOT/$size/apps/asm-terminal.png"
    done
    if [ -f "$D/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg" ]; then
        mkdir -p "$ICONROOT/symbolic/apps"
        install -m 0644 "$D/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg" \
            "$ICONROOT/symbolic/apps/asm-terminal-symbolic.svg"
    fi
    refresh_caches
    say "Added ASM Terminal to your app menu (search \"ASM\")."
fi

# ---------------------------------------------------------------------------
# PATH check: another `asm` (pwntools ships /usr/bin/asm) may win.
# ---------------------------------------------------------------------------
found="$(command -v asm 2>/dev/null || true)"
case ":$PATH:" in
    *":$BINDIR:"*) on_path=1 ;;
    *)             on_path=0 ;;
esac
say ""
if [ "$on_path" = 0 ]; then
    say "$BINDIR is not on your PATH. Add it:"
    say "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.bashrc"
    say "then open a new terminal."
elif [ -n "$found" ] && [ "$(readlink -f "$found")" != "$(readlink -f "$BINDIR/asm-terminal")" ]; then
    say "note: 'asm' currently runs $found, not ASM Terminal."
    say "Use 'asm-terminal', or open a new terminal. If 'asm' is still the other"
    say "program there, put $BINDIR first in PATH in ~/.bashrc."
else
    say "Run: asm"
fi
