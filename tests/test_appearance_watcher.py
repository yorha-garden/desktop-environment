import os
import plistlib
import select
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "bin" / "appearance-watcher.swift"
PLIST = ROOT / "launchd" / "com.yorha.appearance-watcher.plist"


class AppearanceWatcherIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tempdir = tempfile.TemporaryDirectory()
        cls.temp = Path(cls.tempdir.name)
        cls.binaries = {}
        for name, flags in (("normal", ()), ("optimized", ("-O",))):
            binary = cls.temp / f"appearance-watcher-{name}"
            subprocess.run(
                ["swiftc", *flags, str(SOURCE), "-o", str(binary)],
                check=True,
                capture_output=True,
                text=True,
            )
            cls.binaries[name] = binary

    @classmethod
    def tearDownClass(cls):
        cls.tempdir.cleanup()

    def setUp(self):
        self.case_dir = Path(tempfile.mkdtemp(dir=self.temp))
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=1)
        shutil.rmtree(self.case_dir)

    def write_coordinator(self, body):
        path = self.case_dir / "coordinator"
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def start_watcher(self, binary, coordinator, extra_env=None):
        env = os.environ | {"YORHA_TEST_ARG_FILE": str(self.case_dir / "argv")}
        if extra_env:
            env.update(extra_env)
        process = subprocess.Popen(
            [str(binary), str(coordinator)],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        return process

    def wait_for_path(self, path, process, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return
            if process.poll() is not None:
                self.fail(f"watcher exited early with {process.returncode}")
            time.sleep(0.01)
        self.fail(f"timed out waiting for {path}")

    def read_until(self, stream, expected, timeout=2):
        deadline = time.monotonic() + timeout
        received = b""
        while time.monotonic() < deadline:
            ready, _, _ = select.select([stream], [], [], 0.05)
            if ready:
                received += os.read(stream.fileno(), 4096)
                if expected in received:
                    return received
        self.fail(f"timed out waiting for {expected!r}; got {received!r}")

    def test_production_global_initializer_starts_normal_and_optimized_binaries(self):
        coordinator = self.write_coordinator(
            'printf "%s\\n" "$#" > "$YORHA_TEST_ARG_FILE"\n'
            'printf "%s\\n" "$1" >> "$YORHA_TEST_ARG_FILE"\n'
        )
        for build, binary in self.binaries.items():
            with self.subTest(build=build):
                arg_file = self.case_dir / "argv"
                arg_file.unlink(missing_ok=True)
                process = self.start_watcher(binary, coordinator)
                self.wait_for_path(arg_file, process)
                self.assertIsNone(process.poll())
                self.assertEqual(arg_file.read_text().splitlines()[0], "1")
                self.assertIn(arg_file.read_text().splitlines()[1], ("light", "dark"))

    def test_invalid_coordinator_arguments_exit_64(self):
        non_executable = self.case_dir / "not-executable"
        non_executable.write_text("#!/usr/bin/env bash\n")
        coordinator = self.write_coordinator("exit 0\n")
        cases = (
            (),
            (str(coordinator), "extra"),
            ("relative-coordinator",),
            (str(non_executable),),
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(self.binaries["normal"]), *arguments],
                    capture_output=True,
                    text=True,
                    timeout=2,
                    check=False,
                )
                self.assertEqual(result.returncode, 64)

    def test_child_stdout_and_stderr_are_inherited_without_stopping_watcher(self):
        coordinator = self.write_coordinator(
            'printf "%s\\n" "$1" > "$YORHA_TEST_ARG_FILE"\n'
            'printf "child stdout\\n"\n'
            'printf "child stderr\\n" >&2\n'
        )
        process = self.start_watcher(self.binaries["normal"], coordinator)
        self.wait_for_path(self.case_dir / "argv", process)
        self.assertIn(b"child stdout", self.read_until(process.stdout, b"child stdout"))
        self.assertIn(b"child stderr", self.read_until(process.stderr, b"child stderr"))
        self.assertIsNone(process.poll())

    def test_nonzero_coordinator_exit_is_logged_and_watcher_stays_alive(self):
        coordinator = self.write_coordinator(
            'printf "child stderr\\n" >&2\n'
            "exit 7\n"
        )
        process = self.start_watcher(self.binaries["normal"], coordinator)
        self.assertIn(
            b"appearance watcher: coordinator exited 7",
            self.read_until(process.stderr, b"appearance watcher: coordinator exited 7"),
        )
        self.assertIsNone(process.poll())

    def test_launch_failure_is_logged_and_watcher_stays_alive(self):
        coordinator = self.case_dir / "broken-launch"
        coordinator.write_text("#!/missing-interpreter\n")
        coordinator.chmod(0o755)
        process = self.start_watcher(self.binaries["normal"], coordinator)
        self.assertIn(
            b"appearance watcher: coordinator failed:",
            self.read_until(process.stderr, b"appearance watcher: coordinator failed:"),
        )
        self.assertIsNone(process.poll())

    def test_launch_agent_plist_has_the_watcher_contract(self):
        with PLIST.open("rb") as plist_file:
            values = plistlib.load(plist_file)
        self.assertEqual(values["Label"], "com.yorha.appearance-watcher")
        self.assertEqual(
            values["ProgramArguments"],
            [
                "HOME_PATH/.config/yorha/bin/yorha-appearance-watcher",
                "HOME_PATH/.config/yorha/bin/apply-appearance.sh",
            ],
        )
        self.assertTrue(values["RunAtLoad"])
        self.assertTrue(values["KeepAlive"])
        self.assertEqual(values["ProcessType"], "Background")
        self.assertEqual(
            values["StandardOutPath"],
            "HOME_PATH/.config/yorha/logs/appearance.log",
        )
        self.assertEqual(
            values["StandardErrorPath"],
            "HOME_PATH/.config/yorha/logs/appearance.log",
        )
