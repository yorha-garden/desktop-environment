# System Appearance Theming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the YoRHa wallpaper, Übersicht widgets, and SketchyBar follow macOS Light/Dark appearance automatically while Ghostty remains permanently dark and byte-for-byte unchanged.

**Architecture:** One committed two-frame dynamic HEIC is assigned once at deployment and macOS selects its Light/Dark frame natively. Übersicht follows `prefers-color-scheme` independently, while a compiled Swift LaunchAgent resolves appearance at login, wake, and `AppleInterfaceThemeChangedNotification` and invokes an idempotent SketchyBar-only coordinator.

**Tech Stack:** macOS 26, Swift 6.2/AppKit/Image I/O, HEIC `apple_desktop:apr` metadata, launchd, Bash 3.2, AppleScript, Übersicht JSX/CSS, SketchyBar CLI, Python 3 standard-library tests; Chrome headless is developer-only regeneration tooling.

## Global Constraints

- Ghostty stays permanently dark; the appearance pipeline must never write, reload, or signal Ghostty.
- Preserve widget geometry, typography, telemetry cadence, and motion timing.
- Light palette: field `#CAC5B0`, ink `#4A4741`, raised surface `#D6D2C1`, live `#BC9A5A`, alert `#BB3B36`.
- Dark palette: field `#16161A`, text `#D8D4C4`, bright `#EFEBDB`, surface `#3A3A40`, ornament `#6E7B8B`, live `#BC9A5A`, alert `#BB3B36`.
- Widget transitions are 200 ms ease and must not reload widgets or replay entrance animations.
- Runtime code/assets live beneath `~/.config/yorha/`; launchd must not read this repository under `~/Documents`.
- `assets/yorha-system.heic` has exactly two 5120×2880 frames with `apple_desktop:apr` mapping `l:0,d:1`; deployment assigns it once and macOS owns frame switching.
- Only `bin/regenerate-system-wallpaper.sh --with-chrome` may invoke Chrome. Deployment, the watcher, and the coordinator never render or regenerate wallpaper.
- The watcher and coordinator own SketchyBar only; they never assign wallpaper, restart `WallpaperAgent`, choose raster paths, read an asset manifest, or refresh Übersicht.
- Deployment and restoration remain idempotent.
- Existing uncommitted changes in `README.md`, `bin/deploy.sh`, `config/sketchybar/sketchybarrc`, `widgets/yorha/hud.jsx`, `widgets/yorha/pod.jsx`, and `launchd/com.yorha.sketchybar-minute.plist` are user-owned. Merge around them; never replace or discard them.
- Add no package dependency.

## File Map

**Create:** `assets/wallpaper-dark.svg`, `assets/yorha-system.heic`, `assets/yorha-icon-light.png`, `assets/yorha-icon-dark.png`, `bin/yorha-system-wallpaper.swift`, `bin/regenerate-system-wallpaper.sh`, `widgets/yorha/theme.jsx`, `bin/apply-appearance.sh`, `bin/appearance-watcher.swift`, `launchd/com.yorha.appearance-watcher.plist`, `tests/__init__.py`, `tests/test_theme_assets.py`, `tests/test_widget_theme.py`, `tests/test_apply_appearance.py`, `tests/appearance_watcher_tests.swift`, `tests/test_deployment_contract.py`.

**Modify:** `config/shell/palette.sh`, `bin/make-wallpaper.sh`, all four existing widget JSX files, `config/sketchybar/sketchybarrc`, `bin/deploy.sh`, `bin/yorha-backup.sh`, `README.md`, and `docs/DECISIONS.md`.

---

### Task 1: Canonical palette and committed dynamic HEIC

**Files:**
- Create: `assets/wallpaper-dark.svg`
- Create: `assets/yorha-system.heic`
- Create: `assets/yorha-icon-light.png`
- Create: `assets/yorha-icon-dark.png`
- Create: `bin/yorha-system-wallpaper.swift`
- Create: `bin/regenerate-system-wallpaper.sh`
- Create: `tests/__init__.py`
- Create: `tests/test_theme_assets.py`
- Modify: `config/shell/palette.sh`
- Modify: `bin/make-wallpaper.sh`

**Interfaces:**
- Produces exports `YORHA_BRIGHT=EFEBDB`, `YORHA_STEEL=6E7B8B`.
- Produces one committed `assets/yorha-system.heic` with exactly two 5120×2880 frames and appearance metadata `{"l":0,"d":1}`.
- Produces `yorha-system-wallpaper.swift --build <light.png> <dark.png> <output.heic>`, `--inspect <wallpaper.heic>`, and `--extract <wallpaper.heic> <index> <output.png>`.
- Produces developer-only `regenerate-system-wallpaper.sh --with-chrome`; every other argument is rejected with exit 64 before Chrome is invoked.
- Produces `make-wallpaper.sh --verify`, verification-only compatibility alias `--render-only`, and `--print-path [light|dark]`. All print-path forms return the same committed HEIC path; no-argument mode verifies and manually applies it.

