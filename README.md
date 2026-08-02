# YoRHa Desktop Environment

A NieR-inspired desktop for macOS: dark hacking-mode terminal, light parchment
palette everywhere else, and a Pod 042 support unit that talks to Gemini.

**Host it was built on:** macOS 26.5.2, Apple Silicon, SIP enabled and staying that way.

---

## What this repo is

The **source of truth** for the whole setup. The live configuration lives in the
places macOS reads from (`~/.config/…`, `~/Library/Application Support/…`); this
repo holds the authoritative copies plus the Gemini integration and the docs.

```
bin/deploy.sh    repo  ->  live locations   (also loads the oracle timer)
bin/capture.sh   live  ->  repo             (run after editing something in place)
```

Edit here, run `deploy.sh`. Or edit in place, run `capture.sh`, then `git diff`
to see exactly what changed on the machine.

---

## Layout

| Path | What it is |
|---|---|
| `bin/pod-oracle.py` | Generates Pod messages via Gemini. Runs on a timer, never from the widget. |
| `bin/deploy.sh` / `capture.sh` | Sync in each direction. |
| `bin/yorha-backup.sh` | Snapshots every path the install touches and emits a tested `restore.sh`. |
| `bin/ubersicht-watchdog.sh` | Health-checks Übersicht every 60s and restarts it after 2 consecutive failures. Also starts it at login. |
| `bin/make-wallpaper.sh` | Rasterizes `assets/wallpaper.svg` → `.png` and sets it as the desktop. Verifies the output dimensions; Chrome silently clamps oversized headless viewports. |
| `widgets/yorha/*.jsx` | Übersicht desktop layer: HUD, Pod, scan beam, corner ornaments (arcs + line trio, ported from the portfolio). |
| `config/ghostty/` | Terminal config + the CRT shader. **Two** config files — see below. |
| `config/sketchybar/` | Menu bar. Transparent — no fill, no border; items float on the wallpaper. |
| `config/aerospace/` | Tiling config. Installed, `start-at-login = false`, currently not running by choice. |
| `config/shell/` | Palette, zsh layer, Starship prompt, fastfetch, boot logo. |
| `config/editor/` | VS Code–format colour theme. Install it yourself; nothing deploys into an editor. |
| `assets/wallpaper.svg` | Wallpaper source. The PNG is generated and gitignored — regenerate with `bin/make-wallpaper.sh`. |
| `assets/yorha-icon.svg` / `.png` | The YoRHa crest. The PNG is the ink-tinted 31×36 raster the bar uses; `deploy.sh` copies it to `~/.config/sketchybar/` because launchd services cannot read TCC-protected `~/Documents`. |
| `launchd/` | Two agents: the oracle's 5-minute timer and the Übersicht watchdog. |
| `docs/` | Architecture, palette, and the decision log. |

---

## The Pod 042 oracle

**Online** → Gemini writes the status reports.
**Offline** → the built-in static reports, byte-identical to the original behaviour.

```
launchd (every 5 min)
   └─ bin/pod-oracle.py
        ├─ reads aggregate telemetry
        ├─ calls gemini-3.1-flash-lite  (fallback: -preview)
        └─ atomically writes ~/.config/yorha/cache/pod-oracle.json  (6 messages)

pod.jsx (every 45 s)
   └─ reads that cache — never the network
        ├─ fresh (< 20 min) → Gemini messages, header shows ◂LINK
        └─ stale / missing / unparseable → static reports, header shows LOCAL
```

**The widget never makes a network call.** A slow or failed API request cannot
stall the desktop; the worst case is that the cache stops being refreshed and the
Pod falls back. The oracle writes via `os.replace`, so the widget can never read a
half-written file.

### What is sent to Google

`build_telemetry()` in `bin/pod-oracle.py` is the complete and only payload:

```json
{"cpu_percent","memory_percent","disk_free","battery_percent","external_power","uptime"}
```

Aggregate machine state, nothing more. No hostname, username, IP address,
filenames, application names, window titles, or network destinations. If you ever
want to verify that claim, that one function is the only place it could change.

### The API key

Stored at `~/.config/yorha/secrets/gemini.key`, `chmod 600`, **outside this repo**.
`secrets/` and `*.key` are gitignored as belt and braces. It is never committed,
never logged, and never appears in widget output.

Rotate it by overwriting that file — nothing else needs to change.

### Model choice

`gemini-3.1-flash-lite`, chosen by measurement rather than by name:

