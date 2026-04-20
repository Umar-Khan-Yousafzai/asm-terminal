#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build an AppImage for ASM Terminal.
# Requires: appimagetool (downloaded automatically to ./_tools if absent)
# Output:   asm-terminal-2.0.0-x86_64.AppImage in the repo root
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPDIR="$HERE/AppDir"
VERSION="${APP_VERSION:-2.0.0}"
OUT="$REPO/asm-terminal-${VERSION}-x86_64.AppImage"

BIN="$REPO/terminal"
[ -x "$BIN" ] || { echo "build terminal first: (cd $REPO && make)" >&2; exit 1; }

rm -rf "$APPDIR"
install -d "$APPDIR/usr/bin"
install -d "$APPDIR/usr/share/applications"
install -d "$APPDIR/usr/share/icons/hicolor/scalable/apps"

install -m 0755 "$BIN"                             "$APPDIR/usr/bin/asm"
install -m 0755 "$HERE/../linux/asm-terminal-launch" "$APPDIR/usr/bin/asm-terminal-launch"
install -m 0644 "$HERE/../linux/asm-terminal.desktop" "$APPDIR/asm-terminal.desktop"
install -m 0644 "$HERE/../linux/asm-terminal.svg"  "$APPDIR/asm-terminal.svg"
install -m 0644 "$HERE/../linux/asm-terminal.svg"  "$APPDIR/usr/share/icons/hicolor/scalable/apps/asm-terminal.svg"
cp "$APPDIR/asm-terminal.desktop" "$APPDIR/usr/share/applications/asm-terminal.desktop"

cat >"$APPDIR/AppRun" <<'RUN'
#!/usr/bin/env sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/asm-terminal-launch" "$@"
RUN
chmod +x "$APPDIR/AppRun"

# Fetch appimagetool if missing
TOOL="$HERE/_tools/appimagetool"
if [ ! -x "$TOOL" ]; then
    mkdir -p "$HERE/_tools"
    echo "Downloading appimagetool ..."
    curl -L -o "$TOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
fi

ARCH=x86_64 "$TOOL" "$APPDIR" "$OUT"
echo "Built: $OUT"
sha256sum "$OUT"
