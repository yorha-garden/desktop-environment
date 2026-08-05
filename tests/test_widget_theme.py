import unittest
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
W = ROOT / "widgets/yorha"
CONSUMERS = ["hud.jsx", "pod.jsx", "arcs.jsx", "beam.jsx"]


class WidgetThemeTests(unittest.TestCase):
    def test_provider(self):
        text = (W / "theme.jsx").read_text()
        self.assertIn("export const refreshFrequency = false", text)
        self.assertNotIn("export const command", text)
        self.assertNotIn("<div", text)
        self.assertRegex(text, r"export const render = \(\) => <style>")
        self.assertIn("width:0;height:0;pointer-events:none", text)
        self.assertIn("@media (prefers-color-scheme: dark)", text)
        for declaration in (
            "--yorha-field:#CAC5B0", "--yorha-text:#4A4741",
            "--yorha-value:#4A4741", "--yorha-panel:rgba(214,210,193,.5)",
            "--yorha-ornament:#4A4741", "--yorha-track:rgba(74,71,65,.18)",
            "--yorha-accent:#BC9A5A", "--yorha-alert:#BB3B36",
            "--yorha-field:#16161A", "--yorha-text:#D8D4C4",
            "--yorha-value:#EFEBDB", "--yorha-panel:rgba(58,58,64,.72)",
            "--yorha-ornament:#6E7B8B", "--yorha-track:rgba(216,212,196,.18)",
        ):
            self.assertIn(declaration, text)
        self.assertNotIn("#3A3A40", text)

    def test_consumers_use_fallbacks(self):
        for name in CONSUMERS:
            text = (W / name).read_text()
            self.assertRegex(text, r"var\(--yorha-[a-z-]+,\s*(?:#|rgba\()", name)
            self.assertNotIn("AppleInterfaceStyle", text, name)

    def test_svg_strokes_follow_current_color(self):
        text = (W / "arcs.jsx").read_text()
        self.assertNotIn('stroke="#4A4741"', text)
        self.assertIn('stroke="currentColor"', text)

    def test_pod_preserves_light_borders_and_themes_dark_borders(self):
        text = (W / "pod.jsx").read_text()
        self.assertIn("--yorha-pod-border:rgba(74,71,65,.45)", text)
        self.assertIn("--yorha-pod-rule:rgba(74,71,65,.3)", text)
        self.assertIn("border: 1px solid var(--yorha-pod-border)", text)
        self.assertIn("border-bottom: 1px solid var(--yorha-pod-rule)", text)
        self.assertIn("transition: border-color 200ms ease", text)
        self.assertRegex(text, r"(?s)@media \(prefers-color-scheme: dark\).*--yorha-pod-border")

    def test_beam_preserves_light_surface_and_overrides_dark_rgb(self):
        text = (W / "beam.jsx").read_text()
        self.assertIn("--yorha-beam-rgb:74,71,65", text)
        self.assertIn("--yorha-beam-surface-rgb:214,210,193", text)
        self.assertIn("rgba(var(--yorha-beam-surface-rgb),.07) 55%", text)
        self.assertIn("--yorha-beam-rgb:110,123,139", text)
        self.assertIn("--yorha-beam-surface-rgb:58,58,64", text)

    def test_appearance_transitions_and_motion_contracts(self):
        for name in CONSUMERS:
            text = (W / name).read_text()
            for transition in re.findall(r"transition:\s*([^;]+)", text):
                for property_timing in transition.split(","):
                    if "200ms" in property_timing:
                        self.assertRegex(
                            property_timing.strip(),
                            r"^(?:color|background|border|border-color|stroke)\s+200ms\s+ease$",
                            name,
                        )
        self.assertIn("animation: bootIn", (W / "hud.jsx").read_text())
        pod = (W / "pod.jsx").read_text()
        self.assertIn("animation: type 1.6s", pod)
        self.assertIn("@media (prefers-reduced-motion: reduce)", pod)
        self.assertIn(".pod-msg, .pod-msg-inner, .pod-enter { animation: none !important; }", pod)
        arcs = (W / "arcs.jsx").read_text()
        for declaration in (".arc-breathe { animation: none; }", ".arc-draw { animation: none; }", ".arc-wave { animation: none; }"):
            self.assertIn(declaration, arcs)
        beam = (W / "beam.jsx").read_text()
        self.assertIn("@media (prefers-reduced-motion: reduce) { .beam { animation: none; opacity: 0; } }", beam)
