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

# Reject malformed metadata before building or replacing the existing bundle.
case "$CONFIG" in
    debug|release) ;;
    *) echo 'Usage: tools/make-app.sh [debug|release]' >&2; exit 1 ;;
esac
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || {
    echo 'TURSORA_BUNDLE_ID must be a reverse-DNS identifier.' >&2; exit 1;
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'TURSORA_VERSION must contain three numeric components (for example 0.1.0).' >&2; exit 1;
}
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo 'TURSORA_BUILD must be a positive integer.' >&2; exit 1;
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$EXEC_NAME"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }
SWIFTTERM_RESOURCES="$BIN_DIR/SwiftTerm_SwiftTerm.bundle"
[ -d "$SWIFTTERM_RESOURCES" ] || { echo "build failed: SwiftTerm resource bundle missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftTerm 1.15.0 probes Bundle.main.resourceURL directly, intentionally
# avoiding SwiftPM's generated Bundle.module accessor and its build-path fallback.
cp -R "$SWIFTTERM_RESOURCES" "$APP/Contents/Resources/"
cp "$ROOT/Resources/SwiftTerm-LICENSE.txt" "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"

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
    <key>CFBundleIconFile</key>               <string>AppIcon</string>
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
codesign --force --sign - --timestamp=none "$APP"
echo "→ $APP"
