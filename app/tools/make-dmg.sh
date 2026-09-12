#!/bin/bash
# Create the distributable drag-to-install DMG and verify its mounted contents.
# Usage: TURSORA_PYTHON=python3.13 tools/make-dmg.sh [release-version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tursora.app"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || {
    echo 'Expected a version such as 0.1.1 or 0.2.0-beta.1.' >&2; exit 1;
}
test "${VERSION%%-*}" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" || {
    echo 'DMG version does not match the packaged application.' >&2; exit 1;
}
codesign --verify --deep --strict "$APP"
python3 "$ROOT/tools/update-metadata.py" verify-bundle "$APP" --public-key "$ROOT/Resources/SparklePublicKey.txt"

PYTHON="${TURSORA_PYTHON:-python3}"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
    echo 'DMG packaging requires Python 3.10 or later; set TURSORA_PYTHON to its executable.' >&2; exit 1;
}
VENV="$ROOT/.build/dmg-tools"
if [ ! -x "$VENV/bin/python" ]; then "$PYTHON" -m venv "$VENV"; fi
"$VENV/bin/python" -m pip install --disable-pip-version-check --no-cache-dir \
    --require-hashes --only-binary=:all: -r "$ROOT/tools/dmg-requirements.txt"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/tursora-dmg.XXXXXX")"
MOUNT="$STAGING/mounted"
MOUNTED=0
cleanup() {
    result=$?
    trap - EXIT
    if [[ "$MOUNTED" == 1 ]] && ! hdiutil detach "$MOUNT" -quiet; then
        echo "Could not detach the test volume; preserved temporary files at $STAGING." >&2
        exit 1
    fi
    rm -rf "$STAGING"
    exit "$result"
}
trap cleanup EXIT

IMAGE="$STAGING/Tursora-$VERSION-macOS-arm64.dmg"
# dmgbuild writes deterministic Finder layout metadata directly and uses hdiutil
# to construct/compress the image; hosted builds need no Finder UI session.
"$VENV/bin/dmgbuild" -s "$ROOT/tools/dmg-settings.py" -D "app=$APP" \
    -D "license=$ROOT/tools/dmgbuild-LICENSE.txt" Tursora "$IMAGE"
mkdir "$MOUNT"
hdiutil attach "$IMAGE" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
MOUNTED=1
test -L "$MOUNT/Applications"
test "$(readlink "$MOUNT/Applications")" = /Applications
cmp "$ROOT/tools/dmgbuild-LICENSE.txt" "$MOUNT/.dmgbuild-LICENSE.txt"
test "$(lipo -archs "$MOUNT/Tursora.app/Contents/MacOS/Tursora")" = arm64
codesign --verify --deep --strict "$MOUNT/Tursora.app"
python3 "$ROOT/tools/update-metadata.py" verify-bundle "$MOUNT/Tursora.app" \
    --public-key "$ROOT/Resources/SparklePublicKey.txt"
"$VENV/bin/python" "$ROOT/tools/verify-dmg-layout.py" "$MOUNT"
hdiutil detach "$MOUNT" -quiet
MOUNTED=0
mkdir -p "$ROOT/dist"
mv "$IMAGE" "$ROOT/dist/$(basename "$IMAGE")"
echo "→ $ROOT/dist/$(basename "$IMAGE")"
