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
- Use `f9fd880` (`docs: plan automatic desktop appearance theming`) as the recorded feature-base commit for final range checks; do not assume a fixed number of feature commits.
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

Create a `unittest.TestCase` whose setup builds a `TemporaryDirectory` as the appearance root, two empty crest files at the fixed runtime names, and an executable SketchyBar double that appends argv to a call log. The helper rewrites the same double so a failed update can be repaired and retried:

```python
def write_sketchybar(self, exit_code=0):
    self.sketchybar.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'sketchybar\t%s\\n\' "$*" >> "$YORHA_TEST_CALL_LOG"\n'
        f"exit {exit_code}\n")
    self.sketchybar.chmod(0o755)

def test_invalid_mode_changes_nothing(self):
    result = self.run_apply("sepia")
    self.assertEqual(result.returncode, 64)
    self.assertEqual(self.calls(), [])

def test_extra_arguments_are_rejected(self):
    result = self.run_apply("light", "--force", "unexpected")
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

def test_bar_failure_preserves_prior_mode_and_dark_retry_succeeds(self):
    self.assertEqual(self.run_apply("light").returncode, 0)
    self.assertEqual(self.state.read_text().strip(), "light")

    self.write_sketchybar(exit_code=1)
    failed = self.run_apply("dark")
    self.assertNotEqual(failed.returncode, 0)
    self.assertEqual(self.state.read_text().strip(), "light")

    self.write_sketchybar(exit_code=0)
    retried = self.run_apply("dark")
    self.assertEqual(retried.returncode, 0, retried.stderr)
    self.assertEqual(self.state.read_text().strip(), "dark")
    self.assertIn(str(self.dark_crest), "\n".join(self.calls()))

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
usage() { echo "usage: $0 light|dark [--force]" >&2; }
[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || { usage; exit 64; }
MODE="$1"; FORCE="${2:-}"
case "$MODE" in light|dark) ;; *) echo "usage: $0 light|dark [--force]" >&2; exit 64;; esac
[ -z "$FORCE" ] || [ "$FORCE" = --force ] || { usage; exit 64; }
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
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
on_signal() {
  status="$1"
  trap - EXIT INT TERM
  cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
```

The exact argument-count gate must execute before mode/asset validation, so missing or surplus arguments always return 64 without changing state or invoking SketchyBar. A repeated completed mode is a no-op unless forced. Do not source any manifest or accept wallpaper paths from the environment. `INT` and `TERM` must clean the lock and terminate with conventional status 130 or 143; they must not resume the update after cleanup.

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
import plistlib, re, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

