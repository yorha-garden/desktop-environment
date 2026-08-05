#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "usage: $0 light|dark [--force]" >&2
}

internal_usage() {
  exit 64
}

TAB="$(printf '\t')"
INTERNAL_OPERATION=""
if [ "${1:-}" = "--internal-lock-operation" ]; then
  [ "$#" -eq 7 ] || internal_usage
  INTERNAL_OPERATION="$2"
  ROOT="$3"
  LOCK_CANDIDATE="$4"
  LOCK_EXPECTED_PID="$5"
  LOCK_START_IDENTITY="$6"
  LOCK_TOKEN="$7"
  case "$INTERNAL_OPERATION" in
    acquire | cleanup) ;;
    *) internal_usage ;;
  esac
  case "$ROOT" in
    /*) ;;
    *) internal_usage ;;
  esac
  [ "$ROOT" != "/" ] && [ "${ROOT%/}" = "$ROOT" ] \
    && [ ! -L "$ROOT" ] && [ -d "$ROOT" ] || internal_usage
  case "$LOCK_EXPECTED_PID" in
    ''|0|0*|*[!0-9]*) internal_usage ;;
  esac
  case "$LOCK_START_IDENTITY" in
    ''|*$'\t'*|*$'\r'*|*$'\n'*) internal_usage ;;
  esac
  case "$LOCK_TOKEN" in
    ''|*[!0-9.]*) internal_usage ;;
  esac
  token_pid="${LOCK_TOKEN%%.*}"
  token_tail="${LOCK_TOKEN#*.}"
  token_time="${token_tail%%.*}"
  token_random="${token_tail#*.}"
  [ "$token_pid" = "$LOCK_EXPECTED_PID" ] \
    && [ "$token_tail" != "$LOCK_TOKEN" ] \
    && [ "$token_random" != "$token_tail" ] \
    || internal_usage
  case "$token_time:$token_random" in
    *[!0-9:]*|:*|*:) internal_usage ;;
  esac
  [ "${YORHA_LOCK_PARENT_PID:-}" = "$LOCK_EXPECTED_PID" ] || internal_usage
  [ "$LOCK_CANDIDATE" = "$ROOT/.apply.lock.candidate.$LOCK_TOKEN" ] \
    && [ ! -L "$LOCK_CANDIDATE" ] && [ -f "$LOCK_CANDIDATE" ] \
    || internal_usage
  MODE=""
  FORCE=""
else
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
  LOCK_EXPECTED_PID="$$"
  LOCK_START_IDENTITY=""
  LOCK_TOKEN="$$.$(date +%s).$RANDOM"
  LOCK_CANDIDATE="$ROOT/.apply.lock.candidate.$LOCK_TOKEN"
fi

STATE="$ROOT/last-successful-mode"
LOCK="$ROOT/apply.lock"
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
LOCK_GUARD="$ROOT/.apply.lock.guard"
LOCKF="${YORHA_LOCKF_BIN:-/usr/bin/lockf}"
LOCK_STALE_GRACE_SECONDS=5

process_start_identity() {
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

read_lock_owner() {
  if [ -d "$1" ]; then
    owner_file="$1/owner"
  else
    owner_file="$1"
  fi
  LOCK_OWNER_PID=""
  LOCK_OWNER_START=""
  LOCK_OWNER_TOKEN=""
  [ ! -L "$owner_file" ] && [ -f "$owner_file" ] || return 1

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

lock_is_stale() {
  lock_modified="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)"
  case "$lock_modified" in
    ''|*[!0-9]*) return 1 ;;
  esac
  lock_now="$(date +%s)"
  [ $((lock_now - lock_modified)) -ge "$LOCK_STALE_GRACE_SECONDS" ]
}

reclaim_stale_lock() {
  [ -e "$LOCK" ] || [ -L "$LOCK" ] || return 0
  if read_lock_owner "$LOCK"; then
    current_start="$(process_start_identity "$LOCK_OWNER_PID")"
    if [ -n "$current_start" ] && [ "$current_start" = "$LOCK_OWNER_START" ]; then
      return 1
    fi
  else
    # Only malformed legacy residue needs grace; current publishers expose a
    # complete owner record in the same atomic link that creates LOCK.
    lock_is_stale "$LOCK" || return 1
  fi

  # Every compliant publisher, reclaimer, and cleanup holds LOCK_GUARD here.
  # A directory can only be residue from the prior lock format.
  if [ -d "$LOCK" ]; then
    reclaim_tombstone="$LOCK.reclaim.$LOCK_TOKEN"
    if mv "$LOCK" "$reclaim_tombstone" 2>/dev/null; then
      rm -rf "$reclaim_tombstone"
      return 0
    fi
    return 1
  fi
  rm -f "$LOCK"
}

prepare_lock_candidate() {
  (umask 077
    set -C
    printf 'pid\t%s\nstart\t%s\ntoken\t%s\n' \
      "$LOCK_EXPECTED_PID" "$LOCK_START_IDENTITY" "$LOCK_TOKEN" \
      > "$LOCK_CANDIDATE"
  )
}

publish_lock_candidate() {
  # POSIX ln treats an existing directory as a destination directory. Test the
  # public pathname while holding LOCK_GUARD so legacy directory locks cannot be
  # mistaken for a successful publication inside that directory.
  [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  ln "$LOCK_CANDIDATE" "$LOCK" 2>/dev/null
}

lock_is_owned_by_self() {
  [ ! -L "$LOCK" ] && [ -f "$LOCK" ] \
    && [ -f "$LOCK_CANDIDATE" ] && [ "$LOCK" -ef "$LOCK_CANDIDATE" ] \
    || return 1
  read_lock_owner "$LOCK_CANDIDATE" || return 1
  [ "$LOCK_OWNER_PID" = "$LOCK_EXPECTED_PID" ] \
    && [ "$LOCK_OWNER_START" = "$LOCK_START_IDENTITY" ] \
    && [ "$LOCK_OWNER_TOKEN" = "$LOCK_TOKEN" ]
}

perform_internal_lock_operation() {
  case "$INTERNAL_OPERATION" in
    acquire)
      read_lock_owner "$LOCK_CANDIDATE" \
        && [ "$LOCK_OWNER_PID" = "$LOCK_EXPECTED_PID" ] \
        && [ "$LOCK_OWNER_START" = "$LOCK_START_IDENTITY" ] \
        && [ "$LOCK_OWNER_TOKEN" = "$LOCK_TOKEN" ] \
        || return 1
      internal_owner_start="$(process_start_identity "$LOCK_EXPECTED_PID")"
      [ -n "$internal_owner_start" ] \
        && [ "$internal_owner_start" = "$LOCK_START_IDENTITY" ] \
        || return 1
      publish_lock_candidate
      internal_status=$?
      if [ "$internal_status" -ne 0 ] && reclaim_stale_lock; then
        publish_lock_candidate
        internal_status=$?
      fi
      return "$internal_status"
      ;;
    cleanup)
      lock_is_owned_by_self && rm -f "$LOCK"
      return 0
      ;;
  esac
  return 64
}

if [ -n "$INTERNAL_OPERATION" ]; then
  perform_internal_lock_operation
  exit $?
fi

run_guarded_lock_operation() {
  YORHA_LOCK_PARENT_PID="$$" "$LOCKF" -s -t 0 -k "$LOCK_GUARD" \
    "$0" --internal-lock-operation "$1" "$ROOT" "$LOCK_CANDIDATE" \
    "$LOCK_EXPECTED_PID" "$LOCK_START_IDENTITY" "$LOCK_TOKEN"
}

cleanup() {
  if [ -n "$TEMP_STATE" ]; then
    rm -f "$TEMP_STATE"
    TEMP_STATE=""
  fi
  if [ "$LOCK_OWNED" -eq 1 ]; then
    cleanup_guard_attempt=0
    while ! run_guarded_lock_operation cleanup; do
      cleanup_guard_attempt=$((cleanup_guard_attempt + 1))
      [ "$cleanup_guard_attempt" -lt 100 ] || break
      /bin/sleep 0.01
    done
    LOCK_OWNED=0
  fi
  rm -f "$LOCK_CANDIDATE"
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
if [ ! -x "$LOCKF" ]; then
  echo "missing atomic lock helper: $LOCKF" >&2
  exit 1
fi
if ! prepare_lock_candidate; then
  echo "could not prepare appearance lock ownership" >&2
  exit 1
fi

attempt=0
while :; do
  LOCK_ACQUISITION_PENDING=1
  run_guarded_lock_operation acquire
  publish_status=$?
  if [ "$publish_status" -eq 0 ]; then
    LOCK_OWNED=1
  fi
  LOCK_ACQUISITION_PENDING=0
  if [ "$PENDING_SIGNAL_STATUS" -ne 0 ]; then
    on_signal "$PENDING_SIGNAL_STATUS"
  fi
  [ "$publish_status" -ne 0 ] || break
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
