#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build an AppImage for ASM Terminal.
# Requires: appimagetool (downloaded automatically to ./_tools if absent)
# Output:   asm-terminal-<version>-x86_64.AppImage in the repo root
#
# The tool and the AppImage runtime it embeds are pinned releases, each checked
# against a SHA-256 before use: this script is part of the release job that
# builds the binary users download. appimagetool would otherwise fetch the
# runtime from a moving "continuous" tag on every build.
# ---------------------------------------------------------------------------
set -euo pipefail
umask 022

TOOL_VERSION="1.9.1"
TOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/$TOOL_VERSION/appimagetool-x86_64.AppImage"
RUNTIME_VERSION="20251108"
RUNTIME_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VERSION/runtime-x86_64"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPDIR="$HERE/AppDir"
VERSION="${APP_VERSION:-$(sed -n 's/.*ASM_VERSION "\(.*\)".*/\1/p' "$REPO/version.inc")}"
OUT="$REPO/asm-terminal-${VERSION}-x86_64.AppImage"

BIN="$REPO/terminal"
[ -x "$BIN" ] || { echo "build terminal first: (cd $REPO && make)" >&2; exit 1; }

rm -rf "$APPDIR"
install -d "$APPDIR/usr/bin"
install -d "$APPDIR/usr/share/applications"
install -d "$APPDIR/usr/share/icons/hicolor/scalable/apps"

install -m 0755 "$BIN"                             "$APPDIR/usr/bin/asm-terminal"
ln -sf asm-terminal                                "$APPDIR/usr/bin/asm"
install -m 0755 "$HERE/../linux/asm-terminal-launch" "$APPDIR/usr/bin/asm-terminal-launch"
install -m 0644 "$HERE/../linux/asm-terminal.desktop" "$APPDIR/asm-terminal.desktop"
install -m 0644 "$HERE/../linux/asm-terminal.svg"  "$APPDIR/asm-terminal.svg"
install -m 0644 "$HERE/../linux/asm-terminal.svg"  "$APPDIR/usr/share/icons/hicolor/scalable/apps/asm-terminal.svg"
cp -r "$HERE/../linux/icons/hicolor/."             "$APPDIR/usr/share/icons/hicolor/"
cp "$APPDIR/asm-terminal.desktop" "$APPDIR/usr/share/applications/asm-terminal.desktop"
install -d "$APPDIR/usr/share/doc/asm-terminal"
install -m 0644 "$REPO/LICENSE"                    "$APPDIR/usr/share/doc/asm-terminal/LICENSE"

cat >"$APPDIR/AppRun" <<'RUN'
#!/usr/bin/env sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/asm-terminal-launch" "$@"
RUN
chmod +x "$APPDIR/AppRun"

# fetch_pinned FILE URL SHA256: download unless FILE already has that hash, and
# fail (leaving nothing behind) if what arrives does not. A leftover file from
# an earlier run or a failed download must never be used unverified.
fetch_pinned() {
    local file="$1" url="$2" want="$3"
    have_hash() { [ -f "$file" ] && [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$want" ]; }
    have_hash && return 0
    mkdir -p "$(dirname "$file")"
    rm -f "$file"
    echo "Downloading $(basename "$url") ..."
    curl -fsSL --proto '=https' --proto-redir '=https' -o "$file" "$url"
    have_hash || { rm -f "$file"; echo "$(basename "$url") does not match the expected SHA-256" >&2; exit 1; }
}

TOOL="$HERE/_tools/appimagetool-$TOOL_VERSION"
RUNTIME="$HERE/_tools/runtime-$RUNTIME_VERSION-x86_64"
fetch_pinned "$TOOL"    "$TOOL_URL"    "$TOOL_SHA256"
fetch_pinned "$RUNTIME" "$RUNTIME_URL" "$RUNTIME_SHA256"
chmod +x "$TOOL"

# Run without FUSE: build machines often have none
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --runtime-file "$RUNTIME" "$APPDIR" "$OUT"
echo "Built: $OUT"
sha256sum "$OUT"