class DeploymentContractTests(unittest.TestCase):
    def deploy_text(self):
        return (ROOT / "bin/deploy.sh").read_text()

    def appearance_block(self):
        text = self.deploy_text()
        begin = "# --- appearance runtime BEGIN"
        end = "# --- appearance runtime END"
        self.assertEqual((text.count(begin), text.count(end)), (1, 1))
        return text.split(begin, 1)[1].split(end, 1)[0]

    def test_deploy_uses_verify_only_and_never_regenerates(self):
        text = self.deploy_text()
        self.appearance_block()
        self.assertEqual(text.count('"$REPO/bin/make-wallpaper.sh" --verify'), 1)
        self.assertEqual(len(re.findall(r"make-wallpaper\.sh", text)), 1)
        lowered = text.lower()
        for forbidden in ("--with-chrome", "google chrome", "regenerate-system-wallpaper",
                          "--headless", "wallpaper-light-", "wallpaper-dark-", "assets.env"):
            self.assertNotIn(forbidden, lowered)

    def test_runtime_assets_are_atomic_and_committed_heic_is_source(self):
        block = self.appearance_block()
        helper = re.search(r"install_atomic\(\) \{(?P<body>.*?)\n\}", block, re.S)
        self.assertIsNotNone(helper)
        body = helper.group("body")
        self.assertIn('temporary="${destination}.tmp.$$"', body)
        self.assertLess(body.index('cp "$source" "$temporary"'),
                        body.index('mv "$temporary" "$destination"'))
        for call in (
            'install_atomic "$REPO/assets/yorha-system.heic" "$RUNTIME_WALLPAPER"',
            'install_atomic "$REPO/assets/yorha-icon-light.png" "$APPEARANCE/yorha-icon-light.png"',
            'install_atomic "$REPO/assets/yorha-icon-dark.png" "$APPEARANCE/yorha-icon-dark.png"',
            'install_atomic "$REPO/bin/apply-appearance.sh" "$RUNTIME_COORDINATOR"',
        ):
            self.assertEqual(block.count(call), 1, call)

    def test_runtime_heic_is_assigned_exactly_once_with_argv(self):
        text = self.deploy_text()
        block = self.appearance_block()
        self.assertEqual(re.findall(r'osascript\s+-\s+"([^"]+)"', text),
                         ["$RUNTIME_WALLPAPER"])
        self.assertEqual(text.count('set picture of every desktop'), 1)
        self.assertEqual(text.count('on run argv'), 1)
        self.assertIn('POSIX file (item 1 of argv)', block)
        self.assertNotRegex(text, r'osascript[^\n]*\$REPO')

    def test_watcher_plist_and_coordinator_install_contract(self):
        block = self.appearance_block()
        self.assertRegex(block, r'swiftc -O .*appearance-watcher\.swift" -o "\$WATCHER_TMP"')
        self.assertLess(block.index('swiftc -O '),
                        block.index('mv "$WATCHER_TMP" "$RUNTIME_WATCHER"'))
        self.assertEqual(block.count('launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"'), 1)
        self.assertEqual(block.count('"$RUNTIME_COORDINATOR" "$MODE" --force'), 1)

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
# --- appearance runtime BEGIN
APPEARANCE="$HOME/.config/yorha/appearance"
YORHA_BIN="$HOME/.config/yorha/bin"
mkdir -p "$APPEARANCE" "$YORHA_BIN" "$HOME/.config/yorha/logs"

install_atomic() {
  source="$1"
  destination="$2"
  temporary="${destination}.tmp.$$"
  cp "$source" "$temporary"
  mv "$temporary" "$destination"
}

"$REPO/bin/make-wallpaper.sh" --verify
RUNTIME_WALLPAPER="$APPEARANCE/yorha-system.heic"
RUNTIME_COORDINATOR="$YORHA_BIN/apply-appearance.sh"
RUNTIME_WATCHER="$YORHA_BIN/yorha-appearance-watcher"
install_atomic "$REPO/assets/yorha-system.heic" "$RUNTIME_WALLPAPER"
install_atomic "$REPO/assets/yorha-icon-light.png" "$APPEARANCE/yorha-icon-light.png"
install_atomic "$REPO/assets/yorha-icon-dark.png" "$APPEARANCE/yorha-icon-dark.png"
install_atomic "$REPO/bin/apply-appearance.sh" "$RUNTIME_COORDINATOR"
chmod +x "$RUNTIME_COORDINATOR"

WATCHER_TMP="$RUNTIME_WATCHER.tmp.$$"
swiftc -O "$REPO/bin/appearance-watcher.swift" -o "$WATCHER_TMP"
chmod +x "$WATCHER_TMP"
mv "$WATCHER_TMP" "$RUNTIME_WATCHER"

osascript - "$RUNTIME_WALLPAPER" <<'AS'
on run argv
  tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)
