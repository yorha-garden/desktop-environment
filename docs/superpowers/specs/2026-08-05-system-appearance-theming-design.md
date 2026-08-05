# System Appearance Theming Design

Date: 2026-08-05
Status: Approved for implementation planning

## Goal

Make the YoRHa desktop layer follow macOS's effective Light or Dark appearance automatically. The desktop layer includes the wallpaper, all Übersicht widgets, and SketchyBar. The effective appearance must be applied at login, after wake, and whenever macOS changes appearance, including scheduled Auto transitions.

Ghostty is explicitly excluded. Its window theme, terminal palette, shader, configuration files, and running windows remain permanently dark and must not be changed or reloaded by the appearance system.

## Design decisions

- Use a dedicated compiled Swift watcher managed by launchd.
- Keep the existing parchment theme unchanged for Light appearance.
- Use the approved **Terminal Native** palette for Dark appearance.
- Preserve widget geometry, typography, telemetry cadence, and motion in both appearances.
- Use CSS media queries for Übersicht so a switch does not reload widgets or replay their entrance animations.
- Commit one dynamic `assets/yorha-system.heic` containing the light and dark wallpaper frames, and commit both crest variants. Deployment assigns the HEIC once; macOS selects its frame natively thereafter.
- Keep Chrome in the explicit developer-only `bin/regenerate-system-wallpaper.sh --with-chrome` workflow. Deployment and appearance runtime never invoke Chrome or regenerate assets.
- Install every executable and runtime asset outside the TCC-protected repository under `~/.config/yorha/`.
- Keep the SketchyBar coordinator idempotent and retain a successful-mode marker so failed bar updates are retried.

## Visual contract

### Light appearance: Parchment

The current desktop appearance remains visually unchanged.

| Role | Value | Use |
|---|---:|---|
| Field | `#CAC5B0` | Wallpaper base |
| Text and ornament | `#4A4741` | Widget text, lines, light crest, SketchyBar |
| Raised surface | `#D6D2C1` | Translucent Pod panel |
| Live signal | `#BC9A5A` | Linked/live state |
| Alert | `#BB3B36` | Memory and battery warnings |

### Dark appearance: Terminal Native

The dark desktop uses colors already present in Ghostty's permanent dark palette. This is visual coordination only; Ghostty does not participate in switching.

| Role | Value | Use |
|---|---:|---|
| Field | `#16161A` | Wallpaper base; matches Ghostty background |
| Text | `#D8D4C4` | Widget and SketchyBar text |
| Bright value | `#EFEBDB` | Primary telemetry values |
| Raised surface | `#3A3A40` | Translucent Pod panel |
| Ornament | `#6E7B8B` | Wallpaper lattice, arcs, and scan beam |
| Live signal | `#BC9A5A` | YoRHa crest/wordmark and linked state |
| Alert | `#BB3B36` | Memory and battery warnings |

The light and dark variants retain the same composition. Only color tokens and the matching wallpaper/crest assets change. Widget color, background-color, border-color, and SVG stroke changes use a 200 ms ease transition. Positions, dimensions, font metrics, command refresh intervals, and animation timing do not change.

## Architecture

```text
macOS effective appearance
        │
        │ AppleInterfaceThemeChangedNotification / wake / process launch
        ▼
        ├── macOS wallpaper engine selects frame 0/1 from the assigned dynamic HEIC
        ├── Übersicht WebKit resolves prefers-color-scheme CSS variables
        └── compiled YoRHa Swift watcher (LaunchAgent, RunAtLoad + KeepAlive)
                    │
                    │ invokes coordinator with exactly "light" or "dark"
                    ▼
            idempotent appearance coordinator
                    └── update live SketchyBar colors and crest image

The dynamic HEIC is assigned once during deployment. Neither the watcher nor the
coordinator participates in wallpaper selection, and Übersicht is not reloaded.

Ghostty is outside this graph.
```

### Swift watcher

Add `bin/appearance-watcher.swift`. Deployment compiles it with the host's `swiftc` into `~/.config/yorha/bin/yorha-appearance-watcher`.

The watcher:

1. Resolves the effective mode at process startup and invokes the coordinator once.
2. Listens for `AppleInterfaceThemeChangedNotification` through `DistributedNotificationCenter`.
3. Listens for `NSWorkspace.didWakeNotification` so wake repairs stale or partially applied state.
4. Coalesces repeated appearance notifications over a short interval before resolving the final effective mode.
5. Invokes the coordinator as a child process with a single validated `light` or `dark` argument.
6. Logs child launch and exit failures to standard error; launchd directs output to `~/.config/yorha/logs/appearance.log`.

The watcher is an agent without windows, Dock presence, or user interaction. It does not import, inspect, or modify Ghostty state.

### LaunchAgent

Add `launchd/com.yorha.appearance-watcher.plist`. Deployment substitutes runtime paths, writes it to `~/Library/LaunchAgents/`, then bootstraps it in the current GUI domain.

