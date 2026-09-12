"""Regression checks for update authenticity, version ordering and bundle defaults."""

import base64
import copy
import importlib.util
from pathlib import Path
import tempfile
import runpy
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location("update_metadata", Path(__file__).with_name("update-metadata.py"))
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)
S = metadata.SPARKLE
PUBLIC_KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


def bundle_info():
    return {
        "CFBundleIdentifier": "com.tursora.Tursora",
        "CFBundleExecutable": "Tursora",
        "CFBundleShortVersionString": "0.1.1",
        "CFBundleVersion": "1789228800",
        "SUFeedURL": metadata.FEED_URL,
        "SUPublicEDKey": PUBLIC_KEY,
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False,
        "SUSendProfileInfo": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "LSMinimumSystemVersion": "14.0",
    }


def latest_release(version="0.1.0", feed=False):
    return {"tag_name": "v" + version, "draft": False, "prerelease": False,
            "assets": [{"name": "appcast.xml"}] if feed else []}


def previous_item(build="1789220000"):
    item = ET.Element("item")
    ET.SubElement(item, S + "version").text = build
    return item


class VersionOrderingTests(unittest.TestCase):
    def test_accepts_numeric_stable_versions(self):
        self.assertEqual(metadata.stable_version("10.2.30"), (10, 2, 30))

    def test_rejects_unsafe_or_ambiguous_versions(self):
        for version in ("v0.1.1", "01.2.3", "1.02.3", "1.2.03", "1.2", "1.2.3-beta.1", "1.2.3\n", None, "1.2.3/other"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                metadata.stable_version(version)

    def test_build_must_be_positive_integer(self):
        self.assertEqual(metadata.build_number("1789228800"), 1789228800)
        for build in ("0", "-1", "01", "1.0", "1\n", "", None):
            with self.subTest(build=build), self.assertRaises(ValueError):
                metadata.build_number(build)

    def test_initial_updater_release_accepts_old_release_without_feed(self):
        metadata.validate_stable_release("0.1.1", "1789228800", latest_release())

    def test_later_release_cannot_silently_lose_feed(self):
        with self.assertRaisesRegex(ValueError, "Only the pre-updater"):
            metadata.validate_stable_release("0.2.0", "1789228800", latest_release("0.1.1"))

    def test_rejects_semantic_downgrade_even_with_larger_build(self):
        for version in ("0.1.0", "0.0.99"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "greater than the current"):
                metadata.validate_stable_release(version, "1789228800", latest_release())

    def test_semantic_version_comparison_is_numeric(self):
        metadata.validate_stable_release("0.10.0", "1789228800", latest_release("0.9.0", True), [previous_item()])

    def test_rejects_equal_or_lower_build_despite_higher_semantic_version(self):
        for build in ("1789220000", "1"):
            with self.subTest(build=build), self.assertRaisesRegex(ValueError, "greater than every build"):
                metadata.validate_stable_release("0.2.0", build, latest_release("0.1.1", True), [previous_item()])

    def test_checks_every_previous_item(self):
        with self.assertRaisesRegex(ValueError, "greater than every build"):
            metadata.validate_stable_release("0.2.0", "1789228800", latest_release("0.1.1", True),
                                             [previous_item(), previous_item("1789228801")])

    def test_cannot_skip_downloaded_feed(self):
        with self.assertRaisesRegex(ValueError, "Download the current appcast"):
            metadata.validate_stable_release("0.2.0", "1789228800", latest_release("0.1.1", True))

    def test_draft_or_prerelease_cannot_be_stable_baseline(self):
        for key in ("draft", "prerelease"):
            latest = latest_release()
            latest[key] = True
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "published stable"):
                metadata.validate_stable_release("0.1.1", "1789228800", latest)

    def test_rejects_prerelease_channel_in_previous_feed(self):
        item = previous_item()
        ET.SubElement(item, S + "channel").text = "beta"
        with self.assertRaisesRegex(ValueError, "prereleases"):
            metadata.validate_stable_release("0.2.0", "1789228800", latest_release("0.1.1", True), [item])