end run
AS
```

Keep the `appearance runtime BEGIN` marker open through Step 5 and close it only after the coordinator call. Do not create an asset manifest, hashed wallpaper directory, or generated raster. Do not restart `WallpaperAgent`: the single assigned HEIC path and its `apple_desktop:apr` metadata are the wallpaper contract. The test requires exactly one `make-wallpaper.sh` reference (`--verify`) and exactly one `osascript - "$RUNTIME_WALLPAPER"` assignment, so do not add a repository-path fallback.

- [ ] **Step 5: Install/bootstrap LaunchAgent and apply current mode**

Render `HOME_PATH`, boot out the prior label, bootstrap the plist, then force the current effective mode for SketchyBar only. Do not skip installation merely because SketchyBar is absent. The forced coordinator call must leave the wallpaper path untouched.

```bash
APPEARANCE_PLIST="$HOME/Library/LaunchAgents/com.yorha.appearance-watcher.plist"
PLIST_TMP="$APPEARANCE_PLIST.tmp.$$"
sed "s|HOME_PATH|$HOME|g" "$REPO/launchd/com.yorha.appearance-watcher.plist" > "$PLIST_TMP"
mv "$PLIST_TMP" "$APPEARANCE_PLIST"
launchctl bootout "gui/$(id -u)/com.yorha.appearance-watcher" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = Dark ]; then
  MODE=dark
else
  MODE=light
fi
"$RUNTIME_COORDINATOR" "$MODE" --force \
  || say "appearance -> watcher installed; SketchyBar update will retry"
