#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "usage: $0 light|dark [--force]" >&2
}

[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || {
  usage
  exit 64
}

MODE="$1"
FORCE="${2:-}"
case "$MODE" in
  light | dark) ;;
  *)
    usage
    exit 64
    ;;
esac
[ -z "$FORCE" ] || [ "$FORCE" = "--force" ] || {
  usage
  exit 64
}

ROOT="${YORHA_APPEARANCE_ROOT:-$HOME/.config/yorha/appearance}"
STATE="$ROOT/last-successful-mode"
LOCK="$ROOT/apply.lock"
LOCK_OWNER="$LOCK/owner"
LIGHT_CREST="$ROOT/yorha-icon-light.png"
DARK_CREST="$ROOT/yorha-icon-dark.png"
SKETCHYBAR="${YORHA_SKETCHYBAR_BIN:-sketchybar}"
LOCK_OWNED=0
LOCK_ACQUISITION_PENDING=0
PENDING_SIGNAL_STATUS=0
TEMP_STATE=""
SKETCHYBAR_PID=""
LOCK_OWNER_PID=""
LOCK_OWNER_START=""
LOCK_OWNER_TOKEN=""
LOCK_START_IDENTITY=""
LOCK_TOKEN="$$.$(date +%s).$RANDOM"
LOCK_METADATA_TEMP=""
LOCK_STALE_GRACE_SECONDS=5
TAB="$(printf '\t')"

process_start_identity() {
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

read_lock_owner() {
  owner_file="$1/owner"
  LOCK_OWNER_PID=""
  LOCK_OWNER_START=""
  LOCK_OWNER_TOKEN=""
  [ -f "$owner_file" ] || return 1

  owner_line_count=0
  while IFS= read -r owner_line || [ -n "$owner_line" ]; do
    owner_line_count=$((owner_line_count + 1))
    case "$owner_line_count:$owner_line" in
      "1:pid$TAB"*) LOCK_OWNER_PID="${owner_line#pid$TAB}" ;;
      "2:start$TAB"*) LOCK_OWNER_START="${owner_line#start$TAB}" ;;
      "3:token$TAB"*) LOCK_OWNER_TOKEN="${owner_line#token$TAB}" ;;
      *) return 1 ;;
    esac
  done < "$owner_file"

  [ "$owner_line_count" -eq 3 ] || return 1
  [ -n "$LOCK_OWNER_PID" ] && [ -n "$LOCK_OWNER_START" ] \
    && [ -n "$LOCK_OWNER_TOKEN" ] || return 1
  case "$LOCK_OWNER_PID" in
    *[!0-9]*) return 1 ;;
  esac
}

lock_owner_is_active() {
  read_lock_owner "$1" || return 1
  current_start="$(process_start_identity "$LOCK_OWNER_PID")"
  [ -n "$current_start" ] && [ "$current_start" = "$LOCK_OWNER_START" ]
}

lock_is_stale() {
  lock_modified="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)"
  case "$lock_modified" in
    ''|*[!0-9]*) return 1 ;;
  esac
  lock_now="$(date +%s)"
  [ $((lock_now - lock_modified)) -ge "$LOCK_STALE_GRACE_SECONDS" ]
}

reclaim_stale_lock() {
  [ -d "$LOCK" ] || return 0
  if read_lock_owner "$LOCK"; then
    current_start="$(process_start_identity "$LOCK_OWNER_PID")"
    if [ -n "$current_start" ] && [ "$current_start" = "$LOCK_OWNER_START" ]; then
      return 1
    fi
  else
    # An owner record is published immediately after mkdir. Only an ownerless or
    # malformed directory needs grace so a creator at that boundary can finish.
    lock_is_stale "$LOCK" || return 1
  fi

  reclaim_claim="$LOCK/reclaim"
  mkdir "$reclaim_claim" 2>/dev/null || return 1
  if lock_owner_is_active "$LOCK"; then
    rmdir "$reclaim_claim" 2>/dev/null || true
    return 1
  fi

  reclaim_tombstone="$LOCK.reclaim.$LOCK_TOKEN"
  if mv "$LOCK" "$reclaim_tombstone" 2>/dev/null; then
    rm -rf "$reclaim_tombstone"
    return 0
  fi
  rmdir "$reclaim_claim" 2>/dev/null || true
  return 1
}

