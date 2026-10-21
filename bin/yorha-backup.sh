#!/usr/bin/env bash
# Snapshot every path the YoRHa layers touch, and emit a data-driven restore script.
#
# HARD RULE: the FIRST snapshot ever taken is the BASELINE and is immutable.
# Later snapshots are informational only. Without this rule a re-run taken after
# install captures YoRHa's own files as the "original", and restore reinstalls the
# very thing it is supposed to remove. That bug shipped once; the marker prevents it.
set -euo pipefail

ROOT="$HOME/.yorha-backup"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
DEST="$ROOT/$STAMP"
mkdir -p "$DEST"

# Paths the install creates or modifies. Restore decides per-path using preexisting.txt.
TARGETS=(
  "$HOME/.config/ghostty"
  "$HOME/.config/yorha/palette.sh"
  "$HOME/.config/yorha/shell.zsh"
  "$HOME/.config/yorha/starship.toml"
  "$HOME/.config/yorha/fastfetch.jsonc"
  "$HOME/.config/yorha/logo.txt"
  "$HOME/.config/yorha/bin/pod-oracle.py"
  "$HOME/.config/yorha/bin/ubersicht-watchdog.sh"
  "$HOME/.config/yorha/cache/pod-oracle.json"
  "$HOME/.config/yorha/cache/pod-oracle.json.tmp"
  "$HOME/.config/yorha/cache/pod-oracle.log"
  "$HOME/.config/yorha/cache/pod-oracle.stderr.log"
  "$HOME/.config/yorha/cache/watchdog.log"
  "$HOME/.config/yorha/cache/watchdog.strikes"
  "$HOME/.config/yorha/cache/watchdog.stderr.log"
  "$HOME/.config/sketchybar"
  "$HOME/.config/aerospace"
  "$HOME/.config/borders"
  "$HOME/Library/Application Support/Übersicht/widgets/yorha"
  "$HOME/Library/Sounds/yorha-alert.aiff"
)

# --- 1. shell config -------------------------------------------------------
cp "$HOME/.zshrc" "$DEST/zshrc"

# --- 2. record which target paths existed AT THIS MOMENT --------------------
# Paths are stored RELATIVE to $HOME. Absolute paths would make restore.sh
# untestable — running it against a sandbox HOME would delete the real directories.
: > "$DEST/preexisting.txt"
for p in "${TARGETS[@]}"; do
  rel="${p#"$HOME"/}"
  if [ -e "$p" ]; then printf '%s\tPRESENT\n' "$rel"; else printf '%s\tABSENT\n' "$rel"; fi
done >> "$DEST/preexisting.txt"

# --- 3. snapshot the whole ghostty tree, not just config -------------------
# Copying the tree covers shaders/ and any future subdir uniformly.
if [ -d "$HOME/.config/ghostty" ]; then
  cp -R "$HOME/.config/ghostty" "$DEST/ghostty-tree"
fi

# --- 4. macOS-native ghostty config, which OVERRIDES the XDG one -----------
APPSUP="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
[ -f "$APPSUP" ] && cp "$APPSUP" "$DEST/ghostty-appsupport-config"
# A sidecar set aside during install is the true baseline; prefer it.
[ -f "$APPSUP.pre-yorha-backup" ] && cp "$APPSUP.pre-yorha-backup" "$DEST/ghostty-appsupport-config.original"

# --- 5. wallpaper ----------------------------------------------------------
osascript -e 'tell application "System Events" to get picture of current desktop' \
  > "$DEST/wallpaper.txt" 2>/dev/null || echo "unknown" > "$DEST/wallpaper.txt"

# --- 6. services and login agents ------------------------------------------
{ brew services list 2>/dev/null || true; } > "$DEST/services.txt"
{ ls -1 "$HOME/Library/LaunchAgents" 2>/dev/null || true; } > "$DEST/launchagents.txt"
# Login items, one per line. Restore removes only the ones absent at snapshot time.
{ osascript -e 'tell application "System Events" to get name of every login item' 2>/dev/null \
    | tr ',' '\n' | sed 's/^ *//;s/ *$//' || true; } > "$DEST/loginitems.txt"

# --- 7. package manifest ---------------------------------------------------
{ brew list --formula 2>/dev/null || true; } > "$DEST/formulae.txt"
{ brew list --cask    2>/dev/null || true; } > "$DEST/casks.txt"
{
  echo "created: $STAMP"
  echo "host: $(sw_vers -productVersion) $(uname -m)"
  echo "sip: $(csrutil status 2>/dev/null | sed 's/.*: //')"
} > "$DEST/manifest.txt"

