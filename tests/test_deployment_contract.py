import os, plistlib, re, signal, subprocess, tempfile, time, unittest
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
        self.assertIn(
            'YORHA_APPEARANCE_INSTALL_TEMPORARY='
            '"${YORHA_APPEARANCE_INSTALL_DESTINATION}.tmp.$$"', body)
        self.assertLess(
            body.index('cp "$YORHA_APPEARANCE_INSTALL_SOURCE" '
                       '"$YORHA_APPEARANCE_INSTALL_TEMPORARY"'),
            body.index('mv "$YORHA_APPEARANCE_INSTALL_TEMPORARY" '
                       '"$YORHA_APPEARANCE_INSTALL_DESTINATION"'))
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
        helper = re.search(r"install_atomic\(\) \{(?P<body>.*?)\n\}", block, re.S)
        self.assertIsNotNone(helper)
        body = helper.group("body")
        self.assertLess(body.index('chmod +x "$YORHA_APPEARANCE_INSTALL_TEMPORARY"'),
                        body.index('mv "$YORHA_APPEARANCE_INSTALL_TEMPORARY" '
                                   '"$YORHA_APPEARANCE_INSTALL_DESTINATION"'))
        self.assertIn('install_atomic "$REPO/bin/apply-appearance.sh" '
                      '"$RUNTIME_COORDINATOR" executable', block)
        self.assertRegex(block, r'swiftc -O .*appearance-watcher\.swift" -o "\$WATCHER_TMP"')
        self.assertLess(block.index('swiftc -O '),
                        block.index('mv "$WATCHER_TMP" "$RUNTIME_WATCHER"'))
        cleanup = re.search(r"cleanup_appearance_temps\(\) \{(?P<body>.*?)\n\}", block, re.S)
        self.assertIsNotNone(cleanup)
        for pending in ("INSTALL_TMP", "WATCHER_TMP", "PLIST_TMP"):
            self.assertIn(pending, cleanup.group("body"))
        for event in ("EXIT", "HUP", "INT", "TERM"):
            self.assertRegex(block, rf"trap [^\n]+\b{event}\b")
        self.assertEqual(block.count('launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"'), 1)
        self.assertEqual(block.count('"$RUNTIME_COORDINATOR" "$MODE" --force'), 1)
        self.assertIn('APPEARANCE_SKETCHYBAR_BIN="${SB_BIN:-}"', block)
        self.assertIn('command -v sketchybar', block)
        self.assertIn('[ ! -x "$APPEARANCE_SKETCHYBAR_BIN" ]', block)

    def test_plist_rendering_is_argv_safe_linted_and_ordered(self):
        block = self.appearance_block()
        self.assertNotRegex(block, r"\bsed\b")
        self.assertIn('-replace ProgramArguments -array', block)
        for index in (0, 1):
            self.assertIn(f'-insert ProgramArguments.{index} -string', block)
        self.assertIn(
            '-replace EnvironmentVariables.YORHA_SKETCHYBAR_BIN '
            '-string "$APPEARANCE_SKETCHYBAR_BIN"',
            block,
        )
        self.assertIn(
            'YORHA_SKETCHYBAR_BIN="$APPEARANCE_SKETCHYBAR_BIN"',
            block,
        )
        for key in ("StandardOutPath", "StandardErrorPath"):
            self.assertIn(f'-replace {key} -string', block)
        lint = block.index(' -lint "$PLIST_TMP"')
        plist_move = block.index('mv "$PLIST_TMP" "$APPEARANCE_PLIST"')
        assignment = block.index('osascript - "$RUNTIME_WALLPAPER"')
        bootout = block.index('launchctl bootout "gui/$(id -u)/com.yorha.appearance-watcher"')
        bootstrap = block.index('launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"')
        coordinator = block.index('"$RUNTIME_COORDINATOR" "$MODE" --force')
        self.assertLess(lint, plist_move)
        self.assertLess(assignment, bootstrap)
        self.assertLess(bootout, bootstrap)
        self.assertLess(bootstrap, coordinator)
        self.assertIn("|| say", block[coordinator:block.index("# ---", coordinator)
                                      if "# ---" in block[coordinator:] else len(block)])

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

    def test_committed_feature_agent_scope_matches_tracked_plists_and_docs(self):
        tracked = subprocess.run(
            ["git", "ls-files", "launchd/com.yorha.*.plist"], cwd=ROOT,
            check=True, text=True, capture_output=True,
        ).stdout.splitlines()
        tracked_names = {Path(path).name for path in tracked}
        self.assertEqual(tracked_names, {
            "com.yorha.appearance-watcher.plist",
            "com.yorha.pod-oracle.plist",
            "com.yorha.ubersicht-watchdog.plist",
        })

        deploy_refs = set(re.findall(
            r'\$REPO/launchd/(com\.yorha\.[A-Za-z0-9.-]+\.plist)',
            self.deploy_text(),
        ))
        self.assertEqual(deploy_refs & tracked_names, tracked_names)
        self.assertNotIn(
            "sketchybar-minute",
            (ROOT / "bin/yorha-backup.sh").read_text(),
        )

        committed_docs = {
            path: subprocess.run(
                ["git", "show", f":{path}"], cwd=ROOT,
                check=True, text=True, capture_output=True,
            ).stdout.lower()
            for path in (
                "README.md", "docs/DECISIONS.md",
                "docs/superpowers/plans/2026-08-05-system-appearance-theming.md",
            )
        }
        for path, text in committed_docs.items():
            self.assertIn("three feature-owned", text, path)
            self.assertNotRegex(text, r"four (?:user )?launchagents", path)


class DeploymentSandboxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.home = self.base / "home & pipe| less< dollar$ spaces"
        self.fake_bin = self.base / "fake-bin"
        self.home.mkdir()
        self.fake_bin.mkdir()
        self.sketchybar = self.base / "SketchyBar executable & live"
        self.sketchybar.write_text(
            "#!/bin/bash\n"
            "printf '%s\n' \"$*\" >> \"$YORHA_TEST_SKETCHYBAR_LOG\"\n"
        )
        self.sketchybar.chmod(0o755)
        self.sketchybar_log = self.base / "sketchybar.log"
        self.script = self.base / "appearance-runtime.sh"
        text = (ROOT / "bin/deploy.sh").read_text()
        block = text.split("# --- appearance runtime BEGIN", 1)[1].split(
            "# --- appearance runtime END", 1)[0]
        self.block = block
        self.script.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\nREPO="$TEST_REPO"\n'
            'SB_BIN="$YORHA_TEST_SKETCHYBAR_BIN"\n'
            "say() { printf '  %s\\n' \"$*\"; }\n" + block)
        self.script.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "TEST_REPO": str(ROOT),
            "YORHA_PLUTIL": str(self.fake_bin / "plutil"),
            "YORHA_SIGNAL_READY": str(self.base / "signal-ready"),
            "YORHA_EXTRACT_READY": str(self.base / "extract-ready"),
            "YORHA_RESTORE_READY": str(self.base / "restore-ready"),
            "YORHA_HANDLER_READY": str(self.base / "handler-ready"),
            "YORHA_TRAP_LOG": str(self.base / "trap.log"),
            "YORHA_TEST_SKETCHYBAR_BIN": str(self.sketchybar),
            "YORHA_TEST_SKETCHYBAR_LOG": str(self.sketchybar_log),
            "SB_BIN": str(self.sketchybar),
        })
        self.write_stub("cp", r'''#!/bin/bash
if [ "${YORHA_DEPLOY_FAIL:-}" = cp ] && [[ "$1" == */assets/yorha-system.heic ]]; then
  printf partial > "$2"
  exit 91
fi
exec /bin/cp "$@"
''')
        self.write_stub("chmod", r'''#!/bin/bash
for target in "$@"; do :; done
if [ "${YORHA_DEPLOY_FAIL:-}" = chmod ] && [[ "$target" == */apply-appearance.sh.tmp.* ]]; then
  exit 92
fi
exec /bin/chmod "$@"
''')
        self.write_stub("swift", "#!/bin/bash\nexit 0\n")
        self.write_stub("swiftc", r'''#!/bin/bash
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    output="$1"
  fi
  shift
done
if [ "${YORHA_DEPLOY_FAIL:-}" = compile ]; then
  printf partial > "$output"
  exit 93
fi
if [ "${YORHA_DEPLOY_FAIL:-}" = signal ]; then
  printf partial > "$output"
  : > "$YORHA_SIGNAL_READY"
  while :; do sleep 1; done
fi
printf '#!/bin/bash\nexit 0\n' > "$output"
''')
        self.write_stub("plutil", r'''#!/bin/bash
if [ "${YORHA_DEPLOY_FAIL:-}" = lint ] && [ "$1" = -lint ]; then
  exit 94
fi
exec /usr/bin/plutil "$@"
''')
        self.write_stub("launchctl", "#!/bin/bash\nexit 0\n")
        self.write_stub("osascript", "#!/bin/bash\nexit 0\n")

    def tearDown(self):
        self.temporary.cleanup()

    def write_stub(self, name, contents):
        path = self.fake_bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def run_block(self, failure=None):
        env = self.env.copy()
        if failure:
            env["YORHA_DEPLOY_FAIL"] = failure
        return subprocess.run(["/bin/bash", str(self.script)], cwd=ROOT, env=env,
                              text=True, capture_output=True, timeout=15)

    def pending_temps(self):
        return list(self.home.rglob("*.tmp.*"))

    def make_trap_script(self):
        path = self.base / "appearance-runtime-with-traps.sh"
        path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