- [ ] **Step 1: Write failing asset tests**

Create `tests/test_theme_assets.py`:

```python
import hashlib, json, re, struct, subprocess, unittest, xml.etree.ElementTree as ET
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def palette():
    text = (ROOT / "config/shell/palette.sh").read_text()
    return dict(re.findall(r"^export YORHA_([A-Z_]+)=([0-9A-F]{6})$", text, re.M))

def png_ihdr(path):
    raw = path.read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">IIBB", raw[16:26])

class ThemeAssetTests(unittest.TestCase):
    def test_terminal_native_tokens(self):
        self.assertEqual(palette()["BRIGHT"], "EFEBDB")
        self.assertEqual(palette()["STEEL"], "6E7B8B")

    def test_wallpaper_sources(self):
        roots = [ET.parse(ROOT / p).getroot() for p in
                 ("assets/wallpaper.svg", "assets/wallpaper-dark.svg")]
        for root in roots:
            self.assertEqual((root.attrib["width"], root.attrib["height"]), ("5120", "2880"))
        dark = (ROOT / "assets/wallpaper-dark.svg").read_text().upper()
        self.assertIn("#16161A", dark)
        self.assertIn("#6E7B8B", dark)

    def test_crest_variants(self):
        for name in ("yorha-icon-light.png", "yorha-icon-dark.png"):
            self.assertEqual(png_ihdr(ROOT / "assets" / name), (31, 36, 8, 6))

    def test_system_wallpaper_has_appearance_variants(self):
        result = subprocess.run(
            ["swift", str(ROOT / "bin/yorha-system-wallpaper.swift"), "--inspect",
             str(ROOT / "assets/yorha-system.heic")],
            check=True, text=True, capture_output=True)
        self.assertEqual(json.loads(result.stdout), {
            "frameCount": 2,
            "frames": [[5120, 2880], [5120, 2880]],
            "appearance": {"l": 0, "d": 1},
        })

    def test_normal_wallpaper_consumer_keeps_chrome_developer_only(self):
        consumer = (ROOT / "bin/make-wallpaper.sh").read_text()
        regenerator = (ROOT / "bin/regenerate-system-wallpaper.sh").read_text()
        self.assertNotIn("Chrome", consumer)
        self.assertNotIn("regenerate-system-wallpaper", consumer)
        self.assertRegex(regenerator, r'"\$1"\s*=\s*"--with-chrome"')
        self.assertLess(regenerator.index('"--with-chrome"'),
                        regenerator.index('"$CHROME" --headless'))

    def test_verification_does_not_modify_committed_heic(self):
        wallpaper = ROOT / "assets/yorha-system.heic"
        before = hashlib.sha256(wallpaper.read_bytes()).digest()
        subprocess.run([str(ROOT / "bin/make-wallpaper.sh"), "--verify"], check=True)
        self.assertEqual(hashlib.sha256(wallpaper.read_bytes()).digest(), before)
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest tests.test_theme_assets -v`

Expected: missing tokens, HEIC, Image I/O tool, crest assets, and gated regeneration behavior fail.

- [ ] **Step 3: Add palette names and dark SVG**

Append to `palette.sh`:

```bash
export YORHA_BRIGHT=EFEBDB
export YORHA_STEEL=6E7B8B
```

Create `wallpaper-dark.svg` with the light SVG's exact dimensions, pattern geometry, grain, and layer order. Use `#16161A` field, `#6E7B8B` lattice at `0.12`, `#131317` vignette, and grain opacity `0.07` with `mix-blend-mode:screen`.

- [ ] **Step 4: Generate and inspect crest variants**

```bash
cp assets/yorha-icon.png assets/yorha-icon-light.png
ffmpeg -y -i assets/yorha-icon.png \
  -filter_complex "color=c=0xBC9A5A:s=31x36,format=rgba[fill];[0:v]alphaextract[a];[fill][a]alphamerge" \
  -frames:v 1 assets/yorha-icon-dark.png
sips -g pixelWidth -g pixelHeight -g hasAlpha assets/yorha-icon-{light,dark}.png
```

Expected: both 31×36 with alpha. Visually inspect: identical silhouette; light ink, dark amber. FFmpeg is development-only and not a runtime dependency.

- [ ] **Step 5: Add the Image I/O HEIC tool**

Implement `bin/yorha-system-wallpaper.swift` with fixed 5120×2880 validation. `--build` writes light as frame 0 and dark as frame 1, and attaches this binary-plist mapping to frame 0 as a base64 string at `apple_desktop:apr`:

```swift
let appearance = ["l": 0, "d": 1]
let plist = try PropertyListSerialization.data(
    fromPropertyList: appearance, format: .binary, options: 0)
CGImageMetadataSetTagWithPath(
    metadata, nil, "apple_desktop:apr" as CFString, tag)
```

