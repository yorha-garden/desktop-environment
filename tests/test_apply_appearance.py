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

    def process_start_identity(self, pid):
        return subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            check=True, text=True, capture_output=True,
        ).stdout.strip()

    def write_lock_owner(self, pid, start_identity, token="foreign-owner"):
        self.lock.write_text(
            f"pid\t{pid}\nstart\t{start_identity}\ntoken\t{token}\n"
        )

    def fast_sleep_env(self):
        fake_bin = Path(self.tempdir.name) / "fast-sleep-bin"
        fake_bin.mkdir(exist_ok=True)
        sleep = fake_bin / "sleep"
        sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
        sleep.chmod(0o755)
        return {"PATH": f"{fake_bin}:{os.environ['PATH']}"}

    def wait_for_path(self, path, process, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                self.fail(
                    f"coordinator exited early ({process.returncode}): "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )
            time.sleep(0.01)
        self.fail(f"timed out waiting for {path}")

    def start_apply(self, mode, extra_env=None):
        env = os.environ | {
            "YORHA_APPEARANCE_ROOT": str(self.appearance_root),
            "YORHA_SKETCHYBAR_BIN": str(self.sketchybar),
            "YORHA_TEST_CALL_LOG": str(self.call_log),
        }
        if extra_env:
            env.update(extra_env)
        return subprocess.Popen(
            [str(SCRIPT), mode], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def write_holding_sketchybar(self, light_started, release_light):
        self.sketchybar.write_text(
            "#!/usr/bin/env bash\n"
            "printf '\\036' >> \"$YORHA_TEST_CALL_LOG\"\n"
            "printf '%s\\0' \"$@\" >> \"$YORHA_TEST_CALL_LOG\"\n"
            "case \"$*\" in\n"
            "  *yorha-icon-light.png*)\n"
            '    : > "$YORHA_TEST_LIGHT_STARTED"\n'
            '    while [ ! -f "$YORHA_TEST_RELEASE_LIGHT" ]; do '
            "/bin/sleep 0.01; done\n"
            "    ;;\n"
            "esac\n"
        )
        self.sketchybar.chmod(0o755)
        return {
            "YORHA_TEST_LIGHT_STARTED": str(light_started),
            "YORHA_TEST_RELEASE_LIGHT": str(release_light),
        }

    def write_pausing_publication_tools(self, ready, release):
        fake_bin = Path(self.tempdir.name) / "pause-publication-bin"
        fake_bin.mkdir()
        pause_marker = Path(self.tempdir.name) / "publication-paused-once"
        (fake_bin / "mkdir").write_text(r'''#!/usr/bin/env bash
if [ "$1" = "$YORHA_TEST_LOCK_PATH" ]; then
  /bin/mkdir "$@"
  status=$?
  if [ "$status" -eq 0 ] && [ ! -e "$YORHA_TEST_PAUSE_MARKER" ]; then
    : > "$YORHA_TEST_PAUSE_MARKER"
    : > "$YORHA_TEST_PUBLICATION_READY"
    while [ ! -e "$YORHA_TEST_PUBLICATION_RELEASE" ]; do /bin/sleep 0.01; done
  fi
  exit "$status"
fi
exec /bin/mkdir "$@"
''')
        (fake_bin / "ln").write_text(r'''#!/usr/bin/env bash
destination="${!#}"
if [ "$destination" = "$YORHA_TEST_LOCK_PATH" ] \
    && [ ! -e "$YORHA_TEST_PAUSE_MARKER" ]; then
  : > "$YORHA_TEST_PAUSE_MARKER"
  : > "$YORHA_TEST_PUBLICATION_READY"
  while [ ! -e "$YORHA_TEST_PUBLICATION_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec /bin/ln "$@"
''')
        (fake_bin / "shlock").write_text(r'''#!/usr/bin/env bash
if [ ! -e "$YORHA_TEST_PAUSE_MARKER" ]; then
  : > "$YORHA_TEST_PAUSE_MARKER"
  : > "$YORHA_TEST_PUBLICATION_READY"
  while [ ! -e "$YORHA_TEST_PUBLICATION_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec /usr/bin/shlock "$@"
''')
        (fake_bin / "sleep").write_text("#!/usr/bin/env bash\nexit 0\n")
        for tool in ("mkdir", "ln", "shlock", "sleep"):
            (fake_bin / tool).chmod(0o755)
        return {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "YORHA_TEST_LOCK_PATH": str(self.lock),
            "YORHA_TEST_PAUSE_MARKER": str(pause_marker),
            "YORHA_TEST_PUBLICATION_READY": str(ready),
            "YORHA_TEST_PUBLICATION_RELEASE": str(release),
            "YORHA_SHLOCK_BIN": str(fake_bin / "shlock"),
        }

    def lock_snapshot(self):
        owner = self.lock / "owner" if self.lock.is_dir() else self.lock
        stat = owner.stat()
        return (stat.st_dev, stat.st_ino, owner.read_bytes())

    def assert_no_internal_lock_residue(self):
        self.assertFalse((self.appearance_root / ".apply.lock.guard").exists())
        self.assertEqual(
            list(self.appearance_root.glob(".apply.lock.candidate.*")), []
        )

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
        self.lock.touch()
        future = time.time() + 60
        os.utime(self.lock, (future, future))
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
        self.assertTrue(self.lock.is_file())
        self.assertEqual(len(sleep_log.read_text().splitlines()), 99)

    def test_active_lock_owner_is_never_reclaimed(self):
        self.write_lock_owner(os.getpid(), self.process_start_identity(os.getpid()))
        result = self.run_apply("dark", extra_env=self.fast_sleep_env())
        self.assertEqual(result.returncode, 75)
        self.assertTrue(self.lock.is_file())
        self.assertEqual(self.call_argvs(), [])

    def test_dead_and_reused_pid_lock_owners_are_reclaimed(self):
        cases = (
            (999999, "dead process"),
            (os.getpid(), "identity from a prior use of this pid"),
        )
        for pid, start_identity in cases:
            with self.subTest(pid=pid, start_identity=start_identity):
                self.lock.unlink(missing_ok=True)
                self.write_lock_owner(pid, start_identity)
                result = self.run_apply("dark", extra_env=self.fast_sleep_env())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.lock.exists())
                self.state.unlink(missing_ok=True)

    def test_malformed_and_ownerless_stale_locks_are_reclaimed(self):
        for owner in (None, "not owner metadata\n"):
            with self.subTest(owner=owner):
                self.lock.write_text(owner or "")
                os.utime(self.lock, (1, 1))
                result = self.run_apply("light", extra_env=self.fast_sleep_env())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.lock.exists())
                self.state.unlink(missing_ok=True)

    def test_cleanup_never_deletes_a_lock_reowned_by_another_process(self):
        other_pid = os.getpid()
        other_start = self.process_start_identity(other_pid)
        foreign_candidate = Path(self.tempdir.name) / "foreign-lock-candidate"
        foreign_candidate.write_text(
            f"pid\t{other_pid}\nstart\t{other_start}\ntoken\tforeign-owner\n"
        )
        self.sketchybar.write_text(
            "#!/usr/bin/env bash\n"
            '/bin/rm -f "$YORHA_TEST_LOCK_PATH"\n'
            '/bin/ln "$YORHA_TEST_FOREIGN_CANDIDATE" "$YORHA_TEST_LOCK_PATH"\n'
            "exit 9\n"
        )
        self.sketchybar.chmod(0o755)
        result = self.run_apply("dark", extra_env={
            "YORHA_TEST_LOCK_PATH": str(self.lock),
            "YORHA_TEST_FOREIGN_CANDIDATE": str(foreign_candidate),
        })
        self.assertEqual(result.returncode, 9)
        self.assertTrue(self.lock.is_file())
        self.assertTrue(os.path.samefile(self.lock, foreign_candidate))
        self.assertIn("token\tforeign-owner", self.lock.read_text())
        self.assert_no_internal_lock_residue()

    def test_delayed_publisher_never_writes_or_removes_new_owner_lock(self):
        publication_ready = Path(self.tempdir.name) / "publication-ready"
        publication_release = Path(self.tempdir.name) / "publication-release"
        light_started = Path(self.tempdir.name) / "light-started"
        release_light = Path(self.tempdir.name) / "release-light"
        holding_env = self.write_holding_sketchybar(light_started, release_light)
        delayed_env = holding_env | self.write_pausing_publication_tools(
            publication_ready, publication_release
        )
        delayed = self.start_apply("dark", delayed_env)
        holder = None
        try:
            self.wait_for_path(publication_ready, delayed)
            if self.lock.exists():
                os.utime(self.lock, (1, 1))
            holder = self.start_apply("light", holding_env)
            self.wait_for_path(light_started, holder)
            holder_lock = self.lock_snapshot()

            publication_release.touch()
            delayed_stdout, delayed_stderr = delayed.communicate(timeout=10)

            self.assertEqual(delayed.returncode, 75, (
                delayed_stdout, delayed_stderr
            ))
            self.assertEqual(self.lock_snapshot(), holder_lock)
            self.assertEqual(self.call_argvs(), [self.expected_argv("light")])
            self.assertIsNone(holder.poll())
        finally:
            publication_release.touch()
            release_light.touch()
            for process in (delayed, holder):
                if process is not None and process.poll() is None:
                    try:
                        process.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate(timeout=3)
        self.assert_no_internal_lock_residue()

    def test_active_published_owner_survives_beyond_stale_grace(self):
        light_started = Path(self.tempdir.name) / "light-started"
        release_light = Path(self.tempdir.name) / "release-light"
        holding_env = self.write_holding_sketchybar(light_started, release_light)
        holder = self.start_apply("light", holding_env)
        try:
            self.wait_for_path(light_started, holder)
            os.utime(self.lock, (1, 1))
            holder_lock = self.lock_snapshot()

            contender = self.run_apply("dark", extra_env=self.fast_sleep_env())

            self.assertEqual(contender.returncode, 75, contender.stderr)
            self.assertEqual(self.lock_snapshot(), holder_lock)
            self.assertEqual(self.call_argvs(), [self.expected_argv("light")])
            self.assertIsNone(holder.poll())
        finally:
            release_light.touch()
            if holder.poll() is None:
                try:
                    holder.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    holder.kill()
                    holder.communicate(timeout=3)
        self.assertEqual(holder.returncode, 0)
        self.assertFalse(self.lock.exists())
        self.assert_no_internal_lock_residue()

    def write_signaling_publish(self, exit_code):
        fake_bin = Path(self.tempdir.name) / f"fake-ln-{exit_code}"
        fake_bin.mkdir()
        publish_command = (
            '  /bin/ln "$@" 2>/dev/null || true'
            if exit_code == 0
            else '  printf \'foreign lock\\n\' > "$YORHA_TEST_LOCK_PATH"'
        )
        ln_body = "\n".join(
            [
                "#!/usr/bin/env bash",
                'destination="${!#}"',
                'if [ "$destination" = "$YORHA_TEST_LOCK_PATH" ]; then',
                publish_command,
                '  kill -INT "$PPID"',
                f"  exit {exit_code}",
                "fi",
                'exec /bin/ln "$@"',
                "",
            ]
        )
        (fake_bin / "ln").write_text(ln_body)
        (fake_bin / "ln").chmod(0o755)
        return {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "YORHA_TEST_LOCK_PATH": str(self.lock),
        }

    def write_ordered_signaling_publish(self, exit_code, signals):
        fake_bin = Path(self.tempdir.name) / f"signal-ln-{exit_code}"
        fake_bin.mkdir()
        first_signal, second_signal = signals
        signal_commands = "\n".join(
            (
                '  target_pid="$PPID"',
                f'  kill -{first_signal} "$target_pid"',
                "  ( /bin/sleep 0.05; "
                f'kill -{second_signal} "$target_pid" 2>/dev/null || true ) &',
            )
        )
        publish_command = (
            '  /bin/ln "$@" 2>/dev/null || true'
            if exit_code == 0
            else '  printf \'foreign lock\\n\' > "$YORHA_TEST_LOCK_PATH"'
        )
        (fake_bin / "ln").write_text(
            "#!/usr/bin/env bash\n"
            'destination="${!#}"\n'
            'if [ "$destination" = "$YORHA_TEST_LOCK_PATH" ]; then\n'
            f"{publish_command}\n"
            f"{signal_commands}\n"
            f"  exit {exit_code}\n"
            "fi\n"
            'exec /bin/ln "$@"\n'
        )
        (fake_bin / "ln").chmod(0o755)
        return {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "YORHA_TEST_LOCK_PATH": str(self.lock),
        }

    def test_signal_after_successful_publication_cleans_our_lock(self):
        result = self.run_apply(
            "dark", extra_env=self.write_signaling_publish(exit_code=0)
        )
        self.assertEqual(result.returncode, 130)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])
        self.assert_no_internal_lock_residue()

    def test_signal_after_failed_publication_preserves_foreign_lock(self):
        result = self.run_apply(
            "dark", extra_env=self.write_signaling_publish(exit_code=1)
        )
        self.assertEqual(result.returncode, 130)
        self.assertEqual(self.lock.read_text(), "foreign lock\n")
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])
        self.assert_no_internal_lock_residue()

    def test_first_signal_wins_during_successful_publication_boundary(self):
        result = self.run_apply(
            "dark",
            extra_env=self.write_ordered_signaling_publish(
                exit_code=0, signals=("INT", "TERM")
            ),
        )
        self.assertEqual(result.returncode, 130)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])
        self.assert_no_internal_lock_residue()

    def test_first_signal_wins_during_failed_publication_boundary(self):
        result = self.run_apply(
            "dark",
            extra_env=self.write_ordered_signaling_publish(
                exit_code=1, signals=("TERM", "INT")
            ),
        )
        self.assertEqual(result.returncode, 143)
        self.assertEqual(self.lock.read_text(), "foreign lock\n")
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call_argvs(), [])
        self.assert_no_internal_lock_residue()

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
            self.assert_no_internal_lock_residue()
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