REPO="$TEST_REPO"
say() { printf '  %s\n' "$*"; }
handler=outer-handler
trap 'printf "prior-exit:%s:%s\n" "$?" "$handler" >> "$YORHA_TRAP_LOG"' EXIT
trap 'printf "prior-hup:%s:%s\n" "$?" "$handler" >> "$YORHA_TRAP_LOG"' HUP
trap 'printf "prior-int:%s:%s\n" "$?" "$handler" >> "$YORHA_TRAP_LOG"' INT
trap 'printf "prior-term:%s:%s\n" "$?" "$handler" >> "$YORHA_TRAP_LOG"' TERM
EXPECTED_EXIT_TRAP="$(trap -p EXIT)"
EXPECTED_HUP_TRAP="$(trap -p HUP)"
EXPECTED_INT_TRAP="$(trap -p INT)"
EXPECTED_TERM_TRAP="$(trap -p TERM)"
''' + self.block + r'''
[ "$(trap -p EXIT)" = "$EXPECTED_EXIT_TRAP" ] || exit 81
[ "$(trap -p HUP)" = "$EXPECTED_HUP_TRAP" ] || exit 82
[ "$(trap -p INT)" = "$EXPECTED_INT_TRAP" ] || exit 83
[ "$(trap -p TERM)" = "$EXPECTED_TERM_TRAP" ] || exit 84
printf 'after-block\n' >> "$YORHA_TRAP_LOG"
''')
        path.chmod(0o755)
        return path

    def make_ignored_signal_script(self):
        path = self.base / "appearance-runtime-ignore-term.sh"
        path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
REPO="$TEST_REPO"
say() { printf '  %s\n' "$*"; }
handler=outer-handler
trap 'printf "prior-exit:%s:%s\n" "$?" "$handler" >> "$YORHA_TRAP_LOG"' EXIT
trap '' TERM
''' + self.block + r'''
printf 'after-block\n' >> "$YORHA_TRAP_LOG"
''')
        path.chmod(0o755)
        return path

    def make_helper_scope_trap_script(self):
        path = self.base / "appearance-runtime-helper-scope.sh"
        path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
REPO="$TEST_REPO"
say() { printf '  %s\n' "$*"; }
definition=outer-definition
captured=outer-captured
signal_name=outer-signal-name
pending=outer-pending
source=outer-source
destination=outer-destination
temporary=outer-temporary
yorha_appearance_pending=outer-yorha-pending
yorha_appearance_source=outer-yorha-source
yorha_appearance_destination=outer-yorha-destination
yorha_appearance_temporary=outer-yorha-temporary
trap 'printf "prior-exit:%s:%s:%s:%s:%s:%s:%s:%s\n" "$?" "$definition" "$captured" "$signal_name" "$yorha_appearance_pending" "$yorha_appearance_source" "$yorha_appearance_destination" "$yorha_appearance_temporary" >> "$YORHA_TRAP_LOG"' EXIT
''' + self.block)
        path.chmod(0o755)
        return path

    def make_extract_scope_signal_script(self):
        path = self.base / "appearance-runtime-extract-scope-signal.sh"
        path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
REPO="$TEST_REPO"
say() { printf '  %s\n' "$*"; }
definition=outer-definition
captured=outer-captured
signal_name=outer-signal-name
yorha_appearance_pending=outer-yorha-pending
yorha_appearance_source=outer-yorha-source
yorha_appearance_destination=outer-yorha-destination
yorha_appearance_temporary=outer-yorha-temporary
trap 'printf "prior-term:%s:%s:%s:%s:%s:%s:%s\n" "$definition" "$captured" "$signal_name" "$yorha_appearance_pending" "$yorha_appearance_source" "$yorha_appearance_destination" "$yorha_appearance_temporary" >> "$YORHA_TRAP_LOG"; builtin trap - TERM; builtin kill -s TERM "$$"' TERM
''' + self.block + r'''
YORHA_TEST_NONEMPTY_EVAL_COUNT=0
eval() {
  if [ -n "${1:-}" ]; then
    YORHA_TEST_NONEMPTY_EVAL_COUNT=$((YORHA_TEST_NONEMPTY_EVAL_COUNT + 1))
  fi
  builtin eval "$@"
  if [ "$YORHA_TEST_NONEMPTY_EVAL_COUNT" -eq 1 ]; then
    YORHA_TEST_NONEMPTY_EVAL_COUNT=2
    : > "$YORHA_EXTRACT_READY"
    while :; do sleep 1; done
  fi
}
YORHA_TEST_TERM_DEFINITION="$(trap -p TERM)"
extract_appearance_trap_handler "$YORHA_TEST_TERM_DEFINITION" >/dev/null
printf 'after-block\n' >> "$YORHA_TRAP_LOG"
''')
        path.chmod(0o755)
        return path

    def make_restore_scope_signal_script(self):
        path = self.base / "appearance-runtime-restore-scope-signal.sh"
        path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