`--inspect` must emit sorted JSON containing `frameCount`, `frames`, and decoded `appearance`; `--extract` writes the requested frame as PNG for visual inspection.

- [ ] **Step 6: Add the developer-only regenerator and normal consumer**

`bin/regenerate-system-wallpaper.sh` must accept exactly `--with-chrome`, render the two SVGs to a `mktemp -d` directory with headless Chrome, call the Swift tool's `--build`, then call `--inspect`. Its trap removes only that temporary directory.

Refactor `bin/make-wallpaper.sh` so `--verify` and `--render-only` inspect the committed HEIC without modifying it, `--print-path` and `--print-path light|dark` print that HEIC path, and no-argument mode verifies then assigns the HEIC. It must contain neither `Chrome` nor a call to `regenerate-system-wallpaper.sh`.

- [ ] **Step 7: Verify and commit**

```bash
bash -n bin/make-wallpaper.sh bin/regenerate-system-wallpaper.sh config/shell/palette.sh
swiftc -typecheck bin/yorha-system-wallpaper.swift
python3 -m unittest tests.test_theme_assets -v
bin/make-wallpaper.sh --verify
swift bin/yorha-system-wallpaper.swift --inspect assets/yorha-system.heic
git add config/shell/palette.sh assets/wallpaper-dark.svg assets/yorha-system.heic \
  assets/yorha-icon-{light,dark}.png bin/make-wallpaper.sh \
  bin/regenerate-system-wallpaper.sh bin/yorha-system-wallpaper.swift \
  tests/__init__.py tests/test_theme_assets.py
git commit -m "fix: package dynamic wallpaper as HEIC"
```

Expected inspection: `{"appearance":{"d":1,"l":0},"frameCount":2,"frames":[[5120,2880],[5120,2880]]}`. This task is already committed through `1cccfef`, `39d9f1e`, and `13d385d`; do not amend those commits or regenerate the HEIC during later tasks.

---

### Task 2: Adaptive Übersicht theme

**Files:**
- Create: `widgets/yorha/theme.jsx`
- Create: `tests/test_widget_theme.py`
- Modify: `widgets/yorha/hud.jsx`
- Modify: `widgets/yorha/pod.jsx`
- Modify: `widgets/yorha/arcs.jsx`
- Modify: `widgets/yorha/beam.jsx`

**Interfaces:** Defines `--yorha-field`, `text`, `value`, `panel`, `ornament`, `track`, `accent`, and `alert` on `:root`; consumers use light fallbacks.

- [ ] **Step 1: Write failing widget tests**

Create `tests/test_widget_theme.py`:

```python
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
W = ROOT / "widgets/yorha"
CONSUMERS = ["hud.jsx", "pod.jsx", "arcs.jsx", "beam.jsx"]

class WidgetThemeTests(unittest.TestCase):
    def test_provider(self):
        text = (W / "theme.jsx").read_text()
        self.assertIn("export const refreshFrequency = false", text)
        self.assertNotIn("export const command", text)
        self.assertIn("@media (prefers-color-scheme: dark)", text)
        for token in ("field", "text", "value", "panel", "ornament", "track", "accent", "alert"):
            self.assertGreaterEqual(text.count(f"--yorha-{token}"), 2)
        for color in ("#CAC5B0", "#4A4741", "#16161A",
                      "#D8D4C4", "#EFEBDB", "#3A3A40", "#6E7B8B",
                      "#BC9A5A", "#BB3B36"):
            self.assertIn(color, text)
        self.assertIn("rgba(214,210,193,.5)", text)

    def test_consumers_use_fallbacks(self):
        for name in CONSUMERS:
            text = (W / name).read_text()
            self.assertRegex(text, r"var\(--yorha-[a-z-]+,\s*(?:#|rgba\()", name)
            self.assertNotIn("AppleInterfaceStyle", text, name)

    def test_svg_strokes_follow_current_color(self):
        text = (W / "arcs.jsx").read_text()
        self.assertNotIn('stroke="#4A4741"', text)
        self.assertIn('stroke="currentColor"', text)
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest tests.test_widget_theme -v`

- [ ] **Step 3: Create render-only provider**

Create `theme.jsx` with no command/timer/visible element:

```jsx
export const refreshFrequency = false;
export const className = `left:0;top:0;width:0;height:0;pointer-events:none;`;
export const render = () => <style>{`
  :root {
    --yorha-field:#CAC5B0; --yorha-text:#4A4741; --yorha-value:#4A4741;
    --yorha-panel:rgba(214,210,193,.5); --yorha-ornament:#4A4741;
    --yorha-track:rgba(74,71,65,.18); --yorha-accent:#BC9A5A; --yorha-alert:#BB3B36;
  }
  @media (prefers-color-scheme: dark) { :root {
    --yorha-field:#16161A; --yorha-text:#D8D4C4; --yorha-value:#EFEBDB;
    --yorha-panel:rgba(58,58,64,.72); --yorha-ornament:#6E7B8B;
    --yorha-track:rgba(216,212,196,.18); --yorha-accent:#BC9A5A; --yorha-alert:#BB3B36;
  }}
