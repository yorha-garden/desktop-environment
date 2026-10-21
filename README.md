# YoRHa Desktop Environment

A NieR-inspired desktop for macOS: automatic appearance switching for the wallpaper,
desktop widgets, and menu bar, plus a Pod 042 support unit that talks to Gemini.
Ghostty remains permanently dark; the appearance system never edits or reloads it.

**Host it was built on:** macOS 26.5.2, Apple Silicon, SIP enabled and staying that way.

---

## What this repo is

The **source of truth** for the whole setup. The live configuration lives in the
places macOS reads from (`~/.config/…`, `~/Library/Application Support/…`); this
repo holds the authoritative copies plus the Gemini integration and the docs.

```
bin/deploy.sh    repo  ->  live locations   (also loads two feature-owned LaunchAgents)
bin/capture.sh   live  ->  repo             (run after editing something in place)
```

`deploy.sh` keeps whatever wallpaper you have set. Run `deploy.sh --wallpaper` to
set the YoRHa wallpaper on every desktop as well.

Edit here, run `deploy.sh`. Or edit in place, run `capture.sh`, then `git diff`
to see exactly what changed on the machine.

---

## Layout

| Path | What it is |
|---|---|
| `bin/pod-oracle.py` | Generates Pod messages via Gemini. Runs on a timer, never from the widget. |
| `bin/deploy.sh` / `capture.sh` | Sync in each direction. `deploy.sh --wallpaper` also sets the YoRHa wallpaper. |
| `bin/yorha-backup.sh` | Snapshots every path the install touches and emits a tested `restore.sh`. |
| `bin/yorha-watcher` | On/off switch for YoRHa Desktop, or only its bar. Deployed to `~/.local/bin`. |
| `bin/build-desktop.sh` / `install-desktop.sh` | Compile YoRHa Desktop; install it under `~/.config/yorha/bin`, load its LaunchAgent, and retire Übersicht and SketchyBar. `deploy.sh` calls the installer. |
| `bin/make-wallpaper.sh` | Verifies or assigns the committed dynamic HEIC; it never regenerates assets. |
| `bin/yorha-system-wallpaper.swift` | Builds, inspects, and extracts the exact two-frame dynamic-HEIC contract. |
| `bin/regenerate-system-wallpaper.sh` | Developer-only SVG rasterization and HEIC regeneration entry point. |
| `native/YoRHaDesktop/` | **YoRHa Desktop**, the native desktop layer (Swift + Core Animation): scan beam, corner ornaments, HUD, Pod panel, and the menu bar in one process. Replaced the Übersicht widgets and SketchyBar. |
| `config/ghostty/` | Terminal config + the CRT shader. **Two** config files — see below. |
| `config/aerospace/` | Tiling config. Installed, `start-at-login = false`, currently not running by choice. |
| `config/shell/` | Palette, zsh layer, Starship prompt, fastfetch, boot logo. |
| `config/editor/` | VS Code–format colour theme. Install it yourself; nothing deploys into an editor. |
| `assets/wallpaper.svg` / `wallpaper-dark.svg` | Developer SVG sources for the matching light and dark wallpaper frames. |
| `assets/yorha-system.heic` | Committed two-frame 5120×2880 dynamic wallpaper; deployment installs it, `deploy.sh --wallpaper` sets it, then macOS owns frame selection. |
| `assets/yorha-icon-light.png` / `yorha-icon-dark.png` | Bar crest sources. The dark one is embedded in the app (`BarCrest.swift`) and tinted per appearance; a test keeps them in sync. |
| `launchd/` | The oracle timer and YoRHa Desktop. |
| `docs/` | Architecture, palette, and the decision log. |

---

## Automatic appearance

The macOS effective appearance owns the change. Deployment installs one stable
`yorha-system.heic` path, and `deploy.sh --wallpaper` sets it on every desktop; its
native appearance metadata lets macOS choose the light or dark frame without a
wallpaper script, process restart, or per-transition assignment. A plain deploy
keeps whatever wallpaper is set. YoRHa Desktop follows the same system state by
observing `NSApp.effectiveAppearance` and easing its palette over 200 ms, so
widgets and the bar keep their state and animations instead of reloading.

```text
macOS effective appearance
   ├─ native wallpaper engine -> selects the HEIC frame
   └─ YoRHa Desktop           -> swaps its palette in place (widgets and bar)
```

Deployment manages two feature-owned LaunchAgents: the Pod oracle timer and
YoRHa Desktop (`com.yorha.desktop`, plain `KeepAlive`). The bar used to be
SketchyBar, recoloured by a separate appearance watcher and coordinator and
clocked by a launchd minute trigger; all three retired when the bar moved into
YoRHa Desktop. The one appearance runtime file is deliberately outside the
TCC-protected repository:

```text
~/.config/yorha/appearance/yorha-system.heic
```

Ghostty remains permanently dark. Nothing in the appearance system reads, writes,
reloads, or signals either Ghostty configuration or its running windows.

The committed HEIC is the deployment source. Asset regeneration is an explicit
developer operation and requires Chrome:

```bash
bin/regenerate-system-wallpaper.sh --with-chrome
```

Normal deployment only inspects the committed file; it never launches Chrome or
regenerates wallpaper frames.

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

