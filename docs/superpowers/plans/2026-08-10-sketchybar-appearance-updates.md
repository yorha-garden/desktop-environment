# SketchyBar Appearance Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the YoRHa SketchyBar colors and crest follow macOS Light/Dark appearance automatically without reloading the bar.

**Architecture:** Deployment resolves SketchyBar to an absolute executable path while the Homebrew-aware interactive environment is available, validates that path, and stores it in the appearance LaunchAgent's `YORHA_SKETCHYBAR_BIN` environment variable. The existing watcher and coordinator remain unchanged: the watcher resolves appearance, and the coordinator performs one in-place SketchyBar transaction and records the mode only after success.

**Tech Stack:** macOS 26, launchd property lists, Bash 3.2, Swift/AppKit appearance watcher, SketchyBar CLI, Python 3 `unittest` and `plistlib`.

## Global Constraints

- SketchyBar appearance changes update live fields and never call `sketchybar --reload`.
- Preserve the existing light palette (`0xff4a4741`) and dark palette (`0xffd8d4c4` text and `0xffbc9a5a` wordmark).
- Preserve the light and dark crest paths under `~/.config/yorha/appearance/`.
- Do not change wallpaper assignment or dynamic HEIC behavior.
- Do not reload or refresh Übersicht; it remains driven by `prefers-color-scheme`.
- Do not read, write, reload, or signal Ghostty; it remains permanently dark.
- Add no package dependency and do not hard-code `/opt/homebrew` or `/usr/local`.
- Preserve the coordinator transaction: `last-successful-mode` advances only after SketchyBar succeeds.
- Preserve user-owned uncommitted changes in `README.md`, `bin/deploy.sh`, `config/sketchybar/sketchybarrc`, `widgets/yorha/hud.jsx`, `widgets/yorha/pod.jsx`, and `launchd/com.yorha.sketchybar-minute.plist`.
- Do not modify `config/sketchybar/sketchybarrc` for this fix.

## File Map

**Modify:**

- `launchd/com.yorha.appearance-watcher.plist` — declare the SketchyBar executable environment contract.
- `tests/test_appearance_watcher.py` — verify the source LaunchAgent contract.
- `bin/deploy.sh` — resolve, validate, and inject the absolute executable path.
- `tests/test_deployment_contract.py` — reproduce the restricted launchd environment and verify safe plist rendering.

No runtime coordinator or watcher source change is required because `bin/apply-appearance.sh` already consumes `YORHA_SKETCHYBAR_BIN` and performs the required live update transaction.

---

### Task 1: Declare the LaunchAgent executable contract

**Files:**

- Modify: `launchd/com.yorha.appearance-watcher.plist:13-19`
- Test: `tests/test_appearance_watcher.py:218-241`

**Interfaces:**

- Consumes: deployment replacement value for `SKETCHYBAR_PATH`.
- Produces: LaunchAgent environment key `YORHA_SKETCHYBAR_BIN: String`.

- [ ] **Step 1: Add the failing plist contract assertion**

Extend `AppearanceWatcherIntegrationTests.test_launch_agent_plist_has_the_watcher_contract` immediately after the `ProgramArguments` assertion:

```python
self.assertEqual(
    values["EnvironmentVariables"],
    {"YORHA_SKETCHYBAR_BIN": "SKETCHYBAR_PATH"},
)
```

- [ ] **Step 2: Run the focused test and confirm the missing key**

Run:

```bash
python3 -m unittest \
  tests.test_appearance_watcher.AppearanceWatcherIntegrationTests.test_launch_agent_plist_has_the_watcher_contract \
  -v
```

Expected: FAIL with `KeyError: 'EnvironmentVariables'`.

- [ ] **Step 3: Add the environment dictionary to the plist template**

Insert this block after `ProgramArguments` and before `RunAtLoad`:

```xml
  <key>EnvironmentVariables</key>
  <dict>
    <key>YORHA_SKETCHYBAR_BIN</key>
    <string>SKETCHYBAR_PATH</string>
  </dict>
```

- [ ] **Step 4: Validate the plist and rerun the focused test**

Run:

```bash
plutil -lint launchd/com.yorha.appearance-watcher.plist
python3 -m unittest \
  tests.test_appearance_watcher.AppearanceWatcherIntegrationTests.test_launch_agent_plist_has_the_watcher_contract \
  -v
```

Expected: plist lint succeeds and the test passes.

- [ ] **Step 5: Commit the LaunchAgent contract**

```bash
git add launchd/com.yorha.appearance-watcher.plist tests/test_appearance_watcher.py
git diff --cached --check
git commit -m "fix: declare SketchyBar runtime path"
```

---

### Task 2: Render the absolute SketchyBar path safely