`}</style>;
```

- [ ] **Step 4: Convert consumers without changing behavior**

Use patterns such as:

```css
color: var(--yorha-text, #4A4741);
.v { color: var(--yorha-value, #4A4741); transition: color 200ms ease; }
.alert { color: var(--yorha-alert, #BB3B36); }
.meter { background: var(--yorha-track, rgba(74,71,65,.18)); }
```

Theme Pod borders/panel/LINK, change arc/line strokes to `currentColor`, and set ornament wrappers to `var(--yorha-ornament, #4A4741)`. In `beam.jsx`, use `--yorha-beam-rgb:74,71,65` and override it to `110,123,139` in a dark media query. Add 200 ms transitions only to color/background/border/stroke. Preserve the current HUD telemetry and Pod refresh changes plus every motion/reduced-motion declaration.

- [ ] **Step 5: Verify and commit**

```bash
python3 -m unittest tests.test_widget_theme -v
rg -n "#4A4741|rgba\(74,71,65" widgets/yorha
git diff -- widgets/yorha
git add widgets/yorha/theme.jsx widgets/yorha/arcs.jsx widgets/yorha/beam.jsx tests/test_widget_theme.py
git add -p widgets/yorha/hud.jsx widgets/yorha/pod.jsx
git commit -m "feat: make desktop widgets appearance-aware"
```

Expected: stage only theming hunks from HUD/Pod. Their pre-existing telemetry/refresh hunks remain unstaged and user-owned.

---

### Task 3: Idempotent appearance coordinator

**Files:**
- Create: `bin/apply-appearance.sh`
- Create: `tests/test_apply_appearance.py`

**Interfaces:** `apply-appearance.sh light|dark [--force]`; `${YORHA_APPEARANCE_ROOT:-$HOME/.config/yorha/appearance}`; fixed crest paths `$ROOT/yorha-icon-light.png` and `$ROOT/yorha-icon-dark.png`; test override `YORHA_SKETCHYBAR_BIN`. Produces `$ROOT/last-successful-mode` only after SketchyBar succeeds. It has no wallpaper, `WallpaperAgent`, raster, manifest, Chrome, regeneration, or Übersicht responsibility.

- [ ] **Step 1: Write failing coordinator tests**

Create a `unittest.TestCase` whose setup builds a `TemporaryDirectory` as the appearance root, two empty crest files at the fixed runtime names, and an executable SketchyBar double that appends argv to a call log. Implement these exact tests:

```python
def test_invalid_mode_changes_nothing(self):
    result = self.run_apply("sepia")
    self.assertEqual(result.returncode, 64)
    self.assertEqual(self.calls(), [])

def test_dark_applies_dark_assets_and_colors(self):
    result = self.run_apply("dark")
    calls = "\n".join(self.calls())
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn(str(self.dark_crest), calls)
    self.assertIn("0xffd8d4c4", calls)
    self.assertIn("0xffbc9a5a", calls)
    self.assertEqual(self.state.read_text().strip(), "dark")

def test_same_mode_is_noop_unless_forced(self):
    self.assertEqual(self.run_apply("light").returncode, 0)
    first = list(self.calls())
    self.assertEqual(self.run_apply("light").returncode, 0)
    self.assertEqual(self.calls(), first)
    self.assertEqual(self.run_apply("light", "--force").returncode, 0)
    self.assertGreater(len(self.calls()), len(first))

def test_bar_failure_does_not_advance_and_is_retryable(self):
    self.make_failing(self.sketchybar)
    result = self.run_apply("dark")
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("sketchybar", "\n".join(self.calls()))
    self.assertFalse(self.state.exists())

def test_missing_crest_changes_nothing(self):
    self.dark_crest.unlink()
    self.assertNotEqual(self.run_apply("dark").returncode, 0)
    self.assertEqual(self.calls(), [])

def test_coordinator_has_no_wallpaper_or_manifest_pipeline(self):
    text = (ROOT / "bin/apply-appearance.sh").read_text().lower()
    for forbidden in ("osascript", "wallpaperagent", "wallpaper_", "assets.env",
                      "chrome", "regenerate-system-wallpaper", "übersicht", "ubersicht"):
        self.assertNotIn(forbidden, text)
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest tests.test_apply_appearance -v`

- [ ] **Step 3: Implement validation and locking**

Start with:

```bash
#!/usr/bin/env bash
set -uo pipefail
MODE="${1:-}"; FORCE="${2:-}"
case "$MODE" in light|dark) ;; *) echo "usage: $0 light|dark [--force]" >&2; exit 64;; esac
[ -z "$FORCE" ] || [ "$FORCE" = --force ] || exit 64
ROOT="${YORHA_APPEARANCE_ROOT:-$HOME/.config/yorha/appearance}"
STATE="$ROOT/last-successful-mode"; LOCK="$ROOT/apply.lock"
LIGHT_CREST="$ROOT/yorha-icon-light.png"
DARK_CREST="$ROOT/yorha-icon-dark.png"
```

