import os, re, signal, subprocess, tempfile, time, unittest
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
        self.assertEqual(re.findall(r"^install_atomic .*$", block, re.M),
                         ['install_atomic "$REPO/assets/yorha-system.heic" "$RUNTIME_WALLPAPER"'])

    def test_runtime_heic_is_assigned_exactly_once_with_argv(self):
        text = self.deploy_text()
        block = self.appearance_block()
        self.assertEqual(re.findall(r'osascript\s+-\s+"([^"]+)"', text),
                         ["$RUNTIME_WALLPAPER"])
        self.assertEqual(text.count('set picture of every desktop'), 1)
        self.assertEqual(text.count('on run argv'), 1)
        self.assertIn('POSIX file (item 1 of argv)', block)
        self.assertNotRegex(text, r'osascript[^\n]*\$REPO')

    def test_block_installs_only_the_wallpaper_and_guards_its_temp(self):
        block = self.appearance_block()
        for retired in ("swiftc", "launchctl", "plutil", "sketchybar", "apply-appearance",
                        "appearance-watcher", "yorha-icon", "WATCHER_TMP", "PLIST_TMP"):
            self.assertNotIn(retired, block)
        cleanup = re.search(r"cleanup_appearance_temps\(\) \{(?P<body>.*?)\n\}", block, re.S)
        self.assertIsNotNone(cleanup)
        self.assertIn('rm -f -- "$INSTALL_TMP"', cleanup.group("body"))
        for event in ("EXIT", "HUP", "INT", "TERM"):
            self.assertRegex(block, rf"trap [^\n]+\b{event}\b")
        self.assertLess(block.index('osascript - "$RUNTIME_WALLPAPER"'),
                        block.index("restore_appearance_traps\n", block.index("osascript")))

    def test_retired_bar_helpers_are_gone_and_the_installer_retires_them(self):
        for path in ("config/sketchybar", "bin/apply-appearance.sh", "bin/appearance-watcher.swift",
                     "launchd/com.yorha.appearance-watcher.plist",
                     "launchd/com.yorha.sketchybar-minute.plist"):
            self.assertFalse((ROOT / path).exists(), path)
        deploy = self.deploy_text()
        for retired in ("config/sketchybar", "sketchybar --", "sketchybar-minute",
                        "appearance-watcher", "apply-appearance"):
            self.assertNotIn(retired, deploy)
        installer = (ROOT / "bin/install-desktop.sh").read_text()
        self.assertIn('services stop sketchybar', installer)
        self.assertIn("for OLD in com.yorha.sketchybar-minute com.yorha.appearance-watcher", installer)
        watcher = (ROOT / "bin/yorha-watcher").read_text()
        self.assertNotIn("brew", watcher)
        self.assertIn("desktop | bar)", watcher)

    def test_pipeline_does_not_target_ghostty(self):
        paths = [ROOT / "native/YoRHaDesktop/Palette.swift", ROOT / "native/YoRHaDesktop/Bar.swift"]
        self.assertNotIn("ghostty", "\n".join(p.read_text().lower() for p in paths))

    def test_committed_feature_agent_scope_matches_tracked_plists_and_docs(self):
        tracked = subprocess.run(
            ["git", "ls-files", "launchd/com.yorha.*.plist"], cwd=ROOT,
            check=True, text=True, capture_output=True,
        ).stdout.splitlines()
        tracked_names = {Path(path).name for path in tracked}
        # Two feature-owned agents. The appearance watcher and SketchyBar's minute
        # trigger retired when YoRHa Desktop took over the bar.
        self.assertEqual(tracked_names, {
            "com.yorha.pod-oracle.plist",
            "com.yorha.desktop.plist",
        })

        deploy_refs = set(re.findall(
            r'\$REPO/launchd/(com\.yorha\.[A-Za-z0-9.-]+\.plist)',
            self.deploy_text(),
        ))
        self.assertEqual(deploy_refs & tracked_names, tracked_names)
        # Restore clears the retired agents an older install may have left.
        self.assertIn(
            "for agent in com.yorha.sketchybar-minute com.yorha.appearance-watcher; do",
            (ROOT / "bin/yorha-backup.sh").read_text(),
        )

        committed_docs = {
            path: subprocess.run(
                ["git", "show", f":{path}"], cwd=ROOT,
                check=True, text=True, capture_output=True,
            ).stdout.lower()
            for path in ("README.md", "docs/DECISIONS.md")
        }
        for path, text in committed_docs.items():
            self.assertIn("two feature-owned", text, path)
            self.assertNotRegex(text, r"(?:three|four) feature-owned", path)


class DeploymentSandboxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.home = self.base / "home & pipe| less< dollar$ spaces"
        self.fake_bin = self.base / "fake-bin"
        self.home.mkdir()
        self.fake_bin.mkdir()
        self.osascript_log = self.base / "osascript.log"
        self.script = self.base / "appearance-runtime.sh"
        text = (ROOT / "bin/deploy.sh").read_text()
        block = text.split("# --- appearance runtime BEGIN", 1)[1].split(
            "# --- appearance runtime END", 1)[0]
        self.block = block
        self.script.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\nREPO="$TEST_REPO"\n'
            "say() { printf '  %s\\n' \"$*\"; }\n" + block)
        self.script.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "TEST_REPO": str(ROOT),
            "YORHA_SIGNAL_READY": str(self.base / "signal-ready"),
            "YORHA_EXTRACT_READY": str(self.base / "extract-ready"),
            "YORHA_RESTORE_READY": str(self.base / "restore-ready"),
            "YORHA_HANDLER_READY": str(self.base / "handler-ready"),
            "YORHA_TRAP_LOG": str(self.base / "trap.log"),
            "YORHA_TEST_OSASCRIPT_LOG": str(self.osascript_log),
        })
        self.write_stub("cp", r'''#!/bin/bash
if [[ "$1" == */assets/yorha-system.heic ]]; then
  case "${YORHA_DEPLOY_FAIL:-}" in
    cp)
      printf partial > "$2"
      exit 91 ;;
    signal)
      printf partial > "$2"
      : > "$YORHA_SIGNAL_READY"
      while :; do sleep 1; done ;;
  esac
fi
exec /bin/cp "$@"
''')
        self.write_stub("swift", "#!/bin/bash\nexit 0\n")
        self.write_stub("osascript",
                        "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$YORHA_TEST_OSASCRIPT_LOG\"\n")

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
  if [ "$YORHA_TEST_TERM_EVAL_COUNT" -eq 1 ] && [ -n "$INSTALL_TMP" ]; then
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
        self.assertTrue(ready.exists(), "sandbox did not reach the wallpaper copy")
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
        self.assertTrue(signal_ready.exists(), "sandbox did not reach the wallpaper copy")
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

    def test_special_home_installs_and_assigns_the_committed_heic(self):
        result = self.run_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        runtime = self.home / ".config/yorha/appearance/yorha-system.heic"
        self.assertEqual(runtime.read_bytes(), (ROOT / "assets/yorha-system.heic").read_bytes())
        self.assertEqual(self.osascript_log.read_text().splitlines(), [f"- {runtime}"])
        self.assertEqual(sorted(p.name for p in runtime.parent.iterdir()), ["yorha-system.heic"])
        self.assertFalse((self.home / "Library/LaunchAgents").exists())
        self.assertEqual(self.pending_temps(), [])

    def test_copy_failure_preserves_the_installed_heic_and_removes_its_temp(self):
        destination = self.home / ".config/yorha/appearance/yorha-system.heic"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text("prior-cp")
        result = self.run_block("cp")
        self.assertEqual(result.returncode, 91)
        self.assertEqual(destination.read_text(), "prior-cp")
        self.assertFalse(self.osascript_log.exists())
        self.assertEqual(self.pending_temps(), [])

    def test_signal_preserves_the_installed_heic_and_removes_its_temp(self):
        heic = self.home / ".config/yorha/appearance/yorha-system.heic"
        heic.parent.mkdir(parents=True, exist_ok=True)
        heic.write_text("prior-signal")
        returncode, _ = self.signal_block(self.script, signal.SIGTERM)
        self.assertEqual(returncode, -signal.SIGTERM)
        self.assertEqual(heic.read_text(), "prior-signal")
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
        heic = self.home / ".config/yorha/appearance/yorha-system.heic"
        heic.parent.mkdir(parents=True, exist_ok=True)
        cases = ((signal.SIGHUP, "hup"), (signal.SIGINT, "int"),
                 (signal.SIGTERM, "term"))
        for signum, name in cases:
            with self.subTest(signal=name):
                heic.write_text("prior-chained-signal")
                returncode, lines = self.signal_block(self.make_trap_script(), signum)
                expected_status = 128 + signum
                self.assertEqual(returncode, expected_status)
                self.assertEqual(lines, [
                    f"prior-{name}:{expected_status}:outer-handler",
                    f"prior-exit:{expected_status}:outer-handler",
                ])
                self.assertNotIn("after-block", lines)
                self.assertEqual(heic.read_text(), "prior-chained-signal")
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

    def make_restore_sandbox(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        sandbox = Path(temporary.name)
        home = sandbox / "home"
        fakebin = sandbox / "bin"
        home.mkdir(); fakebin.mkdir()
        (home / ".zshrc").write_text("baseline\n")
        agents = home / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        recorded_wallpaper = sandbox / "recorded.heic"
        recorded_wallpaper.write_bytes(b"baseline wallpaper")
        wallpaper_state = sandbox / "wallpaper-state"
        launchctl_log = sandbox / "launchctl-log"
        mutation_log = sandbox / "mutation-log"
        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "PATH": f"{fakebin}:/usr/bin:/bin",
            "YORHA_TEST_RECORDED_WALLPAPER": str(recorded_wallpaper),
            "YORHA_TEST_WALLPAPER_STATE": str(wallpaper_state),
            "YORHA_TEST_LAUNCHCTL_LOG": str(launchctl_log),
            "YORHA_TEST_MUTATION_LOG": str(mutation_log),
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
exit 0
''')
        self.write_double(fakebin, "cp", r'''
printf 'cp\t%s\n' "$*" >> "$YORHA_TEST_MUTATION_LOG"
exec /bin/cp "$@"
''')
        self.write_double(fakebin, "mv", r'''
printf 'mv\t%s\n' "$*" >> "$YORHA_TEST_MUTATION_LOG"
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
            "recorded_wallpaper": recorded_wallpaper,
            "wallpaper_state": wallpaper_state, "launchctl_log": launchctl_log,
            "mutation_log": mutation_log, "env": env,
            "snapshot": snapshot, "restore": restore,
        }

    def deploy_fixture(self, context):
        home = context["home"]
        yorha = home / ".config/yorha"
        yorha.mkdir(parents=True, exist_ok=True)
        keep = yorha / "keep.txt"
        keep.write_text("unrelated after snapshot\n")
        appearance = yorha / "appearance"
        agents = context["agents"]
        runtime_paths = [
            appearance / "yorha-system.heic",
            agents / "com.yorha.desktop.plist",
            yorha / "bin/yorha-desktop",
            yorha / "logs/yorha-desktop.log",
            yorha / "bar-off",
            # retired helpers an older install left behind
            agents / "com.yorha.appearance-watcher.plist",
            agents / "com.yorha.sketchybar-minute.plist",
            appearance / "yorha-icon-light.png",
            appearance / "yorha-icon-dark.png",
            appearance / "last-successful-mode",
            yorha / "bin/yorha-appearance-watcher",
            yorha / "bin/apply-appearance.sh",
            yorha / "logs/appearance.log",
            yorha / "cache/sketchybar-minute.stderr.log",
        ]
        for path in runtime_paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("installed\n")
        (appearance / "apply.lock").mkdir()
        context.update({"keep": keep, "appearance": appearance,
                        "runtime_paths": runtime_paths})

    def run_restore(self, context):
        return subprocess.run([str(context["restore"])], env=context["env"],
                              text=True, capture_output=True)

    def assert_runtime_removed(self, context):
        for path in context["runtime_paths"]:
            self.assertFalse(path.exists(), path)
        self.assertFalse(context["appearance"].exists())
        self.assertTrue(context["keep"].is_file())

    def test_restore_removes_owned_and_retired_paths_and_preserves_later_file(self):
        context = self.make_restore_sandbox()
        preexisting = (context["snapshot"] / "preexisting.txt").read_text().splitlines()
        self.assertFalse(any(line.startswith(".config/yorha\t") for line in preexisting))
        self.assertFalse(any("appearance-watcher" in p.name for p in context["snapshot"].iterdir()))
        self.deploy_fixture(context)
        result = self.run_restore(context)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_runtime_removed(context)
        calls = context["launchctl_log"].read_text().splitlines()
        for label in ("com.yorha.desktop", "com.yorha.appearance-watcher",
                      "com.yorha.sketchybar-minute"):
            self.assertTrue(any(call.startswith("bootout") and call.endswith(label)
                                for call in calls), label)
        self.assertFalse(any(call.startswith("bootstrap") for call in calls))
        self.assertEqual(context["wallpaper_state"].read_text().strip(),
                         str(context["recorded_wallpaper"]))
        self.assertIn("Restore complete.", result.stdout)

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
                self.deploy_fixture(context)
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
                self.assertEqual(context["launchctl_log"].read_text(), "")
                self.assertEqual(context["mutation_log"].read_text(), "")
                self.assertFalse(context["wallpaper_state"].exists())
                self.assertNotIn("Restore complete.", result.stdout)

    def test_docs_state_boundary(self):
        readme = (ROOT / "README.md").read_text().lower()
        decisions = (ROOT / "docs/DECISIONS.md").read_text().lower()
        self.assertIn("automatic appearance", readme)
        self.assertIn("ghostty remains permanently dark", readme)
        self.assertIn("watcher and coordinator retired", decisions)
        self.assertIn("prefers-color-scheme", decisions)
        self.assertIn("yorha-watcher off bar", readme)