# --- appearance runtime END
```

The block markers are part of the test interface. Keep the HEIC assignment before LaunchAgent bootstrap and keep the forced coordinator call after bootstrap. The coordinator call may fail when SketchyBar is absent, but it must not roll back the installed watcher or cause a second wallpaper assignment.

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

**Interfaces:** Snapshot stores the original `com.yorha.appearance-watcher.plist` bytes when present and records whether `gui/$(id -u)/com.yorha.appearance-watcher` was loaded. Restore boots out the deployed job, reinstates and re-bootstraps the original plist only when it was previously present and loaded, or removes the feature-created plist otherwise. Explicit removal targets are the watcher binary, coordinator, `~/.config/yorha/appearance` (copied HEIC, crests, lock, and successful-mode marker), and appearance log; the recorded wallpaper is restored through argv-bound AppleScript.

- [ ] **Step 1: Add failing restore/docs tests**

Extend the imports in `tests/test_deployment_contract.py` with `os`, `subprocess`, and `tempfile`, then append this complete second `unittest.TestCase`. Do not place these functions at module scope: `write_double`, `test_generated_restore_cleans_appearance_runtime_in_sandbox`, and `test_docs_state_boundary` must have the four-space indentation shown beneath `RestoreContractTests` so `python3 -m unittest` discovers both tests. The sandbox runs the backup generator and generated restore under a temporary `HOME`; every external command that could touch the real session is replaced by a command double:

```python
class RestoreContractTests(unittest.TestCase):
    def write_double(self, directory, name, body):
        path = directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def test_generated_restore_cleans_appearance_runtime_in_sandbox(self):
        with tempfile.TemporaryDirectory() as raw:
            sandbox = Path(raw)
            home = sandbox / "home"
            fakebin = sandbox / "bin"
            home.mkdir(); fakebin.mkdir()
            (home / ".zshrc").write_text("baseline\n")

            yorha = home / ".config/yorha"
            yorha.mkdir(parents=True)
            (yorha / "keep.txt").write_text("pre-existing\n")
            agents = home / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            plist = agents / "com.yorha.appearance-watcher.plist"
            original_plist = b"pre-existing plist bytes\n"
            plist.write_bytes(original_plist)

            # The snapshot sees an already-loaded pre-existing job. The fake
            # launchctl mutates this file for bootout/bootstrap state changes.
            job_state = sandbox / "appearance-job-loaded"
            job_state.write_text("loaded\n")
            recorded_wallpaper = sandbox / "recorded.heic"
            recorded_wallpaper.write_bytes(b"baseline wallpaper")
            wallpaper_state = sandbox / "wallpaper-state"
            launchctl_log = sandbox / "launchctl-log"
            env = os.environ.copy()
            env.update({
                "HOME": str(home),
                "PATH": f"{fakebin}:/usr/bin:/bin",
                "YORHA_TEST_RECORDED_WALLPAPER": str(recorded_wallpaper),
                "YORHA_TEST_WALLPAPER_STATE": str(wallpaper_state),
                "YORHA_TEST_LAUNCHCTL_LOG": str(launchctl_log),
                "YORHA_TEST_JOB_STATE": str(job_state),
            })

            self.write_double(fakebin, "osascript", r'''
if [ "$1" = "-e" ]; then
  case "$2" in
    *"get picture of current desktop"*)
      printf '%s\n' "$YORHA_TEST_RECORDED_WALLPAPER" ;;
  esac
elif [ "$1" = "-" ]; then
  printf '%s\n' "$2" > "$YORHA_TEST_WALLPAPER_STATE"
fi
exit 0
''')
            self.write_double(fakebin, "launchctl", r'''
printf '%s\n' "$*" >> "$YORHA_TEST_LAUNCHCTL_LOG"
case "$1:$2" in
  print:*com.yorha.appearance-watcher)
    [ -f "$YORHA_TEST_JOB_STATE" ] ;;
  bootout:*com.yorha.appearance-watcher)
    rm -f "$YORHA_TEST_JOB_STATE" ;;
  bootstrap:*)
    case "$3" in
      *com.yorha.appearance-watcher.plist)
        : > "$YORHA_TEST_JOB_STATE" ;;
    esac ;;
esac
exit 0
''')
            self.write_double(fakebin, "brew", "exit 0\n")
            self.write_double(fakebin, "pkill", "exit 0\n")
            self.write_double(fakebin, "sw_vers", "printf '26.0\\n'\n")
            self.write_double(fakebin, "csrutil", "printf 'System Integrity Protection status: enabled.\\n'\n")

            generated = subprocess.run(
                [str(ROOT / "bin/yorha-backup.sh")], env=env,
                text=True, capture_output=True, check=True)
            snapshot = Path(generated.stdout.strip().splitlines()[-1])
            restore = snapshot / "restore.sh"
            self.assertTrue(restore.is_file())

            # Simulate deployment replacing the original plist while its new
            # job is loaded, then populate every appearance runtime target.
            plist.write_text("deployed YoRHa plist\n")
            job_state.write_text("deployed job loaded\n")
            self.assertNotEqual(plist.read_bytes(), original_plist)
            self.assertTrue(job_state.is_file())
            appearance = yorha / "appearance"
            runtime_paths = [
                appearance / "yorha-system.heic",
                appearance / "yorha-icon-light.png",
                appearance / "yorha-icon-dark.png",
                appearance / "last-successful-mode",
                yorha / "bin/yorha-appearance-watcher",
                yorha / "bin/apply-appearance.sh",
                yorha / "logs/appearance.log",
            ]
            for path in runtime_paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("installed\n")
            (appearance / "apply.lock").mkdir()

            subprocess.run([str(restore)], env=env, check=True,
                           text=True, capture_output=True)

            for path in runtime_paths:
                self.assertFalse(path.exists(), path)
            self.assertFalse((appearance / "apply.lock").exists())
            self.assertTrue((yorha / "keep.txt").is_file())
            self.assertEqual(plist.read_bytes(), original_plist)
            self.assertTrue(job_state.is_file())
            calls = launchctl_log.read_text().splitlines()
            label = "com.yorha.appearance-watcher"
            self.assertTrue(any("bootout" in call and label in call for call in calls))
            self.assertTrue(any("bootstrap" in call and str(plist) in call for call in calls))
            self.assertEqual(wallpaper_state.read_text().strip(), str(recorded_wallpaper))

    def test_docs_state_boundary(self):
        readme = (ROOT / "README.md").read_text().lower()
        decisions = (ROOT / "docs/DECISIONS.md").read_text().lower()
        self.assertIn("automatic appearance", readme)
        self.assertIn("ghostty remains permanently dark", readme)
        self.assertIn("appearance-watcher", decisions)
        self.assertIn("prefers-color-scheme", decisions)