The job uses `RunAtLoad` and `KeepAlive`. It points only to files under `~/.config/yorha/`, because launchd jobs cannot reliably execute or read this repository under `~/Documents`. Standard output and error use a dedicated log under `~/.config/yorha/logs/`.

Repeated deployment first boots out the existing job, replaces the binary, coordinator, crests, dynamic HEIC, and plist, then bootstraps the new job. A watcher crash is recovered by launchd; a coordinator failure does not terminate the watcher.

### Appearance coordinator

Add `bin/apply-appearance.sh`. Deployment copies it to `~/.config/yorha/bin/apply-appearance.sh`. Its accepted forms are `apply-appearance.sh light`, `apply-appearance.sh dark`, and either form followed by `--force` for deployment and tests.

The coordinator serializes concurrent runs with `~/.config/yorha/appearance/apply.lock`. It resolves the two committed crest variants at fixed runtime paths, validates the selected crest before changing SketchyBar, and records the last fully successful mode in `~/.config/yorha/appearance/last-successful-mode`. A repeated successful mode is a no-op unless forced. If SketchyBar is unavailable or its update fails, the successful-state marker is not advanced, allowing the next notification, wake event, or bar reload to retry.

The coordinator owns only live SketchyBar colors and crest selection. It contains no wallpaper assignment, `WallpaperAgent` restart, raster-path selection, asset manifest, or Übersicht refresh behavior.

### Wallpaper assets and switching

Retain `assets/wallpaper.svg` and `assets/wallpaper-dark.svg` as 5120×2880 developer sources with identical geometry, lattice, grain, and vignette structure. The committed runtime artifact is `assets/yorha-system.heic`, containing exactly two 5120×2880 frames: light at index 0 and dark at index 1. Its `apple_desktop:apr` Image I/O metadata maps `l` to `0` and `d` to `1`.

`bin/yorha-system-wallpaper.swift` builds, inspects, and extracts this HEIC. `bin/regenerate-system-wallpaper.sh --with-chrome` is the sole wallpaper-generation entry point and is developer-only: it rasterizes both SVG sources in a temporary directory, rebuilds the committed HEIC, and prints the inspected contract. `bin/make-wallpaper.sh` only verifies or applies the committed HEIC; it contains no Chrome or regeneration invocation.

Deployment verifies the committed asset, copies it to `~/.config/yorha/appearance/yorha-system.heic`, and assigns that stable runtime path to every desktop once. No deploy-time rendering occurs. After assignment, macOS owns Light/Dark frame selection and its native transition. Appearance notifications, wake events, and forced coordinator calls never reassign the wallpaper, select a frame, restart a wallpaper process, or maintain wallpaper state.

### Übersicht widgets

Add a render-only theme provider widget that publishes the approved light tokens as CSS custom properties and overrides them under `@media (prefers-color-scheme: dark)` with the Terminal Native tokens. It has no command, timer, visible element, or JavaScript appearance polling.

Update `hud.jsx`, `pod.jsx`, `arcs.jsx`, and `beam.jsx` to use those CSS variables. SVG strokes use `currentColor` or CSS-backed stroke properties instead of literal light-theme values. Each consumer includes an appropriate light fallback for its critical custom properties so a delayed provider render does not create invisible content.

WebKit updates the media query when the effective macOS appearance changes. The coordinator does not request an Übersicht refresh, so module state, network-rate sampling, message rotation, and entrance-animation latches remain intact. Only the relevant color properties transition for 200 ms.

### SketchyBar

SketchyBar remains transparent in both modes. The coordinator updates already-created items rather than reloading the bar:

- Light: ink labels, ink YoRHa wordmark, ink crest.
- Dark: bone date/time labels, amber YoRHa wordmark, amber crest.
- Fonts, spacing, height, animation, clock/date events, and item order remain unchanged.

SketchyBar does not support image tinting, so deployment provides `~/.config/yorha/appearance/yorha-icon-light.png` and `~/.config/yorha/appearance/yorha-icon-dark.png`: separate pre-tinted 31×36 RGBA crests derived from the same SVG. The coordinator swaps `yorha_icon`'s `background.image` path and explicitly updates the existing items' label/icon colors. It does not rely on changing SketchyBar defaults, because defaults affect future items rather than the live ones.

At the end of a normal SketchyBar configuration load, the installed coordinator is invoked with the effective current appearance and `--force`. This prevents a manual SketchyBar reload from temporarily restoring light colors while the system is dark.

## Palette ownership

`config/shell/palette.sh` remains the named palette source and gains names for the bright and steel tokens already present in Ghostty's palette. The widget theme provider, wallpaper SVG sources and committed HEIC frames, SketchyBar mapping, and tests use the same approved values. A validation test checks those consumers against the canonical token values so duplicated CSS/SVG representations cannot silently drift.

## Ghostty isolation invariant

