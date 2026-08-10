# SketchyBar Appearance Updates Design

## Goal

Make the YoRHa SketchyBar theme follow the effective macOS Light/Dark appearance automatically, using the existing appearance watcher and live field updates. Appearance changes must not reload SketchyBar, alter the wallpaper or Übersicht widget pipeline, or affect Ghostty's permanently dark theme.

## Current failure

The appearance watcher is running as a LaunchAgent with launchd's default `PATH` of `/usr/bin:/bin:/usr/sbin:/sbin`. The installed coordinator defaults to invoking `sketchybar` by its bare command name, while the executable on this host is `/opt/homebrew/bin/sketchybar`.

As a result, the watcher can resolve a new appearance and start the coordinator, but the coordinator cannot execute SketchyBar. It exits before updating the menu bar or advancing `last-successful-mode`. Existing coordinator tests inject `YORHA_SKETCHYBAR_BIN` directly, so they verify the update transaction but do not reproduce this deployment boundary.

## Chosen design

Deployment will resolve SketchyBar once with `command -v sketchybar` and render that absolute executable path into the appearance LaunchAgent. The LaunchAgent will expose it to the coordinator through the coordinator's existing `YORHA_SKETCHYBAR_BIN` interface.

This keeps executable discovery at deployment time, where the interactive Homebrew-aware environment is available, and keeps runtime execution independent of launchd's restricted `PATH`. It avoids hard-coded Apple Silicon or Intel Homebrew paths and does not add executable search logic to the coordinator.

## Runtime data flow

```text
deploy.sh
  -> resolves absolute SketchyBar executable
  -> renders appearance LaunchAgent

macOS appearance notification / login / wake
  -> yorha-appearance-watcher resolves light or dark
  -> apply-appearance.sh reads YORHA_SKETCHYBAR_BIN
  -> SketchyBar receives one live update transaction
       - clock label color
       - date label color
       - YoRHa wordmark color
       - YoRHa crest image
  -> coordinator records last-successful-mode after success
```

The coordinator will continue to update existing SketchyBar items in place. It will not call `sketchybar --reload`, recreate items, replay the entrance animation, or disturb clock/date subscriptions.

## Deployment and failure behavior

- The appearance LaunchAgent template will contain a placeholder for the absolute SketchyBar executable.
- `deploy.sh` will render that placeholder using the already-resolved `SB_BIN` value before bootstrapping the watcher.
- Deployment must not silently install an appearance watcher with an unusable SketchyBar path. If SketchyBar cannot be resolved, the appearance portion will report the missing dependency rather than recording a successful menu-bar appearance update.
- The coordinator will retain its transaction boundary: a failed SketchyBar invocation leaves the previous `last-successful-mode` unchanged so a later notification, wake, or restart can retry.
- Wallpaper selection remains owned by macOS and the dynamic HEIC.
- Übersicht remains driven by `prefers-color-scheme`.
- Ghostty remains outside the appearance pipeline and permanently dark.

## Testing

Automated coverage will verify:

1. The LaunchAgent declares the SketchyBar executable through `YORHA_SKETCHYBAR_BIN`.
2. Deployment replaces every appearance plist placeholder with an absolute executable path.
3. A launchd-equivalent environment with only `/usr/bin:/bin:/usr/sbin:/sbin` can still execute the configured SketchyBar binary.
4. Light mode applies ink-colored clock, date, wordmark, and light crest fields.
5. Dark mode applies light text, amber wordmark, and dark crest fields.
6. Appearance updates never contain `--reload` and never target Ghostty, wallpaper, or Übersicht.
7. A failed bar command does not advance the successful-mode marker and can be retried.

Live verification will apply both bar palettes directly, query the four affected SketchyBar items, and restore the effective macOS appearance. It will not toggle the macOS appearance setting or reassign the wallpaper.

## Scope

The implementation is limited to the appearance LaunchAgent template, deployment rendering, and their tests and documentation. It will merge around the user's existing uncommitted changes, including `bin/deploy.sh` and `config/sketchybar/sketchybarrc`. The SketchyBar configuration itself does not need to change for this fix.
