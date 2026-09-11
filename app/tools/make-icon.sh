#!/bin/bash
# Rebuild the macOS icon family from the 1024px PNG master using system tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Resources/AppIcon.png"
[ -f "$SOURCE" ] || { echo "Missing icon master: $SOURCE" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp/}tursora-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "→ $ROOT/Resources/AppIcon.icns"