Resolve the selected fixed crest with `case` and require it to be a regular file before invoking SketchyBar. Wait for an existing lock for at most 10 seconds, then fail with exit 75 rather than dropping the newer mode:

```bash
attempt=0
until mkdir "$LOCK" 2>/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || { echo "appearance lock timeout" >&2; exit 75; }
  sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM
```

A repeated completed mode is a no-op unless forced. Do not source any manifest or accept wallpaper paths from the environment.

- [ ] **Step 4: Implement the SketchyBar-only update**

Use the injected SketchyBar command and these exact mappings:

```bash
case "$MODE" in
  light) BAR_TEXT=0xff4a4741; BRAND=0xff4a4741; CREST="$LIGHT_CREST";;
  dark)  BAR_TEXT=0xffd8d4c4; BRAND=0xffbc9a5a; CREST="$DARK_CREST";;
esac
"$SKETCHYBAR" --set clock label.color="$BAR_TEXT" --set date label.color="$BAR_TEXT" \
  --set yorha label.color="$BRAND" --set yorha_icon background.image="$CREST"
```

Atomically write `last-successful-mode` only after the single SketchyBar command succeeds. On failure, return nonzero and leave the prior marker untouched so the watcher or bar reload retries. The script must never assign or inspect wallpaper, restart a wallpaper process, or refresh Übersicht.

- [ ] **Step 5: Verify and commit**

```bash
chmod +x bin/apply-appearance.sh
bash -n bin/apply-appearance.sh
python3 -m unittest tests.test_apply_appearance -v
git add bin/apply-appearance.sh tests/test_apply_appearance.py
git commit -m "feat: add idempotent appearance coordinator"
```

---

### Task 4: Native Swift watcher and LaunchAgent

**Files:**
- Create: `bin/appearance-watcher.swift`
- Create: `tests/appearance_watcher_tests.swift`
- Create: `launchd/com.yorha.appearance-watcher.plist`

**Interfaces:** `resolveAppearance(style: String?) -> String`; `coordinatorArguments(mode: String) -> [String]`; production invocation `yorha-appearance-watcher <absolute-coordinator-path>`; `TESTING` excludes production main.

- [ ] **Step 1: Write failing Swift tests**

Create `tests/appearance_watcher_tests.swift`:

```swift
import Foundation
@main struct AppearanceWatcherTests {
    static func main() {
        precondition(resolveAppearance(style: "Dark") == "dark")
        precondition(resolveAppearance(style: nil) == "light")
        precondition(resolveAppearance(style: "Light") == "light")
        precondition(coordinatorArguments(mode: "dark") == ["dark"])
        print("appearance watcher tests passed")
    }
}
```

- [ ] **Step 2: Confirm compile failure**

Run: `swiftc -D TESTING bin/appearance-watcher.swift tests/appearance_watcher_tests.swift -o /tmp/yorha-appearance-watcher-tests`

- [ ] **Step 3: Implement testable watcher boundaries**

Begin `appearance-watcher.swift`:

```swift
import AppKit
import Foundation
func resolveAppearance(style: String?) -> String { style == "Dark" ? "dark" : "light" }
func coordinatorArguments(mode: String) -> [String] { [mode] }
```

Implement `runCoordinator(path:mode:)` with `Process`, absolute executable URL, `[mode]`, inherited stdout/stderr, and `waitUntilExit`. Log nonzero exit without terminating the watcher.

- [ ] **Step 4: Implement observation/coalescing**

An `AppearanceWatcher` owns observer tokens and a pending `DispatchWorkItem`. Cancel/reschedule appearance events after 150 ms; startup and wake apply immediately. Register:

```swift
DistributedNotificationCenter.default().addObserver(
  forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
  object: nil, queue: .main) { [weak self] _ in self?.scheduleApply(after: 0.15) }
NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didWakeNotification,
  object: nil, queue: .main) { [weak self] _ in self?.scheduleApply(after: 0) }
```

Resolve from `UserDefaults.standard.string(forKey: "AppleInterfaceStyle")`. Under `#if !TESTING`, validate one absolute coordinator path, set `NSApplication.shared.setActivationPolicy(.prohibited)`, schedule startup application, and run `RunLoop.main`.

- [ ] **Step 5: Create the plist**

Use the existing plist header and these fields:

```xml
<key>Label</key><string>com.yorha.appearance-watcher</string>
<key>ProgramArguments</key><array>
  <string>HOME_PATH/.config/yorha/bin/yorha-appearance-watcher</string>
  <string>HOME_PATH/.config/yorha/bin/apply-appearance.sh</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>HOME_PATH/.config/yorha/logs/appearance.log</string>
<key>StandardErrorPath</key><string>HOME_PATH/.config/yorha/logs/appearance.log</string>
```