class PublicKeyAndBundleTests(unittest.TestCase):
    def test_accepts_32_byte_public_key(self):
        self.assertEqual(metadata.base64_value(PUBLIC_KEY, 32, "public key"), PUBLIC_KEY)

    def test_rejects_invalid_or_wrong_length_public_keys(self):
        for key in (None, "test", "" , PUBLIC_KEY + "\n", base64.b64encode(bytes(64)).decode()):
            with self.subTest(key=key), self.assertRaises(ValueError):
                metadata.base64_value(key, 32, "public key")

    def test_reads_key_file_with_final_newline(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "public-key.txt"
            path.write_text(PUBLIC_KEY + "\n")
            self.assertEqual(metadata.read_public_key(path), PUBLIC_KEY)

    def test_accepts_expected_bundle_settings(self):
        metadata.validate_bundle_metadata(bundle_info(), PUBLIC_KEY)

    def test_bundle_override_requires_explicit_expected_identity(self):
        info = bundle_info()
        info["CFBundleIdentifier"] = "com.example.TestBuild"
        with self.assertRaisesRegex(ValueError, "CFBundleIdentifier"):
            metadata.validate_bundle_metadata(info, PUBLIC_KEY)
        metadata.validate_bundle_metadata(info, PUBLIC_KEY, "com.example.TestBuild")

    def test_rejects_unsafe_update_defaults_or_wrong_key(self):
        for key in ("SUPublicEDKey", "SUFeedURL", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate",
                    "SUSendProfileInfo", "SUVerifyUpdateBeforeExtraction"):
            info = bundle_info()
            info[key] = not info[key] if isinstance(info[key], bool) else "incorrect"
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                metadata.validate_bundle_metadata(info, PUBLIC_KEY)

    def test_rejects_integer_plist_boolean(self):
        info = bundle_info()
        info["SUEnableAutomaticChecks"] = 1
        with self.assertRaisesRegex(ValueError, "SUEnableAutomaticChecks"):
            metadata.validate_bundle_metadata(info, PUBLIC_KEY)

    def test_does_not_force_automatic_download_eligibility(self):
        info = bundle_info()
        info["SUAllowsAutomaticUpdates"] = True
        with self.assertRaisesRegex(ValueError, "SUAllowsAutomaticUpdates"):
            metadata.validate_bundle_metadata(info, PUBLIC_KEY)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.archive = Path(self.folder.name) / "Tursora-0.1.1-macOS-arm64.dmg"
        self.archive.write_bytes(b"test archive")
        self.info = bundle_info()
        self.item = ET.Element("item")
        for key, value in (("version", self.info["CFBundleVersion"]), ("shortVersionString", "0.1.1"),
                           ("minimumSystemVersion", "14.0"), ("hardwareRequirements", "arm64")):
            ET.SubElement(self.item, S + key).text = value
        ET.SubElement(self.item, "description", {S + "format": "markdown"}).text = "Release notes"
        ET.SubElement(self.item, "enclosure", {
            "url": "https://github.com/zerolfx/Tursora/releases/download/v0.1.1/" + self.archive.name,
            "length": str(self.archive.stat().st_size), "type": "application/octet-stream", S + "edSignature": SIGNATURE})

    def validate(self):
        return metadata.validate_appcast([self.item], self.archive, self.info)

    def test_accepts_matching_signed_archive(self):
        self.assertEqual(self.validate(), SIGNATURE)

    def test_rejects_modified_archive_length(self):
        self.archive.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "length"):
            self.validate()

    def test_rejects_untrusted_download_url(self):
        self.item.find("enclosure").set("url", "https://example.com/app.dmg")
        with self.assertRaisesRegex(ValueError, "immutable release"):
            self.validate()

    def test_rejects_legacy_zip_asset(self):
        legacy = self.archive.with_suffix(".zip")
        legacy.write_bytes(self.archive.read_bytes())
        with self.assertRaisesRegex(ValueError, "archive name"):
            metadata.validate_appcast([self.item], legacy, self.info)

    def test_rejects_missing_or_malformed_archive_signature(self):
        for signature in (None, "", PUBLIC_KEY, "bad=="):
            enclosure = self.item.find("enclosure")
            if signature is None:
                enclosure.attrib.pop(S + "edSignature", None)
            else:
                enclosure.set(S + "edSignature", signature)
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                self.validate()

    def test_rejects_wrong_build_version_system_or_architecture(self):
        for key in ("version", "shortVersionString", "minimumSystemVersion", "hardwareRequirements"):
            element = self.item.find(S + key)
            old = element.text
            element.text = "wrong"
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                self.validate()
            element.text = old

    def test_rejects_extra_items(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            metadata.validate_appcast([self.item, copy.deepcopy(self.item)], self.archive, self.info)

    def test_rejects_extra_enclosures(self):
        ET.SubElement(self.item, "enclosure")
        with self.assertRaisesRegex(ValueError, "one update archive"):
            self.validate()

    def test_rejects_prerelease_channel(self):
        ET.SubElement(self.item, S + "channel").text = "beta"
        with self.assertRaisesRegex(ValueError, "prerelease"):
            self.validate()

    def test_rejects_unpublished_deltas(self):
        ET.SubElement(self.item, S + "deltas")
        with self.assertRaisesRegex(ValueError, "Delta updates"):
            self.validate()

    def test_requires_embedded_notes(self):
        self.item.remove(self.item.find("description"))
        with self.assertRaisesRegex(ValueError, "embedded release notes"):
            self.validate()

    def test_rejects_external_release_notes(self):
        ET.SubElement(self.item, S + "releaseNotesLink").text = "https://example.com/notes"
        with self.assertRaisesRegex(ValueError, "must be embedded"):
            self.validate()

    def test_parses_generated_rss_shape(self):
        path = Path(self.folder.name) / "appcast.xml"
        root = ET.Element("rss")
        ET.SubElement(root, "channel").append(self.item)
        ET.ElementTree(root).write(path)
        self.assertEqual(len(metadata.parse_appcast(path)), 1)

    def test_rejects_unsafe_empty_or_ambiguous_feeds(self):
        path = Path(self.folder.name) / "appcast.xml"
        for source in ("<!DOCTYPE rss><rss/>", "<rss><channel/></rss>", "<rss><channel/><channel/></rss>",
                       "<html/>", " " * 2_000_001):
            path.write_text(source)
            with self.subTest(source=source[:60]), self.assertRaises(ValueError):
                metadata.parse_appcast(path)


class ExecutablePathsTests(unittest.TestCase):
    OUTPUT = """Load command 1
          cmd LC_RPATH
      cmdsize 32
         path @loader_path (offset 12)
Load command 2
          cmd LC_RPATH
      cmdsize 56
         path /Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx (offset 12)
Load command 3
          cmd LC_RPATH
      cmdsize 48
         path @executable_path/../Frameworks (offset 12)
"""

    def test_reads_all_runtime_search_paths(self):
        self.assertEqual(metadata.executable_rpaths(self.OUTPUT), ["@loader_path",
            "/Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx", "@executable_path/../Frameworks"])

    def test_removes_developer_runtime_without_changing_bundle_search(self):
        with mock.patch.object(metadata.subprocess, "check_output", return_value=self.OUTPUT), \
                mock.patch.object(metadata.subprocess, "run") as run:
            metadata.prepare_executable(Path("/tmp/Tursora.app/Contents/MacOS/Tursora"))
        run.assert_called_once_with(["install_name_tool", "-delete_rpath",
            "/Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx",
            "/tmp/Tursora.app/Contents/MacOS/Tursora"], check=True)


class DiskImageLayoutTests(unittest.TestCase):
    def test_drag_install_layout_is_fixed_without_finder_automation(self):
        settings = runpy.run_path(str(Path(__file__).with_name("dmg-settings.py")),
                                  init_globals={"defines": {"app": "/tmp/Tursora.app", "license": "/tmp/LICENSE"}})
        self.assertEqual(settings["files"], ["/tmp/Tursora.app", ("/tmp/LICENSE", ".dmgbuild-LICENSE.txt")])
        self.assertEqual(settings["symlinks"], {"Applications": "/Applications"})
        self.assertEqual(settings["icon_locations"], {"Tursora.app": (140, 120), "Applications": (500, 120)})
        self.assertEqual(settings["window_rect"], ((100, 100), (640, 280)))
        self.assertEqual(settings["default_view"], "icon-view")
        self.assertEqual(settings["background"], "builtin-arrow")
        self.assertEqual(settings["format"], "UDZO")
        self.assertNotIn("hide_extensions", settings)  # FinderInfo must not modify the signed app.


if __name__ == "__main__":
    unittest.main()