**Files:**

- Modify: `bin/deploy.sh:59-222`
- Test: `tests/test_deployment_contract.py:59-102`
- Test: `tests/test_deployment_contract.py:161-237`
- Test: `tests/test_deployment_contract.py:467-487`

**Interfaces:**

- Consumes: optional existing shell variable `SB_BIN` and fallback `command -v sketchybar`.
- Produces: validated absolute executable `APPEARANCE_SKETCHYBAR_BIN` and a rendered plist with `EnvironmentVariables.YORHA_SKETCHYBAR_BIN`.
- Preserves: direct deployment call `apply-appearance.sh light|dark --force`, now with the same absolute executable in its environment.

- [ ] **Step 1: Add failing static deployment assertions**

Extend `DeploymentContractTests.test_plist_rendering_is_argv_safe_linted_and_ordered` with:

```python
self.assertIn(
    '-replace EnvironmentVariables.YORHA_SKETCHYBAR_BIN '
    '-string "$APPEARANCE_SKETCHYBAR_BIN"',
    block,
)
self.assertIn(
    'YORHA_SKETCHYBAR_BIN="$APPEARANCE_SKETCHYBAR_BIN"',
    block,
)
```

Extend `DeploymentContractTests.test_watcher_plist_and_coordinator_install_contract` with:

```python
self.assertIn('APPEARANCE_SKETCHYBAR_BIN="${SB_BIN:-}"', block)
self.assertIn('command -v sketchybar', block)
self.assertIn('[ ! -x "$APPEARANCE_SKETCHYBAR_BIN" ]', block)
```

- [ ] **Step 2: Make the deployment sandbox provide a path containing spaces**

In `DeploymentSandboxTests.setUp`, create an executable double before building `self.script`:

```python
self.sketchybar = self.base / "SketchyBar executable & live"
self.sketchybar.write_text(
    "#!/bin/bash\n"
    "printf '%s\\n' \"$*\" >> \"$YORHA_TEST_SKETCHYBAR_LOG\"\n"
)
self.sketchybar.chmod(0o755)
self.sketchybar_log = self.base / "sketchybar.log"
```

Add the externally established deployment value to the extracted-block preamble:

```python
'#!/usr/bin/env bash\nset -euo pipefail\nREPO="$TEST_REPO"\n'
'SB_BIN="$YORHA_TEST_SKETCHYBAR_BIN"\n'
'say() { printf \'  %s\\n\' "$*"; }\n' + block
```

Add these variables to `self.env`:

```python
"YORHA_TEST_SKETCHYBAR_BIN": str(self.sketchybar),
"YORHA_TEST_SKETCHYBAR_LOG": str(self.sketchybar_log),
```

- [ ] **Step 3: Add failing rendered-plist and missing-dependency assertions**

In `test_special_home_renders_exact_parseable_runtime_plist`, add:

```python
self.assertEqual(
    data["EnvironmentVariables"],
    {"YORHA_SKETCHYBAR_BIN": str(self.sketchybar)},
)
self.assertTrue(self.sketchybar_log.is_file())
arguments = self.sketchybar_log.read_text().splitlines()
self.assertTrue(any("--set clock" in line for line in arguments), arguments)
self.assertFalse(any("--reload" in line for line in arguments), arguments)
```

Add this test to `DeploymentSandboxTests`:

```python
def test_missing_sketchybar_stops_before_appearance_runtime_mutation(self):
    env = self.env.copy()
    env["YORHA_TEST_SKETCHYBAR_BIN"] = ""
    result = subprocess.run(
        ["/bin/bash", str(self.script)], cwd=ROOT, env=env,
        text=True, capture_output=True, timeout=15,
    )
    self.assertEqual(result.returncode, 69)
    self.assertIn("missing SketchyBar executable", result.stderr)
    self.assertFalse((self.home / ".config/yorha/appearance").exists())
```

- [ ] **Step 4: Run the deployment tests and confirm they fail for the missing path propagation**

Run:

```bash
python3 -m unittest \
  tests.test_deployment_contract.DeploymentContractTests.test_plist_rendering_is_argv_safe_linted_and_ordered \
  tests.test_deployment_contract.DeploymentContractTests.test_watcher_plist_and_coordinator_install_contract \
  tests.test_deployment_contract.DeploymentSandboxTests.test_special_home_renders_exact_parseable_runtime_plist \
  tests.test_deployment_contract.DeploymentSandboxTests.test_missing_sketchybar_stops_before_appearance_runtime_mutation \
  -v
```

Expected: FAIL because deployment neither validates nor writes the executable environment key.

- [ ] **Step 5: Resolve and validate the executable before creating runtime directories**

Immediately after `# --- appearance runtime BEGIN`, add:

