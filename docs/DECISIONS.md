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

The wallpaper, YoRHa Desktop layer, and SketchyBar follow the effective macOS Light or
Dark appearance. Ghostty remains permanently dark. Its files, shader, palette,
process, and windows are intentionally outside the appearance system; matching
some dark desktop colors to Ghostty is visual coordination, not runtime coupling.

### Exact visual palettes

Light preserves the original parchment design:

| Role | Value | Consumers |
|---|---|---|
| Field | `#CAC5B0` | Wallpaper base |
| Text and ornament | `#4A4741` | Widgets, light crest, SketchyBar text and wordmark |
| Raised surface | `#D6D2C1` | Translucent Pod panel |
| Live signal | `#BC9A5A` | Linked state |
| Alert | `#BB3B36` | Memory and battery warnings |

Dark uses the approved Terminal Native palette:

| Role | Value | Consumers |
|---|---|---|
| Field | `#16161A` | Wallpaper base |
| Text | `#D8D4C4` | Widgets and SketchyBar text |
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
list is exactly `{"l": 0, "d": 1}`. Deployment validates the contract, copies the
HEIC to `~/.config/yorha/appearance/yorha-system.heic`, and assigns that path to
every desktop once. macOS then owns frame choice and transition timing.

This avoids wallpaper cache churn, stale repository paths, per-transition
AppleScript, and `WallpaperAgent` restarts. The watcher and coordinator therefore
contain no wallpaper behavior. The developer-only regeneration boundary is
`bin/regenerate-system-wallpaper.sh --with-chrome`; deploy and runtime paths only
inspect the committed asset and never start Chrome.

### Dedicated watcher and coordinator

`com.yorha.appearance-watcher` is a compiled Swift LaunchAgent with `RunAtLoad`
and `KeepAlive`. A native observer is used because scheduled Auto transitions are
system events, not polling intervals, and because wake needs an immediate repair
opportunity. It observes `AppleInterfaceThemeChangedNotification`, coalesces a
burst for 150 ms, handles wake and startup immediately, resolves the final
effective mode, and invokes the installed coordinator with exactly `light` or
`dark`. Keeping this responsibility out of SketchyBar and the desktop layer gives
one small, crash-recovered owner and avoids reloading either UI.

The executables live under `~/.config/yorha/bin` and output is directed to
`~/.config/yorha/logs/appearance.log`. They cannot reliably run from this
TCC-protected repository under `~/Documents`, even when launchd successfully loads
the plist.

The committed feature owns exactly three feature-owned LaunchAgents: the Pod
oracle, YoRHa Desktop, and appearance watcher. The SketchyBar minute-boundary
agent is deployed alongside them but belongs to the bar, and stays outside the
backup and restore contracts.

`apply-appearance.sh` owns only live SketchyBar fields: clock/date text, YoRHa
wordmark, and crest path. It serializes calls with `appearance/apply.lock` and
writes `appearance/last-successful-mode` atomically only after SketchyBar succeeds.
Repeating that mode is a no-op unless `--force` is supplied. A failed update leaves
the prior marker untouched, so startup, wake, a manual reload, or the next system
notification retries instead of falsely considering the mode applied.

### Palette swapped in place, no widget reload

YoRHa Desktop observes `NSApp.effectiveAppearance` and swaps its palette inside one
200 ms Core Animation transaction. The tokens are the ones Übersicht's `theme.jsx`
declared with `@media (prefers-color-scheme: dark)`, carried over verbatim into
`Palette.swift`. Layers, telemetry cadence, and animation progress survive an
appearance transition. A rebuild would replay entrance effects, so neither the
watcher nor the coordinator signals the desktop layer.

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
compiles Swift for the appearance watcher, so no second toolchain was added.

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