| Model | Latency | Tokens | Status |
|---|---|---|---|
| `gemini-3.1-flash-lite` | ~1.6 s | ~85 | **in use** |
| `gemini-3.1-flash-lite-preview` | ~1.1 s | ~82 | fallback |
| `gemini-3-flash-preview` | ~7.9 s | ~2019 | rejected — it reasons before answering; 24× the cost for one line |
| `gemini-2.5-flash`, `-flash-lite` | — | — | HTTP 404, retired for new keys |
| `gemini-2.0-flash`, `-flash-lite` | — | — | HTTP 429, quota exhausted |

Three of those were discovered dead *during* setup, which is why the oracle has a
fallback model and fails silently to static rather than trusting one endpoint.

At 5-minute intervals this is roughly **288 calls/day**, ~310 tokens each.

---

## Gotchas that cost real time

Recorded because each one was expensive to find and is easy to hit again.

**Ghostty reads two config files.** `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
silently **overrides** `~/.config/ghostty/config` for any key it sets. Validation
against the XDG file will happily report success while the terminal ignores it.
`deploy.sh` writes both.

**The umlaut in `Übersicht` breaks shell patterns.** `pkill -f "Übersicht.app"`
matches nothing. Kill it by PID:
`kill -9 $(pgrep -f "bersicht.app/Contents/MacOS" | head -1)`

**Übersicht's server can die while the app stays alive.** No crash report; the
desktop simply goes blank. This is why `bin/ubersicht-watchdog.sh` exists — a plain
`KeepAlive` would not help, because launchd sees a perfectly healthy app process.
The watchdog checks health (server child present, listening, answering 200) every
60s and restarts only after 2 consecutive failures. It also starts Übersicht at
login, which is what makes the desktop layer survive a reboot.

Pause it with `touch ~/.config/yorha/cache/watchdog.off`, resume by removing that
file. Without the flag, quitting Übersicht deliberately would just see it return
within a minute.

**`sketchybar --animate … --bar y_offset` silently no-ops after a reload.** The rc
once parked the bar at `y_offset=-36` and relied on the entrance animation to slide
it in; a reload dropped the animation and stranded the entire bar invisible
off-screen. Visibility must never depend on an animation firing — the rc now ends
with an unconditional `y_offset=0`, and the slide-in ceremony is scoped to first
login via a `/tmp` sentinel.

**The browser preview of Übersicht (127.0.0.1:41416) is not ground truth.** A
second browser client can mount every widget container and render nothing into
any of them — while the desktop webview is perfectly healthy. Twice this led to
debugging a "blank desktop" that was never blank. Verify on the desktop itself.

**Widget CSS is document-global — namespace every class.** Übersicht injects all
widget `<style>` blocks into one shared document. A generic `.tl { top:0 }` in
the arcs widget overrode the HUD's `.tl { top:60px }` and yanked its left column
to the screen edge; the earlier `.enter` collision was the same disease. Every
class a widget defines gets a widget prefix, no exceptions.

**SketchyBar's query telemetry is not a visibility oracle.** After reloads,
`bounding_rects` comes back empty and `--query displays` returns `[]` even while
the bar is rendering perfectly on screen. Verify visibility with eyes or the
window server, not with queries — half an hour was once spent "fixing" a bar that
was never broken.

**A widget with `refreshFrequency` but no `command` never re-renders.** Übersicht
only creates the refresh timer for widgets that have a command; a widget that
needs periodic re-renders must export a trivial command (`"true"`) even if it
ignores the output. (The since-removed reticle widget learned this the hard way.)

**Übersicht renders once with `output: ""` before the command runs.** Any widget
that mutates module state on that placeholder render will corrupt its first real
render. `hud.jsx` and `pod.jsx` both return early on empty output.

**`animation-fill-mode: both` on a reveal animation fails invisible.** If the
animation never starts, the `from` state persists. The Pod's typewriter once left
messages permanently blank this way. Base states are now the *visible* state.

**Don't derive layout numbers — measure them.** The Pod panel is content-box, so
its 300px width *is* the text area; "300 minus padding" was wrong and over-scrolled
the marquee by 40px.

---

## Restore

```bash
bash "$(cat ~/.config/yorha/BACKUP_PATH)/restore.sh"
```

Points at an immutable pre-install baseline. Stops services, removes LaunchAgents,
restores both Ghostty configs and `~/.zshrc`, and derives its uninstall advice by
diffing the captured package manifest. Verified by sandboxed dry run.

---

## Requirements

Already installed on the build host:

```bash
brew install --cask ghostty ubersicht font-cascadia-code font-cascadia-code-nf
brew tap FelixKratz/formulae && brew install sketchybar borders
brew install starship fastfetch jq
brew install --cask nikitabobko/tap/aerospace   # optional; tiling is opt-in
```