```

This test must never execute the generated restore with the real `HOME`, `launchctl`, `osascript`, `brew`, or `pkill`. The pre-existing `~/.config/yorha/keep.txt`, byte-exact original plist, and loaded-job-state assertions prevent an implementation from passing by recursively deleting the broad parent, merely retaining the deployed plist, or failing to re-bootstrap the prior job.

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest tests.test_deployment_contract -v`

- [ ] **Step 3: Snapshot and restore the prior watcher job safely**

Before emitting `restore.sh`, capture both the original plist bytes and the GUI-domain loaded state:

```bash
APPEARANCE_LABEL=com.yorha.appearance-watcher
APPEARANCE_PLIST="$HOME/Library/LaunchAgents/$APPEARANCE_LABEL.plist"
if [ -f "$APPEARANCE_PLIST" ]; then
  cp "$APPEARANCE_PLIST" "$DEST/appearance-watcher.plist.original"
fi
if launchctl print "gui/$(id -u)/$APPEARANCE_LABEL" >/dev/null 2>&1; then
  printf 'loaded\n' > "$DEST/appearance-watcher.loaded-state"
else
  printf 'unloaded\n' > "$DEST/appearance-watcher.loaded-state"
fi
```

Before the generated restore script's path-reversion loop, boot out the deployed job and remove only the appearance runtime targets. Then atomically restore the original plist bytes when the snapshot contains them and re-bootstrap that plist only when the recorded state was `loaded`:

```bash
LABEL=com.yorha.appearance-watcher
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$HOME/.config/yorha/bin/yorha-appearance-watcher"
rm -f "$HOME/.config/yorha/bin/apply-appearance.sh"
rm -f "$HOME/.config/yorha/logs/appearance.log"
rm -rf "$HOME/.config/yorha/appearance"

if [ -f "$HERE/appearance-watcher.plist.original" ]; then
  PLIST_TMP="$PLIST.restore.$$"
  cp "$HERE/appearance-watcher.plist.original" "$PLIST_TMP"
  mv "$PLIST_TMP" "$PLIST"
  if grep -qxF loaded "$HERE/appearance-watcher.loaded-state" 2>/dev/null; then
    launchctl bootstrap "gui/$(id -u)" "$PLIST" \
      || echo "warning: could not restore pre-existing $LABEL job" >&2
  fi
else
  rm -f "$PLIST"
fi
```

Do not infer prior state from the post-deployment plist or from `launchagents.txt`: only the copied `.original` file and `appearance-watcher.loaded-state` are authoritative. Do not broaden the recursive target. An originally present-but-unloaded plist is restored without bootstrapping; an originally absent plist is removed.

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
```

- [ ] **Step 7: Deploy, verify one HEIC assignment, and exercise SketchyBar modes**

```bash
bash bin/deploy.sh
VERIFY_DIR="$(cat /tmp/yorha-appearance-verify-dir)"
APPLY="$HOME/.config/yorha/bin/apply-appearance.sh"
RUNTIME_HEIC="$HOME/.config/yorha/appearance/yorha-system.heic"
swift bin/yorha-system-wallpaper.swift --inspect "$RUNTIME_HEIC"

capture_wallpaper_paths() {
  osascript <<'AS'
tell application "System Events"
  set wallpaperPaths to {}
  repeat with desktopItem in every desktop
    set desktopPicture to picture of desktopItem
    set end of wallpaperPaths to POSIX path of (POSIX file desktopPicture as alias)
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return wallpaperPaths as text
AS
}

assert_all_desktops_use_runtime_heic() {
  output="$1"
  expected_count="$(osascript -e 'tell application "System Events" to count every desktop')"
  seen=0
  while IFS= read -r wallpaper_path || [ -n "$wallpaper_path" ]; do
    [ -n "$wallpaper_path" ] || { echo "empty desktop wallpaper path" >&2; return 1; }
    [ "$wallpaper_path" = "$RUNTIME_HEIC" ] \
      || { echo "unexpected wallpaper: $wallpaper_path" >&2; return 1; }
    seen=$((seen + 1))
  done < "$output"
  [ "$seen" -gt 0 ] && [ "$seen" -eq "$expected_count" ]
}

