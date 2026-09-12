#!/usr/bin/env python3
"""Validate release ordering and the metadata that authenticates Sparkle updates."""

import argparse
import base64
import binascii
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
REPOSITORY = "zerolfx/Tursora"
FEED_URL = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def stable_version(value):
    require(isinstance(value, str) and re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value),
            "Expected a stable version with three numeric components and no leading zeros.")
    return tuple(int(part) for part in value.split("."))


def build_number(value):
    require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*", value),
            "Expected a positive integer bundle version.")
    return int(value)


def base64_value(value, length, label):
    require(isinstance(value, str), f"Missing {label}.")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError(f"Invalid {label} encoding.") from error
    require(len(data) == length and base64.b64encode(data).decode() == value,
            f"Invalid {label} length or noncanonical encoding.")
    return value


def read_public_key(path):
    return base64_value(Path(path).read_text().strip(), 32, "Sparkle public key")


def parse_appcast(path):
    data = Path(path).read_bytes()
    require(len(data) <= 2_000_000, "Appcast exceeds the metadata size limit.")
    require(b"<!DOCTYPE" not in data.upper() and b"<!ENTITY" not in data.upper(),
            "Appcast must not declare XML entities.")
    root = ET.fromstring(data)
    require(root.tag == "rss", "Appcast must be RSS.")
    channels = root.findall("channel")
    require(len(channels) == 1, "Appcast must contain one RSS channel.")
    items = channels[0].findall("item")
    require(bool(items), "Appcast has no updates.")
    return items


def validate_stable_release(version, build, latest, previous_items=None):
    next_version = stable_version(version)
    next_build = build_number(build)
    require(latest.get("draft") is False and latest.get("prerelease") is False,
            "Latest release must be a published stable release.")
    tag = latest.get("tag_name", "")
    require(isinstance(tag, str) and tag.startswith("v"), "Latest stable release has an invalid tag.")
    require(next_version > stable_version(tag[1:]),
            "New stable version must be greater than the current stable release.")
    assets = latest.get("assets")
    require(isinstance(assets, list), "Latest release asset metadata is missing.")
    has_feed = any(asset.get("name") == "appcast.xml" for asset in assets)
    require(has_feed or tag == "v0.1.0", "Only the pre-updater 0.1.0 release may lack an appcast.")
    require(has_feed == (previous_items is not None),
            "Download the current appcast when present; never skip its build-order check.")
    for item in previous_items or []:
        require(item.find(SPARKLE + "channel") is None, "Stable feed must not contain prereleases.")
        require(next_build > build_number(item.findtext(SPARKLE + "version")),
                "New build must be greater than every build in the current stable appcast.")


def validate_bundle_metadata(info, public_key, bundle_id="com.tursora.Tursora"):
    stable_version(info.get("CFBundleShortVersionString"))
    build_number(info.get("CFBundleVersion"))
    expected = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "Tursora",
        "SUFeedURL": FEED_URL,
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False,
        "SUSendProfileInfo": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "LSMinimumSystemVersion": "14.0",
    }
    for key, value in expected.items():
        require(info.get(key) == value and type(info.get(key)) is type(value),
                f"Unexpected or missing bundle value for {key}.")
    require("SUAllowsAutomaticUpdates" not in info,
            "Leave SUAllowsAutomaticUpdates unset so automatic checks govern eligibility.")


def executable_rpaths(load_commands):
    return re.findall(r"cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.*?) \(offset \d+\)", load_commands)


RUNTIME_PATHS = {"@loader_path", "@executable_path/../Frameworks", "/usr/lib/swift"}


def prepare_executable(executable):
    output = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    # SwiftPM adds developer-toolchain fallback paths. Installed applications
    # resolve only from their own bundle and the operating system runtime.
    for path in executable_rpaths(output):
        if path not in RUNTIME_PATHS:
            subprocess.run(["install_name_tool", "-delete_rpath", path, str(executable)], check=True)


