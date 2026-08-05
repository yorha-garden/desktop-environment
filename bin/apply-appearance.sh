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
until mkdir "$LOCK" 2>/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || {
    echo "appearance lock timeout" >&2
    exit 75
  }
  sleep 0.1
done

cleanup() {
  rmdir "$LOCK" 2>/dev/null || true
}

on_signal() {
  status="$1"
  trap - EXIT INT TERM
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

if [ -f "$STATE" ] && [ "$(<"$STATE")" = "$MODE" ] && [ "$FORCE" != "--force" ]; then
  exit 0
fi

"$SKETCHYBAR" --set clock label.color="$BAR_TEXT" --set date label.color="$BAR_TEXT" \
  --set yorha label.color="$BRAND" --set yorha_icon background.image="$CREST"
status=$?
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

temporary_state="$(mktemp "$ROOT/.last-successful-mode.XXXXXX")" || exit 1
printf '%s\n' "$MODE" > "$temporary_state" || exit 1
mv -f "$temporary_state" "$STATE"
