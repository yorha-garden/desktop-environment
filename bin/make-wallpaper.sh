#!/usr/bin/env bash
# Rasterize the light and dark wallpaper sources to content-addressed PNGs.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

source_for() {
  case "$1" in
    light) echo "$REPO/assets/wallpaper.svg" ;;
    dark) echo "$REPO/assets/wallpaper-dark.svg" ;;
    *) return 64 ;;
  esac
}

output_for() {
  local mode="$1" src hash
  src="$(source_for "$mode")" || return
  hash="$(shasum -a 256 "$src" | cut -c1-10)"
  echo "$REPO/assets/wallpaper-$mode-$hash.png"
}

validate_raster() {
  local out="$1" width height
  width="$(sips -g pixelWidth "$out" | awk '/pixelWidth/{print $2}')"
  height="$(sips -g pixelHeight "$out" | awk '/pixelHeight/{print $2}')"
  echo "  rendered ${width}x${height}  ($(basename "$out"))"
  [ "${width:-0}" -ge 2560 ] || {
    echo "  WARNING: viewport was clamped; wallpaper is lower-resolution than intended" >&2
  }
}

render() {
  local mode="$1" src out
  src="$(source_for "$mode")" || return
  [ -f "$src" ] || { echo "missing source: $src" >&2; return 1; }
  out="$(output_for "$mode")"

  if [ -f "$out" ]; then
    echo "  unchanged — reusing $(basename "$out")"
  else
    [ -x "$CHROME" ] || { echo "Google Chrome not found — it is the rasterizer" >&2; return 1; }
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb \
      --screenshot="$out" --window-size=5120,2880 "file://$src" >/dev/null 2>&1
  fi
  validate_raster "$out"
}

prune_mode() {
  local mode="$1" current
  current="$(basename "$(output_for "$mode")")"
  find "$REPO/assets" -maxdepth 1 -name "wallpaper-$mode-*.png" ! -name "$current" -delete 2>/dev/null || true
}

effective_mode() {
  if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = Dark ]; then
    echo dark
  else
    echo light
  fi
}

apply_wallpaper() {
  local mode="$1" out
  out="$(output_for "$mode")"
  osascript - "$out" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS
  killall WallpaperAgent 2>/dev/null || true
  echo "  wallpaper set: $out"
}

case "$#" in
  0)
    render light
    render dark
    apply_wallpaper "$(effective_mode)"
    prune_mode light
    prune_mode dark
    rm -f "$REPO/assets/wallpaper.png"
    ;;
  1)
    if [ "$1" = "--render-only" ]; then
      render light
      render dark
    else
      echo "usage: $0 [--render-only | --print-path light|dark]" >&2
      exit 64
    fi
    ;;
  2)
    if [ "$1" = "--print-path" ]; then
      source_for "$2" >/dev/null || { echo "mode must be light or dark" >&2; exit 64; }
      output_for "$2"
    else
      echo "usage: $0 [--render-only | --print-path light|dark]" >&2
      exit 64
    fi
    ;;
  *)
    echo "usage: $0 [--render-only | --print-path light|dark]" >&2
    exit 64
    ;;
esac
