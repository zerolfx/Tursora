#!/bin/bash
# Build and verify a signed stable appcast from an already packaged release DMG.
# Usage: tools/make-appcast.sh 0.1.1 /path/to/release-notes.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?A stable release version is required}"
NOTES="${2:?The release notes file is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo 'Only stable releases can produce the stable appcast.' >&2; exit 1;
}
[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || { echo 'SPARKLE_PRIVATE_KEY is required.' >&2; exit 1; }
[ -s "$NOTES" ] || { echo 'Release notes are missing or empty.' >&2; exit 1; }
ARCHIVE="Tursora-$VERSION-macOS-arm64.dmg"
[ -s "$ROOT/dist/$ARCHIVE" ] || { echo 'The packaged release DMG is missing.' >&2; exit 1; }
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/tursora-appcast.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$ROOT/dist/$ARCHIVE" "$STAGING/$ARCHIVE"
cp "$NOTES" "$STAGING/${ARCHIVE%.dmg}.md"

# Private material is never passed as an argument or written to the workspace.
# Strip the inherited secret after the shell has supplied it through stdin.
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | env -u SPARKLE_PRIVATE_KEY "$TOOLS/generate_appcast" \
    --ed-key-file - --maximum-deltas 0 --maximum-versions 1 --embed-release-notes \
    --download-url-prefix "https://github.com/zerolfx/Tursora/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/zerolfx/Tursora/releases" \
    --link "https://zerolfx.github.io/Tursora/" "$STAGING"

SIGNATURE="$(python3 "$ROOT/tools/update-metadata.py" verify-appcast "$STAGING/appcast.xml" \
    --archive "$ROOT/dist/$ARCHIVE" --app "$ROOT/build/Tursora.app")"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | env -u SPARKLE_PRIVATE_KEY "$TOOLS/sign_update" \
    --verify --ed-key-file - "$ROOT/dist/$ARCHIVE" "$SIGNATURE"
cp "$STAGING/appcast.xml" "$ROOT/dist/appcast.xml"
echo 'Signed stable appcast and archive signature verified.'
