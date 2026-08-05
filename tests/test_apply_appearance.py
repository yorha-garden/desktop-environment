import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "apply-appearance.sh"


class ApplyAppearanceTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.appearance_root = Path(self.tempdir.name) / "appearance; $(literal) & [space]"
        self.appearance_root.mkdir()
        self.light_crest = self.appearance_root / "yorha-icon-light.png"
        self.dark_crest = self.appearance_root / "yorha-icon-dark.png"
        self.light_crest.touch()
        self.dark_crest.touch()
        self.state = self.appearance_root / "last-successful-mode"
        self.lock = self.appearance_root / "apply.lock"
        self.call_log = Path(self.tempdir.name) / "sketchybar-calls.bin"
        self.sketchybar = Path(self.tempdir.name) / "sketchybar"
        self.write_sketchybar()

    def tearDown(self):
        self.tempdir.cleanup()

    def write_sketchybar(self, exit_code=0):
        self.sketchybar.write_text(
            "#!/usr/bin/env bash\n"
            "printf '\\036' >> \"$YORHA_TEST_CALL_LOG\"\n"
            "printf '%s\\0' \"$@\" >> \"$YORHA_TEST_CALL_LOG\"\n"
            f"exit {exit_code}\n"
        )
        self.sketchybar.chmod(0o755)

    def write_long_running_sketchybar(self, child_pid_file):
        self.sketchybar.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$$\" > \"$YORHA_TEST_CHILD_PID_FILE\"\n"
            "exec sleep 30\n"
        )
        self.sketchybar.chmod(0o755)
        return {"YORHA_TEST_CHILD_PID_FILE": str(child_pid_file)}

    def run_apply(self, *args, extra_env=None):
        env = os.environ | {
            "YORHA_APPEARANCE_ROOT": str(self.appearance_root),
            "YORHA_SKETCHYBAR_BIN": str(self.sketchybar),
            "YORHA_TEST_CALL_LOG": str(self.call_log),
        }
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(SCRIPT), *args], text=True, capture_output=True, env=env, check=False
        )

    def call_argvs(self):
        if not self.call_log.exists():
            return []
        records = self.call_log.read_bytes().split(b"\x1e")[1:]
        return [
            [argument.decode() for argument in record.split(b"\0")[:-1]]
            for record in records
        ]

    def expected_argv(self, mode):
        if mode == "light":
            bar_text = brand = "0xff4a4741"
            crest = self.light_crest
        else:
            bar_text = "0xffd8d4c4"
            brand = "0xffbc9a5a"
            crest = self.dark_crest
        return [
            "--set", "clock", f"label.color={bar_text}",
            "--set", "date", f"label.color={bar_text}",
            "--set", "yorha", f"label.color={brand}",
            "--set", "yorha_icon", f"background.image={crest}",
        ]

    def test_argument_count_validation_precedes_missing_asset_checks(self):
        self.light_crest.unlink()
        self.dark_crest.unlink()
        for arguments in ((), ("light", "--force", "unexpected")):
            with self.subTest(arguments=arguments):
                result = self.run_apply(*arguments)
                self.assertEqual(result.returncode, 64)
                self.assertIn("usage:", result.stderr)
                self.assertEqual(self.call_argvs(), [])
                self.assertFalse(self.state.exists())

    def test_invalid_mode_and_second_argument_are_rejected(self):
        for arguments in (("sepia",), ("light", "unexpected")):
            with self.subTest(arguments=arguments):
                result = self.run_apply(*arguments)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(self.call_argvs(), [])
                self.assertFalse(self.state.exists())

    def test_light_and_dark_use_exact_ordered_argv_with_literal_crest_paths(self):
        light = self.run_apply("light")
        self.assertEqual(light.returncode, 0, light.stderr)
        self.assertEqual(self.call_argvs(), [self.expected_argv("light")])
        self.assertEqual(self.state.read_text().strip(), "light")

        dark = self.run_apply("dark")
        self.assertEqual(dark.returncode, 0, dark.stderr)
        self.assertEqual(
            self.call_argvs(),
            [self.expected_argv("light"), self.expected_argv("dark")],
        )
        self.assertEqual(self.state.read_text().strip(), "dark")

    def test_same_mode_is_noop_unless_forced(self):
        self.assertEqual(self.run_apply("light").returncode, 0)
        first = list(self.call_argvs())
        self.assertEqual(self.run_apply("light").returncode, 0)
        self.assertEqual(self.call_argvs(), first)
        self.assertEqual(self.run_apply("light", "--force").returncode, 0)
        self.assertEqual(self.call_argvs(), [*first, self.expected_argv("light")])

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
        self.assertEqual(self.call_argvs()[-1], self.expected_argv("dark"))

    def test_missing_crest_changes_nothing(self):
        self.dark_crest.unlink()
        self.assertNotEqual(self.run_apply("dark").returncode, 0)
        self.assertEqual(self.call_argvs(), [])
        self.assertFalse(self.state.exists())

    def test_existing_lock_times_out_without_invoking_sketchybar(self):
        self.lock.mkdir()
        fake_bin = Path(self.tempdir.name) / "fake-bin"
        fake_bin.mkdir()
        sleep_log = Path(self.tempdir.name) / "sleep-calls.log"
        (fake_bin / "sleep").write_text(
            "#!/usr/bin/env bash\n"
            "printf 'sleep\\t%s\\n' \"$*\" >> \"$YORHA_TEST_SLEEP_LOG\"\n"
        )
        (fake_bin / "sleep").chmod(0o755)
        result = self.run_apply(
            "dark",
            extra_env={
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "YORHA_TEST_SLEEP_LOG": str(sleep_log),
            },
        )
        self.assertEqual(result.returncode, 75)
        self.assertIn("appearance lock timeout", result.stderr)
        self.assertEqual(self.call_argvs(), [])
        self.assertTrue(self.lock.is_dir())
        self.assertEqual(len(sleep_log.read_text().splitlines()), 99)

    def write_signaling_mkdir(self, exit_code):
        fake_bin = Path(self.tempdir.name) / f"fake-mkdir-{exit_code}"
        fake_bin.mkdir()
        mkdir_body = "\n".join(
            [
                "#!/usr/bin/env bash",
                'if [ "$1" = "$YORHA_TEST_LOCK_PATH" ]; then',
                '  /bin/mkdir "$1" 2>/dev/null || true',
                '  kill -INT "$PPID"',
                f"  exit {exit_code}",
                "fi",
                'exec /bin/mkdir "$@"',
                "",
            ]
        )
        (fake_bin / "mkdir").write_text(mkdir_body)
        (fake_bin / "mkdir").chmod(0o755)
        return {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "YORHA_TEST_LOCK_PATH": str(self.lock),
        }

    def write_ordered_signaling_mkdir(self, exit_code, signals):
        bash_env = Path(self.tempdir.name) / f"signal-mkdir-{exit_code}.bash"
        signal_commands = "\n".join(
            f'  builtin kill -{signal_name} "$$"' for signal_name in signals
        )
        bash_env.write_text(
            "mkdir() {\n"
            '  /bin/mkdir "$@" 2>/dev/null || true\n'
            f"{signal_commands}\n"
            f"  return {exit_code}\n"
            "}\n"
        )
        return {"BASH_ENV": str(bash_env)}

    def test_signal_after_successful_mkdir_before_ownership_cleans_our_lock(self):
        result = self.run_apply("dark", extra_env=self.write_signaling_mkdir(exit_code=0))
        self.assertEqual(result.returncode, 130)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])

    def test_signal_after_failed_mkdir_preserves_foreign_lock(self):
        self.lock.mkdir()
        result = self.run_apply("dark", extra_env=self.write_signaling_mkdir(exit_code=1))
        self.assertEqual(result.returncode, 130)
        self.assertTrue(self.lock.is_dir())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])

    def test_first_signal_wins_during_successful_mkdir_boundary(self):
        result = self.run_apply(
            "dark",
            extra_env=self.write_ordered_signaling_mkdir(
                exit_code=0, signals=("INT", "TERM")
            ),
        )
        self.assertEqual(result.returncode, 130)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])

    def test_first_signal_wins_during_failed_mkdir_boundary(self):
        self.lock.mkdir()
        result = self.run_apply(
            "dark",
            extra_env=self.write_ordered_signaling_mkdir(
                exit_code=1, signals=("TERM", "INT")
            ),
        )
        self.assertEqual(result.returncode, 143)
        self.assertTrue(self.lock.is_dir())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])

    def test_printf_failure_removes_temporary_marker_and_preserves_prior_mode(self):
        self.assertEqual(self.run_apply("light").returncode, 0)
        bash_env = Path(self.tempdir.name) / "fail-printf.bash"
        bash_env.write_text(
            "printf() {\n"
            "  if [ \"$#\" -eq 2 ] && [ \"$1\" = '%s\\n' ] && [ \"$2\" = dark ]; then\n"
            "    return 1\n"
            "  fi\n"
            "  builtin printf \"$@\"\n"
            "}\n"
        )
        failed = self.run_apply("dark", extra_env={"BASH_ENV": str(bash_env)})
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "light")
        self.assertEqual(list(self.appearance_root.glob(".last-successful-mode.*")), [])

    def test_marker_replacement_failure_keeps_previous_marker_visible(self):
        self.assertEqual(self.run_apply("light").returncode, 0)
        fake_bin = Path(self.tempdir.name) / "fake-bin"
        fake_bin.mkdir()
        (fake_bin / "mv").write_text("#!/usr/bin/env bash\nexit 1\n")
        (fake_bin / "mv").chmod(0o755)
        failed = self.run_apply(
            "dark", extra_env={"PATH": f"{fake_bin}:{os.environ['PATH']}"}
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "light")
        self.assertEqual(list(self.appearance_root.glob(".last-successful-mode.*")), [])

    def assert_parent_only_signal_exits_promptly(self, signum, expected_status):
        child_pid_file = Path(self.tempdir.name) / "child.pid"
        extra_env = self.write_long_running_sketchybar(child_pid_file)
        env = os.environ | {
            "YORHA_APPEARANCE_ROOT": str(self.appearance_root),
            "YORHA_SKETCHYBAR_BIN": str(self.sketchybar),
            "YORHA_TEST_CALL_LOG": str(self.call_log),
        } | extra_env
        process = subprocess.Popen([str(SCRIPT), "dark"], env=env)
        try:
            deadline = time.monotonic() + 2
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.lock.exists())
            self.assertTrue(child_pid_file.exists())
            started = time.monotonic()
            process.send_signal(signum)
            self.assertEqual(process.wait(timeout=2), expected_status)
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertFalse(self.lock.exists())
            self.assertFalse(self.state.exists())
            self.assertEqual(list(self.appearance_root.glob(".last-successful-mode.*")), [])
            child_pid = int(child_pid_file.read_text().strip())
            child_deadline = time.monotonic() + 1
            while time.monotonic() < child_deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                self.fail(f"SketchyBar child {child_pid} survived the parent-only signal")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)
            if child_pid_file.exists():
                child_pid = int(child_pid_file.read_text().strip())
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_parent_only_sigint_terminates_child_cleans_lock_and_exits_130(self):
        self.assert_parent_only_signal_exits_promptly(signal.SIGINT, 130)

    def test_parent_only_sigterm_terminates_child_cleans_lock_and_exits_143(self):
        self.assert_parent_only_signal_exits_promptly(signal.SIGTERM, 143)

    def test_coordinator_has_no_wallpaper_or_manifest_pipeline(self):
        text = (ROOT / "bin/apply-appearance.sh").read_text().lower()
        for forbidden in (
            "osascript", "wallpaperagent", "wallpaper_", "assets.env", "chrome",
            "regenerate-system-wallpaper", "übersicht", "ubersicht", "manifest",
            "heic", "ghostty",
        ):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
