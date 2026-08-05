#!/usr/bin/env bash
# Push this repo's tracked configuration into the live locations macOS reads from.
# The repo is the source of truth; the live paths are deployment targets.
#
# Idempotent and additive. Does not touch ~/.zshrc, SIP, or any system setting.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UB="$HOME/Library/Application Support/Übersicht/widgets"

say() { printf '  %s\n' "$*"; }

say "repo: $REPO"

# --- widgets ---------------------------------------------------------------
mkdir -p "$UB/yorha"
cp "$REPO"/widgets/yorha/*.jsx "$UB/yorha/"
say "widgets  -> $UB/yorha/"

# --- ghostty ---------------------------------------------------------------
mkdir -p "$HOME/.config/ghostty/shaders"
cp "$REPO/config/ghostty/config" "$HOME/.config/ghostty/config"
cp "$REPO"/config/ghostty/shaders/*.glsl "$HOME/.config/ghostty/shaders/"
# macOS-native location OVERRIDES the XDG one for any key it sets. Keeping both
# in sync is not optional; a mismatch here silently wins and is very hard to spot.
APPSUP="$HOME/Library/Application Support/com.mitchellh.ghostty"
if [ -f "$REPO/config/ghostty/config.ghostty" ]; then
  mkdir -p "$APPSUP"
  cp "$REPO/config/ghostty/config.ghostty" "$APPSUP/config.ghostty"
  say "ghostty  -> ~/.config/ghostty + Application Support override"
else
  say "ghostty  -> ~/.config/ghostty"
fi

# --- sketchybar ------------------------------------------------------------
mkdir -p "$HOME/.config/sketchybar"
cp "$REPO/config/sketchybar/sketchybarrc" "$HOME/.config/sketchybar/sketchybarrc"
chmod +x "$HOME/.config/sketchybar/sketchybarrc"
# The crest PNG must live outside the repo: sketchybar is a launchd service and
# ~/Documents is TCC-protected — same constraint as the oracle below.
[ -f "$REPO/assets/yorha-icon.png" ] && cp "$REPO/assets/yorha-icon.png" "$HOME/.config/sketchybar/yorha-icon.png"
command -v sketchybar >/dev/null && sketchybar --reload >/dev/null 2>&1 || true
say "sketchybar -> ~/.config/sketchybar/ (rc + crest, reloaded)"

# --- appearance runtime BEGIN
APPEARANCE="$HOME/.config/yorha/appearance"
YORHA_BIN="$HOME/.config/yorha/bin"
mkdir -p "$APPEARANCE" "$YORHA_BIN" "$HOME/.config/yorha/logs" \
  "$HOME/Library/LaunchAgents"

INSTALL_TMP=""
WATCHER_TMP=""
PLIST_TMP=""

cleanup_appearance_temps() {
  for pending in "$INSTALL_TMP" "$WATCHER_TMP" "$PLIST_TMP"; do
    [ -z "$pending" ] || rm -f -- "$pending"
  done
}

abort_appearance_install() {
  signal_status="$1"
  trap - EXIT HUP INT TERM
  cleanup_appearance_temps
  exit "$signal_status"
}

trap cleanup_appearance_temps EXIT
trap 'abort_appearance_install 129' HUP
trap 'abort_appearance_install 130' INT
trap 'abort_appearance_install 143' TERM

install_atomic() {
  source="$1"
  destination="$2"
  temporary="${destination}.tmp.$$"
  INSTALL_TMP="$temporary"
  cp "$source" "$temporary"
  if [ "${3:-}" = executable ]; then
    chmod +x "$temporary"
  fi
  mv "$temporary" "$destination"
  INSTALL_TMP=""
}

"$REPO/bin/make-wallpaper.sh" --verify
RUNTIME_WALLPAPER="$APPEARANCE/yorha-system.heic"
RUNTIME_COORDINATOR="$YORHA_BIN/apply-appearance.sh"
RUNTIME_WATCHER="$YORHA_BIN/yorha-appearance-watcher"
install_atomic "$REPO/assets/yorha-system.heic" "$RUNTIME_WALLPAPER"
install_atomic "$REPO/assets/yorha-icon-light.png" "$APPEARANCE/yorha-icon-light.png"
install_atomic "$REPO/assets/yorha-icon-dark.png" "$APPEARANCE/yorha-icon-dark.png"
install_atomic "$REPO/bin/apply-appearance.sh" "$RUNTIME_COORDINATOR" executable

WATCHER_TMP="$RUNTIME_WATCHER.tmp.$$"
swiftc -O "$REPO/bin/appearance-watcher.swift" -o "$WATCHER_TMP"
chmod +x "$WATCHER_TMP"
mv "$WATCHER_TMP" "$RUNTIME_WATCHER"
WATCHER_TMP=""

osascript - "$RUNTIME_WALLPAPER" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS

APPEARANCE_PLIST="$HOME/Library/LaunchAgents/com.yorha.appearance-watcher.plist"
PLIST_TMP="$APPEARANCE_PLIST.tmp.$$"
PLUTIL="${YORHA_PLUTIL:-/usr/bin/plutil}"
cp "$REPO/launchd/com.yorha.appearance-watcher.plist" "$PLIST_TMP"
"$PLUTIL" -replace ProgramArguments -array -- "$PLIST_TMP"
"$PLUTIL" -insert ProgramArguments.0 -string "$RUNTIME_WATCHER" -- "$PLIST_TMP"
"$PLUTIL" -insert ProgramArguments.1 -string "$RUNTIME_COORDINATOR" -- "$PLIST_TMP"
"$PLUTIL" -replace StandardOutPath -string "$HOME/.config/yorha/logs/appearance.log" -- "$PLIST_TMP"
"$PLUTIL" -replace StandardErrorPath -string "$HOME/.config/yorha/logs/appearance.log" -- "$PLIST_TMP"
"$PLUTIL" -lint "$PLIST_TMP"
mv "$PLIST_TMP" "$APPEARANCE_PLIST"
PLIST_TMP=""
launchctl bootout "gui/$(id -u)/com.yorha.appearance-watcher" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = Dark ]; then
  MODE=dark
else
  MODE=light
fi
"$RUNTIME_COORDINATOR" "$MODE" --force \
  || say "appearance -> watcher installed; SketchyBar update will retry"
trap - EXIT HUP INT TERM
# --- appearance runtime END

# --- aerospace (installed but intentionally not running) -------------------
if [ -f "$REPO/config/aerospace/aerospace.toml" ]; then
  mkdir -p "$HOME/.config/aerospace"
  cp "$REPO/config/aerospace/aerospace.toml" "$HOME/.config/aerospace/"
  say "aerospace -> ~/.config/aerospace/  (start-at-login stays false)"
fi

# --- shell -----------------------------------------------------------------
mkdir -p "$HOME/.config/yorha"
cp "$REPO/config/shell/palette.sh"   "$HOME/.config/yorha/palette.sh"
cp "$REPO/config/shell/shell.zsh"    "$HOME/.config/yorha/shell.zsh"
cp "$REPO/config/shell/starship.toml" "$HOME/.config/yorha/starship.toml"
cp "$REPO/config/shell/fastfetch.jsonc" "$HOME/.config/yorha/fastfetch.jsonc"
cp "$REPO/config/shell/logo.txt"     "$HOME/.config/yorha/logo.txt"
say "shell    -> ~/.config/yorha/"

# --- pod oracle ------------------------------------------------------------
# The script MUST be copied out of the repo: ~/Documents is TCC-protected and a
# launchd job cannot read it (Errno 1, every fire, silently).
mkdir -p "$HOME/.config/yorha/bin"
cp "$REPO/bin/pod-oracle.py" "$HOME/.config/yorha/bin/pod-oracle.py"
chmod +x "$HOME/.config/yorha/bin/pod-oracle.py"
say "oracle   -> ~/.config/yorha/bin/ (outside TCC-protected ~/Documents)"

PLIST="$HOME/Library/LaunchAgents/com.yorha.pod-oracle.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.config/yorha/cache"
sed -e "s|REPO_PATH|$REPO|g" -e "s|HOME_PATH|$HOME|g" \
    "$REPO/launchd/com.yorha.pod-oracle.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/com.yorha.pod-oracle" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
  && say "oracle   -> loaded (every 5 min)" \
  || say "oracle   -> plist written; load with: launchctl bootstrap gui/\$(id -u) $PLIST"

# --- übersicht watchdog ----------------------------------------------------
# Health-checking, not just liveness: the observed failure is the app staying
# alive while its widget server dies. Also starts Übersicht at login.
cp "$REPO/bin/ubersicht-watchdog.sh" "$HOME/.config/yorha/bin/ubersicht-watchdog.sh"
chmod +x "$HOME/.config/yorha/bin/ubersicht-watchdog.sh"
WPLIST="$HOME/Library/LaunchAgents/com.yorha.ubersicht-watchdog.plist"
sed -e "s|REPO_PATH|$REPO|g" -e "s|HOME_PATH|$HOME|g" \
    "$REPO/launchd/com.yorha.ubersicht-watchdog.plist" > "$WPLIST"
launchctl bootout "gui/$(id -u)/com.yorha.ubersicht-watchdog" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$WPLIST" 2>/dev/null \
  && say "watchdog -> loaded (health check every 60s, starts at login)" \
  || say "watchdog -> plist written; load with: launchctl bootstrap gui/\$(id -u) $WPLIST"

# --- refresh ---------------------------------------------------------------
osascript -e 'tell application id "tracesOf.Uebersicht" to refresh' >/dev/null 2>&1 \
  && say "übersicht refreshed" || say "übersicht not running"

echo
say "Done. Reload Ghostty with Cmd+Shift+, to pick up shader/config changes."
