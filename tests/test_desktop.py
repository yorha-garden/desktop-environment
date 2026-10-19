import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted((ROOT / "native" / "YoRHaDesktop").glob("*.swift"))
BUILD = ROOT / "bin" / "build-desktop.sh"


class DesktopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tempdir = tempfile.TemporaryDirectory()
        cls.temp = Path(cls.tempdir.name)

    @classmethod
    def tearDownClass(cls):
        cls.tempdir.cleanup()

    def test_pure_palette_geometry_and_timing(self):
        library = [s for s in SOURCES if s.name != "main.swift"]
        binary = self.temp / "desktop-tests"
        subprocess.run(
            ["swiftc", *map(str, library), str(ROOT / "tests" / "desktop_tests.swift"),
             "-o", str(binary)],
            check=True, capture_output=True, text=True,
        )
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("desktop tests passed", result.stdout)

    def test_native_telemetry_matches_the_shell_tools_it_replaces(self):
        probe_dir = self.temp / "probe"
        probe_dir.mkdir(exist_ok=True)
        (probe_dir / "main.swift").write_text(
            'import Foundation\n'
            'let t = TelemetrySampler().sample()\n'
            'let n = TelemetrySampler.networkBytes()\n'
            'print(t.mem, t.uptime, t.battery.map(String.init) ?? "none", t.onAC,\n'
            '      n?.received ?? 0, n?.sent ?? 0, PodReports.diskFree(), separator: "|")\n'
        )
        binary = probe_dir / "probe"
        library = [str(s) for s in SOURCES if s.name != "main.swift"]
        subprocess.run(
            ["swiftc", *library, str(probe_dir / "main.swift"), "-o", str(binary)],
            check=True, capture_output=True, text=True,
        )

        def shell(command):
            return subprocess.run(["/bin/bash", "-c", command], capture_output=True,
                                  text=True, check=True).stdout.strip()

        for attempt in range(3):   # a minute boundary between the two readings is a retry
            mem, up, battery, on_ac, received, sent, disk = subprocess.run(
                [str(binary)], capture_output=True, text=True, check=True).stdout.strip().split("|")
            shell_up = shell("uptime | awk -F'up ' '{print $2}' "
                             "| sed -E 's/, *[0-9]+ users?,.*//' | tr -s ' ' | sed 's/^ //'")
            if up == shell_up:
                break
        self.assertEqual(up, shell_up)

        shell_mem = int(shell("memory_pressure | awk '/percentage/ {print 100-$5}' | tr -d '%'"))
        self.assertLessEqual(abs(int(mem) - shell_mem), 5)

        pm = shell("pmset -g batt")
        percent = [w.rstrip("%;") for w in pm.split() if w.rstrip(";").endswith("%")]
        self.assertEqual(battery, percent[0] if percent else "none")
        self.assertEqual(on_ac == "true", "AC Power" in pm)

        # Pod disk line: same unit as `df -h /`, value within normal disk churn
        shell_disk = shell("df -h / | awk 'NR==2 {print $4}'")
        unit = lambda s: s.lstrip("0123456789.")
        number = lambda s: float(s[: len(s) - len(unit(s))])
        self.assertEqual(unit(disk), unit(shell_disk))
        self.assertLessEqual(abs(number(disk) - number(shell_disk)), max(1.0, number(shell_disk) * 0.05))

        rx, tx = map(int, shell("netstat -ib | awk '/en0.*Link/{i+=$7;o+=$10} END{print i, o}'").split())
        if rx or tx:
            self.assertLessEqual(abs(int(received) - rx), 50_000_000)
            self.assertLessEqual(abs(int(sent) - tx), 50_000_000)
            self.assertGreater(int(received), 0)

    def test_build_script_compiles_optimized_app_without_warnings(self):
        binary = self.temp / "yorha-desktop"
        result = subprocess.run([str(BUILD), str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning:", result.stderr)
        self.assertTrue(binary.exists())

    def test_app_stays_running_until_terminated(self):
        binary = self.temp / "yorha-desktop-smoke"
        subprocess.run([str(BUILD), str(binary)], check=True, capture_output=True, text=True)
        process = subprocess.Popen(
            [str(binary), "--appearance", "dark"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            time.sleep(1.5)
            self.assertIsNone(process.poll(), process.stderr.read() if process.poll() else "")
        finally:
            process.terminate()
            process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
