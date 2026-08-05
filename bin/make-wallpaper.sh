#!/usr/bin/env bash
# Apply the committed appearance-aware HEIC. Regeneration is developer-only.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WALLPAPER="$REPO/assets/yorha-system.heic"
INSPECTOR="$REPO/bin/yorha-system-wallpaper.swift"

verify() {
  swift "$INSPECTOR" --inspect "$WALLPAPER" >/dev/null
}

apply_wallpaper() {
  osascript - "$WALLPAPER" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS
  killall WallpaperAgent 2>/dev/null || true
  echo "  wallpaper set: $WALLPAPER"
}

case "$#" in
  0)
    verify
    apply_wallpaper
    ;;
  1)
    case "$1" in
      --render-only|--verify) verify ;;
      --print-path) printf '%s\n' "$WALLPAPER" ;;
      *) echo "usage: $0 [--verify|--print-path]" >&2; exit 64 ;;
    esac
    ;;
  2)
    if [ "$1" = "--print-path" ] && { [ "$2" = light ] || [ "$2" = dark ]; }; then
      printf '%s\n' "$WALLPAPER"
    else
      echo "usage: $0 [--verify|--print-path]" >&2
      exit 64
    fi
    ;;
  *)
    echo "usage: $0 [--verify|--print-path]" >&2
    exit 64
    ;;
esac