```bash
APPEARANCE_SKETCHYBAR_BIN="${SB_BIN:-}"
if [ -z "$APPEARANCE_SKETCHYBAR_BIN" ]; then
  APPEARANCE_SKETCHYBAR_BIN="$(command -v sketchybar || true)"
fi
case "$APPEARANCE_SKETCHYBAR_BIN" in
  /*) ;;
  *)
    echo "missing SketchyBar executable; install SketchyBar and rerun deploy" >&2
    exit 69
    ;;
esac
if [ ! -x "$APPEARANCE_SKETCHYBAR_BIN" ]; then
  echo "missing SketchyBar executable: $APPEARANCE_SKETCHYBAR_BIN" >&2
  exit 69
fi
```

This uses the current worktree's existing `SB_BIN` when present, but remains self-contained on a clean checkout where the user-owned minute-boundary block is absent.

- [ ] **Step 6: Render the environment value with `plutil`**

Add this command after the two `ProgramArguments` insertions and before log-path replacements:

```bash
"$PLUTIL" -replace EnvironmentVariables.YORHA_SKETCHYBAR_BIN \
  -string "$APPEARANCE_SKETCHYBAR_BIN" -- "$PLIST_TMP"
```

Do not use `sed` for the path: the executable path is external data and may contain spaces or delimiter characters.

- [ ] **Step 7: Use the same absolute path for deployment's immediate live update**

Replace the forced coordinator call with:

```bash
YORHA_SKETCHYBAR_BIN="$APPEARANCE_SKETCHYBAR_BIN" \
  "$RUNTIME_COORDINATOR" "$MODE" --force \
  || say "appearance -> watcher installed; SketchyBar update will retry"
```

- [ ] **Step 8: Run focused and full regression tests**

Run:

```bash
bash -n bin/deploy.sh bin/apply-appearance.sh
plutil -lint launchd/com.yorha.appearance-watcher.plist
python3 -m unittest tests.test_deployment_contract -v
python3 -m unittest tests.test_apply_appearance tests.test_appearance_watcher -v
```

Expected: all commands pass. The deployment sandbox's path contains spaces, its forced coordinator call reaches the double, and no invocation contains `--reload`.

- [ ] **Step 9: Stage only feature-owned hunks and commit**

Because `bin/deploy.sh` already contains user-owned changes, inspect and stage it interactively:

```bash
git diff -- bin/deploy.sh tests/test_deployment_contract.py
git add -p bin/deploy.sh
git add tests/test_deployment_contract.py
git diff --cached --check
git diff --cached -- bin/deploy.sh tests/test_deployment_contract.py
git commit -m "fix: propagate SketchyBar path to appearance watcher"
```

The cached `bin/deploy.sh` diff must contain only the appearance-runtime path resolution, plist rendering, and forced-call environment changes. It must not contain the user-owned minute-boundary LaunchAgent block.

---

### Task 3: Verify and activate the fix

**Files:**

- Verify only; no source files are modified.
- Install target: `~/Library/LaunchAgents/com.yorha.appearance-watcher.plist`.

**Interfaces:**

- Consumes: the tested LaunchAgent template, installed watcher/coordinator paths, and `command -v sketchybar`.
- Produces: a re-bootstrapped appearance watcher whose child receives an absolute SketchyBar executable.

Run Steps 2 through 5 in the same shell session so the recorded checksum and wallpaper variables remain available for the final comparisons.

- [ ] **Step 1: Run the complete repository test suite**

Run:

```bash
python3 -m unittest discover -s tests -v
bash -n bin/*.sh config/sketchybar/sketchybarrc
swiftc -typecheck bin/appearance-watcher.swift
plutil -lint launchd/*.plist
git diff --check
```

Expected: every test and syntax check passes. `git diff --check` reports no whitespace errors.

- [ ] **Step 2: Record untouched-surface state**

Run:

```bash
GHOSTTY_XDG_BEFORE="$(shasum -a 256 "$HOME/.config/ghostty/config")"
GHOSTTY_NATIVE_BEFORE="$(shasum -a 256 "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty")"
WALLPAPER_BEFORE="$(osascript -e 'tell application "System Events" to get picture of current desktop')"
```

Expected: both Ghostty checksums and the current HEIC path are captured without changing them.

- [ ] **Step 3: Install only the appearance plist change and restart its watcher**

Run:

