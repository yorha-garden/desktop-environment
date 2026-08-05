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
LIGHT_CREST="$ROOT/yorha-icon-light.png"
DARK_CREST="$ROOT/yorha-icon-dark.png"
SKETCHYBAR="${YORHA_SKETCHYBAR_BIN:-sketchybar}"
LOCK_OWNED=0
LOCK_ACQUISITION_PENDING=0
PENDING_SIGNAL_STATUS=0
TEMP_STATE=""
SKETCHYBAR_PID=""

cleanup() {
  if [ -n "$TEMP_STATE" ]; then
    rm -f "$TEMP_STATE"
    TEMP_STATE=""
  fi
  if [ "$LOCK_OWNED" -eq 1 ]; then
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
    PENDING_SIGNAL_STATUS="$status"
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

attempt=0
while :; do
  LOCK_ACQUISITION_PENDING=1
  mkdir "$LOCK" 2>/dev/null
  mkdir_status=$?
  if [ "$mkdir_status" -eq 0 ]; then
    LOCK_OWNED=1
  fi
  LOCK_ACQUISITION_PENDING=0
  if [ "$PENDING_SIGNAL_STATUS" -ne 0 ]; then
    on_signal "$PENDING_SIGNAL_STATUS"
  fi
  [ "$mkdir_status" -ne 0 ] || break
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