REPO="$TEST_REPO"
say() { printf '  %s\n' "$*"; }
definition=outer-definition
captured=outer-captured
signal_name=outer-signal-name
yorha_appearance_pending=outer-yorha-pending
yorha_appearance_source=outer-yorha-source
yorha_appearance_destination=outer-yorha-destination
yorha_appearance_temporary=outer-yorha-temporary
trap 'printf "prior-term:%s:%s:%s:%s:%s:%s:%s\n" "$definition" "$captured" "$signal_name" "$yorha_appearance_pending" "$yorha_appearance_source" "$yorha_appearance_destination" "$yorha_appearance_temporary" >> "$YORHA_TRAP_LOG"; builtin trap - TERM; : > "$YORHA_HANDLER_READY"; while :; do sleep 1; done' TERM
YORHA_TEST_TERM_EVAL_COUNT=0
eval() {
  case "${1:-}" in
    *' SIGTERM')
      YORHA_TEST_TERM_EVAL_COUNT=$((YORHA_TEST_TERM_EVAL_COUNT + 1))
      ;;
  esac
  builtin eval "$@"
  if [ "$YORHA_TEST_TERM_EVAL_COUNT" -eq 1 ] && [ -n "$WATCHER_TMP" ]; then
    YORHA_TEST_TERM_EVAL_COUNT=2
    : > "$YORHA_RESTORE_READY"
    while :; do sleep 1; done
  fi
}
''' + self.block + r'''
printf 'after-block\n' >> "$YORHA_TRAP_LOG"
''')
        path.chmod(0o755)
        return path

    def make_recursive_signal_script(self):
        path = self.base / "appearance-runtime-recursive-term.sh"
        path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
REPO="$TEST_REPO"
say() { printf '  %s\n' "$*"; }
handler=outer-handler
trap 'printf "prior-term:%s:%s\n" "$?" "$handler" >> "$YORHA_TRAP_LOG"; trap - TERM; kill -s TERM "$$"' TERM
''' + self.block + r'''
printf 'after-block\n' >> "$YORHA_TRAP_LOG"
''')
        path.chmod(0o755)
        return path

    def signal_block(self, script, signum):
        ready = Path(self.env["YORHA_SIGNAL_READY"])
        trap_log = Path(self.env["YORHA_TRAP_LOG"])
        ready.unlink(missing_ok=True)
        trap_log.unlink(missing_ok=True)
        env = self.env.copy()
        env["YORHA_DEPLOY_FAIL"] = "signal"
        process = subprocess.Popen(["/bin/bash", str(script)], cwd=ROOT, env=env,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        deadline = time.monotonic() + 5
        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "sandbox did not reach watcher compilation")
        os.killpg(process.pid, signum)
        process.communicate(timeout=5)
        lines = trap_log.read_text().splitlines() if trap_log.exists() else []
        return process.returncode, lines

    def signal_block_during_extract(self, script, signum):
        ready = Path(self.env["YORHA_EXTRACT_READY"])
        trap_log = Path(self.env["YORHA_TRAP_LOG"])
        ready.unlink(missing_ok=True)
        trap_log.unlink(missing_ok=True)
        process = subprocess.Popen(
            ["/bin/bash", str(script)], cwd=ROOT, env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + 5
        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "sandbox did not reach trap extraction")
        os.killpg(process.pid, signum)
        process.communicate(timeout=5)
        lines = trap_log.read_text().splitlines() if trap_log.exists() else []
        return process.returncode, lines

    def signal_block_during_restore(self, script, entry_signum, restored_signum):
        signal_ready = Path(self.env["YORHA_SIGNAL_READY"])
        restore_ready = Path(self.env["YORHA_RESTORE_READY"])
        handler_ready = Path(self.env["YORHA_HANDLER_READY"])
        trap_log = Path(self.env["YORHA_TRAP_LOG"])
        signal_ready.unlink(missing_ok=True)
        restore_ready.unlink(missing_ok=True)
        handler_ready.unlink(missing_ok=True)
        trap_log.unlink(missing_ok=True)
        env = self.env.copy()
        env["YORHA_DEPLOY_FAIL"] = "signal"
        process = subprocess.Popen(
            ["/bin/bash", str(script)], cwd=ROOT, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + 5
        while (not signal_ready.exists() and process.poll() is None
               and time.monotonic() < deadline):
            time.sleep(0.02)
        self.assertTrue(signal_ready.exists(), "sandbox did not reach watcher compilation")
        os.killpg(process.pid, entry_signum)
        deadline = time.monotonic() + 5
        while (not restore_ready.exists() and process.poll() is None
               and time.monotonic() < deadline):
            time.sleep(0.02)
        self.assertTrue(restore_ready.exists(), "sandbox did not reach trap restoration")
        os.killpg(process.pid, restored_signum)
        deadline = time.monotonic() + 5
        while (not handler_ready.exists() and process.poll() is None
               and time.monotonic() < deadline):
            time.sleep(0.02)
        self.assertTrue(handler_ready.exists(), "sandbox did not reach prior trap handler")
        os.killpg(process.pid, restored_signum)
        process.communicate(timeout=5)
        lines = trap_log.read_text().splitlines() if trap_log.exists() else []
        return process.returncode, lines

    def test_special_home_renders_exact_parseable_runtime_plist(self):
        result = self.run_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        plist_path = self.home / "Library/LaunchAgents/com.yorha.appearance-watcher.plist"
        with plist_path.open("rb") as handle:
            data = plistlib.load(handle)
        runtime_bin = self.home / ".config/yorha/bin"
        log = str(self.home / ".config/yorha/logs/appearance.log")
        self.assertEqual(data["ProgramArguments"], [
            str(runtime_bin / "yorha-appearance-watcher"),
            str(runtime_bin / "apply-appearance.sh"),
        ])
        self.assertEqual(data["StandardOutPath"], log)
        self.assertEqual(data["StandardErrorPath"], log)
        self.assertEqual(
            data["EnvironmentVariables"],
            {"YORHA_SKETCHYBAR_BIN": str(self.sketchybar)},
        )
        self.assertTrue(self.sketchybar_log.is_file())
        arguments = self.sketchybar_log.read_text().splitlines()
        self.assertTrue(any("--set clock" in line for line in arguments), arguments)
        self.assertFalse(any("--reload" in line for line in arguments), arguments)
        self.assertEqual(self.pending_temps(), [])

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

    def test_failures_preserve_destinations_and_remove_pending_temps(self):
        cases = (
            ("cp", self.home / ".config/yorha/appearance/yorha-system.heic"),
            ("chmod", self.home / ".config/yorha/bin/apply-appearance.sh"),
            ("compile", self.home / ".config/yorha/bin/yorha-appearance-watcher"),
            ("lint", self.home / "Library/LaunchAgents/com.yorha.appearance-watcher.plist"),
        )
        for failure, destination in cases:
            with self.subTest(failure=failure):
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(f"prior-{failure}")
                result = self.run_block(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(destination.read_text(), f"prior-{failure}")
                self.assertEqual(self.pending_temps(), [])

    def test_signal_preserves_watcher_and_removes_pending_temp(self):
        watcher = self.home / ".config/yorha/bin/yorha-appearance-watcher"
        watcher.parent.mkdir(parents=True, exist_ok=True)
        watcher.write_text("prior-signal")
        returncode, _ = self.signal_block(self.script, signal.SIGTERM)
        self.assertEqual(returncode, -signal.SIGTERM)
        self.assertEqual(watcher.read_text(), "prior-signal")
        self.assertEqual(self.pending_temps(), [])

    def test_normal_completion_restores_exact_prior_traps(self):
        result = subprocess.run(["/bin/bash", str(self.make_trap_script())], cwd=ROOT,
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        trap_log = Path(self.env["YORHA_TRAP_LOG"])
        self.assertEqual(trap_log.read_text().splitlines(),
                         ["after-block", "prior-exit:0:outer-handler"])

    def test_failed_block_preserves_exit_status_and_outer_handler_variable(self):
        env = self.env.copy()
        env["YORHA_DEPLOY_FAIL"] = "cp"
        result = subprocess.run(["/bin/bash", str(self.make_trap_script())], cwd=ROOT,
                                env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 91, result.stderr)
        trap_log = Path(self.env["YORHA_TRAP_LOG"])
        self.assertEqual(trap_log.read_text().splitlines(),
                         ["prior-exit:91:outer-handler"])
        self.assertEqual(self.pending_temps(), [])

    def test_failed_block_preserves_outer_helper_scratch_variables(self):
        env = self.env.copy()
        env["YORHA_DEPLOY_FAIL"] = "cp"
        result = subprocess.run(
            ["/bin/bash", str(self.make_helper_scope_trap_script())], cwd=ROOT,
            env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 91, result.stderr)
        trap_log = Path(self.env["YORHA_TRAP_LOG"])
        self.assertEqual(trap_log.read_text().splitlines(), [
            "prior-exit:91:outer-definition:outer-captured:outer-signal-name:"
            "outer-yorha-pending:outer-yorha-source:outer-yorha-destination:"
            "outer-yorha-temporary",
        ])
        self.assertEqual(self.pending_temps(), [])

    def test_signal_during_trap_extraction_preserves_outer_helper_variables(self):
        returncode, lines = self.signal_block_during_extract(
            self.make_extract_scope_signal_script(), signal.SIGTERM)
        self.assertEqual(returncode, -signal.SIGTERM)
        self.assertEqual(lines, [
            "prior-term:outer-definition:outer-captured:outer-signal-name:"
            "outer-yorha-pending:outer-yorha-source:outer-yorha-destination:"
            "outer-yorha-temporary",
        ])
        self.assertNotIn("after-block", lines)
        self.assertEqual(self.pending_temps(), [])

    def test_signal_during_trap_restore_preserves_outer_helper_variables(self):
        returncode, lines = self.signal_block_during_restore(
            self.make_restore_scope_signal_script(), signal.SIGHUP, signal.SIGTERM)
        self.assertEqual(returncode, -signal.SIGTERM)
        self.assertEqual(lines, [
            "prior-term:outer-definition:outer-captured:outer-signal-name:"
            "outer-yorha-pending:outer-yorha-source:outer-yorha-destination:"
            "outer-yorha-temporary",
        ])
        self.assertNotIn("after-block", lines)
        self.assertEqual(self.pending_temps(), [])

    def test_signal_cleans_then_dispatches_prior_handler_and_stops(self):
        watcher = self.home / ".config/yorha/bin/yorha-appearance-watcher"
        watcher.parent.mkdir(parents=True, exist_ok=True)
        watcher.write_text("prior-chained-signal")
        cases = ((signal.SIGHUP, "hup"), (signal.SIGINT, "int"),
                 (signal.SIGTERM, "term"))
        for signum, name in cases:
            with self.subTest(signal=name):
                watcher.write_text("prior-chained-signal")
                returncode, lines = self.signal_block(self.make_trap_script(), signum)
                expected_status = 128 + signum
                self.assertEqual(returncode, expected_status)
                self.assertEqual(lines, [
                    f"prior-{name}:{expected_status}:outer-handler",
                    f"prior-exit:{expected_status}:outer-handler",
                ])
                self.assertNotIn("after-block", lines)
                self.assertEqual(watcher.read_text(), "prior-chained-signal")
                self.assertEqual(self.pending_temps(), [])

    def test_ignored_term_is_not_dispatched_and_does_not_continue(self):
        returncode, lines = self.signal_block(self.make_ignored_signal_script(), signal.SIGTERM)
        self.assertEqual(returncode, 143)
        self.assertEqual(lines, ["prior-exit:143:outer-handler"])
        self.assertNotIn("after-block", lines)
        self.assertEqual(self.pending_temps(), [])

    def test_guarded_recursive_term_handler_runs_once_without_loop(self):
        returncode, lines = self.signal_block(self.make_recursive_signal_script(), signal.SIGTERM)
        self.assertEqual(returncode, -signal.SIGTERM)
        self.assertEqual(lines, ["prior-term:143:outer-handler"])
        self.assertEqual(self.pending_temps(), [])


class RestoreContractTests(unittest.TestCase):
    def write_double(self, directory, name, body):
        path = directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def make_restore_sandbox(self, original_plist=b"pre-existing plist bytes\n",
                             originally_loaded=True):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        sandbox = Path(temporary.name)
        home = sandbox / "home"
        fakebin = sandbox / "bin"
        home.mkdir(); fakebin.mkdir()
        (home / ".zshrc").write_text("baseline\n")
        agents = home / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        plist = agents / "com.yorha.appearance-watcher.plist"
        if original_plist is not None:
            plist.write_bytes(original_plist)

        job_state = sandbox / "appearance-job-loaded"
        if originally_loaded:
            job_state.write_text("loaded\n")
        recorded_wallpaper = sandbox / "recorded.heic"
        recorded_wallpaper.write_bytes(b"baseline wallpaper")
        wallpaper_state = sandbox / "wallpaper-state"
        launchctl_log = sandbox / "launchctl-log"
        mutation_log = sandbox / "mutation-log"
        failure_ready = sandbox / "failure-ready"
        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "PATH": f"{fakebin}:/usr/bin:/bin",
            "YORHA_TEST_RECORDED_WALLPAPER": str(recorded_wallpaper),
            "YORHA_TEST_WALLPAPER_STATE": str(wallpaper_state),
            "YORHA_TEST_LAUNCHCTL_LOG": str(launchctl_log),
            "YORHA_TEST_MUTATION_LOG": str(mutation_log),
            "YORHA_TEST_JOB_STATE": str(job_state),
            "YORHA_TEST_FAILURE_READY": str(failure_ready),
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
    [ -f "$YORHA_TEST_JOB_STATE" ]
    exit $? ;;
  bootout:*com.yorha.appearance-watcher)
    /bin/rm -f "$YORHA_TEST_JOB_STATE"
    exit 0 ;;
  bootstrap:*)
    case "$3" in
      *com.yorha.appearance-watcher.plist)
        if [ "${YORHA_TEST_RESTORE_FAILURE:-}" = bootstrap ]; then
          exit 73
        fi
        : > "$YORHA_TEST_JOB_STATE"
        exit 0 ;;
    esac ;;
