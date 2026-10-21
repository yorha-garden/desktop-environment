#!/usr/bin/env bash
# Push this repo's tracked configuration into the live locations macOS reads from.
# The repo is the source of truth; the live paths are deployment targets.
#   bin/deploy.sh [--wallpaper]   --wallpaper also sets the YoRHa wallpaper on every desktop
#
# Idempotent and additive. Does not touch ~/.zshrc, SIP, or any system setting,
# and leaves the current wallpaper alone unless --wallpaper is given.
set -euo pipefail

ASSIGN_WALLPAPER=0
for arg in "$@"; do
  case "$arg" in
    --wallpaper) ASSIGN_WALLPAPER=1 ;;
    *) echo "usage: $0 [--wallpaper]" >&2; exit 64 ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '  %s\n' "$*"; }

say "repo: $REPO"

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

# --- appearance runtime BEGIN
# The dynamic HEIC is the only appearance runtime left: macOS picks its frame, and
# YoRHa Desktop recolours the widgets and bar itself. The block guards its one
# pending temp with traps that hand back whatever traps the caller had set.
APPEARANCE="$HOME/.config/yorha/appearance"
mkdir -p "$APPEARANCE"

INSTALL_TMP=""
PRIOR_EXIT_TRAP="$(trap -p EXIT)"
PRIOR_HUP_TRAP="$(trap -p HUP)"
PRIOR_INT_TRAP="$(trap -p INT)"
PRIOR_TERM_TRAP="$(trap -p TERM)"

extract_appearance_trap_handler() {
  local YORHA_APPEARANCE_EXTRACT_DEFINITION="$1"
  local YORHA_APPEARANCE_EXTRACT_CAPTURED=""
  trap() {
    [ "$1" != -- ] || shift
    YORHA_APPEARANCE_EXTRACT_CAPTURED="$1"
  }
  eval "$YORHA_APPEARANCE_EXTRACT_DEFINITION"
  unset -f trap
  printf '%s' "$YORHA_APPEARANCE_EXTRACT_CAPTURED"
}

PRIOR_EXIT_HANDLER="$(extract_appearance_trap_handler "$PRIOR_EXIT_TRAP")"
PRIOR_HUP_HANDLER="$(extract_appearance_trap_handler "$PRIOR_HUP_TRAP")"
PRIOR_INT_HANDLER="$(extract_appearance_trap_handler "$PRIOR_INT_TRAP")"
PRIOR_TERM_HANDLER="$(extract_appearance_trap_handler "$PRIOR_TERM_TRAP")"

cleanup_appearance_temps() {
  [ -z "$INSTALL_TMP" ] || rm -f -- "$INSTALL_TMP"
}

restore_appearance_trap() {
  local YORHA_APPEARANCE_RESTORE_DEFINITION="$1"
  local YORHA_APPEARANCE_RESTORE_SIGNAL_NAME="$2"
  if [ -n "$YORHA_APPEARANCE_RESTORE_DEFINITION" ]; then
    eval "$YORHA_APPEARANCE_RESTORE_DEFINITION"
  else
    trap - "$YORHA_APPEARANCE_RESTORE_SIGNAL_NAME"
  fi
}

restore_appearance_traps() {
  restore_appearance_trap "$PRIOR_EXIT_TRAP" EXIT
  restore_appearance_trap "$PRIOR_HUP_TRAP" HUP
  restore_appearance_trap "$PRIOR_INT_TRAP" INT
  restore_appearance_trap "$PRIOR_TERM_TRAP" TERM
}

prepare_appearance_exit() {
  cleanup_appearance_temps
  restore_appearance_traps
}

prepare_appearance_signal() {
  YORHA_APPEARANCE_SIGNAL_NAME="$1"
  YORHA_APPEARANCE_SIGNAL_EXIT_STATUS="$2"
  YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION=""
  YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER=""
  cleanup_appearance_temps
  restore_appearance_traps
  case "$YORHA_APPEARANCE_SIGNAL_NAME" in
    HUP)
      YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION="$PRIOR_HUP_TRAP"
      YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER="$PRIOR_HUP_HANDLER"
      ;;
    INT)
      YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION="$PRIOR_INT_TRAP"
      YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER="$PRIOR_INT_HANDLER"
      ;;
    TERM)
      YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION="$PRIOR_TERM_TRAP"
      YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER="$PRIOR_TERM_HANDLER"
      ;;
  esac
}

yorha_appearance_return_dispatch_status() {
  return "$YORHA_APPEARANCE_DISPATCH_STATUS"
}

