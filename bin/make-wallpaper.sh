#!/usr/bin/env bash
# Rasterize assets/wallpaper.svg -> assets/wallpaper.png and set it as the desktop.
#
# The PNG is gitignored: a 5120x2880 generated artifact, regenerated from the SVG
# whenever the source changes. The SVG is the source of truth.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/assets/wallpaper.svg"
OUT="$REPO/assets/wallpaper.png"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

[ -f "$SRC" ]   || { echo "missing source: $SRC" >&2; exit 1; }
[ -x "$CHROME" ] || { echo "Google Chrome not found — it is the rasterizer" >&2; exit 1; }

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb \
  --screenshot="$OUT" --window-size=5120,2880 "file://$SRC" >/dev/null 2>&1

# Chrome silently clamps oversized headless viewports on some displays. Verify
# rather than shipping a stretched wallpaper.
W=$(sips -g pixelWidth  "$OUT" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')
echo "  rendered ${W}x${H}"
[ "${W:-0}" -lt 2560 ] && echo "  WARNING: viewport was clamped; wallpaper is lower-resolution than intended" >&2

# Bind the path as an argv value. Splicing it into AppleScript source would let a
# path containing a double quote break out of the string literal.
osascript - "$OUT" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS

echo "  wallpaper set: $OUT"