```bash
APPEARANCE_SKETCHYBAR_BIN="$(command -v sketchybar)"
APPEARANCE_PLIST="$HOME/Library/LaunchAgents/com.yorha.appearance-watcher.plist"
APPEARANCE_PLIST_TMP="$APPEARANCE_PLIST.tmp.$$"
cp launchd/com.yorha.appearance-watcher.plist "$APPEARANCE_PLIST_TMP"
plutil -replace ProgramArguments -array -- "$APPEARANCE_PLIST_TMP"
plutil -insert ProgramArguments.0 -string \
  "$HOME/.config/yorha/bin/yorha-appearance-watcher" -- "$APPEARANCE_PLIST_TMP"
plutil -insert ProgramArguments.1 -string \
  "$HOME/.config/yorha/bin/apply-appearance.sh" -- "$APPEARANCE_PLIST_TMP"
plutil -replace EnvironmentVariables.YORHA_SKETCHYBAR_BIN \
  -string "$APPEARANCE_SKETCHYBAR_BIN" -- "$APPEARANCE_PLIST_TMP"
plutil -replace StandardOutPath -string \
  "$HOME/.config/yorha/logs/appearance.log" -- "$APPEARANCE_PLIST_TMP"
plutil -replace StandardErrorPath -string \
  "$HOME/.config/yorha/logs/appearance.log" -- "$APPEARANCE_PLIST_TMP"
plutil -lint "$APPEARANCE_PLIST_TMP"
mv "$APPEARANCE_PLIST_TMP" "$APPEARANCE_PLIST"
launchctl bootout "gui/$(id -u)/com.yorha.appearance-watcher" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"
```

Expected: the plist lints and the watcher bootstraps successfully. This targeted activation does not run the broader deployment or copy Ghostty, wallpaper, widget, or SketchyBar configuration files.

- [ ] **Step 4: Verify both live palettes and restore the effective mode**

Run:

```bash
APPLY="$HOME/.config/yorha/bin/apply-appearance.sh"
YORHA_SKETCHYBAR_BIN="$APPEARANCE_SKETCHYBAR_BIN" "$APPLY" light --force
test "$(sketchybar --query clock | jq -r '.label.color')" = "0xff4a4741"
test "$(sketchybar --query date | jq -r '.label.color')" = "0xff4a4741"
test "$(sketchybar --query yorha | jq -r '.label.color')" = "0xff4a4741"
test "$(sketchybar --query yorha_icon | jq -r '.geometry.background.image.value')" \
  = "$HOME/.config/yorha/appearance/yorha-icon-light.png"

YORHA_SKETCHYBAR_BIN="$APPEARANCE_SKETCHYBAR_BIN" "$APPLY" dark --force
test "$(sketchybar --query clock | jq -r '.label.color')" = "0xffd8d4c4"
test "$(sketchybar --query date | jq -r '.label.color')" = "0xffd8d4c4"
test "$(sketchybar --query yorha | jq -r '.label.color')" = "0xffbc9a5a"
test "$(sketchybar --query yorha_icon | jq -r '.geometry.background.image.value')" \
  = "$HOME/.config/yorha/appearance/yorha-icon-dark.png"

if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = Dark ]; then
  EFFECTIVE_MODE=dark
else
  EFFECTIVE_MODE=light
fi
YORHA_SKETCHYBAR_BIN="$APPEARANCE_SKETCHYBAR_BIN" \
  "$APPLY" "$EFFECTIVE_MODE" --force
test "$(tr -d '\n' < "$HOME/.config/yorha/appearance/last-successful-mode")" \
  = "$EFFECTIVE_MODE"
```

Expected: all assertions pass and the bar ends in the current macOS appearance. The bar is never reloaded.

- [ ] **Step 5: Verify the LaunchAgent and untouched surfaces**

Run:

```bash
test "$(launchctl print "gui/$(id -u)/com.yorha.appearance-watcher" \
  | awk '/state =/{print $3; exit}')" = running
test "$(plutil -extract EnvironmentVariables.YORHA_SKETCHYBAR_BIN raw \
  "$HOME/Library/LaunchAgents/com.yorha.appearance-watcher.plist")" \
  = "$APPEARANCE_SKETCHYBAR_BIN"
test "$(shasum -a 256 "$HOME/.config/ghostty/config")" = "$GHOSTTY_XDG_BEFORE"
test "$(shasum -a 256 "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty")" \
  = "$GHOSTTY_NATIVE_BEFORE"
test "$(osascript -e 'tell application "System Events" to get picture of current desktop')" \
  = "$WALLPAPER_BEFORE"
```

Expected: the watcher is running with the absolute executable value, both Ghostty files are byte-for-byte unchanged, and the wallpaper path is unchanged.

- [ ] **Step 6: Inspect final repository state**

Run:

```bash
git log --oneline -4
git status --short
git diff --check
```

Expected: the two implementation commits are present, user-owned uncommitted files remain present and unmodified outside the intentionally merged `bin/deploy.sh` hunk, and there are no whitespace errors.