# --- 8. the undo -----------------------------------------------------------
cat > "$DEST/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
# Return this Mac to the state captured in this snapshot.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREEXISTING_FILE="$HERE/preexisting.txt"
PREEXISTING_COUNT=0
PREEXISTING_TAB="$(printf '\t')"
PREEXISTING_01=""; PREEXISTING_02=""; PREEXISTING_03=""; PREEXISTING_04=""
PREEXISTING_05=""; PREEXISTING_06=""; PREEXISTING_07=""; PREEXISTING_08=""
PREEXISTING_09=""; PREEXISTING_10=""; PREEXISTING_11=""; PREEXISTING_12=""
PREEXISTING_13=""; PREEXISTING_14=""; PREEXISTING_15=""; PREEXISTING_16=""
PREEXISTING_17=""; PREEXISTING_18=""; PREEXISTING_19=""; PREEXISTING_20=""

invalid_preexisting_metadata() {
  echo "error: invalid restore metadata in $PREEXISTING_FILE" >&2
  exit 65
}

# Parse the complete metadata contract into fixed state slots before touching a
# service, wallpaper, or destination path. Restore never
# re-reads the file, so a later replacement cannot smuggle in an unchecked path.
[ -f "$PREEXISTING_FILE" ] || invalid_preexisting_metadata
PREEXISTING_LAST_BYTE="$(tail -c 1 "$PREEXISTING_FILE" 2>/dev/null \
  | od -An -t u1 | tr -d '[:space:]')"