- [ ] **Step 6: Verify and commit**

```bash
swiftc -D TESTING bin/appearance-watcher.swift tests/appearance_watcher_tests.swift -o /tmp/yorha-appearance-watcher-tests
/tmp/yorha-appearance-watcher-tests
swiftc -typecheck bin/appearance-watcher.swift
plutil -lint launchd/com.yorha.appearance-watcher.plist
git add bin/appearance-watcher.swift tests/appearance_watcher_tests.swift launchd/com.yorha.appearance-watcher.plist
git commit -m "feat: watch macOS appearance changes natively"
```

---

### Task 5: SketchyBar startup and deployment

**Files:**
- Create: `tests/test_deployment_contract.py`
- Modify: `config/sketchybar/sketchybarrc`
- Modify: `bin/deploy.sh`

**Interfaces:** Runtime binary/coordinator under `~/.config/yorha/bin`; copied `yorha-system.heic` and both fixed-name crests under `~/.config/yorha/appearance`; GUI job label `com.yorha.appearance-watcher`. Deployment verifies and assigns the committed HEIC once, but never renders it and never invokes the developer regenerator or Chrome.

- [ ] **Step 1: Write failing deployment/isolation tests**

Create `tests/test_deployment_contract.py`:

```python
import plistlib, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

class DeploymentContractTests(unittest.TestCase):
    def test_deploy_installs_contract(self):
        text = (ROOT / "bin/deploy.sh").read_text()
        for value in ("appearance-watcher.swift", "swiftc", "apply-appearance.sh",
                      "yorha-system.heic", "yorha-icon-light.png", "yorha-icon-dark.png",
                      "com.yorha.appearance-watcher.plist"):
            self.assertIn(value, text)

    def test_deploy_never_renders_wallpaper(self):
        text = (ROOT / "bin/deploy.sh").read_text().lower()
        for forbidden in ("--with-chrome", "google chrome", "regenerate-system-wallpaper",
                          "--headless", "wallpaper-light-", "wallpaper-dark-", "assets.env"):
            self.assertNotIn(forbidden, text)

    def test_bar_resolves_mode_before_defaults(self):
        text = (ROOT / "config/sketchybar/sketchybarrc").read_text()
        self.assertLess(text.index("AppleInterfaceStyle"), text.index("sketchybar --default"))
        self.assertIn("apply-appearance.sh", text)

    def test_plist_uses_runtime_paths(self):
        raw = (ROOT / "launchd/com.yorha.appearance-watcher.plist").read_bytes()
        data = plistlib.loads(raw.replace(b"HOME_PATH", b"/Users/test"))
        self.assertTrue(data["RunAtLoad"] and data["KeepAlive"])
        self.assertTrue(all("Documents" not in arg for arg in data["ProgramArguments"]))

    def test_pipeline_does_not_target_ghostty(self):
        paths = [ROOT / "bin/apply-appearance.sh", ROOT / "bin/appearance-watcher.swift",
                 ROOT / "launchd/com.yorha.appearance-watcher.plist", ROOT / "widgets/yorha/theme.jsx"]
        self.assertNotIn("ghostty", "\n".join(p.read_text().lower() for p in paths))

    def test_watcher_and_coordinator_are_sketchybar_only(self):
        text = "\n".join((ROOT / p).read_text().lower() for p in
                         ("bin/apply-appearance.sh", "bin/appearance-watcher.swift"))
        for forbidden in ("osascript", "wallpaperagent", "wallpaper_", "assets.env",
                          "chrome", "regenerate-system-wallpaper", "übersicht", "ubersicht"):
            self.assertNotIn(forbidden, text)
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest tests.test_deployment_contract -v`

- [ ] **Step 3: Make SketchyBar start with the effective colors**

Before `sketchybar --default`, resolve:

```bash
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = Dark ]; then
  TEXT=0xffd8d4c4; BRAND=0xffbc9a5a
  CREST="$HOME/.config/yorha/appearance/yorha-icon-dark.png"
else
  TEXT=0xff4a4741; BRAND=0xff4a4741
  CREST="$HOME/.config/yorha/appearance/yorha-icon-light.png"
fi
```

Use `$TEXT` for defaults/date/clock, `$BRAND` for the wordmark, `$CREST` for the image. Preserve the current minute event and entrance behavior. After the final `y_offset=0`, call installed `apply-appearance.sh <effective-mode> --force` best-effort so manual reloads reconcile live values.

- [ ] **Step 4: Install committed runtime artifacts atomically**

Merge into the current `deploy.sh`, preserving the minute-agent block:

1. Create `~/.config/yorha/bin`, `~/.config/yorha/appearance`, and `~/.config/yorha/logs`.
2. Run `bin/make-wallpaper.sh --verify` to inspect the already committed HEIC. Do not invoke its no-argument apply mode, its developer regenerator, or Chrome.
3. Copy `assets/yorha-system.heic` atomically to `~/.config/yorha/appearance/yorha-system.heic` and copy both crest PNGs to their fixed names.
4. Copy the coordinator atomically and compile the watcher to `yorha-appearance-watcher.tmp`, `chmod`, then `mv` to final.
5. Assign the copied HEIC path to every desktop once with argv-bound AppleScript:

