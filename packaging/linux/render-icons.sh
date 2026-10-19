#!/bin/sh
# ---------------------------------------------------------------------------
# render-icons.sh
# Regenerate the PNG icons in packaging/linux/icons/ from asm-terminal.svg.
# Only needed after editing the SVG. The PNGs are committed, so a normal
# build/install never runs this.
#
# Uses rsvg-convert when present, otherwise headless Chromium + Python PIL.
# ---------------------------------------------------------------------------
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SVG="$HERE/asm-terminal.svg"
OUT="$HERE/icons/hicolor"
SIZES="16 22 24 32 48 64 96 128 192 256 512"

if command -v rsvg-convert >/dev/null 2>&1; then
    for s in $SIZES; do
        mkdir -p "$OUT/${s}x${s}/apps"
        rsvg-convert -w "$s" -h "$s" "$SVG" -o "$OUT/${s}x${s}/apps/asm-terminal.png"
    done
    echo "Rendered with rsvg-convert into $OUT"
    exit 0
fi

CHROME="${CHROME:-}"
for c in chromium chromium-browser google-chrome /opt/pw-browsers/chromium; do
    [ -n "$CHROME" ] && break
    command -v "$c" >/dev/null 2>&1 && CHROME="$c"
done
[ -n "$CHROME" ] || { echo "need rsvg-convert or chromium" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '<html><body style="margin:0;background:transparent"><img src="file://%s" width="1024" height="1024" style="display:block"></body></html>' \
    "$SVG" > "$TMP/r.html"
"$CHROME" --headless --no-sandbox --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 --window-size=1024,1400 \
    --screenshot="$TMP/master.png" "file://$TMP/r.html" >/dev/null 2>&1

python3 - "$TMP/master.png" "$OUT" $SIZES <<'PY'
import os, sys
from PIL import Image
master, out, sizes = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3:]]
m = Image.open(master).crop((0, 0, 1024, 1024))
for s in sizes:
    d = os.path.join(out, "%dx%d" % (s, s), "apps")
    os.makedirs(d, exist_ok=True)
    m.resize((s, s), Image.LANCZOS).save(os.path.join(d, "asm-terminal.png"), optimize=True)
PY
echo "Rendered with $CHROME into $OUT"