trap 'YORHA_APPEARANCE_EXIT_STATUS=$?; prepare_appearance_exit; if [ -n "$PRIOR_EXIT_TRAP" ]; then YORHA_APPEARANCE_DISPATCH_STATUS="$YORHA_APPEARANCE_EXIT_STATUS"; yorha_appearance_return_dispatch_status || eval "$PRIOR_EXIT_HANDLER"; fi; trap - EXIT; exit "$YORHA_APPEARANCE_EXIT_STATUS"' EXIT
trap 'YORHA_APPEARANCE_SIGNAL_CONTEXT_STATUS=$?; prepare_appearance_signal HUP 129; if [ -n "$YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION" ]; then if [ -n "$YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER" ]; then YORHA_APPEARANCE_DISPATCH_STATUS="$YORHA_APPEARANCE_SIGNAL_CONTEXT_STATUS"; yorha_appearance_return_dispatch_status || eval "$YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER"; fi; exit "$YORHA_APPEARANCE_SIGNAL_EXIT_STATUS"; fi; kill -s "$YORHA_APPEARANCE_SIGNAL_NAME" "$$"; exit "$YORHA_APPEARANCE_SIGNAL_EXIT_STATUS"' HUP
trap 'YORHA_APPEARANCE_SIGNAL_CONTEXT_STATUS=$?; prepare_appearance_signal INT 130; if [ -n "$YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION" ]; then if [ -n "$YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER" ]; then YORHA_APPEARANCE_DISPATCH_STATUS="$YORHA_APPEARANCE_SIGNAL_CONTEXT_STATUS"; yorha_appearance_return_dispatch_status || eval "$YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER"; fi; exit "$YORHA_APPEARANCE_SIGNAL_EXIT_STATUS"; fi; kill -s "$YORHA_APPEARANCE_SIGNAL_NAME" "$$"; exit "$YORHA_APPEARANCE_SIGNAL_EXIT_STATUS"' INT
trap 'YORHA_APPEARANCE_SIGNAL_CONTEXT_STATUS=$?; prepare_appearance_signal TERM 143; if [ -n "$YORHA_APPEARANCE_PRIOR_SIGNAL_DEFINITION" ]; then if [ -n "$YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER" ]; then YORHA_APPEARANCE_DISPATCH_STATUS="$YORHA_APPEARANCE_SIGNAL_CONTEXT_STATUS"; yorha_appearance_return_dispatch_status || eval "$YORHA_APPEARANCE_PRIOR_SIGNAL_HANDLER"; fi; exit "$YORHA_APPEARANCE_SIGNAL_EXIT_STATUS"; fi; kill -s "$YORHA_APPEARANCE_SIGNAL_NAME" "$$"; exit "$YORHA_APPEARANCE_SIGNAL_EXIT_STATUS"' TERM

install_atomic() {
  local YORHA_APPEARANCE_INSTALL_SOURCE
  local YORHA_APPEARANCE_INSTALL_DESTINATION
  local YORHA_APPEARANCE_INSTALL_TEMPORARY
  YORHA_APPEARANCE_INSTALL_SOURCE="$1"
  YORHA_APPEARANCE_INSTALL_DESTINATION="$2"
  YORHA_APPEARANCE_INSTALL_TEMPORARY="${YORHA_APPEARANCE_INSTALL_DESTINATION}.tmp.$$"
  INSTALL_TMP="$YORHA_APPEARANCE_INSTALL_TEMPORARY"
  cp "$YORHA_APPEARANCE_INSTALL_SOURCE" "$YORHA_APPEARANCE_INSTALL_TEMPORARY"
  mv "$YORHA_APPEARANCE_INSTALL_TEMPORARY" "$YORHA_APPEARANCE_INSTALL_DESTINATION"
  INSTALL_TMP=""
}

"$REPO/bin/make-wallpaper.sh" --verify
RUNTIME_WALLPAPER="$APPEARANCE/yorha-system.heic"
install_atomic "$REPO/assets/yorha-system.heic" "$RUNTIME_WALLPAPER"

# Assigning replaces whatever wallpaper is set, so it happens only when asked.
# Once assigned, macOS owns frame selection; later deploys only refresh the file.
if [ "${ASSIGN_WALLPAPER:-0}" = 1 ]; then
  osascript - "$RUNTIME_WALLPAPER" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS
  say "wallpaper -> ~/.config/yorha/appearance/yorha-system.heic (set on every desktop)"
else
  say "wallpaper -> ~/.config/yorha/appearance/yorha-system.heic (installed; current wallpaper kept, --wallpaper sets it)"
fi

restore_appearance_traps
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

# --- native desktop layer --------------------------------------------------
# YoRHa Desktop draws the beam, ornaments, HUD, Pod, and bar in one native process.
# It replaces Übersicht, its widget server, and its watchdog, and SketchyBar with
# its minute trigger and appearance watcher; the installer retires all of them.
"$REPO/bin/install-desktop.sh" "$REPO/launchd/com.yorha.desktop.plist"

# --- on/off switch -----------------------------------------------------------
# One command to stop or resume YoRHa Desktop, or only its bar.
mkdir -p "$HOME/.local/bin"
cp "$REPO/bin/yorha-watcher" "$HOME/.local/bin/yorha-watcher"
chmod +x "$HOME/.local/bin/yorha-watcher"
say "switch   -> ~/.local/bin/yorha-watcher (on|off|status)"

echo
say "Done. Reload Ghostty with Cmd+Shift+, to pick up shader/config changes."
