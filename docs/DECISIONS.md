# Decision log

Why things are the way they are, including the ones that were wrong first.

---

## Palette

Twelve tokens, single source of truth in `config/shell/palette.sh`. Every consumer
reads from it; nothing hardcodes a colour.

```
bone CAC5B0   bone-raised D6D2C1   bone-recessed B5B09A
ink  4A4741   ink-muted   6E6B62   alert BB3B36   amber BC9A5A
void 16161A   void-text   D8D4C4   void-deep 131317
surface 3A3A40   olive A3A87E
```

`VOID_DEEP`, `SURFACE` and `OLIVE` were originally hardcoded into the editor theme,
Starship prompt and Ghostty ANSI slots. An audit caught them; declaring them here
was the fix. Ghostty's 16-colour ANSI table is deliberately its own set — a terminal
needs 16 slots, and that is a different concern from the UI palette.

---

## Automatic appearance: native ownership, narrow coordination

The wallpaper and YoRHa Desktop (widgets and bar) follow the effective macOS Light or
Dark appearance. Ghostty remains permanently dark. Its files, shader, palette,
process, and windows are intentionally outside the appearance system; matching
some dark desktop colors to Ghostty is visual coordination, not runtime coupling.

### Exact visual palettes

Light preserves the original parchment design:

| Role | Value | Consumers |
|---|---|---|
| Field | `#CAC5B0` | Wallpaper base |
| Text and ornament | `#4A4741` | Widgets, light crest, bar text and wordmark |
| Raised surface | `#D6D2C1` | Translucent Pod panel |
| Live signal | `#BC9A5A` | Linked state |
| Alert | `#BB3B36` | Memory and battery warnings |

Dark uses the approved Terminal Native palette:

| Role | Value | Consumers |
|---|---|---|
| Field | `#16161A` | Wallpaper base |
| Text | `#D8D4C4` | Widgets and bar text |
| Bright value | `#EFEBDB` | Primary telemetry values |
| Raised surface | `#3A3A40` | Translucent Pod panel |
| Ornament | `#6E7B8B` | Wallpaper lattice, arcs, and scan beam |
| Live signal | `#BC9A5A` | Dark crest, YoRHa wordmark, and linked state |
| Alert | `#BB3B36` | Memory and battery warnings |

Only colors and the crest/wallpaper variant change. Geometry, typography, command
cadence, and motion do not.

### One assigned dynamic HEIC

The wallpaper is a single committed `assets/yorha-system.heic`, rather than two
runtime files selected by a script. The file contains exactly two 5120×2880
frames: light at index 0 and dark at index 1. Frame 0 carries an
`apple_desktop:apr` Image I/O metadata tag whose base64-encoded binary property
list is exactly `{"l": 0, "d": 1}`. Deployment validates the contract and copies the
HEIC to `~/.config/yorha/appearance/yorha-system.heic`. Assigning that path to every
desktop is opt-in (`deploy.sh --wallpaper`), because it replaces whatever wallpaper
is set; a plain deploy only refreshes the file. Once assigned, macOS owns frame
choice and transition timing.

This avoids wallpaper cache churn, stale repository paths, per-transition
AppleScript, and `WallpaperAgent` restarts. The watcher and coordinator therefore
contain no wallpaper behavior. The developer-only regeneration boundary is
`bin/regenerate-system-wallpaper.sh --with-chrome`; deploy and runtime paths only
inspect the committed asset and never start Chrome.

### One process follows the appearance (watcher and coordinator retired)

Until 2026-10-21, `com.yorha.appearance-watcher`, a compiled Swift LaunchAgent,
observed `AppleInterfaceThemeChangedNotification` and wake and ran
`apply-appearance.sh`, which set SketchyBar's text colours, wordmark colour, and
crest behind a lock and a last-successful-mode marker. That machinery existed only
because the bar was a separate program. Once YoRHa Desktop drew the bar, the bar
joined the app's own appearance observer, and the watcher, the coordinator, its
lock protocol, and their tests were retired.

The committed feature now owns two feature-owned LaunchAgents: the Pod oracle and
YoRHa Desktop. Their executables live under `~/.config/yorha/bin` because launchd
jobs cannot reliably run from this TCC-protected repository under `~/Documents`,
even when launchd successfully loads the plist.

### Palette swapped in place, no widget reload

YoRHa Desktop observes `NSApp.effectiveAppearance` and swaps its palette inside one
200 ms Core Animation transaction. The tokens are the ones Übersicht's `theme.jsx`
declared with `@media (prefers-color-scheme: dark)`, carried over verbatim into
`Palette.swift`. Layers, telemetry cadence, and animation progress survive an
appearance transition. A rebuild would replay entrance effects, so nothing outside
the app signals it on an appearance change. The bar recolours in the same
transaction: its crest is one embedded mask tinted from `Palette.wordmark`, so it
eases with the text instead of swapping images.

