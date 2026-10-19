# Native Desktop Layer Design

## Goal

Replace Übersicht with a native macOS app, **YoRHa Desktop**, that draws the same
four widgets (scan beam, corner ornaments, HUD, Pod panel) directly with AppKit and
Core Animation. Node, the widget server, WebKit, and the shell pipelines the widgets
fork go away. The look, motion, and light/dark behaviour stay the same.

## Why

Measured on this machine (8 GB RAM, 2026-10-20), with every helper running:

| Process | Memory | Notes |
|---|---|---|
| Übersicht app | ~31 MB | |
| Übersicht `node-arm64` widget server | ~20 MB | |
| Übersicht WebKit content + GPU + networking | ~45 MB | |
| **Übersicht total** | **~100 MB** | |
| SketchyBar | ~15 MB | already native C; out of scope |
| appearance watcher | ~13 MB | already native Swift |

The bigger cost is CPU churn the memory table hides. `hud.jsx` runs a shell
pipeline **every second**: `ps -A`, `memory_pressure`, `uptime`, `pmset`,
`netstat`, plus `awk`/`sed`/`grep`, which is 10+ process launches per second. One
run takes ~0.19 s wall time. `pod.jsx` repeats a similar pipeline every 30 s. All of
these values are available from in-process system calls.

The watchdog exists only because Übersicht's Node server can die while the app stays
alive. A single native process has no such split state. If it crashes, launchd's
plain `KeepAlive` restarts it, so the watchdog can be retired.

**Expected result:** ~100 MB down to ~20–30 MB, zero process launches per second,
one LaunchAgent instead of an app plus a watchdog.

## Language: Swift, not Rust

Both compile to native code, and either would hit the memory target, because AppKit
and Core Animation dominate the footprint whichever language calls them. The choice
comes down to fit:

- **The work is almost entirely AppKit/Core Animation.** Swift calls those APIs
  directly. Rust would go through `objc2` bindings, where every layer, animation,
  and observer becomes verbose and mostly `unsafe` glue, with no speed gain because
  Core Animation renders on the GPU either way.
- **The repo already builds Swift.** `deploy.sh` compiles `appearance-watcher.swift`
  with `swiftc -O`, and the Python tests compile Swift test files the same way. Rust
  would add `cargo`, a lockfile, and a second toolchain to deploy and tests.
- **One language for the native parts.** The appearance watcher can later merge into
  this app.

Rust would make sense for a cross-platform or compute-heavy core. Neither applies
here.

## Architecture

```text
yorha-desktop (one process, LaunchAgent com.yorha.desktop, KeepAlive)
  NSApplication, accessory policy (no Dock icon, no menu)
  per NSScreen: borderless transparent NSWindow
      level            = desktop window level (same layer Übersicht used)
      ignoresMouse     = true
      collection       = canJoinAllSpaces, stationary, ignoresCycle
      root CALayer     = geometryFlipped (top-left origin, like CSS)
        BeamLayer        CAGradientLayer, translation animation
        ArcsLayer        CAShapeLayers, strokeEnd / scale / translation animations
        HudLayer         CATextLayers + meter layers         (phase 2)
        PodLayer         panel, typewriter, marquee          (phase 3)
  Theme       NSApp.effectiveAppearance KVO -> palette (theme.jsx tokens) -> 200 ms colour transition
  Motion      NSWorkspace reduce-motion flag + change notification
  Screens     didChangeScreenParameters -> rebuild windows
```

Animations are Core Animation layer animations, so they run on the render server like
the composited CSS transforms do today. No timers fire for the beam or the ornaments.

## Widget mapping