esac
exit 0
''')
        self.write_double(fakebin, "cp", r'''
printf 'cp\t%s\n' "$*" >> "$YORHA_TEST_MUTATION_LOG"
case "${YORHA_TEST_RESTORE_FAILURE:-}:$2" in
  cp:*.restore.*)
    printf partial > "$2"
    exit 71 ;;
  pause:*.restore.*)
    printf partial > "$2"
    : > "$YORHA_TEST_FAILURE_READY"
    while :; do /bin/sleep 1; done ;;
esac
exec /bin/cp "$@"
''')
        self.write_double(fakebin, "mv", r'''
printf 'mv\t%s\n' "$*" >> "$YORHA_TEST_MUTATION_LOG"
case "${YORHA_TEST_RESTORE_FAILURE:-}:$1" in
  mv:*.restore.*) exit 72 ;;
esac
exec /bin/mv "$@"
''')
        self.write_double(fakebin, "mkdir", r'''
printf 'mkdir\t%s\n' "$*" >> "$YORHA_TEST_MUTATION_LOG"
exec /bin/mkdir "$@"
''')
        self.write_double(fakebin, "rm", r'''
printf 'rm\t%s\n' "$*" >> "$YORHA_TEST_MUTATION_LOG"
exec /bin/rm "$@"
''')
        self.write_double(fakebin, "brew", "exit 0\n")
        self.write_double(fakebin, "pkill", "exit 0\n")
        self.write_double(fakebin, "sw_vers", "printf '26.0\\n'\n")
        self.write_double(fakebin, "csrutil",
                          "printf 'System Integrity Protection status: enabled.\\n'\n")

        generated = subprocess.run(
            [str(ROOT / "bin/yorha-backup.sh")], env=env,
            text=True, capture_output=True, check=True)
        snapshot = Path(generated.stdout.strip().splitlines()[-1])
        restore = snapshot / "restore.sh"
        self.assertTrue(restore.is_file())
        return {
            "sandbox": sandbox, "home": home, "agents": agents,
            "plist": plist, "original_plist": original_plist,
            "job_state": job_state, "recorded_wallpaper": recorded_wallpaper,
            "wallpaper_state": wallpaper_state, "launchctl_log": launchctl_log,
            "mutation_log": mutation_log,
            "failure_ready": failure_ready, "env": env,
            "snapshot": snapshot, "restore": restore,
        }

    def deploy_appearance_fixture(self, context):
        home = context["home"]
        yorha = home / ".config/yorha"
        yorha.mkdir(parents=True, exist_ok=True)
        keep = yorha / "keep.txt"
        keep.write_text("unrelated after snapshot\n")
        context["plist"].write_text("deployed YoRHa plist\n")
        context["job_state"].write_text("deployed job loaded\n")
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
        context.update({"keep": keep, "appearance": appearance,
                        "runtime_paths": runtime_paths})

    def run_restore(self, context, failure=None):
        env = context["env"].copy()
        if failure:
            env["YORHA_TEST_RESTORE_FAILURE"] = failure
        return subprocess.run([str(context["restore"])], env=env,
                              text=True, capture_output=True)

    def assert_no_plist_temps(self, context):
        self.assertEqual(list(context["agents"].glob("*.restore.*")), [])

    def assert_runtime_removed(self, context):
        for path in context["runtime_paths"]:
            self.assertFalse(path.exists(), path)
        self.assertFalse((context["appearance"] / "apply.lock").exists())
        self.assertTrue(context["keep"].is_file())

    def test_present_loaded_restores_exact_plist_and_job(self):
        context = self.make_restore_sandbox()
        self.deploy_appearance_fixture(context)
        result = self.run_restore(context)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_runtime_removed(context)
        self.assertEqual(context["plist"].read_bytes(), context["original_plist"])
        self.assertTrue(context["job_state"].is_file())
        calls = context["launchctl_log"].read_text().splitlines()
        self.assertTrue(any("bootout" in call for call in calls))
        self.assertTrue(any("bootstrap" in call and str(context["plist"]) in call
                            for call in calls))
        self.assertEqual(context["wallpaper_state"].read_text().strip(),
                         str(context["recorded_wallpaper"]))
        self.assertIn("Restore complete.", result.stdout)
        self.assert_no_plist_temps(context)

    def test_present_unloaded_restores_plist_without_bootstrap(self):
        context = self.make_restore_sandbox(originally_loaded=False)
        self.deploy_appearance_fixture(context)
        result = self.run_restore(context)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_runtime_removed(context)
        self.assertEqual(context["plist"].read_bytes(), context["original_plist"])
        self.assertFalse(context["job_state"].exists())
        calls = context["launchctl_log"].read_text().splitlines()
        self.assertFalse(any("bootstrap" in call for call in calls))
        self.assert_no_plist_temps(context)

    def test_absent_snapshot_removes_only_owned_paths_and_preserves_later_file(self):
        context = self.make_restore_sandbox(original_plist=None, originally_loaded=False)
        preexisting = (context["snapshot"] / "preexisting.txt").read_text().splitlines()
        self.assertFalse(any(line.startswith(".config/yorha\t") for line in preexisting))
        self.deploy_appearance_fixture(context)
        result = self.run_restore(context)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_runtime_removed(context)
        self.assertFalse(context["plist"].exists())
        self.assertFalse(context["job_state"].exists())
        self.assert_no_plist_temps(context)

    def test_missing_or_corrupt_loaded_state_fails_before_mutation(self):
        invalid_states = (
            None,
            b"corrupt\n",
            b"loaded\ncorrupt\n",
            b"corrupt\nloaded\n",
            b"loaded\nloaded\n",
            b"unloaded\ncorrupt\n",
            b"corrupt\nunloaded\n",
            b"unloaded\nunloaded\n",
            b"loaded",
            b"unloaded",
            b"loaded \n",
            b" unloaded\n",
            b"unloaded\t\n",
        )
        for state in invalid_states:
            with self.subTest(state=state):
                context = self.make_restore_sandbox()
                self.deploy_appearance_fixture(context)
                state_path = context["snapshot"] / "appearance-watcher.loaded-state"
                if state is None:
                    state_path.unlink()
                else:
                    state_path.write_bytes(state)
                result = self.run_restore(context)
                self.assertEqual(result.returncode, 65)
                self.assertEqual(context["plist"].read_text(), "deployed YoRHa plist\n")
                self.assertTrue(context["job_state"].is_file())
                self.assertTrue(all(path.exists() for path in context["runtime_paths"]))
                calls = context["launchctl_log"].read_text().splitlines()
                self.assertFalse(any("bootout" in call or "bootstrap" in call
                                     for call in calls))
                self.assertFalse(context["wallpaper_state"].exists())
                self.assertIn("invalid appearance watcher state", result.stderr)
                self.assertNotIn("Restore complete.", result.stdout)
                self.assert_no_plist_temps(context)

    def test_plan_timeout_diagnostic_executes_valid_applescript(self):
        plan = (ROOT / "docs/superpowers/plans/2026-08-05-system-appearance-theming.md")
        diagnostic = next(line.strip() for line in plan.read_text().splitlines()
                          if line.strip().startswith('echo "desktop count:'))
        with tempfile.TemporaryDirectory() as raw:
            fakebin = Path(raw)
            self.write_double(fakebin, "osascript", r'''