YoRHa Desktop's Pod panel (every 30 s)
   └─ reads that cache — never the network
        ├─ fresh (< 20 min) → Gemini messages, header shows ◂LINK
        └─ stale / missing / unparseable → static reports, header shows LOCAL
```

**The desktop layer never makes a network call.** A slow or failed API request cannot
stall the desktop; the worst case is that the cache stops being refreshed and the
Pod falls back. The oracle writes via `os.replace`, so the panel can never read a
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
never logged, and never appears on the desktop.

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

**To switch helpers off and keep them off across logins, use `yorha-watcher`.**
`yorha-watcher off` stops YoRHa Desktop and keeps it off at login; `yorha-watcher on`
reverses it. `yorha-watcher off bar` hides only the bar: it leaves
`~/.config/yorha/bar-off` and restarts the desktop, which reads the marker at
launch (the restart replays the desktop entrances). `yorha-watcher status` shows
the current state. `deploy.sh` leaves a switched-off desktop layer unloaded.

**Visibility must never depend on an animation firing.** SketchyBar once parked the
bar off-screen and relied on a slide-in that a reload silently dropped, stranding
the bar invisible. The native bar animates only its presentation; its model
position is the resting one, so a dropped animation still leaves it on screen.

**Assign the dynamic HEIC once and leave it to macOS.** Deployment copies the
committed file to `~/.config/yorha/appearance/yorha-system.heic`; `deploy.sh
--wallpaper` assigns that exact stable path to every desktop. A plain deploy only
refreshes the file, so a wallpaper you chose yourself survives it. macOS reads
its `apple_desktop:apr` metadata and owns frame selection and transition timing. Nothing else may rewrite the
HEIC, reassign it, select a frame, or restart `WallpaperAgent`.

**launchd jobs cannot run from this repository.** `~/Documents` is TCC-protected,
and a correctly loaded plist can still fail with `Operation not permitted` when
its executable lives here. Deployment therefore installs YoRHa Desktop and the
oracle under `~/.config/yorha/bin`, the wallpaper under `~/.config/yorha/appearance`,
and logs under `~/.config/yorha/logs`. The bar's crest is compiled into the binary
for the same reason.

**A relative interval does not align to wall-clock minutes.** SketchyBar's clock
once polled every 10 seconds and trailed the macOS clock by up to that much. The
native bar arms a wall-clock deadline at each minute boundary, which also fires on
time after a sleep, and redraws at once on display wake, clock change, and
time-zone change.

**`animation-fill-mode: both` on a reveal animation fails invisible.** If the
animation never starts, the `from` state persists. The Pod's typewriter once left
messages permanently blank this way. Base states are now the *visible* state.

**AppKit resets `isGeometryFlipped` on a layer-hosting view's own layer.** YoRHa
Desktop's first build drew everything y-up despite setting it. The flipped scene
root must be a sublayer of a plain host layer. Verified with a red-to-blue test
gradient, because the real beam is too faint to judge by eye.

**`CATextLayer` draws thin on a transparent window.** It switches font smoothing
off for non-opaque backgrounds, so the HUD looked lighter than WebKit had drawn it.
`TextLayer` draws the string itself with smoothing on.

**`uptime` rounds to the nearest minute.** BSD w(1) adds 30 s before formatting,
so truncating the boot-time difference ran one minute behind.

**Don't derive layout numbers — measure them.** The Pod panel is content-box, so
its 300px width *is* the text area; "300 minus padding" was wrong and over-scrolled
the marquee by 40px. The sketchybarrc comment said the crest was centred in its
slot; window captures showed SketchyBar drew it at the left edge.

**A transform on the flipped root applies in the host's y-up space.** The bar's
first entrance slid up from below. Animate a sublayer of the flipped root instead.

---

## Restore

```bash
bash "$(cat ~/.config/yorha/BACKUP_PATH)/restore.sh"
```

Points at an appearance-aware derived copy of the immutable pre-install baseline;
the original captured baseline is never modified or deleted. Restore validates the
recorded metadata before changing anything, removes only explicit
installation-owned paths (including SketchyBar's minute trigger and the appearance
watcher, if an older install left them), restores the recorded wallpaper with an
argv-bound path, restores both Ghostty configs and `~/.zshrc`, and derives
uninstall advice from the captured package manifest. Metadata failures exit
nonzero before any change. Verified against a copy under a temporary `HOME`, never
the real session.

`restore.sh` scripts generated before YoRHa Desktop existed do not know about it.
Turn it off first with `yorha-watcher off desktop`, then remove
`~/Library/LaunchAgents/com.yorha.desktop.plist` and `~/.config/yorha/bin/yorha-desktop`.
Scripts generated before the native bar also leave `~/.config/yorha/bar-off`
behind if the bar was switched off; it is safe to delete.

---

## Requirements

Already installed on the build host:

```bash
xcode-select --install   # swiftc builds YoRHa Desktop
brew install --cask ghostty font-cascadia-code font-cascadia-code-nf
brew tap FelixKratz/formulae && brew install borders   # with AeroSpace
brew install starship fastfetch jq
brew install --cask nikitabobko/tap/aerospace   # optional; tiling is opt-in
```
