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
  "$HOME/.config/yorha/cache/sketchybar-minute.stderr.log"
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
APPEARANCE_LABEL=com.yorha.appearance-watcher
APPEARANCE_PLIST="$HOME/Library/LaunchAgents/$APPEARANCE_LABEL.plist"
if [ -f "$APPEARANCE_PLIST" ]; then
  cp "$APPEARANCE_PLIST" "$DEST/appearance-watcher.plist.original"
fi
if launchctl print "gui/$(id -u)/$APPEARANCE_LABEL" >/dev/null 2>&1; then
  printf 'loaded\n' > "$DEST/appearance-watcher.loaded-state"
else
  printf 'unloaded\n' > "$DEST/appearance-watcher.loaded-state"
fi
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
LABEL=com.yorha.appearance-watcher
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PLIST_STATE_FILE="$HERE/appearance-watcher.loaded-state"
RESTORE_PLIST_TMP=""

cleanup_restore_temp() {
  [ -z "$RESTORE_PLIST_TMP" ] || rm -f -- "$RESTORE_PLIST_TMP"
}
trap cleanup_restore_temp EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$PLIST_STATE_FILE" ]; then
  echo "error: invalid appearance watcher state: missing $PLIST_STATE_FILE" >&2
  exit 65
fi
if grep -qxF loaded "$PLIST_STATE_FILE"; then
  ORIGINAL_APPEARANCE_STATE=loaded
elif grep -qxF unloaded "$PLIST_STATE_FILE"; then
  ORIGINAL_APPEARANCE_STATE=unloaded
else
  echo "error: invalid appearance watcher state in $PLIST_STATE_FILE" >&2
  exit 65
fi

# Stage the complete original bytes beside the destination before changing any
# live state. A partial or failed copy is removed by the EXIT/signal cleanup.
if [ -f "$HERE/appearance-watcher.plist.original" ]; then
  RESTORE_PLIST_TMP="$PLIST.restore.$$"
  if cp "$HERE/appearance-watcher.plist.original" "$RESTORE_PLIST_TMP"; then
    :
  else
    RESTORE_STATUS=$?
    echo "error: could not stage the original $LABEL plist" >&2
    exit "$RESTORE_STATUS"
  fi
fi

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

echo "==> restoring appearance watcher"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$HOME/.config/yorha/bin/yorha-appearance-watcher"
rm -f "$HOME/.config/yorha/bin/apply-appearance.sh"
rm -f "$HOME/.config/yorha/logs/appearance.log"
rm -rf "$HOME/.config/yorha/appearance"

if [ -f "$HERE/appearance-watcher.plist.original" ]; then
  if mv "$RESTORE_PLIST_TMP" "$PLIST"; then
    RESTORE_PLIST_TMP=""
  else
    RESTORE_STATUS=$?
    echo "error: could not install the original $LABEL plist" >&2
    exit "$RESTORE_STATUS"
  fi
  if [ "$ORIGINAL_APPEARANCE_STATE" = loaded ]; then
    if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
      :
    else
      RESTORE_STATUS=$?
      echo "error: could not restore pre-existing $LABEL job" >&2
      exit "$RESTORE_STATUS"
    fi
  fi
else
  rm -f "$PLIST"
fi

echo "==> reverting paths, per what actually existed at snapshot time"
# Data-driven: never guess. ABSENT means the install created it -> delete.
# PRESENT means it predates us -> restore the captured copy.
while IFS=$'\t' read -r rel state; do
  [ -z "${rel:-}" ] && continue
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
done < "$HERE/preexisting.txt"

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