[ "$1" = "-e" ] || exit 80
[ "$2" = 'tell application "System Events" to count every desktop' ] || {
  printf 'unexpected AppleScript: <%s>\n' "$2" >&2
  exit 81
}
printf '1\n'
''')
            env = os.environ.copy()
            env["PATH"] = f"{fakebin}:/usr/bin:/bin"
            result = subprocess.run(["/bin/bash", "-c", diagnostic], env=env,
                                    text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "desktop count: 1\n")

    def test_copy_failure_keeps_deployed_state_and_cleans_partial_temp(self):
        context = self.make_restore_sandbox()
        self.deploy_appearance_fixture(context)
        result = self.run_restore(context, "cp")
        self.assertEqual(result.returncode, 71)
        self.assertEqual(context["plist"].read_text(), "deployed YoRHa plist\n")
        self.assertTrue(context["job_state"].is_file())
        self.assertTrue(all(path.exists() for path in context["runtime_paths"]))
        self.assertNotIn("Restore complete.", result.stdout)
        self.assert_no_plist_temps(context)

    def test_move_failure_keeps_deployed_plist_but_stops_job_and_cleans_temp(self):
        context = self.make_restore_sandbox()
        self.deploy_appearance_fixture(context)
        result = self.run_restore(context, "mv")
        self.assertEqual(result.returncode, 72)
        self.assertEqual(context["plist"].read_text(), "deployed YoRHa plist\n")
        self.assertFalse(context["job_state"].exists())
        self.assert_runtime_removed(context)
        self.assertNotIn("Restore complete.", result.stdout)
        self.assert_no_plist_temps(context)

    def test_bootstrap_failure_restores_plist_but_reports_failure(self):
        context = self.make_restore_sandbox()
        self.deploy_appearance_fixture(context)
        result = self.run_restore(context, "bootstrap")
        self.assertEqual(result.returncode, 73)
        self.assertEqual(context["plist"].read_bytes(), context["original_plist"])
        self.assertFalse(context["job_state"].exists())
        self.assert_runtime_removed(context)
        self.assertNotIn("Restore complete.", result.stdout)
        self.assert_no_plist_temps(context)

    def test_signals_clean_partial_plist_temp_and_preserve_deployed_state(self):
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                context = self.make_restore_sandbox()
                self.deploy_appearance_fixture(context)
                env = context["env"].copy()
                env["YORHA_TEST_RESTORE_FAILURE"] = "pause"
                process = subprocess.Popen(
                    [str(context["restore"])], env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                deadline = time.monotonic() + 5
                while (not context["failure_ready"].exists()
                       and process.poll() is None and time.monotonic() < deadline):
                    time.sleep(0.02)
                self.assertTrue(context["failure_ready"].exists())
                os.killpg(process.pid, signum)
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 128 + signum)
                self.assertEqual(context["plist"].read_text(), "deployed YoRHa plist\n")
                self.assertTrue(context["job_state"].is_file())
                self.assertTrue(all(path.exists() for path in context["runtime_paths"]))
                self.assert_no_plist_temps(context)

    def test_corrupt_preexisting_metadata_fails_before_every_mutation(self):
        def corruptions(lines):
            return {
                "unknown": [*lines, ".config/yorha/not-owned\tABSENT\n"],
                "duplicate": [*lines, lines[0]],
                "absolute": [f"/tmp/escape\tABSENT\n", *lines[1:]],
                "traversal": [f"../escape\tABSENT\n", *lines[1:]],
                "missing": lines[:-1],
                "extra-field": [f"{lines[0].rstrip()}\textra\n", *lines[1:]],
                "missing-field": [f"{lines[0].split(chr(9), 1)[0]}\n", *lines[1:]],
                "wrong-state": [f"{lines[0].split(chr(9), 1)[0]}\tMAYBE\n", *lines[1:]],
                "missing-newline": [*lines[:-1], lines[-1].rstrip("\n")],
                "blank-row": [*lines, "\n"],
            }

        for name in (
            "unknown", "duplicate", "absolute", "traversal", "missing",
            "extra-field", "missing-field", "wrong-state", "missing-newline",
            "blank-row",
        ):
            with self.subTest(corruption=name):
                context = self.make_restore_sandbox()
                self.deploy_appearance_fixture(context)
                metadata = context["snapshot"] / "preexisting.txt"
                lines = metadata.read_text().splitlines(keepends=True)
                metadata.write_text("".join(corruptions(lines)[name]))
                context["launchctl_log"].write_text("")
                context["mutation_log"].write_text("")
                context["wallpaper_state"].unlink(missing_ok=True)
                before = {
                    str(path.relative_to(context["home"])):
                        ("dir" if path.is_dir() else path.read_bytes())
                    for path in context["home"].rglob("*")
                }
                for executable in (context["sandbox"] / "bin").iterdir():
                    self.assertTrue(os.access(executable, os.X_OK), executable)

                result = self.run_restore(context)

                after = {
                    str(path.relative_to(context["home"])):
                        ("dir" if path.is_dir() else path.read_bytes())
                    for path in context["home"].rglob("*")
                }
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertEqual(after, before)
                self.assertTrue(context["job_state"].is_file())
                self.assertEqual(context["launchctl_log"].read_text(), "")
                self.assertEqual(context["mutation_log"].read_text(), "")
                self.assertFalse(context["wallpaper_state"].exists())
                self.assertNotIn("Restore complete.", result.stdout)

    def test_docs_state_boundary(self):
        readme = (ROOT / "README.md").read_text().lower()
        decisions = (ROOT / "docs/DECISIONS.md").read_text().lower()
        self.assertIn("automatic appearance", readme)
        self.assertIn("ghostty remains permanently dark", readme)
        self.assertIn("appearance-watcher", decisions)
        self.assertIn("prefers-color-scheme", decisions)
