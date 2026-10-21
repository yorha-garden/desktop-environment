#!/usr/bin/env bash
# Build and install YoRHa Desktop (the native widget layer and bar), then retire
# what it replaces: Übersicht, SketchyBar, and the helpers built around SketchyBar.
#   bin/install-desktop.sh [plist-template]
# deploy.sh calls this; it is also safe to run on its own. Idempotent.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.yorha.desktop"
TEMPLATE="${1:-$REPO/launchd/$LABEL.plist}"
DOMAIN="gui/$(id -u)"
BIN="$HOME/.config/yorha/bin/yorha-desktop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

say() { printf '  %s\n' "$*"; }

mkdir -p "$HOME/.config/yorha/bin" "$HOME/.config/yorha/logs" "$HOME/Library/LaunchAgents"

# Build beside the destination and swap it in, so a failed build leaves the
# installed binary untouched.
TMP="$BIN.tmp.$$"
trap 'rm -f "$TMP"' EXIT
"$REPO/bin/build-desktop.sh" "$TMP" >/dev/null
mv "$TMP" "$BIN"

sed -e "s|HOME_PATH|$HOME|g" "$TEMPLATE" > "$PLIST"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
# bootout returns before launchd finishes unloading; bootstrap fails until it has.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
# Respect `yorha-watcher off desktop`: launchd refuses to bootstrap a disabled job.
if launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -q "\"$LABEL\" => disabled"; then
  say "desktop  -> installed but switched off (yorha-watcher on desktop)"
else
  launchctl bootstrap "$DOMAIN" "$PLIST"
  say "desktop  -> loaded (native widget layer, starts at login)"
fi

# --- retire Übersicht --------------------------------------------------------
# The app stays installed; only what YoRHa set up around it is removed.
OLD="com.yorha.ubersicht-watchdog"
launchctl bootout "$DOMAIN/$OLD" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$OLD.plist" "$HOME/.config/yorha/bin/ubersicht-watchdog.sh"
osascript -e 'quit app id "tracesOf.Uebersicht"' >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to delete (every login item whose name is "Übersicht")' \
  >/dev/null 2>&1 || true
say "übersicht -> retired (watchdog removed, app quit and out of login items)"

# --- retire SketchyBar -------------------------------------------------------
# The bar is drawn by YoRHa Desktop now. The formula and ~/.config/sketchybar stay
# (backup/restore owns that path); only the service and YoRHa's helpers go: the
# minute trigger, and the appearance watcher whose coordinator only recoloured it.
BREW="$(command -v brew || true)"
[ -z "$BREW" ] || "$BREW" services stop sketchybar >/dev/null 2>&1 || true
pkill -x sketchybar >/dev/null 2>&1 || true
for OLD in com.yorha.sketchybar-minute com.yorha.appearance-watcher; do
  launchctl bootout "$DOMAIN/$OLD" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/$OLD.plist"
done
rm -f "$HOME/.config/yorha/bin/yorha-appearance-watcher" "$HOME/.config/yorha/bin/apply-appearance.sh" \
  "$HOME/.config/yorha/logs/appearance.log" "$HOME/.config/yorha/cache/sketchybar-minute.stderr.log"
# The appearance tree keeps only the wallpaper HEIC that deploy.sh assigns.
APPEARANCE="$HOME/.config/yorha/appearance"
rm -rf "$APPEARANCE/yorha-icon-light.png" "$APPEARANCE/yorha-icon-dark.png" \
  "$APPEARANCE/last-successful-mode" "$APPEARANCE/apply.lock" "$APPEARANCE"/.apply.lock.*
say "sketchybar -> retired (service stopped, minute trigger and appearance watcher removed)"
