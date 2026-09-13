#!/bin/bash
# Assemble "Tursora.app" from the SPM build.
# Usage: tools/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Tursora"
EXEC_NAME="Tursora"
BUNDLE_ID="${TURSORA_BUNDLE_ID:-com.tursora.Tursora}"
VERSION="${TURSORA_VERSION:-0.2.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A given source commit has the same update version locally and in every workflow.
# Release publication also checks this against the current stable appcast.
BUILD_NUMBER="${TURSORA_BUILD:-$(git -C "$ROOT" show -s --format=%ct HEAD)}"
PUBLIC_KEY="$(python3 "$ROOT/tools/update-metadata.py" public-key "$ROOT/Resources/SparklePublicKey.txt")"

# Reject malformed metadata before building or replacing the existing bundle.
case "$CONFIG" in
    debug|release) ;;
    *) echo 'Usage: tools/make-app.sh [debug|release]' >&2; exit 1 ;;
esac
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || {
    echo 'TURSORA_BUNDLE_ID must be a reverse-DNS identifier.' >&2; exit 1;
}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo 'TURSORA_VERSION must contain three numeric components without leading zeros (for example 0.1.0).' >&2; exit 1;
}
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo 'TURSORA_BUILD must be a positive integer.' >&2; exit 1;
}

OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

cd "$ROOT"
"$ROOT/tools/make-icon.sh"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$EXEC_NAME"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }
SWIFTTERM_RESOURCES="$BIN_DIR/SwiftTerm_SwiftTerm.bundle"
[ -d "$SWIFTTERM_RESOURCES" ] || { echo "build failed: SwiftTerm resource bundle missing" >&2; exit 1; }
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "build failed: Sparkle framework missing" >&2; exit 1; }
codesign --verify --deep --strict "$SPARKLE_FRAMEWORK"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
python3 "$ROOT/tools/update-metadata.py" prepare-executable "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/../LICENSE" "$APP/Contents/Resources/Tursora-LICENSE.txt"
# SwiftTerm 1.15.0 probes Bundle.main.resourceURL directly, intentionally
# avoiding SwiftPM's generated Bundle.module accessor and its build-path fallback.
cp -R "$SWIFTTERM_RESOURCES" "$APP/Contents/Resources/"
cp "$ROOT/Resources/SwiftTerm-LICENSE.txt" "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
# Preserve Sparkle's signed installer, updater, XPC services, symlinks and modes.
# Re-sign only our outer bundle; --deep signing would strip helper entitlements.
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Sparkle-LICENSE.txt" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

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
    <key>SUFeedURL</key>                      <string>https://github.com/zerolfx/Tursora/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>                  <string>$PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>        <true/>
    <key>SUAutomaticallyUpdate</key>          <false/>
    <key>SUSendProfileInfo</key>              <false/>
    <key>SUVerifyUpdateBeforeExtraction</key> <true/>
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
python3 "$ROOT/tools/update-metadata.py" verify-bundle "$APP" \
    --public-key "$ROOT/Resources/SparklePublicKey.txt" --bundle-id "$BUNDLE_ID"
echo "→ $APP"
