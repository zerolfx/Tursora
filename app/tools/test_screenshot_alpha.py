"""Verify the screenshot gate against native captures and PNG corruption."""

from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from screenshot_alpha import inspect, validate


def png(width, height, rows, color=6):
    def chunk(kind, content):
        return struct.pack(">I", len(content)) + kind + content + struct.pack(">I", zlib.crc32(kind + content))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class ScreenshotAlphaTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="tursora-alpha-test-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "window.png"

    def test_existing_native_prepared_image_matches_imageio(self):
        path = Path(__file__).resolve().parents[2] / "docs/images/features/path-navigation.png"
        result = validate(path)
        self.assertEqual(result["corner_alpha"], [0, 0, 0, 0])
        self.assertGreater(result["transparent_pixels"], 0)
        self.assertGreater(result["partial_pixels"], 0)

    def test_known_rgba_edge_and_opaque_matte(self):
        rows = b"\0" + bytes([20, 20, 20, 0, 20, 20, 20, 127, 20, 20, 20, 0])
        self.path.write_bytes(png(3, 2, rows * 2))
        result = validate(self.path)
        self.assertEqual((result["transparent_pixels"], result["partial_pixels"]), (4, 2))
        self.path.write_bytes(png(3, 1, b"\0" + bytes([255] * 12)))
        with self.assertRaisesRegex(ValueError, "transparent exteriors"):
            validate(self.path)

    def test_refuses_rgb_and_mislabeled_jpeg(self):
        self.path.write_bytes(png(1, 1, b"\0\xff\xff\xff", color=2))
        with self.assertRaisesRegex(ValueError, "RGBA"):
            validate(self.path)
        self.path.write_bytes(b"\xff\xd8\xff\xe0not a PNG")
        with self.assertRaisesRegex(ValueError, "actual PNG"):
            inspect(self.path)

    def test_refuses_corrupt_and_truncated_data(self):
        original = png(1, 1, b"\0\0\0\0\0")
        self.path.write_bytes(original[:20] + b"bad!" + original[24:])
        with self.assertRaisesRegex(ValueError, "CRC"):
            inspect(self.path)
        self.path.write_bytes(original[:10])
        with self.assertRaisesRegex(ValueError, "truncated"):
            inspect(self.path)
        self.path.write_bytes(png(2, 1, b"\0\0\0\0\0"))
        with self.assertRaisesRegex(ValueError, "decoded size"):
            inspect(self.path)


if __name__ == "__main__":
    unittest.main()
