#!/usr/bin/env python3
"""Generate the tap cask only from a verified, published stable release."""

import argparse
import hashlib
import json
from pathlib import Path
import re


REPOSITORY = "https://github.com/zerolfx/Tursora"


def render(release, checksums, archive, *, auto_updates=False):
    tag = release.get("tag_name", "")
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag):
        raise ValueError("Expected a stable vMAJOR.MINOR.PATCH release tag")
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("Only published stable releases may update this cask")
    version = tag[1:]
    filename = f"Tursora-{version}-macOS-arm64.{'zip' if version == '0.1.0' else 'dmg'}"
    expected_url = f"{REPOSITORY}/releases/download/{tag}/{filename}"
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == filename]
    if len(assets) != 1 or assets[0].get("browser_download_url") != expected_url:
        raise ValueError("Release must contain exactly one official, versioned application asset")
    asset = assets[0]
    entries = []
    for line in checksums.splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
        if not match:
            raise ValueError("Malformed SHA256SUMS entry")
        if match[2] == filename:
            entries.append(match[1].lower())
    if len(entries) != 1:
        raise ValueError("Checksum file must name the application asset exactly once")
    archive = Path(archive)
    if archive.name != filename or not archive.is_file():
        raise ValueError(f"Expected the downloaded {filename}")
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    sha256 = digest.hexdigest()
    if sha256 != entries[0] or archive.stat().st_size != asset.get("size"):
        raise ValueError("Downloaded asset does not match the published checksum/size")
    if asset.get("digest") is not None and asset["digest"] != f"sha256:{sha256}":
        raise ValueError("GitHub asset digest disagrees with downloaded bytes")
    if auto_updates and version == "0.1.0":
        raise ValueError("The historical 0.1.0 application has no updater")
    if auto_updates and len([a for a in release.get("assets", []) if a.get("name") == "appcast.xml"
                            and a.get("browser_download_url") == f"{REPOSITORY}/releases/download/{tag}/appcast.xml"]) != 1:
        raise ValueError("An auto-updating release must publish its versioned appcast.xml")
    ruby_url = expected_url.replace(tag, "v#{version}").replace(f"Tursora-{version}", "Tursora-#{version}")
    updater = "  auto_updates true\n" if auto_updates else ""
    return f'''cask "tursora" do
  version "{version}"
  sha256 "{sha256}"

  url "{ruby_url}"
  name "Tursora"
  desc "Native macOS file manager with split panes and editable paths"
  homepage "{REPOSITORY}"

{updater}  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Tursora.app"

  caveats <<~EOS
    Tursora is ad-hoc signed and is not notarized by Apple.
    If macOS blocks the first launch, follow the trusted-download steps at:
      {REPOSITORY}#first-launch
  EOS
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-json", type=Path, required=True)
    parser.add_argument("--checksums", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--auto-updates", action="store_true", help="Release includes Sparkle and a published appcast")
    args = parser.parse_args()
    text = render(json.loads(args.release_json.read_text()), args.checksums.read_text(),
                  args.archive, auto_updates=args.auto_updates)
    if args.output.is_symlink():
        raise ValueError("Refusing to replace a symlink cask")
    inputs = [args.release_json, args.checksums, args.archive]
    if args.output.resolve() in [path.resolve() for path in inputs]:
        raise ValueError("Output must not replace a release input")
    args.output.write_text(text, encoding="utf-8")
    print(f"Wrote {args.output} from verified {args.archive.name}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError) as error:
        raise SystemExit(f"Homebrew cask update refused: {error}") from error
