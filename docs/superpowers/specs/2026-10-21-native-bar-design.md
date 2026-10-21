# Native Bar Design

## Goal

Draw the menu bar inside **YoRHa Desktop** instead of SketchyBar: the crest, the
YoRHa wordmark, the date, and the clock, with the same look, motion, and light/dark
behaviour. Then retire SketchyBar and the helpers that exist only for it.

## Why

| Helper | Exists for | Cost |
|---|---|---|
| SketchyBar (brew service) | the bar | ~12 MB footprint |
| `com.yorha.sketchybar-minute` | fires `sketchybar --trigger` every minute | a launch per minute, plus a shell and `date` per item |
| `com.yorha.appearance-watcher` | runs the coordinator on theme changes | ~13 MB |
| `apply-appearance.sh` | sets the bar's colours and crest (DECISIONS.md: it owns only those fields) | 351 lines of lock code, ~935 lines of tests |

YoRHa Desktop already follows `NSApp.effectiveAppearance` and already pauses its
timers while the displays sleep, so the bar adds no process. Once it draws the bar,
all four rows above can go.

## Language

Swift, in the existing app, for the reasons in the
[native desktop layer design](2026-10-20-native-desktop-layer-design.md): the work is
AppKit and Core Animation, and the repo builds Swift already.

## Mapping

| sketchybarrc | Native (`Bar.swift`) |
|---|---|
| `--bar height=32 position=top`, transparent, padding 12 | one borderless, click-through `BarWindow` per screen, top 32 pt |
| SketchyBar window level | `backstopMenu` (−20), measured from SketchyBar's windows: above the desktop layer, below app windows; every Space, not full-screen ones |
| `yorha_icon`: PNG at scale 0.5 in a 22 pt slot | the crest PNG embedded in `BarCrest.swift`, used as a mask and tinted from the palette |
| `yorha`: Bold 11, BRAND colour | `TextLayer`, `Palette.wordmark` (light `#4A4741`, dark `#BC9A5A`) |
| `date`, `clock`: Regular 11, `date` scripts | `BarFormat.day` / `BarFormat.clock`, pinned to the C-locale wording |
| `yorha_minute` launchd event + `system_woke` | `MinuteClock`: a wall-clock deadline at each minute boundary; redraws at once on display wake, clock change, and time-zone change |
| `apply-appearance.sh` | the bar joins the app's 200 ms palette transaction |
| entrance: `y_offset -36 → 0`, `--animate sin 30`, once per boot | 0.5 s slide with easeOutSine, once per launch, skipped under Reduce Motion; the model value is the resting position |

## Phase 1 results (2026-10-21)

The bar is built and tested but not deployed. Deploying it before phase 2 would draw
two bars whenever SketchyBar is switched on.

Window captures of both bars, item by item, with SketchyBar running beside the new
build:

| Item | Alpha difference (light and dark) | Largest colour difference |
|---|---|---|
| Crest | 0 | 7/255 light (the light PNG is not a flat tint), 2/255 dark |
| Wordmark | 0 | 2/255 |
| Date | 0 | 2/255 |
| Clock | 0 | 2/255 |

Findings while matching SketchyBar:

- **The crest is not centred.** The rc comment says the crest sits centred in its
  22 pt slot. SketchyBar actually draws it at the slot's left edge. The native bar
  copies the measured placement.
- **Labels are sized by ink.** SketchyBar sizes a label box from the glyphs' ink,
  rounded up, plus 1 pt, not from the advance width. The clock box can therefore
  change by a point between minutes, and the date moves with it. The native bar
  reproduces this.
- **Smoothing off.** SketchyBar draws text with font smoothing off, which is lighter
  than the HUD's WebKit-matched weight. `TextLayer` gained a `smoothsFonts` switch.
- **Baseline.** SketchyBar centres ascent minus descent on the midline and truncates
  to a whole point: 20 pt below the top for Cascadia Code 11. `TextLayer.origin` puts
  the baseline there while the layer stays on whole points.
- **Entrance direction.** A transform on the flipped root layer applies in the host
  layer's y-up space, so the first build slid up from below. The items now sit in a
  content layer inside the root, and the slide comes down from above.
- **Clock timing.** The label changed at 07:23:00, within the ~0.1 s resolution of the
  capture loop.

| Measure | YoRHa Desktop with bar | Installed YoRHa Desktop (no bar) | SketchyBar |
|---|---|---|---|
| Physical footprint | 11 MB | 11 MB | 12 MB |
| CPU over the same 60 s | 0.15 s | 0.32 s | 0.01 s, plus the minute trigger's launches (switched off during this sample) |

## Phase 2 (next)

- A bar switch: `yorha-watcher on|off bar` writes a preference and restarts the
  desktop agent, and the app skips the bar when it is off.
- Retire SketchyBar (`brew services`), `com.yorha.sketchybar-minute`, the appearance
  watcher, `apply-appearance.sh`, their plists, and their tests. The wallpaper HEIC
  install shares the "appearance runtime" block in `deploy.sh` and stays.
- `yorha-watcher` targets, backup and restore scripts, README, DECISIONS, and the
  deployment contract tests.