wait_for_all_desktops_to_use_runtime_heic() {
  output="$1"
  pending="${output}.pending"
  attempt=1
  while [ "$attempt" -le 40 ]; do
    if capture_wallpaper_paths > "$pending" 2>/dev/null \
        && assert_all_desktops_use_runtime_heic "$pending" >/dev/null 2>&1; then
      mv "$pending" "$output"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.25
  done
  echo "timed out waiting for every desktop to adopt $RUNTIME_HEIC" >&2
  echo "desktop count: $(osascript -e 'tell application \"System Events\" to count every desktop')" >&2
  echo "last reported wallpaper paths:" >&2
  cat "$pending" >&2 2>/dev/null || true
  return 1
}

assert_sketchybar_field() {
  item="$1"; field="$2"; expected="$3"
  sketchybar --query "$item" | python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
actual, expected = str(value), sys.argv[2]
assert actual.lower() == expected.lower(), f"{sys.argv[1]}: {actual!r} != {expected!r}"
' "$field" "$expected"
}

wait_for_all_desktops_to_use_runtime_heic "$VERIFY_DIR/wallpaper.deployed"

REAL_SKETCHYBAR="$(command -v sketchybar)"
PROBE="$VERIFY_DIR/sketchybar-probe"
PROBE_LOG="$VERIFY_DIR/sketchybar-probe.log"
cat > "$PROBE" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$YORHA_PROBE_LOG"
exec "$YORHA_REAL_SKETCHYBAR" "$@"
SH
chmod +x "$PROBE"
export YORHA_REAL_SKETCHYBAR="$REAL_SKETCHYBAR" YORHA_PROBE_LOG="$PROBE_LOG"

YORHA_SKETCHYBAR_BIN="$PROBE" "$APPLY" light --force
test "$(cat "$HOME/.config/yorha/appearance/last-successful-mode")" = light
assert_sketchybar_field clock label.color 0xff4a4741
assert_sketchybar_field date label.color 0xff4a4741
assert_sketchybar_field yorha label.color 0xff4a4741
assert_sketchybar_field yorha_icon geometry.background.image.value \
  "$HOME/.config/yorha/appearance/yorha-icon-light.png"

before_noop="$(wc -l < "$PROBE_LOG" | tr -d ' ')"
YORHA_SKETCHYBAR_BIN="$PROBE" "$APPLY" light
test "$(wc -l < "$PROBE_LOG" | tr -d ' ')" -eq "$before_noop"
YORHA_SKETCHYBAR_BIN="$PROBE" "$APPLY" light --force
test "$(wc -l < "$PROBE_LOG" | tr -d ' ')" -eq "$((before_noop + 1))"

YORHA_SKETCHYBAR_BIN="$PROBE" "$APPLY" dark --force
test "$(cat "$HOME/.config/yorha/appearance/last-successful-mode")" = dark
assert_sketchybar_field clock label.color 0xffd8d4c4
assert_sketchybar_field date label.color 0xffd8d4c4
assert_sketchybar_field yorha label.color 0xffbc9a5a
assert_sketchybar_field yorha_icon geometry.background.image.value \
  "$HOME/.config/yorha/appearance/yorha-icon-dark.png"

