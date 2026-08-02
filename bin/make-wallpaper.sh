#!/usr/bin/env bash
# Rasterize assets/wallpaper.svg -> assets/wallpaper-<hash>.png and set it as the desktop.
#
# WHY THE HASH IN THE FILENAME: macOS caches the desktop picture BY PATH. Setting
# the same path again after editing the file is a no-op — the old rendition keeps
# showing, with no error anywhere. Several wallpaper edits appeared to "not apply"
# for exactly this reason. A content-derived filename means every change produces a
# path the window server has never cached.
#
# The PNGs are gitignored (assets/wallpaper*.png); the SVG is the source of truth.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/assets/wallpaper.svg"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

[ -f "$SRC" ]    || { echo "missing source: $SRC" >&2; exit 1; }
[ -x "$CHROME" ] || { echo "Google Chrome not found — it is the rasterizer" >&2; exit 1; }

HASH="$(shasum -a 256 "$SRC" | cut -c1-10)"
OUT="$REPO/assets/wallpaper-$HASH.png"

if [ -f "$OUT" ]; then
  echo "  unchanged (hash $HASH) — reusing existing raster"
else
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb \
    --screenshot="$OUT" --window-size=5120,2880 "file://$SRC" >/dev/null 2>&1

  # Chrome silently clamps oversized headless viewports on some displays. Verify
  # rather than shipping a stretched wallpaper.
  W=$(sips -g pixelWidth  "$OUT" | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')
  echo "  rendered ${W}x${H}  (hash $HASH)"
  [ "${W:-0}" -lt 2560 ] && echo "  WARNING: viewport was clamped; wallpaper is lower-resolution than intended" >&2
fi

# Bind the path as an argv value. Splicing it into AppleScript source would let a
# path containing a double quote break out of the string literal.
osascript - "$OUT" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS

# On macOS 26 the wallpaper is owned by WallpaperAgent, and the AppleScript set
# alone does not always make it re-read: System Events kept reporting a path that
# had already been deleted. Restarting the agent forces it. It relaunches on
# demand, so this is safe and the desktop does not flicker.
killall WallpaperAgent 2>/dev/null || true

# Drop superseded rasters so assets/ does not accumulate 10 MB files.
find "$REPO/assets" -maxdepth 1 -name 'wallpaper-*.png' ! -name "$(basename "$OUT")" -delete 2>/dev/null || true
rm -f "$REPO/assets/wallpaper.png"   # legacy un-hashed name

echo "  wallpaper set: $OUT"