write_lock_owner() {
  LOCK_METADATA_TEMP="$LOCK/.owner.$LOCK_TOKEN"
  printf 'pid\t%s\nstart\t%s\ntoken\t%s\n' \
    "$$" "$LOCK_START_IDENTITY" "$LOCK_TOKEN" > "$LOCK_METADATA_TEMP" || return 1
  if [ -d "$LOCK/reclaim" ]; then
    rm -f "$LOCK_METADATA_TEMP"
    LOCK_METADATA_TEMP=""
    return 1
  fi
  mv "$LOCK_METADATA_TEMP" "$LOCK_OWNER" || return 1
  LOCK_METADATA_TEMP=""
}

lock_is_owned_by_self() {
  read_lock_owner "$LOCK" || return 1
  [ "$LOCK_OWNER_PID" = "$$" ] \
    && [ "$LOCK_OWNER_START" = "$LOCK_START_IDENTITY" ] \
    && [ "$LOCK_OWNER_TOKEN" = "$LOCK_TOKEN" ]
}

cleanup() {
  if [ -n "$TEMP_STATE" ]; then
    rm -f "$TEMP_STATE"
    TEMP_STATE=""
  fi
  if [ "$LOCK_OWNED" -eq 1 ]; then
    if lock_is_owned_by_self; then
      rm -f "$LOCK_OWNER"
    elif [ ! -e "$LOCK_OWNER" ] && [ -n "$LOCK_METADATA_TEMP" ]; then
      rm -f "$LOCK_METADATA_TEMP"
    fi
    rmdir "$LOCK" 2>/dev/null || true
    LOCK_OWNED=0
  fi
}

terminate_sketchybar() {
  if [ -n "$SKETCHYBAR_PID" ]; then
    kill -TERM "$SKETCHYBAR_PID" 2>/dev/null || true
    wait "$SKETCHYBAR_PID" 2>/dev/null || true
    SKETCHYBAR_PID=""
  fi
}

on_signal() {
  status="$1"
  if [ "$LOCK_ACQUISITION_PENDING" -eq 1 ]; then
    if [ "$PENDING_SIGNAL_STATUS" -eq 0 ]; then
      PENDING_SIGNAL_STATUS="$status"
    fi
    return
  fi
  trap - EXIT INT TERM
  terminate_sketchybar
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

case "$MODE" in
  light)
    BAR_TEXT=0xff4a4741
    BRAND=0xff4a4741
    CREST="$LIGHT_CREST"
    ;;
  dark)
    BAR_TEXT=0xffd8d4c4
    BRAND=0xffbc9a5a
    CREST="$DARK_CREST"
    ;;
esac

if [ ! -f "$CREST" ]; then
  echo "missing crest: $CREST" >&2
  exit 1
fi

LOCK_START_IDENTITY="$(process_start_identity "$$")"
if [ -z "$LOCK_START_IDENTITY" ]; then
  echo "could not determine appearance lock owner identity" >&2
  exit 1
fi

attempt=0
while :; do
  LOCK_ACQUISITION_PENDING=1
  lock_metadata_status=0
  mkdir "$LOCK" 2>/dev/null
  mkdir_status=$?
  if [ "$mkdir_status" -eq 0 ]; then
    LOCK_OWNED=1
    write_lock_owner || lock_metadata_status=$?
  fi
  LOCK_ACQUISITION_PENDING=0
  if [ "$PENDING_SIGNAL_STATUS" -ne 0 ]; then
    on_signal "$PENDING_SIGNAL_STATUS"
  fi
  if [ "$mkdir_status" -eq 0 ] && [ "$lock_metadata_status" -ne 0 ]; then
    echo "could not record appearance lock ownership" >&2
    exit "$lock_metadata_status"
  fi
  [ "$mkdir_status" -ne 0 ] || break
  reclaim_stale_lock || true
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || {
    echo "appearance lock timeout" >&2
    exit 75
  }
  sleep 0.1
done

if [ -f "$STATE" ] && [ "$(<"$STATE")" = "$MODE" ] && [ "$FORCE" != "--force" ]; then
  exit 0
fi

"$SKETCHYBAR" --set clock label.color="$BAR_TEXT" --set date label.color="$BAR_TEXT" \
  --set yorha label.color="$BRAND" --set yorha_icon background.image="$CREST" &
SKETCHYBAR_PID=$!
wait "$SKETCHYBAR_PID"
status=$?
SKETCHYBAR_PID=""
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

TEMP_STATE="$(mktemp "$ROOT/.last-successful-mode.XXXXXX")" || exit 1
printf '%s\n' "$MODE" > "$TEMP_STATE" || exit 1
mv -f "$TEMP_STATE" "$STATE" || exit 1
TEMP_STATE=""
