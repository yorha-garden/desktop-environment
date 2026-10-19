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
bin/deploy.sh    repo  ->  live locations   (also loads three feature-owned LaunchAgents)
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
| `bin/yorha-backup.sh` | Snapshots every path the install touches and emits a tested `restore.sh`, including the prior appearance-watcher plist bytes and loaded state. |
| `bin/yorha-watcher` | On/off switch for SketchyBar, YoRHa Desktop, and the appearance watcher. Deployed to `~/.local/bin`. |
| `bin/build-desktop.sh` / `install-desktop.sh` | Compile YoRHa Desktop; install it under `~/.config/yorha/bin`, load its LaunchAgent, and retire Übersicht. `deploy.sh` calls the installer. |
| `bin/apply-appearance.sh` | Idempotent SketchyBar coordinator: applies one validated palette/crest and records only successful modes. |
| `bin/appearance-watcher.swift` | Native macOS appearance and wake observer, compiled by deployment into the runtime tree. |
| `bin/make-wallpaper.sh` | Verifies or assigns the committed dynamic HEIC; it never regenerates assets. |
| `bin/yorha-system-wallpaper.swift` | Builds, inspects, and extracts the exact two-frame dynamic-HEIC contract. |
| `bin/regenerate-system-wallpaper.sh` | Developer-only SVG rasterization and HEIC regeneration entry point. |
| `native/YoRHaDesktop/` | **YoRHa Desktop**, the native desktop layer (Swift + Core Animation): scan beam, corner ornaments, HUD, and Pod panel in one process. Replaced the Übersicht widgets. |
| `config/ghostty/` | Terminal config + the CRT shader. **Two** config files — see below. |
| `config/sketchybar/` | Menu bar. Transparent — no fill, no border; items float on the wallpaper. |
| `config/aerospace/` | Tiling config. Installed, `start-at-login = false`, currently not running by choice. |
| `config/shell/` | Palette, zsh layer, Starship prompt, fastfetch, boot logo. |
| `config/editor/` | VS Code–format colour theme. Install it yourself; nothing deploys into an editor. |
| `assets/wallpaper.svg` / `wallpaper-dark.svg` | Developer SVG sources for the matching light and dark wallpaper frames. |
| `assets/yorha-system.heic` | Committed two-frame 5120×2880 dynamic wallpaper; deployment copies and assigns it once, then macOS owns frame selection. |
| `assets/yorha-icon-light.png` / `yorha-icon-dark.png` | Fixed-name SketchyBar crests copied into the appearance runtime tree. |
| `launchd/` | The oracle timer, YoRHa Desktop, the appearance watcher, and the SketchyBar minute-boundary event. |
| `docs/` | Architecture, palette, and the decision log. |

---

## Automatic appearance

The macOS effective appearance owns the change. Deployment assigns one stable
`yorha-system.heic` path to every desktop; its native appearance metadata lets
macOS choose the light or dark frame without a wallpaper script, process restart,
or per-transition assignment. YoRHa Desktop follows the same system state by
observing `NSApp.effectiveAppearance` and easing its palette over 200 ms, so
widgets keep their state and animations instead of reloading.

```text
macOS effective appearance
   ├─ native wallpaper engine -> selects the HEIC frame
   ├─ YoRHa Desktop           -> swaps its palette in place
   └─ appearance-watcher      -> apply-appearance.sh -> live SketchyBar fields
```

The dedicated `com.yorha.appearance-watcher` LaunchAgent observes appearance
notifications, login, and wake, and launchd restarts it after a crash. The
coordinator updates only SketchyBar text colors, wordmark color, and crest. A
same-mode run is a no-op unless passed `--force`; failures do not advance the
successful-mode marker, so startup, wake, or the next notification retries.

Deployment manages three feature-owned LaunchAgents: the Pod oracle timer,
YoRHa Desktop (`com.yorha.desktop`, plain `KeepAlive`), and the appearance
watcher. The SketchyBar minute-boundary agent is deployed alongside them but
belongs to the bar and stays outside the backup and restore contracts.
Appearance runtime files are deliberately outside the TCC-protected repository:

