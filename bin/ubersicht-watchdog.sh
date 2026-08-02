#!/usr/bin/env bash
# Übersicht watchdog — keeps the desktop layer actually working, not merely running.
#
# WHY NOT A PLAIN KeepAlive: the observed failure is not the app exiting. The app
# stays alive while its node widget server dies — no crash report, port dead, blank
# desktop. launchd sees a healthy process and does nothing. So this checks HEALTH,
# not liveness, and restarts only when the app is genuinely wedged.
#
# It also covers ordinary KeepAlive semantics: if Übersicht is not running at all
# (login, crash, manual kill), it gets started. That is what makes the desktop
# come back on boot.
#
# OPT-OUT: create ~/.config/yorha/cache/watchdog.off and this script does nothing.
#   touch ~/.config/yorha/cache/watchdog.off     # stop babysitting
#   rm    ~/.config/yorha/cache/watchdog.off     # resume
# Without that, quitting Übersicht deliberately would just see it return in <60s.
set -uo pipefail

CACHE="$HOME/.config/yorha/cache"
LOG="$CACHE/watchdog.log"
STRIKES="$CACHE/watchdog.strikes"
OFF="$CACHE/watchdog.off"
BUNDLE="tracesOf.Uebersicht"
MAX_STRIKES=2          # ~2 min unhealthy before acting; rides out refresh transients

mkdir -p "$CACHE"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

[ -f "$OFF" ] && exit 0

# Keep the log from growing without bound.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
  tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

strikes() { cat "$STRIKES" 2>/dev/null || echo 0; }
set_strikes() { echo "$1" > "$STRIKES"; }

restart() {
  local why="$1"
  log "UNHEALTHY ($why) — restarting"
  # NOTE: pkill -f "Übersicht.app" matches NOTHING because of the umlaut. Kill by PID.
  local pid
  pid=$(pgrep -f "bersicht.app/Contents/MacOS" | head -1)
  [ -n "$pid" ] && { kill -9 "$pid" 2>/dev/null; sleep 3; }
  open -b "$BUNDLE" 2>/dev/null
  set_strikes 0
  log "relaunched"
}

# --- 1. is the app running at all? ----------------------------------------
APP_PID=$(pgrep -f "bersicht.app/Contents/MacOS" | head -1)
if [ -z "$APP_PID" ]; then
  log "not running — starting"
  open -b "$BUNDLE" 2>/dev/null
  set_strikes 0
  exit 0
fi

# --- 2. does it still have its node widget server? -------------------------
# The wedge the user actually hit: app alive, this child gone.
NODE_PID=$(pgrep -f "bersicht.app/Contents/Resources/node" | head -1)
if [ -z "$NODE_PID" ]; then
  n=$(( $(strikes) + 1 )); set_strikes "$n"
  [ "$n" -ge "$MAX_STRIKES" ] && restart "widget server process gone"
  exit 0
fi

# --- 3. is that server actually answering? ---------------------------------
PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$NODE_PID" 2>/dev/null \
        | awk 'NR>1 {split($9,a,":"); print a[length(a)]; exit}')
if [ -z "$PORT" ]; then
  n=$(( $(strikes) + 1 )); set_strikes "$n"
  [ "$n" -ge "$MAX_STRIKES" ] && restart "server listening on no port"
  exit 0
fi

CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)
if [ "$CODE" != "200" ]; then
  n=$(( $(strikes) + 1 )); set_strikes "$n"
  [ "$n" -ge "$MAX_STRIKES" ] && restart "server on :$PORT returned '$CODE'"
  exit 0
fi

# healthy — clear any accumulated strikes
[ "$(strikes)" != "0" ] && { log "recovered (:$PORT healthy)"; set_strikes 0; }
exit 0
