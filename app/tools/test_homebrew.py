"""Release-boundary checks for the Homebrew cask generator."""

import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("homebrew", Path(__file__).with_name("update-homebrew.py"))
homebrew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(homebrew)


class HomebrewReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="tursora-homebrew-test-")
        self.addCleanup(self.directory.cleanup)

    def fixture(self, version="0.1.0"):
        extension = "zip" if version == "0.1.0" else "dmg"
        name = f"Tursora-{version}-macOS-arm64.{extension}"
        archive = Path(self.directory.name) / name
        data = b"test application archive"
        archive.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        release = {"tag_name": f"v{version}", "draft": False, "prerelease": False, "assets": [
            {"name": name, "browser_download_url": f"{homebrew.REPOSITORY}/releases/download/v{version}/{name}",
             "size": len(data), "digest": f"sha256:{digest}"}
        ]}
        return release, f"{digest}  {name}\n", archive

    def test_current_zip_is_reproducible_and_has_no_updater(self):
        release, sums, archive = self.fixture()
        result = homebrew.render(release, sums, archive)
        self.assertIn('Tursora-#{version}-macOS-arm64.zip"', result)
        self.assertNotIn("auto_updates", result)
        self.assertNotIn("quarantine", result)
        self.assertIn('depends_on macos: :sonoma', result)

    def test_next_published_dmg_with_appcast(self):
        release, sums, archive = self.fixture("0.1.1")
        release["assets"].append({"name": "appcast.xml", "browser_download_url":
                                  f"{homebrew.REPOSITORY}/releases/download/v0.1.1/appcast.xml"})
        result = homebrew.render(release, sums, archive, auto_updates=True)
        self.assertIn('Tursora-#{version}-macOS-arm64.dmg"', result)
        self.assertIn("auto_updates true", result)

    def test_rejects_prerelease_draft_and_nonstable_tags(self):
        for key, value in [("draft", True), ("prerelease", True), ("draft", None),
                           ("tag_name", "v1.0.0-beta"), ("tag_name", "v01.0.0"),
                           ("tag_name", 'v1.0.0\"; system(\"echo injected\")')]:
            with self.subTest(key=key, value=value):
                release, sums, archive = self.fixture()
                release[key] = value
                with self.assertRaises(ValueError):
                    homebrew.render(release, sums, archive)

    def test_rejects_mutated_ambiguous_or_retargeted_assets(self):
        for change in ["url", "digest", "size", "duplicate", "missing"]:
            with self.subTest(change=change):
                release, sums, archive = self.fixture()
                asset = release["assets"][0]
                if change == "url": asset["browser_download_url"] = "https://example.com/app.zip"
                if change == "digest": asset["digest"] = "sha256:" + "0" * 64
                if change == "size": asset["size"] += 1
                if change == "duplicate": release["assets"].append(copy.deepcopy(asset))
                if change == "missing": release["assets"] = []
                with self.assertRaises(ValueError):
                    homebrew.render(release, sums, archive)

    def test_rejects_checksum_confusion_and_changed_bytes(self):
        release, sums, archive = self.fixture()
        for bad in [sums + sums, sums.replace("0.1.0", "0.1.1"), "0" * 64 + sums[64:], "bad\n"]:
            with self.subTest(checksum=bad), self.assertRaises(ValueError):
                homebrew.render(release, bad, archive)
        archive.write_bytes(b"changed application bytes")
        with self.assertRaises(ValueError):
            homebrew.render(release, sums, archive)

    def test_updater_requires_a_published_appcast_and_new_version(self):
        for version in ["0.1.0", "0.1.1"]:
            release, sums, archive = self.fixture(version)
            with self.subTest(version=version), self.assertRaises(ValueError):
                homebrew.render(release, sums, archive, auto_updates=True)


if __name__ == "__main__":
    unittest.main()
