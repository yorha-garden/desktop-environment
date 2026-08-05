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
        self.appearance_root = Path(self.tempdir.name) / "appearance"
        self.appearance_root.mkdir()
        self.light_crest = self.appearance_root / "yorha-icon-light.png"
        self.dark_crest = self.appearance_root / "yorha-icon-dark.png"
        self.light_crest.touch()
        self.dark_crest.touch()
        self.state = self.appearance_root / "last-successful-mode"
        self.lock = self.appearance_root / "apply.lock"
        self.call_log = Path(self.tempdir.name) / "sketchybar-calls.log"
        self.sketchybar = Path(self.tempdir.name) / "sketchybar"
        self.write_sketchybar()

    def tearDown(self):
        self.tempdir.cleanup()

    def write_sketchybar(self, exit_code=0):
        self.sketchybar.write_text(
            "#!/usr/bin/env bash\n"
            'printf \'sketchybar\\t%s\\n\' "$*" >> "$YORHA_TEST_CALL_LOG"\n'
            f"exit {exit_code}\n"
        )
        self.sketchybar.chmod(0o755)

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

    def calls(self):
        if not self.call_log.exists():
            return []
        return self.call_log.read_text().splitlines()

    def test_invalid_mode_changes_nothing(self):
        result = self.run_apply("sepia")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_extra_arguments_are_rejected(self):
        result = self.run_apply("light", "--force", "unexpected")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_dark_applies_dark_assets_and_colors_once(self):
        result = self.run_apply("dark")
        calls = "\n".join(self.calls())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
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
        self.assertFalse(self.state.exists())

    def test_existing_lock_times_out_without_invoking_sketchybar(self):
        self.lock.mkdir()
        fake_bin = Path(self.tempdir.name) / "fake-bin"
        fake_bin.mkdir()
        sleep_log = Path(self.tempdir.name) / "sleep-calls.log"
        (fake_bin / "sleep").write_text(
            "#!/usr/bin/env bash\n"
            'printf \'sleep\\t%s\\n\' "$*" >> "$YORHA_TEST_SLEEP_LOG"\n'
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
        self.assertEqual(self.calls(), [])
        self.assertTrue(self.lock.is_dir())
        self.assertEqual(len(sleep_log.read_text().splitlines()), 99)

    def test_interrupt_cleans_lock_and_does_not_apply_state(self):
        self.sketchybar.write_text(
            "#!/usr/bin/env bash\n"
            "trap 'exit 130' INT TERM\n"
            "sleep 30\n"
        )
        self.sketchybar.chmod(0o755)
        env = os.environ | {
            "YORHA_APPEARANCE_ROOT": str(self.appearance_root),
            "YORHA_SKETCHYBAR_BIN": str(self.sketchybar),
            "YORHA_TEST_CALL_LOG": str(self.call_log),
        }
        process = subprocess.Popen(
            [str(SCRIPT), "dark"], env=env, start_new_session=True
        )
        deadline = time.monotonic() + 2
        while not self.lock.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(self.lock.exists())
        os.killpg(process.pid, signal.SIGINT)
        self.assertEqual(process.wait(timeout=2), 130)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.state.exists())

    def test_coordinator_has_no_wallpaper_or_manifest_pipeline(self):
        text = (ROOT / "bin/apply-appearance.sh").read_text().lower()
        for forbidden in (
            "osascript", "wallpaperagent", "wallpaper_", "assets.env", "chrome",
            "regenerate-system-wallpaper", "übersicht", "ubersicht",
        ):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
