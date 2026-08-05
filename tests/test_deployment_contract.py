import plistlib, re, unittest
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
        self.assertIn('temporary="${destination}.tmp.$$"', body)
        self.assertLess(body.index('cp "$source" "$temporary"'),
                        body.index('mv "$temporary" "$destination"'))
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
        self.assertRegex(block, r'swiftc -O .*appearance-watcher\.swift" -o "\$WATCHER_TMP"')
        self.assertLess(block.index('swiftc -O '),
                        block.index('mv "$WATCHER_TMP" "$RUNTIME_WATCHER"'))
        self.assertEqual(block.count('launchctl bootstrap "gui/$(id -u)" "$APPEARANCE_PLIST"'), 1)
        self.assertEqual(block.count('"$RUNTIME_COORDINATOR" "$MODE" --force'), 1)

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