```bash
RUNTIME_WALLPAPER="$APPEARANCE/yorha-system.heic"
osascript - "$RUNTIME_WALLPAPER" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS
```

Do not create an asset manifest, hashed wallpaper directory, or generated raster. Do not restart `WallpaperAgent`: the single assigned HEIC path and its `apple_desktop:apr` metadata are the wallpaper contract.

- [ ] **Step 5: Install/bootstrap LaunchAgent and apply current mode**

Render `HOME_PATH`, boot out the prior label, bootstrap the plist, then force the current effective mode for SketchyBar only. Do not skip installation merely because SketchyBar is absent. The forced coordinator call must leave the wallpaper path untouched.

```bash
sed "s|HOME_PATH|$HOME|g" "$REPO/launchd/com.yorha.appearance-watcher.plist" > "$APPEARANCE_PLIST"
launchctl bootout "gui/$(id -u)/com.yorha.appearance-watcher" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"
```

- [ ] **Step 6: Verify and commit**

```bash
bash -n bin/deploy.sh config/sketchybar/sketchybarrc bin/apply-appearance.sh bin/make-wallpaper.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
swift bin/yorha-system-wallpaper.swift --inspect assets/yorha-system.heic
swiftc -D TESTING bin/appearance-watcher.swift tests/appearance_watcher_tests.swift -o /tmp/yorha-appearance-watcher-tests
/tmp/yorha-appearance-watcher-tests
plutil -lint launchd/com.yorha.appearance-watcher.plist
git diff -- bin/deploy.sh config/sketchybar/sketchybarrc
rg -n "yorha_minute|sketchybar-minute" bin/deploy.sh config/sketchybar/sketchybarrc
if rg -n -- '--with-chrome|Google Chrome|regenerate-system-wallpaper|--headless|wallpaper-(light|dark)-|assets\.env' bin/deploy.sh bin/apply-appearance.sh bin/appearance-watcher.swift; then exit 1; fi
git add tests/test_deployment_contract.py
git add -p bin/deploy.sh config/sketchybar/sketchybarrc
git commit -m "feat: deploy automatic desktop appearance switching"
```

Expected: stage only appearance-related hunks. The user's minute-boundary hunks and untracked plist remain unstaged and present.

---

### Task 6: Restore, documentation, and live verification

**Files:**
- Modify: `bin/yorha-backup.sh`
- Modify: `README.md`
- Modify: `docs/DECISIONS.md`
- Modify: `tests/test_deployment_contract.py`

**Interfaces:** Restore label `com.yorha.appearance-watcher`; explicit removal targets are the watcher binary, coordinator, `~/.config/yorha/appearance` (copied HEIC, crests, lock, and successful-mode marker), and appearance log. Restore returns the pre-install wallpaper through the existing backup mechanism.

- [ ] **Step 1: Add failing restore/docs tests**

Append:

```python
def test_restore_removes_appearance_runtime(self):
    text = (ROOT / "bin/yorha-backup.sh").read_text()
    for value in ("com.yorha.appearance-watcher", "yorha-appearance-watcher",
                  "apply-appearance.sh", ".config/yorha/appearance"):
        self.assertIn(value, text)

def test_docs_state_boundary(self):
    readme = (ROOT / "README.md").read_text().lower()
    decisions = (ROOT / "docs/DECISIONS.md").read_text().lower()
    self.assertIn("automatic appearance", readme)
    self.assertIn("ghostty remains permanently dark", readme)
    self.assertIn("appearance-watcher", decisions)
    self.assertIn("prefers-color-scheme", decisions)
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest tests.test_deployment_contract -v`

- [ ] **Step 3: Extend generated restore script safely**

Before its path-reversion loop, add:

```bash
LABEL=com.yorha.appearance-watcher
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
if ! grep -qxF "$LABEL.plist" "$HERE/launchagents.txt" 2>/dev/null; then
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
fi
rm -f "$HOME/.config/yorha/bin/yorha-appearance-watcher"
rm -f "$HOME/.config/yorha/bin/apply-appearance.sh"
rm -f "$HOME/.config/yorha/logs/appearance.log"
rm -rf "$HOME/.config/yorha/appearance"
```

Do not broaden the recursive target.

- [ ] **Step 4: Update documentation**

README: automatic desktop appearance/permanent-dark Ghostty summary, new file-map entries, macOS-native dynamic HEIC ownership, system→watcher→SketchyBar-coordinator flow, runtime/log paths, four LaunchAgents, TCC/runtime-path gotchas, and the developer-only `--with-chrome` regeneration command. DECISIONS: single assigned HEIC rationale and exact metadata/frame contract, dedicated watcher rationale, exact palettes, media-query/no-reload choice, SketchyBar retry behavior, and Ghostty boundary. Preserve current README minute-event changes.

