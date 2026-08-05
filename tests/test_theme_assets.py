import hashlib, json, re, struct, subprocess, unittest, xml.etree.ElementTree as ET
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def palette():
    text = (ROOT / "config/shell/palette.sh").read_text()
    return dict(re.findall(r"^export YORHA_([A-Z_]+)=([0-9A-F]{6})$", text, re.M))

def png_ihdr(path):
    raw = path.read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">IIBB", raw[16:26])

class ThemeAssetTests(unittest.TestCase):
    def test_terminal_native_tokens(self):
        self.assertEqual(palette()["BRIGHT"], "EFEBDB")
        self.assertEqual(palette()["STEEL"], "6E7B8B")

    def test_wallpaper_sources(self):
        roots = [ET.parse(ROOT / p).getroot() for p in
                 ("assets/wallpaper.svg", "assets/wallpaper-dark.svg")]
        for root in roots:
            self.assertEqual((root.attrib["width"], root.attrib["height"]), ("5120", "2880"))
        dark = (ROOT / "assets/wallpaper-dark.svg").read_text().upper()
        self.assertIn("#16161A", dark)
        self.assertIn("#6E7B8B", dark)

    def test_crest_variants(self):
        for name in ("yorha-icon-light.png", "yorha-icon-dark.png"):
            self.assertEqual(png_ihdr(ROOT / "assets" / name), (31, 36, 8, 6))

    def test_system_wallpaper_has_appearance_variants(self):
        result = subprocess.run(
            ["swift", str(ROOT / "bin/yorha-system-wallpaper.swift"), "--inspect",
             str(ROOT / "assets/yorha-system.heic")],
            check=True, text=True, capture_output=True)
        self.assertEqual(json.loads(result.stdout), {
            "frameCount": 2,
            "frames": [[5120, 2880], [5120, 2880]],
            "appearance": {"l": 0, "d": 1},
        })

    def test_normal_wallpaper_consumer_keeps_chrome_developer_only(self):
        consumer = (ROOT / "bin/make-wallpaper.sh").read_text()
        regenerator = (ROOT / "bin/regenerate-system-wallpaper.sh").read_text()
        self.assertNotIn("Chrome", consumer)
        self.assertNotIn("regenerate-system-wallpaper", consumer)
        self.assertRegex(regenerator, r'"\$1"\s*=\s*"--with-chrome"')
        self.assertLess(regenerator.index('"--with-chrome"'),
                        regenerator.index('"$CHROME" --headless'))

    def test_verification_does_not_modify_committed_heic(self):
        wallpaper = ROOT / "assets/yorha-system.heic"
        before = hashlib.sha256(wallpaper.read_bytes()).digest()
        subprocess.run([str(ROOT / "bin/make-wallpaper.sh"), "--verify"], check=True)
        self.assertEqual(hashlib.sha256(wallpaper.read_bytes()).digest(), before)
