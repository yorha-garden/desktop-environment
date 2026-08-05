import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
W = ROOT / "widgets/yorha"
CONSUMERS = ["hud.jsx", "pod.jsx", "arcs.jsx", "beam.jsx"]


class WidgetThemeTests(unittest.TestCase):
    def test_provider(self):
        text = (W / "theme.jsx").read_text()
        self.assertIn("export const refreshFrequency = false", text)
        self.assertNotIn("export const command", text)
        self.assertIn("@media (prefers-color-scheme: dark)", text)
        for token in ("field", "text", "value", "panel", "ornament", "track", "accent", "alert"):
            self.assertGreaterEqual(text.count(f"--yorha-{token}"), 2)
        for color in ("#CAC5B0", "#4A4741", "#16161A",
                      "#D8D4C4", "#EFEBDB", "#3A3A40", "#6E7B8B",
                      "#BC9A5A", "#BB3B36"):
            self.assertIn(color, text)
        self.assertIn("rgba(214,210,193,.5)", text)

    def test_consumers_use_fallbacks(self):
        for name in CONSUMERS:
            text = (W / name).read_text()
            self.assertRegex(text, r"var\(--yorha-[a-z-]+,\s*(?:#|rgba\()", name)
            self.assertNotIn("AppleInterfaceStyle", text, name)

    def test_svg_strokes_follow_current_color(self):
        text = (W / "arcs.jsx").read_text()
        self.assertNotIn('stroke="#4A4741"', text)
        self.assertIn('stroke="currentColor"', text)