| Widget | Übersicht | Native |
|---|---|---|
| Theme | CSS custom properties + `prefers-color-scheme` | `Palette` struct, light/dark, same hex values |
| Beam | 14vh gradient band, `translateY(-16vh → 102vh)`, 11 s linear, infinite | `CAGradientLayer` with the same stops, `transform.translation.y` animation |
| Arcs | two quarter-arcs per corner: draw-on 1.5 s, breathe 1↔1.1 over 3 s; three diagonals per corner: draw-on, wave 0→−10→0 over 4 s | `CAShapeLayer` from the verbatim SVG paths; `strokeEnd`, `transform.scale`, `transform.translation.y` |
| HUD | shell pipeline every 1 s; boot-in stagger; meters | `host_statistics` (CPU), `kern.memorystatus_level` (memory pressure, verified equal to `memory_pressure`'s figure), `kern.boottime` (uptime), IOKit power sources (battery), `getifaddrs` en0 counters (network); 1 s timer for network, 3 s for the rest |
| Pod | pipeline every 30 s; reads `pod-oracle.json`; typewriter, cursor blink, marquee | same cache contract and 20-minute staleness fallback; static reports unchanged; `statfs` for disk |

The Pod oracle (`pod-oracle.py`, launchd every 5 minutes) is unchanged. The app only
reads its cache, as the widget does.

## Phases and estimate

| Phase | Scope | Size |
|---|---|---|
| 1 | App shell (windows per screen, Spaces, theme, reduced motion, screen changes) + beam + arcs | ~350 lines Swift + tests |
| 2 | HUD: native telemetry, layout, meters, alerts, boot-in stagger | ~300 lines + tests |
| 3 | Pod: cache read + staleness fallback, static reports, typewriter, blink, marquee, 30 s cycle | ~300 lines + tests |
| 4 | Integration: `com.yorha.desktop` LaunchAgent, `deploy.sh` build + install, `yorha-watcher` target, backup/restore contract, retire Übersicht watchdog and widget deploy, README/DECISIONS | ~200 lines changed + contract-test updates |

Each phase is one reviewable commit, with a side-by-side visual check against
Übersicht before moving on. Phase 4 is the slowest because the deployment contract
tests are strict.

## Risks

- **Text metrics.** HUD and Pod use Cascadia Code (installed) with CSS letter-spacing
  in `em`. Native kerning must be converted (`em × font size`), and the Pod marquee's
  measured 6.78 px/char should be re-measured, not copied.
- **Gradient direction under a flipped root layer.** Verify on screen, not by reasoning.
  (Phase 1 finding: AppKit resets `isGeometryFlipped` on a layer-hosting view's own
  layer. The flipped scene root must be a sublayer of a plain host layer.)
- **Desktop icons and Spaces.** YoRHa Desktop uses the desktop window level, below
  Finder's desktop icons. Übersicht actually drew its widgets in a window at layer −1,
  above the icons. Below the icons is the intended choice here. Check Mission
  Control, full-screen Spaces, and a second display.
- **Animation timing parity.** CSS `cubic-bezier(0.22,1,0.36,1)` and per-keyframe
  `ease-in-out` map directly to `CAMediaTimingFunction`; the HUD's overshoot curve
  `cubic-bezier(.34,1.56,.64,1)` also maps directly.

## Testing

- Swift `@main` test files with `precondition` checks, compiled by Python tests,
  matching `tests/appearance_watcher_tests.swift`: palette resolution, corner geometry
  for a given screen size, timing constants, telemetry parsing (phase 2), Pod
  staleness/fallback/marquee maths (phase 3).
- Visual check per phase: screenshots of Übersicht and YoRHa Desktop at the same
  appearance.
- Phase 4: deployment contract tests updated for the new agent and the retired
  watchdog.

## Phase 1 results (2026-10-20)

Shell, beam, and ornaments are built in `native/YoRHaDesktop/` and compiled by
`bin/build-desktop.sh`. Window captures of YoRHa Desktop and Übersicht show matching
placement for both corners, the bottom-right overhang, and the beam band.

| Measure | YoRHa Desktop (phase 1) | Übersicht (all widgets) |
|---|---|---|
| RSS | ~35 MB | ~100 MB |
| Physical footprint | ~9 MB | — |
| CPU over 10 s idle | 0.06 s | — |

Phase 1 replaces only the beam and ornaments, so the comparison is indicative. The
real comparison comes after phase 3, when HUD and Pod are included.

## Phase 2 results (2026-10-20)

The HUD reads every value in-process (`Telemetry.swift`) and redraws on one shared
1-second clock, which stops while the displays sleep. Tests compare each reading
with the shell tool it replaces: `uptime` wording, `memory_pressure`, `pmset`, and
`netstat -ib` en0 byte counters.

Findings while matching Übersicht:

- **Uptime rounds.** BSD `uptime` adds 30 s past the first minute, so it shows the
  nearest minute; truncating was one minute behind.
- **Text weight.** `CATextLayer` turns font smoothing off on a transparent window
  and drew visibly thinner than WebKit. `TextLayer` draws with smoothing on and
  matches the old weight.
- **Layout.** Window captures match Übersicht's label, value, meter, and
  right-aligned positions to the pixel, including CSS's trailing letter-spacing.
- **Reduced motion** now also skips the HUD boot-in and meter easing. hud.jsx had
  no reduced-motion rule.

| Measure | YoRHa Desktop (beam + ornaments + HUD) |
|---|---|
| RSS | ~15 MB |
| Physical footprint | ~10 MB |
| CPU over 30 s | 0.09 s (≈0.3% of one core) |
| Processes launched per second | 0 (hud.jsx: 10+) |

## Phase 3 results (2026-10-20)

The Pod panel keeps pod.jsx's contract: the oracle cache is used while it is under
20 minutes old, non-empty, and well-formed; otherwise the six built-in reports show,
with the same wording. One message every 30 s on a shared feed, which pauses while
the displays sleep. The disk figure comes from `statfs` in `df -h` wording, and a
test checks it against `df`.

Deliberate differences from pod.jsx:

- **No cursor.** The `▌` cursor never showed in Übersicht: its base opacity was 0 and
  the blink keyframe also set 0. It is left out.
- **Constant height.** The invisible cursor still took up space and wrapped onto a
  second line whenever the message overflowed, and during every typewriter reveal,
  so the panel jumped between one and two lines. The native panel is always one
  message line tall (71.7 pt).
- **Marquee distance is measured.** The scroll distance uses the rendered text width
  instead of `length × 6.78px`.

Window captures match Übersicht's width, border, corner brackets, header row, rule,
and message baseline.

### Final comparison (all four widgets)

| Measure | YoRHa Desktop | Übersicht |
|---|---|---|
| RSS | ~21 MB | ~100 MB (app + Node + WebKit) |
| Physical footprint | ~11 MB | — |
| CPU over 60 s | 0.22 s (≈0.4% of one core) | plus 10+ process launches per second |
| Processes | 1 | app, Node server, 3+ WebKit, watchdog |

## Out of scope

- SketchyBar (already native) and its configuration.
- Ghostty, wallpaper, and the appearance coordinator.
- Rewriting the Pod oracle (runs for ~0.2 s CPU every 5 minutes).