- [ ] **Step 5: Run full static verification**

```bash
set -e
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash -n bin/*.sh config/sketchybar/sketchybarrc config/shell/*.sh
swiftc -typecheck bin/appearance-watcher.swift
swiftc -D TESTING bin/appearance-watcher.swift tests/appearance_watcher_tests.swift -o /tmp/yorha-appearance-watcher-tests
/tmp/yorha-appearance-watcher-tests
swift bin/yorha-system-wallpaper.swift --inspect assets/yorha-system.heic
for plist in launchd/*.plist; do plutil -lint "$plist"; done
if rg -n -- '--with-chrome|Google Chrome|regenerate-system-wallpaper|--headless|wallpaper-(light|dark)-|assets\.env' bin/deploy.sh bin/apply-appearance.sh bin/appearance-watcher.swift; then exit 1; fi
git diff --check
```

- [ ] **Step 6: Record mode and Ghostty checksums**

```bash
VERIFY_DIR="$(mktemp -d)"; echo "$VERIFY_DIR" > /tmp/yorha-appearance-verify-dir
shasum -a 256 config/ghostty/config config/ghostty/config.ghostty \
  "$HOME/.config/ghostty/config" "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
  > "$VERIFY_DIR/ghostty.before"
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = Dark ]; then echo dark; else echo light; fi \
  > "$VERIFY_DIR/effective-mode"
osascript -e 'tell application "System Events" to get picture of every desktop' \
  > "$VERIFY_DIR/wallpaper.before"
```

- [ ] **Step 7: Deploy, verify one HEIC assignment, and exercise SketchyBar modes**

```bash
bash bin/deploy.sh
VERIFY_DIR="$(cat /tmp/yorha-appearance-verify-dir)"
APPLY="$HOME/.config/yorha/bin/apply-appearance.sh"
swift bin/yorha-system-wallpaper.swift --inspect "$HOME/.config/yorha/appearance/yorha-system.heic"
osascript -e 'tell application "System Events" to get picture of every desktop' \
  > "$VERIFY_DIR/wallpaper.deployed"
grep -F "$HOME/.config/yorha/appearance/yorha-system.heic" "$VERIFY_DIR/wallpaper.deployed"
"$APPLY" light --force; test "$(cat "$HOME/.config/yorha/appearance/last-successful-mode")" = light
osascript -e 'tell application "System Events" to get picture of every desktop' \
  > "$VERIFY_DIR/wallpaper.after-light"
diff -u "$VERIFY_DIR/wallpaper.deployed" "$VERIFY_DIR/wallpaper.after-light"
"$APPLY" dark --force; test "$(cat "$HOME/.config/yorha/appearance/last-successful-mode")" = dark
osascript -e 'tell application "System Events" to get picture of every desktop' \
  > "$VERIFY_DIR/wallpaper.after-dark"
diff -u "$VERIFY_DIR/wallpaper.deployed" "$VERIFY_DIR/wallpaper.after-dark"
"$APPLY" "$(cat "$VERIFY_DIR/effective-mode")" --force
```

For each forced mode, query `sketchybar --query` for clock/date/wordmark/icon properties. Forced coordinator modes intentionally affect only SketchyBar; the exact wallpaper-path diffs above must be empty. Do not change the macOS appearance setting or attempt to force a HEIC frame—Image I/O metadata plus macOS's native selection is the wallpaper contract.

- [ ] **Step 8: Verify crash recovery and Ghostty isolation**

```bash
UID_NOW="$(id -u)"
launchctl print "gui/$UID_NOW/com.yorha.appearance-watcher"
launchctl kill SIGTERM "gui/$UID_NOW/com.yorha.appearance-watcher"
sleep 2
launchctl print "gui/$UID_NOW/com.yorha.appearance-watcher"
VERIFY_DIR="$(cat /tmp/yorha-appearance-verify-dir)"
shasum -a 256 config/ghostty/config config/ghostty/config.ghostty \
  "$HOME/.config/ghostty/config" "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
  > "$VERIFY_DIR/ghostty.after"
diff -u "$VERIFY_DIR/ghostty.before" "$VERIFY_DIR/ghostty.after"
```

Expected: launchd restarts the watcher and checksum diff is empty.

Also query every desktop after watcher restart and compare it with `$VERIFY_DIR/wallpaper.deployed`; the assigned dynamic HEIC path must remain unchanged.

- [ ] **Step 9: Commit and final check**

```bash
git add bin/yorha-backup.sh docs/DECISIONS.md tests/test_deployment_contract.py
git add -p README.md
git commit -m "docs: document and restore appearance switching"
git status --short
git log --oneline -7
git diff --check HEAD~6..HEAD
```

Expected: only intentionally unabsorbed user changes remain; six feature commits are visible; no whitespace errors.