The new watcher, coordinator, LaunchAgent, theme provider, and appearance assets must contain no Ghostty path, command, reload request, or config mutation. Existing Ghostty files remain byte-for-byte unchanged by this feature.

Deployment may continue its existing idempotent copy of the repository's unchanged Ghostty configuration. The appearance watcher and every later appearance change do not invoke that deployment path.

Verification records checksums for both tracked Ghostty configuration files and both live Ghostty configuration files before forced light/dark tests, then compares them afterward. Any mismatch fails verification.

## Failure behavior

- Invalid mode: reject without changing any surface.
- Missing or invalid committed HEIC during deployment: abort before wallpaper assignment.
- Missing selected crest at runtime: reject that mode before changing SketchyBar.
- Concurrent notifications: serialize coordinator runs and coalesce watcher callbacks.
- SketchyBar absent or update failure: report nonzero without advancing the successful-mode marker, then retry after wake or the next event. A later SketchyBar reload applies the current mode itself.
- Übersicht absent: no action is required; its CSS resolves the effective appearance when Übersicht next launches.
- Watcher crash: launchd restarts it and startup application repairs the current appearance.
- Machine wake: force re-evaluation even if the effective mode did not change.

No failure path falls back to changing Ghostty.

## Deployment and restoration

`bin/deploy.sh` will:

1. Validate `swiftc` availability and compile the watcher.
2. Inspect the committed two-frame HEIC contract; do not render or regenerate it.
3. Copy the dynamic HEIC, both crest variants, coordinator, and watcher beneath `~/.config/yorha/`.
4. Deploy the updated widgets and SketchyBar configuration.
5. Install and bootstrap the appearance LaunchAgent.
6. Assign the copied dynamic HEIC to every desktop once, then force one SketchyBar application of the effective current mode.

Chrome is used only when a developer explicitly runs `bin/regenerate-system-wallpaper.sh --with-chrome`; it is not a deployment or runtime dependency. Swift 6.2 and `swiftc` are present on the target host.

The backup/restore flow will boot out and remove `com.yorha.appearance-watcher`, its plist, binary, coordinator, appearance state, logs, copied dynamic HEIC, and copied crest variants. It will then restore the pre-install wallpaper and existing desktop configuration as it does today. Cleanup targets are explicit paths beneath `~/.config/yorha/` and `~/Library/LaunchAgents/`.

## Verification strategy

Static verification:

- `swiftc -typecheck` and a release compilation of the watcher.
- `bash -n` for modified shell scripts.
- `plutil -lint` for the LaunchAgent.
- SVG/XML parsing for both wallpaper sources.
- Image I/O inspection proving one HEIC has exactly two 5120×2880 frames and `apple_desktop:apr` maps `l:0,d:1`; RGBA and dimension checks for both crest rasters.
- Regression checks proving the normal wallpaper consumer, deployment, watcher, and coordinator do not invoke Chrome or the developer regeneration command.
- Palette consistency checks across shell, CSS, SVG, and SketchyBar mappings.
- Search confirming the new appearance pipeline contains no Ghostty mutation or reload command.

Behavioral verification:

1. Record the effective system mode, assigned wallpaper path, live SketchyBar values, and Ghostty checksums.
2. Deploy and verify every desktop points at the copied `yorha-system.heic` runtime path.
3. Apply forced Light mode without changing the macOS appearance setting; verify only ink crest/labels and coordinator state change, while the assigned wallpaper path remains unchanged.
4. Apply forced Dark mode; verify amber crest/wordmark, bone date/time labels, coordinator state, and the same assigned wallpaper path.
5. Verify widget styles contain both media-query paths and that the coordinator never reloads widget modules.
6. Reapply the same mode and verify it is a no-op; force it and verify a retry occurs.
7. Terminate the watcher and verify launchd restarts it.
8. Restore SketchyBar to the effective system mode and confirm the assigned HEIC path is unchanged.
9. Confirm all recorded Ghostty checksums are unchanged.

Live tests may temporarily change the bar, but they do not change the macOS appearance setting or force a HEIC frame. The final test step restores SketchyBar to the system's effective mode; macOS remains the only wallpaper-frame selector.

## Acceptance criteria

- Logging in while macOS is light produces the existing parchment desktop.
- Logging in while macOS is dark produces the Terminal Native desktop.
- Manual and scheduled system appearance changes update wallpaper, widgets, and SketchyBar automatically without a user command.
- The switch is prompt, does not flash an intermediate palette, and does not replay widget entrance animations.
- Sleep/wake and watcher restart converge on the effective appearance.
- Partial failures are logged and retryable.
- Every desktop retains the single assigned dynamic HEIC path, and macOS selects its correct Light/Dark frame natively.
- Ghostty stays dark and all Ghostty configuration checksums remain unchanged.
- Repeated deployment and restoration are safe and leave no duplicate LaunchAgent jobs or stale runtime assets.