[ "$PREEXISTING_LAST_BYTE" = 10 ] || invalid_preexisting_metadata
while IFS= read -r PREEXISTING_ROW || [ -n "$PREEXISTING_ROW" ]; do
  case "$PREEXISTING_ROW" in
    *"$PREEXISTING_TAB"*) ;;
    *) invalid_preexisting_metadata ;;
  esac
  PREEXISTING_REL="${PREEXISTING_ROW%%"$PREEXISTING_TAB"*}"
  PREEXISTING_STATE="${PREEXISTING_ROW#*"$PREEXISTING_TAB"}"
  case "$PREEXISTING_STATE" in
    *"$PREEXISTING_TAB"*) invalid_preexisting_metadata ;;
    PRESENT | ABSENT) ;;
    *) invalid_preexisting_metadata ;;
  esac
  case "$PREEXISTING_REL" in
    '' | /* | .. | ../* | */.. | */../*) invalid_preexisting_metadata ;;
  esac
  case "$PREEXISTING_REL" in
    .config/ghostty) [ -z "$PREEXISTING_01" ] || invalid_preexisting_metadata; PREEXISTING_01="$PREEXISTING_STATE" ;;
    .config/yorha/palette.sh) [ -z "$PREEXISTING_02" ] || invalid_preexisting_metadata; PREEXISTING_02="$PREEXISTING_STATE" ;;
    .config/yorha/shell.zsh) [ -z "$PREEXISTING_03" ] || invalid_preexisting_metadata; PREEXISTING_03="$PREEXISTING_STATE" ;;
    .config/yorha/starship.toml) [ -z "$PREEXISTING_04" ] || invalid_preexisting_metadata; PREEXISTING_04="$PREEXISTING_STATE" ;;
    .config/yorha/fastfetch.jsonc) [ -z "$PREEXISTING_05" ] || invalid_preexisting_metadata; PREEXISTING_05="$PREEXISTING_STATE" ;;
    .config/yorha/logo.txt) [ -z "$PREEXISTING_06" ] || invalid_preexisting_metadata; PREEXISTING_06="$PREEXISTING_STATE" ;;
    .config/yorha/bin/pod-oracle.py) [ -z "$PREEXISTING_07" ] || invalid_preexisting_metadata; PREEXISTING_07="$PREEXISTING_STATE" ;;
    .config/yorha/bin/ubersicht-watchdog.sh) [ -z "$PREEXISTING_08" ] || invalid_preexisting_metadata; PREEXISTING_08="$PREEXISTING_STATE" ;;
    .config/yorha/cache/pod-oracle.json) [ -z "$PREEXISTING_09" ] || invalid_preexisting_metadata; PREEXISTING_09="$PREEXISTING_STATE" ;;
    .config/yorha/cache/pod-oracle.json.tmp) [ -z "$PREEXISTING_10" ] || invalid_preexisting_metadata; PREEXISTING_10="$PREEXISTING_STATE" ;;
    .config/yorha/cache/pod-oracle.log) [ -z "$PREEXISTING_11" ] || invalid_preexisting_metadata; PREEXISTING_11="$PREEXISTING_STATE" ;;
    .config/yorha/cache/pod-oracle.stderr.log) [ -z "$PREEXISTING_12" ] || invalid_preexisting_metadata; PREEXISTING_12="$PREEXISTING_STATE" ;;
    .config/yorha/cache/watchdog.log) [ -z "$PREEXISTING_13" ] || invalid_preexisting_metadata; PREEXISTING_13="$PREEXISTING_STATE" ;;
    .config/yorha/cache/watchdog.strikes) [ -z "$PREEXISTING_14" ] || invalid_preexisting_metadata; PREEXISTING_14="$PREEXISTING_STATE" ;;
    .config/yorha/cache/watchdog.stderr.log) [ -z "$PREEXISTING_15" ] || invalid_preexisting_metadata; PREEXISTING_15="$PREEXISTING_STATE" ;;
    .config/sketchybar) [ -z "$PREEXISTING_16" ] || invalid_preexisting_metadata; PREEXISTING_16="$PREEXISTING_STATE" ;;
    .config/aerospace) [ -z "$PREEXISTING_17" ] || invalid_preexisting_metadata; PREEXISTING_17="$PREEXISTING_STATE" ;;
    .config/borders) [ -z "$PREEXISTING_18" ] || invalid_preexisting_metadata; PREEXISTING_18="$PREEXISTING_STATE" ;;
    'Library/Application Support/Übersicht/widgets/yorha') [ -z "$PREEXISTING_19" ] || invalid_preexisting_metadata; PREEXISTING_19="$PREEXISTING_STATE" ;;
    'Library/Sounds/yorha-alert.aiff') [ -z "$PREEXISTING_20" ] || invalid_preexisting_metadata; PREEXISTING_20="$PREEXISTING_STATE" ;;
    *) invalid_preexisting_metadata ;;
  esac
  PREEXISTING_COUNT=$((PREEXISTING_COUNT + 1))
done < "$PREEXISTING_FILE"
[ "$PREEXISTING_COUNT" -eq 20 ] || invalid_preexisting_metadata

echo "==> stopping services this install started"
# Must happen BEFORE deleting configs: killing the config does not kill the daemon,
# and a KeepAlive LaunchAgent relaunches at every login otherwise.
for svc in sketchybar borders; do
  if command -v brew >/dev/null 2>&1; then
    brew services stop "$svc" >/dev/null 2>&1 || true
  fi
  launchctl bootout "gui/$(id -u)/homebrew.mxcl.$svc" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/homebrew.mxcl.$svc.plist"
  pkill -x "$svc" >/dev/null 2>&1 || true
done

echo "==> removing login items this install added"
# Only remove what was NOT already a login item at snapshot time. A missing
# loginitems.txt means the snapshot predates this check, so treat as absent.
for li in "Übersicht"; do
  if ! grep -qxF "$li" "$HERE/loginitems.txt" 2>/dev/null; then
    osascript -e "tell application \"System Events\" to delete login item \"$li\"" >/dev/null 2>&1 \
      && echo "    removed login item: $li" || true
  else
    echo "    KEPT login item: $li (pre-existing)"
  fi
done

echo "==> restoring ~/.zshrc"
cp "$HERE/zshrc" "$HOME/.zshrc"

echo "==> restoring ghostty (Application Support — this overrides the XDG config)"
APPSUP="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
if [ -f "$HERE/ghostty-appsupport-config.original" ]; then
  mkdir -p "$(dirname "$APPSUP")"
  cp "$HERE/ghostty-appsupport-config.original" "$APPSUP"
  rm -f "$APPSUP.pre-yorha-backup"
elif [ -f "$HERE/ghostty-appsupport-config" ]; then
  mkdir -p "$(dirname "$APPSUP")"
  cp "$HERE/ghostty-appsupport-config" "$APPSUP"
else
  rm -f "$APPSUP"
fi

echo "==> removing YoRHa Desktop and the wallpaper runtime"
# Owned outright by the install. The bar-off marker is yorha-watcher's switch.
launchctl bootout "gui/$(id -u)/com.yorha.desktop" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/com.yorha.desktop.plist"
rm -f "$HOME/.config/yorha/bin/yorha-desktop"
rm -f "$HOME/.config/yorha/logs/yorha-desktop.log"
rm -f "$HOME/.config/yorha/bar-off"
rm -rf "$HOME/.config/yorha/appearance"

echo "==> removing retired helpers"
# SketchyBar's minute trigger and the appearance watcher. Installs since the native
# bar no longer create them; this clears what an older install left behind.
for agent in com.yorha.sketchybar-minute com.yorha.appearance-watcher; do
  launchctl bootout "gui/$(id -u)/$agent" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/$agent.plist"
done
rm -f "$HOME/.config/yorha/bin/yorha-appearance-watcher"
rm -f "$HOME/.config/yorha/bin/apply-appearance.sh"
rm -f "$HOME/.config/yorha/logs/appearance.log"
rm -f "$HOME/.config/yorha/cache/sketchybar-minute.stderr.log"

echo "==> reverting paths, per what actually existed at snapshot time"
# Data-driven: never guess. ABSENT means the install created it -> delete.
# PRESENT means it predates us -> restore the captured copy.
restore_recorded_path() {
  rel="$1"
  state="$2"
  path="$HOME/$rel"
  case "$state" in
    ABSENT)
      rm -rf "$path"
      echo "    removed  ~/$rel"
      ;;
    PRESENT)
      if [ "$rel" = ".config/ghostty" ] && [ -d "$HERE/ghostty-tree" ]; then
        rm -rf "$path"; cp -R "$HERE/ghostty-tree" "$path"
        echo "    restored ~/$rel"
      else
        echo "    KEPT     ~/$rel (pre-existing; not touched)"
      fi
      ;;
  esac
}
restore_recorded_path .config/ghostty "$PREEXISTING_01"
restore_recorded_path .config/yorha/palette.sh "$PREEXISTING_02"
restore_recorded_path .config/yorha/shell.zsh "$PREEXISTING_03"
restore_recorded_path .config/yorha/starship.toml "$PREEXISTING_04"
restore_recorded_path .config/yorha/fastfetch.jsonc "$PREEXISTING_05"
restore_recorded_path .config/yorha/logo.txt "$PREEXISTING_06"
restore_recorded_path .config/yorha/bin/pod-oracle.py "$PREEXISTING_07"
restore_recorded_path .config/yorha/bin/ubersicht-watchdog.sh "$PREEXISTING_08"
restore_recorded_path .config/yorha/cache/pod-oracle.json "$PREEXISTING_09"
restore_recorded_path .config/yorha/cache/pod-oracle.json.tmp "$PREEXISTING_10"
restore_recorded_path .config/yorha/cache/pod-oracle.log "$PREEXISTING_11"
restore_recorded_path .config/yorha/cache/pod-oracle.stderr.log "$PREEXISTING_12"
restore_recorded_path .config/yorha/cache/watchdog.log "$PREEXISTING_13"
restore_recorded_path .config/yorha/cache/watchdog.strikes "$PREEXISTING_14"
restore_recorded_path .config/yorha/cache/watchdog.stderr.log "$PREEXISTING_15"
restore_recorded_path .config/sketchybar "$PREEXISTING_16"
restore_recorded_path .config/aerospace "$PREEXISTING_17"
restore_recorded_path .config/borders "$PREEXISTING_18"
restore_recorded_path 'Library/Application Support/Übersicht/widgets/yorha' "$PREEXISTING_19"
restore_recorded_path 'Library/Sounds/yorha-alert.aiff' "$PREEXISTING_20"

echo "==> restoring wallpaper"
WP="$(cat "$HERE/wallpaper.txt")"
if [ -f "$WP" ]; then
  # Bind the path as an argv value. Splicing it into AppleScript source would let a
  # path containing a double quote break out of the string literal.
  osascript - "$WP" >/dev/null 2>&1 <<'AS' || true
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS
fi

echo
echo "==> packages added since this snapshot (advice only — nothing removed)"
# Derived from the manifest, never hardcoded: a hardcoded list once told the user to
# uninstall jq, which they already had.
if command -v brew >/dev/null 2>&1; then
  NEWF=$(comm -13 <(sort "$HERE/formulae.txt") <(brew list --formula 2>/dev/null | sort) | tr '\n' ' ')
  NEWC=$(comm -13 <(sort "$HERE/casks.txt")    <(brew list --cask    2>/dev/null | sort) | tr '\n' ' ')
  [ -n "${NEWF// /}" ] && echo "  brew uninstall $NEWF"
  [ -n "${NEWC// /}" ] && echo "  brew uninstall --cask $NEWC"
  [ -z "${NEWF// /}${NEWC// /}" ] && echo "  (none)"
  echo "  brew autoremove   # drops dependencies pulled in alongside them"
else
  echo "  (brew not found)"
fi

echo
echo "Restore complete."
RESTORE

chmod +x "$DEST/restore.sh"

# --- 9. protect the baseline ------------------------------------------------
if [ ! -e "$ROOT/BASELINE" ]; then
  echo "$DEST" > "$ROOT/BASELINE"
fi
echo "$DEST"