---

## Terminal: Ghostty

Chosen over kitty, WezTerm and iTerm2 because it is the only one of the four that
can post-process the rendered terminal via a custom GLSL shader — which is the
entire point of a CRT effect. Alacritty was eliminated twice over: no ligature
support by design, and its Homebrew cask is deprecated for failing Gatekeeper.

**Two config files.** `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
silently overrides `~/.config/ghostty/config`. Validating the XDG file alone reports
success while the terminal ignores it. `deploy.sh` writes both.

### Shader bugs worth remembering

**Scanlines were a mathematical no-op.** `sin(row * PI)` sampled at pixel centres
(n + 0.5) is always ±1, so `sin²` is a constant 1.0 — a flat uniform dim, adjacent
rows differing by 0.000 against an intended 0.100. Now driven by `floor()` of the
device row.

**Chromatic aberration split channels by ~103px.** The constant was documented "in
uv units" and then multiplied by 40, which on a 3024px panel is 51px per channel,
red one way and blue the other. Text rendered tripled and unreadable. Now expressed
in physical pixels and divided by `iResolution.x`.

**Scanlines need help to be visible on a dark theme.** The background is RGB(22,22,26);
darkening 10% moves it ~2/255 — invisible. Now a 6px cycle at 22% depth plus a small
phosphor lift on lit rows, giving ~10/255 of real contrast.

---

## Desktop layer: YoRHa Desktop (native)

Übersicht was replaced on 2026-10-20 by YoRHa Desktop, a Swift + Core Animation
app in `native/YoRHaDesktop/` that draws the same four widgets in one process.
Design and measurements: `docs/superpowers/specs/2026-10-20-native-desktop-layer-design.md`.

**Why.** Measured with every widget running: Übersicht used ~100 MB across the app,
its Node widget server, and WebKit, and `hud.jsx` launched 10+ processes every
second (`ps`, `memory_pressure`, `uptime`, `pmset`, `netstat`, plus text tools).
YoRHa Desktop uses ~21 MB, reads every value from the kernel, and spends ~0.4% of
one core. The animations run on the render server as before; the savings are the
runtime around them.

**Swift, not Rust.** The work is AppKit and Core Animation calls, which Swift
makes directly and Rust would make through `objc2` bindings. The repo already
compiled Swift (for the appearance watcher, since retired), so no second toolchain
was added. The bar followed the same reasoning.

**No watchdog.** Übersicht could lose its widget server while the app stayed up,
which launchd could not see. One native process has no such split state, so
`com.yorha.desktop` is a plain `KeepAlive` LaunchAgent.

**Deliberate differences from the widgets:**

- The layer sits at the desktop window level, below Finder's icons. Übersicht drew
  above them.
- The Pod has no cursor and a constant one-line height. The `▌` cursor never
  rendered (opacity 0 in both base style and keyframe), yet it still wrapped onto a
  second line and made the panel jump.
- Reduced motion also stops the HUD boot-in and meter easing.
- The Pod marquee distance uses the measured text width.

---

## Menu bar: YoRHa Desktop (native)

On 2026-10-21 the bar moved from SketchyBar into YoRHa Desktop (`Bar.swift`).
Design and captures: `docs/superpowers/specs/2026-10-21-native-bar-design.md`.

**Why.** SketchyBar itself was native and small (~12 MB). The cost was around it: a
launchd job firing every minute to trigger it, a ~13 MB appearance watcher, and a
351-line coordinator with its own lock protocol, all to set four labels' colours
and a crest. Inside YoRHa Desktop the bar reuses the app's appearance observer and
adds no process.

**Matched, not redesigned.** Window captures with both bars running showed zero
alpha difference per item in light and dark. SketchyBar's quirks were kept: the
crest sits at its slot's left edge, label boxes are sized by glyph ink (so the date
can shift a point between minutes), and text draws with smoothing off. The window
sits at SketchyBar's backstop-menu level, below app windows, on every Space but
full-screen ones.

**Clock.** A wall-clock deadline at each minute boundary replaces the launchd
trigger; it fires on time after a sleep. Display wake, clock change, and time-zone
change redraw at once. Wording is pinned to the C locale, as `date` printed it
under launchd.

**Switch.** `yorha-watcher off bar` leaves `~/.config/yorha/bar-off` and restarts
the desktop agent; the app reads the marker at launch. A restart replays the
desktop entrances, which is acceptable for a rare toggle and simpler than a live
preference channel.

---

## Menu bar: SketchyBar (retired)

Kept for the history; the rc, minute trigger, and coordinator are in git history.
`install-desktop.sh` retires the service and YoRHa's helpers around it; the formula
and `~/.config/sketchybar` stay, and backup/restore owns that path.

- **`--animate … --bar y_offset` silently no-ops after a reload.** The rc once
  parked the bar at `y_offset=-36` and relied on the slide-in, which stranded the
  bar off-screen after a reload. Visibility must never depend on an animation.
- **Query telemetry is not a visibility oracle.** After reloads, `bounding_rects`
  came back empty while the bar rendered fine. Verify with the window server.
- **A relative `update_freq` does not align to wall-clock minutes.** It trailed the
  macOS clock by up to the poll interval, which is why the launchd minute trigger
  existed at all.

---

## Desktop layer: Übersicht (retired)

Kept for the history; the widgets are in git history before the native layer.

Four widgets: `hud` (corner telemetry), `pod` (Gemini messages), `ring` (reticle over
the wallpaper's targeting array), `beam` (scan sweep).

**The performance panic that was wrong.** A review attributed ~40-49% WindowServer
load to this animation layer, and the rotations and continuous beam were removed on
that basis. A differential measurement disproved it:

```
Übersicht running, everything restored ... 46% of a core
Übersicht killed ........................ 44% of a core
```

The animation layer costs ~2%, at or below noise. The real load is the normal app
mix — Claude's desktop app ~31%, "Clawd on Desk" ~19%, Discord ~12%, Ghostty ~11%.
Everything was restored. **Lesson: attribute by differential measurement, never by
correlation.** The review had flagged that it never isolated the widgets; that caveat
should have blocked the fix.

**One structural improvement was kept.** Rotation applies to HTML wrappers around
per-ring SVGs, not to `<g>` groups inside one SVG. Rotating SVG children uses WebKit's
legacy non-composited path (CPU re-rasterization); rotating an HTML element is a
GPU-composited layer. Measured in Übersicht's WebContent process: static 0%,
composited rotation 0%.

### Übersicht quirks

- A widget with `refreshFrequency` but **no `command`** never re-renders. Übersicht
  only creates the timer for widgets that have a command. `ring.jsx` exports a
  trivial `"true"` purely to get its hourly geometry re-read.
- Übersicht renders once with `output: ""` **before** the command runs. Mutating
  module state on that render corrupts the first real one — it once made the HUD
  display lifetime network bytes as a rate ("4768 MB/S").
- The server can die while the app stays alive. No crash report, blank desktop.
  Kill by PID (the umlaut defeats `pkill -f`) and relaunch.

---

## Pod 042 and Gemini

**Model: `gemini-3.1-flash-lite`**, chosen by measurement. `gemini-3-flash-preview`
reasons before answering: 7.9s and 2019 tokens for one line, versus 1.6s and 85.
`gemini-2.5-flash`, `gemini-2.5-flash-lite` return 404 (retired for new keys);
`gemini-2.0-flash` and its lite variant return 429. Three dead endpoints found during
setup is why the oracle carries a fallback model and fails silently to static.

**The widget never touches the network.** A launchd timer runs the oracle every 5
minutes; the widget only reads its cache. This is the difference between "the API is
slow" and "the desktop is frozen".

**launchd cannot execute from `~/Documents`.** It is TCC-protected, so the job failed
with `Operation not permitted` on every fire, silently, while `launchctl print`
cheerfully reported the plist as loaded. `deploy.sh` copies the script to
`~/.config/yorha/bin/` and the plist points there.

**Marquee, not clipping.** The panel fits ~44 characters and Gemini writes up to 72,
so overflowing lines ping-pong. The scroll distance is computed as
`length × 6.78px − 300px`. Both constants are **measured**, not derived: the panel is
content-box so its 300px width *is* the text area, and deriving "300 minus padding"
over-scrolled by 40px. Verified against the live renderer: 63 chars → 427px inner,
300px wrap, 127px needed, 127px applied.

**`animation-fill-mode: both` on a reveal animation fails invisible.** The typewriter
animated `max-width` from 0 with `both`; any run that never started held the message
at zero width forever — header visible, text gone. Base states are now the *visible*
state.

---

## Window tiling: installed, off

AeroSpace and JankyBorders are installed and configured, `start-at-login = false`,
currently not running — tried and not liked. The config remains so it is one
`open -a AeroSpace` away. SIP stays enabled; AeroSpace never needed it disabled,
unlike yabai.

---

## Things deliberately not done

- **Theming macOS chrome.** Finder windows, dialogs, the Dock and Apple's own menu
  bar cannot be themed by any supported mechanism.
- **Disabling SIP.** Never, for any feature.
- **Redistributing game assets.** All art, palettes and icons are generated originals
  in the NieR idiom.
- **App icon replacement.** Reset by every app update; weakest return in the design.