def verify_bundle(app, public_key_path, bundle_id="com.tursora.Tursora"):
    contents = Path(app) / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    validate_bundle_metadata(info, read_public_key(public_key_path), bundle_id)
    executable = contents / "MacOS/Tursora"
    rpaths = executable_rpaths(subprocess.check_output(["otool", "-l", str(executable)], text=True))
    require("@executable_path/../Frameworks" in rpaths, "Packaged executable cannot locate its embedded framework.")
    require(set(rpaths) <= RUNTIME_PATHS, "Packaged executable still searches development directories.")
    linked = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    require("\n\t@rpath/Sparkle.framework/Versions/B/Sparkle (" in linked,
            "Packaged executable does not link the embedded Sparkle framework.")
    framework = contents / "Frameworks/Sparkle.framework"
    for path in ("Versions/Current", "Sparkle", "Autoupdate", "Updater.app", "XPCServices"):
        require((framework / path).is_symlink(), f"Sparkle symlink was not preserved: {path}")
        require((framework / path).exists(), f"Sparkle symlink is broken: {path}")
    for path in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                 "XPCServices/Installer.xpc/Contents/MacOS/Installer",
                 "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
        file = framework / path
        require(file.is_file() and file.stat().st_mode & 0o111, f"Sparkle executable is missing: {path}")
    require((contents / "Resources/Sparkle-LICENSE.txt").is_file(), "Sparkle license is missing.")


def validate_appcast(items, archive, info, repository=REPOSITORY):
    require(repository == REPOSITORY, "Update publishing is restricted to the application repository.")
    require(len(items) == 1, "A release asset appcast must contain exactly one stable update.")
    item = items[0]
    require(item.find(SPARKLE + "channel") is None, "Stable appcast contains a prerelease channel.")
    require(item.find(SPARKLE + "deltas") is None, "Delta updates are not published by this workflow.")
    for key, value in (("version", info["CFBundleVersion"]),
                       ("shortVersionString", info["CFBundleShortVersionString"]),
                       ("minimumSystemVersion", info["LSMinimumSystemVersion"]),
                       ("hardwareRequirements", "arm64")):
        require(item.findtext(SPARKLE + key) == value, f"Appcast {key} does not match the bundle.")
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, "Appcast must contain one update archive.")
    enclosure = enclosures[0]
    archive = Path(archive)
    version = info["CFBundleShortVersionString"]
    expected_name = f"Tursora-{version}-macOS-arm64.dmg"
    require(archive.name == expected_name, "Update archive name does not match the stable version.")
    expected_url = f"https://github.com/{repository}/releases/download/v{version}/{expected_name}"
    require(enclosure.get("url") == expected_url, "Update archive must use the immutable release asset URL.")
    require(enclosure.get("length") == str(archive.stat().st_size), "Update archive length does not match.")
    require(enclosure.get("type") == "application/octet-stream", "Update archive has an unexpected content type.")
    require(item.find("description") is not None, "Appcast is missing embedded release notes.")
    require(item.find(SPARKLE + "releaseNotesLink") is None, "Release notes must be embedded in this feed.")
    return base64_value(enclosure.get(SPARKLE + "edSignature"), 64, "archive Ed25519 signature")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    key = sub.add_parser("public-key")
    key.add_argument("path", type=Path)
    bundle = sub.add_parser("verify-bundle")
    bundle.add_argument("app", type=Path)
    bundle.add_argument("--public-key", type=Path, required=True)
    bundle.add_argument("--bundle-id", default="com.tursora.Tursora")
    executable = sub.add_parser("prepare-executable")
    executable.add_argument("path", type=Path)
    stable = sub.add_parser("stable-release")
    stable.add_argument("--version", required=True)
    stable.add_argument("--build", required=True)
    stable.add_argument("--latest-release", type=Path, required=True)
    stable.add_argument("--previous-appcast", type=Path)
    feed = sub.add_parser("verify-appcast")
    feed.add_argument("path", type=Path)
    feed.add_argument("--archive", type=Path, required=True)
    feed.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "public-key":
            print(read_public_key(args.path))
        elif args.command == "verify-bundle":
            verify_bundle(args.app, args.public_key, args.bundle_id)
        elif args.command == "prepare-executable":
            prepare_executable(args.path)
        elif args.command == "stable-release":
            previous = parse_appcast(args.previous_appcast) if args.previous_appcast else None
            validate_stable_release(args.version, args.build,
                                    json.loads(args.latest_release.read_text()), previous)
        else:
            info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
            print(validate_appcast(parse_appcast(args.path), args.archive, info))
    except (ValueError, OSError, ET.ParseError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Update metadata: {error}\n")


if __name__ == "__main__":
    main()
