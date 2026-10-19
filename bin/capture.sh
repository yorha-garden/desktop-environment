#!/usr/bin/env bash
# Pull the CURRENTLY LIVE configuration back into this repo.
#
# The inverse of deploy.sh. Use it after editing something in place (a shader
# constant, a bar colour) so the repo does not drift from what is actually running.
# Run `git diff` afterwards to see exactly what changed on the machine.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '  %s\n' "$*"; }

if [ -f "$HOME/.config/ghostty/config" ]; then
  cp "$HOME/.config/ghostty/config" "$REPO/config/ghostty/config"
  cp "$HOME"/.config/ghostty/shaders/*.glsl "$REPO/config/ghostty/shaders/" 2>/dev/null || true
  say "ghostty  <- ~/.config/ghostty"
fi
APPSUP="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
[ -f "$APPSUP" ] && { cp "$APPSUP" "$REPO/config/ghostty/config.ghostty"; say "ghostty  <- Application Support override"; }

[ -f "$HOME/.config/sketchybar/sketchybarrc" ] && \
  { cp "$HOME/.config/sketchybar/sketchybarrc" "$REPO/config/sketchybar/"; say "sketchybar <- ~/.config/sketchybar"; }

[ -f "$HOME/.config/aerospace/aerospace.toml" ] && \
  { cp "$HOME/.config/aerospace/aerospace.toml" "$REPO/config/aerospace/"; say "aerospace <- ~/.config/aerospace"; }

for f in palette.sh shell.zsh starship.toml fastfetch.jsonc logo.txt; do
  [ -f "$HOME/.config/yorha/$f" ] && cp "$HOME/.config/yorha/$f" "$REPO/config/shell/$f"
done
say "shell    <- ~/.config/yorha"

[ -f "$HOME/.config/yorha/wallpaper.svg" ] && \
  { cp "$HOME/.config/yorha/wallpaper.svg" "$REPO/assets/wallpaper.svg"; say "wallpaper <- ~/.config/yorha/wallpaper.svg"; }

echo
say "Captured. Review with: git -C $REPO diff"
