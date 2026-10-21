import base64
import os
import plistlib
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
        result = subprocess.run([str(binary), str(ROOT)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("desktop tests passed", result.stdout)

    def test_embedded_crest_is_the_dark_asset(self):
        source = (ROOT / "native" / "YoRHaDesktop" / "BarCrest.swift").read_text()
        encoded = source.split('"""')[1]
        embedded = base64.b64decode("".join(encoded.split()))
        self.assertEqual(embedded, (ROOT / "assets" / "yorha-icon-dark.png").read_bytes())

    def test_bar_wording_matches_date_under_launchd(self):
        probe_dir = self.temp / "bar-probe"
        probe_dir.mkdir(exist_ok=True)
        (probe_dir / "main.swift").write_text(
            'import Foundation\n'
            'let now = Date()\n'
            'print(BarFormat.day(now), BarFormat.clock(now), separator: "|")\n'
        )
        binary = probe_dir / "probe"
        library = [str(s) for s in SOURCES if s.name != "main.swift"]
        subprocess.run(
            ["swiftc", *library, str(probe_dir / "main.swift"), "-o", str(binary)],
            check=True, capture_output=True, text=True,
        )
        # SketchyBar ran its `date` scripts under launchd, which sets no locale; a
        # different user locale must not change the bar either.
        env = {**os.environ, "LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8"}
        for attempt in range(3):   # a minute boundary between the two readings is a retry
            native = subprocess.run([str(binary)], capture_output=True, text=True, check=True,
                                    env=env).stdout.strip()
            shell = subprocess.run(
                ["/bin/bash", "-c", "echo \"$(date '+%a %d %b' | tr '[:lower:]' '[:upper:]')|$(date '+%H.%M')\""],
                capture_output=True, text=True, check=True, env={**os.environ, "LC_ALL": "C"},
            ).stdout.strip()
            if native == shell:
                break
        self.assertEqual(native, shell)

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

    def test_launch_agent_runs_installed_binary_with_keepalive(self):
        raw = (ROOT / "launchd" / "com.yorha.desktop.plist").read_bytes()
        data = plistlib.loads(raw.replace(b"HOME_PATH", b"/Users/test"))
        self.assertEqual(data["Label"], "com.yorha.desktop")
        self.assertEqual(data["ProgramArguments"], ["/Users/test/.config/yorha/bin/yorha-desktop"])
        self.assertTrue(data["RunAtLoad"] and data["KeepAlive"])
        self.assertEqual(data["LimitLoadToSessionType"], "Aqua")
        self.assertEqual(data["StandardErrorPath"], "/Users/test/.config/yorha/logs/yorha-desktop.log")

    def install_sandbox(self, disabled=False):
        sandbox = Path(tempfile.mkdtemp(dir=self.temp))
        home, fake_bin, log = sandbox / "home with space", sandbox / "bin", sandbox / "calls.log"
        home.mkdir()
        fake_bin.mkdir()
        old = home / "Library" / "LaunchAgents" / "com.yorha.ubersicht-watchdog.plist"
        old.parent.mkdir(parents=True)
        old.write_text("old")
        disabled_line = '"com.yorha.desktop" => disabled' if disabled else ""
        for name, body in {
            "launchctl": f'echo "launchctl $*" >> "$CALLS"\n'
                         f'[ "$1" = print-disabled ] && echo \'{disabled_line}\'\n'
                         f'[ "$1" = print ] && exit 1\nexit 0\n',
            "osascript": 'echo "osascript $*" >> "$CALLS"\nexit 0\n',
        }.items():
            (fake_bin / name).write_text("#!/bin/bash\n" + body)
            (fake_bin / name).chmod(0o755)
        env = {**os.environ, "HOME": str(home), "CALLS": str(log),
               "PATH": f"{fake_bin}:{os.environ['PATH']}"}
        result = subprocess.run([str(ROOT / "bin" / "install-desktop.sh")], env=env,
                                capture_output=True, text=True, timeout=300)
        return result, home, log.read_text() if log.exists() else ""

    def test_installer_builds_installs_loads_and_retires_ubersicht(self):
        result, home, calls = self.install_sandbox()
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = home / ".config/yorha/bin/yorha-desktop"
        self.assertTrue(binary.exists() and os.access(binary, os.X_OK))
        self.assertEqual(list(binary.parent.glob("*.tmp.*")), [])
        plist = plistlib.loads((home / "Library/LaunchAgents/com.yorha.desktop.plist").read_bytes())
        self.assertEqual(plist["ProgramArguments"], [str(binary)])
        self.assertIn("launchctl bootstrap", calls)
        self.assertIn("com.yorha.ubersicht-watchdog", calls)
        self.assertFalse((home / "Library/LaunchAgents/com.yorha.ubersicht-watchdog.plist").exists())
        self.assertIn('quit app id "tracesOf.Uebersicht"', calls)
        self.assertIn("loaded", result.stdout)

    def test_installer_leaves_a_switched_off_layer_unloaded(self):
        result, home, calls = self.install_sandbox(disabled=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((home / ".config/yorha/bin/yorha-desktop").exists())
        self.assertNotIn("launchctl bootstrap", calls)
        self.assertIn("switched off", result.stdout)

    def test_build_script_compiles_optimized_app_without_warnings(self):
        binary = self.temp / "yorha-desktop"
        result = subprocess.run([str(BUILD), str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning:", result.stderr)
        self.assertTrue(binary.exists())

    def test_app_stays_running_with_a_bar_at_sketchybar_level(self):
        binary = self.temp / "yorha-desktop-smoke"
        subprocess.run([str(BUILD), str(binary)], check=True, capture_output=True, text=True)
        windows = self.temp / "windows"
        (self.temp / "windows.swift").write_text(
            'import AppKit\n'
            'let pid = Int(CommandLine.arguments[1])!\n'
            'let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]\n'
            'for w in list where w[kCGWindowOwnerPID as String] as? Int == pid {\n'
            '    let b = w[kCGWindowBounds as String] as! [String: Any]\n'
            '    print(w[kCGWindowLayer as String]!, b["Width"]!, b["Height"]!)\n'
            '}\n'
            'for s in NSScreen.screens { print("screen", Int(s.frame.width)) }\n'
        )
        subprocess.run(["swiftc", str(self.temp / "windows.swift"), "-o", str(windows)],
                       check=True, capture_output=True, text=True)
        process = subprocess.Popen(
            [str(binary), "--appearance", "dark"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            time.sleep(1.5)
            self.assertIsNone(process.poll(), process.stderr.read() if process.poll() else "")
            lines = subprocess.run([str(windows), str(process.pid)], capture_output=True,
                                   text=True, check=True).stdout.split("\n")
            screens = [l.split()[1] for l in lines if l.startswith("screen")]
            self.assertTrue(screens)
            # one 32 pt bar per screen, at SketchyBar's backstop-menu level
            bars = [l.split()[1] for l in lines if l.split()[:1] == ["-20"] and l.split()[2] == "32"]
            self.assertEqual(sorted(bars), sorted(screens))
        finally:
            process.terminate()
            process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
