#!/usr/bin/env bash
# Developer-only command: rasterize the SVG sources, then rebuild the committed HEIC.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

[ "$#" -eq 1 ] && [ "$1" = "--with-chrome" ] || {
  echo "usage: $0 --with-chrome" >&2
  exit 64
}
[ -x "$CHROME" ] || { echo "Google Chrome not found — it rasterizes the SVG sources" >&2; exit 1; }

workdir="$(mktemp -d "${TMPDIR:-/tmp}/yorha-system-wallpaper.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

for mode in light dark; do
  case "$mode" in
    light) source="$REPO/assets/wallpaper.svg" ;;
    dark) source="$REPO/assets/wallpaper-dark.svg" ;;
  esac
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb \
    --screenshot="$workdir/$mode.png" --window-size=5120,2880 "file://$source" >/dev/null 2>&1
done

swift "$REPO/bin/yorha-system-wallpaper.swift" --build \
  "$workdir/light.png" "$workdir/dark.png" "$REPO/assets/yorha-system.heic"
swift "$REPO/bin/yorha-system-wallpaper.swift" --inspect "$REPO/assets/yorha-system.heic"