```text
~/.config/yorha/bin/yorha-appearance-watcher
~/.config/yorha/bin/apply-appearance.sh
~/.config/yorha/appearance/yorha-system.heic
~/.config/yorha/appearance/yorha-icon-{light,dark}.png
~/.config/yorha/appearance/{apply.lock,last-successful-mode}
~/.config/yorha/logs/appearance.log
~/Library/LaunchAgents/com.yorha.appearance-watcher.plist
```

Ghostty remains permanently dark. Neither the watcher nor the coordinator reads,
writes, reloads, or signals either Ghostty configuration or its running windows.

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
`yorha-watcher off` stops SketchyBar (via `brew services`) and its minute clock,
YoRHa Desktop, and the appearance watcher; `yorha-watcher on` reverses it. Name
one helper to switch only that one: `yorha-watcher off sketchybar|desktop|appearance`.
`yorha-watcher status` shows the current state. `deploy.sh` leaves a switched-off
appearance watcher or desktop layer unloaded.

**`sketchybar --animate … --bar y_offset` silently no-ops after a reload.** The rc
once parked the bar at `y_offset=-36` and relied on the entrance animation to slide
it in; a reload dropped the animation and stranded the entire bar invisible
off-screen. Visibility must never depend on an animation firing — the rc now ends
with an unconditional `y_offset=0`, and the slide-in ceremony is scoped to first
login via a `/tmp` sentinel.

**Assign the dynamic HEIC once and leave it to macOS.** Deployment copies the
committed file to `~/.config/yorha/appearance/yorha-system.heic` and assigns that
exact stable path to every desktop. macOS reads its `apple_desktop:apr` metadata
and owns frame selection and transition timing. The appearance watcher and
SketchyBar coordinator must never rewrite the HEIC, reassign it, select a frame,
or restart `WallpaperAgent`.

**launchd jobs cannot run from this repository.** `~/Documents` is TCC-protected,
and a correctly loaded plist can still fail with `Operation not permitted` when
its executable lives here. Deployment therefore installs the watcher and
coordinator under `~/.config/yorha/bin`, wallpaper and crests under
`~/.config/yorha/appearance`, and logs under `~/.config/yorha/logs`.

**SketchyBar's query telemetry is not a visibility oracle.** After reloads,
`bounding_rects` comes back empty and `--query displays` returns `[]` even while
the bar is rendering perfectly on screen. Verify visibility with eyes or the
window server, not with queries — half an hour was once spent "fixing" a bar that
was never broken.

**A relative SketchyBar `update_freq` does not align to wall-clock boundaries.**
The clock once polled every 10 seconds and could trail the macOS menu-bar clock by
the full 10 seconds. `com.yorha.sketchybar-minute` now uses launchd's calendar
schedule to trigger `yorha_minute` at each system minute, with `system_woke` as an
immediate catch-up event. There is no one-second polling loop.

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
the marquee by 40px.

---

## Restore

```bash
bash "$(cat ~/.config/yorha/BACKUP_PATH)/restore.sh"
```

Points at an appearance-aware derived copy of the immutable pre-install baseline;
the original captured baseline is never modified or deleted. Restore validates the
recorded watcher state before changing anything, stages prior plist bytes beside
their destination, removes only explicit installation-owned paths, restores the
recorded wallpaper with an argv-bound path, restores both Ghostty configs and
`~/.zshrc`, and derives uninstall advice from the captured package manifest. Copy,
move, bootstrap, or state-integrity failures exit nonzero without printing false
success. Verified against a copy under a temporary `HOME`, never the real session.

`restore.sh` scripts generated before YoRHa Desktop existed do not know about it.
Turn it off first with `yorha-watcher off desktop`, then remove
`~/Library/LaunchAgents/com.yorha.desktop.plist` and `~/.config/yorha/bin/yorha-desktop`.

---

## Requirements

Already installed on the build host:

```bash
xcode-select --install   # swiftc builds YoRHa Desktop and the appearance watcher
brew install --cask ghostty font-cascadia-code font-cascadia-code-nf
brew tap FelixKratz/formulae && brew install sketchybar borders
brew install starship fastfetch jq
brew install --cask nikitabobko/tap/aerospace   # optional; tiling is opt-in
```