capture_wallpaper_paths > "$VERIFY_DIR/wallpaper.after-forced-modes"
assert_all_desktops_use_runtime_heic "$VERIFY_DIR/wallpaper.after-forced-modes"
diff -u "$VERIFY_DIR/wallpaper.deployed" "$VERIFY_DIR/wallpaper.after-forced-modes"
YORHA_SKETCHYBAR_BIN="$PROBE" "$APPLY" "$(cat "$VERIFY_DIR/effective-mode")" --force
```

`capture_wallpaper_paths` emits one POSIX path per desktop. System Events returns
the `picture` property as POSIX text on this host, so the explicit `POSIX file`
coercion is required before converting it to an alias. The bounded poll gives the
wallpaper service up to ten seconds to expose the newly assigned path before the
invariance baseline is established; timeout output includes the expected desktop
count and last reported paths. The assertion rejects empty entries, any repository
or stale path, zero desktops, and a line count that differs from `System Events`'
desktop count. The probe executes the real SketchyBar command while recording
coordinator invocations, so the unchanged call count proves same-mode no-op and the
increment proves `--force` bypasses it. Do not change the macOS appearance setting
or attempt to force a HEIC frame.

- [ ] **Step 8: Verify crash recovery and Ghostty isolation**

```bash
UID_NOW="$(id -u)"
launchctl print "gui/$UID_NOW/com.yorha.appearance-watcher"
launchctl kill SIGTERM "gui/$UID_NOW/com.yorha.appearance-watcher"
sleep 2
launchctl print "gui/$UID_NOW/com.yorha.appearance-watcher"
VERIFY_DIR="$(cat /tmp/yorha-appearance-verify-dir)"
capture_wallpaper_paths > "$VERIFY_DIR/wallpaper.after-watcher-restart"
assert_all_desktops_use_runtime_heic "$VERIFY_DIR/wallpaper.after-watcher-restart"
diff -u "$VERIFY_DIR/wallpaper.deployed" "$VERIFY_DIR/wallpaper.after-watcher-restart"
shasum -a 256 config/ghostty/config config/ghostty/config.ghostty \
  "$HOME/.config/ghostty/config" "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
  > "$VERIFY_DIR/ghostty.after"
diff -u "$VERIFY_DIR/ghostty.before" "$VERIFY_DIR/ghostty.after"
```

Expected: launchd restarts the watcher, every enumerated desktop still has the runtime HEIC path, both diffs are empty, and the Ghostty checksum diff is empty. Run Steps 7 and 8 in the same verification shell so the exact `capture_wallpaper_paths` and `assert_all_desktops_use_runtime_heic` functions remain defined.

- [ ] **Step 9: Commit and final check**

```bash
git add bin/yorha-backup.sh docs/DECISIONS.md tests/test_deployment_contract.py
git add -p README.md
git commit -m "docs: document and restore appearance switching"
git status --short
git log --oneline f9fd880..HEAD
git diff --check f9fd880..HEAD
```

Expected: only intentionally unabsorbed user changes remain; every commit after the recorded feature base is shown without relying on a fixed count; no whitespace errors.

#### Task 6 review correction (2026-08-06)

This correction supersedes the original broad restore snippets above:

- `preexisting.txt` must never contain the parent `.config/yorha`. Record only
  installation-owned files under that parent (the five shell files, two
  non-appearance runtime executables, and named cache/log files). The appearance
  watcher binary, coordinator, appearance directory, and appearance log remain
  the narrow explicit cleanup targets. User-created siblings such as `secrets/`,
  `BACKUP_PATH`, `watchdog.off`, and unrelated files must survive.
- Validate `appearance-watcher.loaded-state` as exactly `loaded` or `unloaded`
  before changing live state. When prior plist bytes exist, copy them completely
  to a same-directory `*.restore.*` temporary before any mutation. Clean that
  temporary on `EXIT`, `HUP`, `INT`, and `TERM`; boot out the deployed job, remove
  only owned runtime, then move the staged file into place. Copy, move, bootstrap,
  and state failures exit nonzero and must never print `Restore complete.`
- Sandbox coverage must exercise present+loaded, present+unloaded, absent,
  missing/corrupt state, partial copy failure, move failure, bootstrap failure,
  and signal cleanup. The absent case creates an unrelated YoRHa sibling only
  after the snapshot and proves it survives.
- Never execute the full configured restore against the user's real `HOME` during
  verification. Migrate the immutable pre-install payload into a separate derived
  appearance-aware baseline, validate the README command against a copy under a
  temporary `HOME`, and atomically repoint `BACKUP_PATH`; retain the original
  baseline and record recovery to its old pointer value.
