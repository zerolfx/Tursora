#!/bin/bash
# Assemble "Tursora.app" from the SPM build.
# Usage: tools/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Tursora"
EXEC_NAME="Tursora"
BUNDLE_ID="${TURSORA_BUNDLE_ID:-com.tursora.Tursora}"
VERSION="${TURSORA_VERSION:-0.1.0}"
BUILD_NUMBER="${TURSORA_BUILD:-$(git -C "$(dirname "$0")/.." rev-list --count HEAD 2>/dev/null || echo 1)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG" 2>&1 | grep -vE "SwiftUICore|^\[|Write " || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>Tursora</string>
    <key>CFBundleDisplayName</key>            <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSHumanReadableCopyright</key>       <string>Copyright © 2026 Fangxin Lin</string>
    <!-- Folder-access prompts (TCC) show these reasons. Keyed off CFBundleIdentifier. -->
    <key>NSDesktopFolderUsageDescription</key>   <string>Tursora is a file manager and needs to show the contents of your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key> <string>Tursora is a file manager and needs to show the contents of your Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key> <string>Tursora is a file manager and needs to show the contents of your Downloads.</string>
    <key>NSRemovableVolumesUsageDescription</key> <string>Tursora is a file manager and needs to browse removable volumes.</string>
    <key>NSNetworkVolumesUsageDescription</key>  <string>Tursora is a file manager and needs to browse network volumes.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key> <string>Folder</string>
            <key>CFBundleTypeRole</key> <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Ad-hoc signature: required for arm64 binaries to launch at all.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
echo "→ $APP"
