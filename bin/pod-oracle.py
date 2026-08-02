#!/usr/bin/env python3
"""
Pod 042 oracle — generates status reports via Google Gemini.

Runs on a timer (see launchd/com.yorha.pod-oracle.plist), NOT from the widget.
The widget must never block on the network, so this writes a cache the widget
reads instantly. If this script fails for any reason — offline, API error,
quota, retired model — it leaves the previous cache untouched and the widget
falls back to its built-in static reports. Failure is always silent and safe.

PRIVACY: the payload below is the complete set of data sent to Google. It is
aggregate machine state only. No hostname, username, IP, filenames, app names,
window titles, or network destinations are collected or transmitted. The
build_telemetry() function is the single place this could change; keep it that way.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

KEY_PATH = os.path.expanduser("~/.config/yorha/secrets/gemini.key")
CACHE_DIR = os.path.expanduser("~/.config/yorha/cache")
CACHE_PATH = os.path.join(CACHE_DIR, "pod-oracle.json")
LOG_PATH = os.path.join(CACHE_DIR, "pod-oracle.log")

MODEL = "gemini-3.1-flash-lite"
FALLBACK_MODEL = "gemini-3.1-flash-lite-preview"
BATCH = 6          # messages per call; widget cycles one per 45s refresh
TIMEOUT = 20
MAX_CHARS = 72     # panel marquees anything longer; beyond this it scrolls too long


def log(msg):
    os.makedirs(CACHE_DIR, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{stamp}  {msg}\n")
    except OSError:
        pass


def sh(cmd, default=""):
    try:
        return subprocess.run(["/bin/sh", "-c", cmd], capture_output=True,
                              text=True, timeout=8).stdout.strip() or default
    except Exception:
        return default


def build_telemetry():
    """The COMPLETE set of data sent off-device. Aggregate state only."""
    ncpu = sh("sysctl -n hw.ncpu", "8")
    cpu = sh("ps -A -o %%cpu | awk '{s+=$1} END {printf \"%%.0f\", s/%s}'" % ncpu, "0")
    mem = sh("memory_pressure | awk '/percentage/ {print 100-$5}' | tr -d '%'", "0")
    disk = sh("df -h / | awk 'NR==2 {print $4}'", "?")
    pm = sh("pmset -g batt")
    batt = sh("echo %s | grep -Eo '[0-9]+%%' | head -1 | tr -d '%%'" % json.dumps(pm), "?")
    ac = "yes" if "AC Power" in pm else "no"
    up = sh("uptime | awk -F'up ' '{print $2}' | sed -E 's/, *[0-9]+ users?,.*//'", "?")
    return {"cpu_percent": cpu, "memory_percent": mem, "disk_free": disk,
            "battery_percent": batt, "external_power": ac, "uptime": up}


PROMPT = """You are Pod 042, an android support unit assigned to a human operator.

Write exactly {n} distinct status reports, one per line, no numbering, no bullets,
no quotation marks, no markdown.

Voice: clinical, terse, faintly deadpan. You are a machine that has been observing
this operator for a long time and has developed something adjacent to concern but
would never call it that. Prefer sentence openers like "Proposal:", "Analysis:",
"Recommendation:", "Observation:", or a plain declarative. Occasional dry
understatement is welcome. Never use emoji or exclamation marks.

Each line must be at most {max} characters.

Base at least half the reports on this telemetry; the rest may be general
observations about the operator or the unit's own condition:
{telemetry}

Output only the {n} lines."""


def call(model, telemetry, key):
    body = json.dumps({
        "contents": [{"parts": [{"text": PROMPT.format(
            n=BATCH, max=MAX_CHARS,
            telemetry=json.dumps(telemetry, indent=2))}]}],
        "generationConfig": {"maxOutputTokens": 2000, "temperature": 1.35,
                             "topP": 0.95},
    }).encode()
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
           f"{model}:generateContent?key={key}")
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        j = json.load(r)
    cand = j["candidates"][0]
    text = "".join(p.get("text", "") for p in cand.get("content", {}).get("parts", []))
    tokens = j.get("usageMetadata", {}).get("totalTokenCount", 0)
    return text, tokens


def clean(text):
    out = []
    for raw in text.splitlines():
        line = raw.strip().strip('"').strip("'").lstrip("-*0123456789. ").strip()
        if not line:
            continue
        if len(line) > MAX_CHARS:
            line = line[:MAX_CHARS - 1].rstrip() + "…"
        out.append(line)
    return out


def main():
    if not os.path.exists(KEY_PATH):
        log("no key file; leaving cache untouched")
        return 1
    key = open(KEY_PATH).read().strip()
    if not key:
        log("empty key; leaving cache untouched")
        return 1

    telemetry = build_telemetry()

    for model in (MODEL, FALLBACK_MODEL):
        try:
            t0 = time.time()
            text, tokens = call(model, telemetry, key)
            msgs = clean(text)
            if len(msgs) < 2:
                log(f"{model}: only {len(msgs)} usable lines; trying next")
                continue
            os.makedirs(CACHE_DIR, exist_ok=True)
            payload = {"generated": int(time.time()), "model": model,
                       "messages": msgs[:BATCH]}
            tmp = CACHE_PATH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(payload, f, separators=(",", ":"))
            os.replace(tmp, CACHE_PATH)  # atomic; widget never sees a partial file
            log(f"{model}: {len(msgs)} msgs, {tokens} tok, "
                f"{int((time.time()-t0)*1000)}ms")
            return 0
        except urllib.error.HTTPError as e:
            try:
                err = json.loads(e.read()).get("error", {})
                log(f"{model}: HTTP {err.get('code')} {err.get('status')}")
            except Exception:
                log(f"{model}: HTTP {e.code}")
        except urllib.error.URLError as e:
            log(f"offline or unreachable ({e.reason}); cache untouched")
            return 2   # expected when offline; widget falls back to static
        except Exception as e:
            log(f"{model}: {type(e).__name__}: {e}")

    log("all models failed; cache untouched")
    return 1


if __name__ == "__main__":
    sys.exit(main())
