"""Synthetic edge regressions; these fixtures are never product screenshots."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from screenshot_alpha import validate
from test_screenshot_alpha import png


@unittest.skipUnless(sys.platform == "darwin", "The native preparation tool uses macOS ImageIO")
class ScreenshotPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="tursora-screenshot-preparation-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(__file__).resolve().parents[2]
        cls.tool = Path(cls.directory.name) / "prepare"
        subprocess.run(["swiftc", "-module-cache-path", str(cls.root / "app/.build/screenshot-tool-module-cache"),
                        str(cls.root / "app/tools/prepare-screenshots.swift"), "-o", str(cls.tool)],
                       check=True, capture_output=True, text=True)

    def capture(self, name, *, light=False, inconsistent=False):
        size, radius = 160, 14
        rows = bytearray()
        for y in range(size):
            rows.append(0)
            for x in range(size):
                xx, yy = min(x, size - 1 - x), min(y, size - 1 - y)
                coverage = sum(1 for j in range(8) for i in range(8)
                               if xx >= radius or yy >= radius
                               or (xx + (i + .5) / 8 - radius) ** 2 + (yy + (j + .5) / 8 - radius) ** 2 <= radius ** 2) / 64
                color = (242, 242, 242) if light else (90, 60, 245) if 7 <= x < 60 and 7 <= y < 21 else (37, 40, 42)
                pixel = [round(coverage * c + (1 - coverage) * 255) for c in color] + [255]
                if inconsistent and (x, y) == (3, 4):
                    pixel = [230, 120, 250, 255]
                rows.extend(pixel)
        source = Path(self.directory.name) / f"{name}.png"
        source.write_bytes(png(size, size, rows))
        output = source.with_name(f"{name}-prepared.png")
        result = subprocess.run([str(self.tool), str(source), str(output), "--describe-stats"],
                                capture_output=True, text=True)
        return result, output

    def test_badge_sample_uses_measured_edge_without_changing_interior(self):
        result, output = self.capture("badge")
        self.assertEqual(result.returncode, 0, result.stderr)
        stats = json.loads(result.stdout)
        self.assertTrue(stats["protectedBytesEqual"])
        self.assertGreater(stats["protectedPixels"], 25_000)
        self.assertGreater(stats["corners"][0]["stableEdgeFallbackPixels"], 0)
        self.assertEqual(validate(output)["corner_alpha"], [0, 0, 0, 0])

    def test_inconsistent_colored_fringe_still_refused(self):
        result, output = self.capture("inconsistent", inconsistent=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("colored or inconsistent fringe", result.stderr)
        self.assertFalse(output.exists())

    def test_light_edge_still_requires_original_alpha_or_registered_reference(self):
        result, output = self.capture("light", light=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no dark, stable outer edge", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
