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
