#!/bin/bash
set -euo pipefail

#
# CNDF-VPN macOS Release Script
# Usage: ./scripts/release.sh [--skip-notarize]
#
# Prerequisites:
#   1. Apple Developer ID Application certificate in keychain
#   2. Apple Developer ID Installer certificate in keychain (for pkg)
#   3. Sparkle EdDSA key in keychain (generated via generate_keys)
#   4. App-specific password for notarization stored in keychain:
#      xcrun notarytool store-credentials "CNDF-VPN-Notarize" \
#        --apple-id "your@email.com" \
#        --team-id "YOUR_TEAM_ID" \
#        --password "app-specific-password"
#
# Environment variables (override defaults):
#   DEVELOPER_ID    - Code signing identity (default: auto-detect)
#   TEAM_ID         - Apple Developer Team ID
#   NOTARIZE_PROFILE - notarytool credential profile name
#   AZURE_CONTAINER  - Azure Blob container URL for uploads
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/release-build"
OUTPUT_DIR="${PROJECT_DIR}/release-output"

APP_NAME="CNDF-VPN"
BUNDLE_ID="com.cndf.vpn"
SCHEME="Pangolin"

# Notarization profile (set up with xcrun notarytool store-credentials)
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-CNDF-VPN-Notarize}"

# Azure Blob Storage
AZURE_CONTAINER="${AZURE_CONTAINER:-https://cndfupdates.blob.core.windows.net/releases}"

# Sparkle tools (from Xcode DerivedData)
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path "*/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)"

SKIP_NOTARIZE=false
if [[ "${1:-}" == "--skip-notarize" ]]; then
    SKIP_NOTARIZE=true
fi

echo "=== CNDF-VPN Release Build ==="
echo ""

# Clean
echo "[1/7] Cleaning..."
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Build
echo "[2/7] Building..."
xcodebuild archive \
    -project "${PROJECT_DIR}/Pangolin.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
    ONLY_ACTIVE_ARCH=NO \
    | tail -5

# Export
echo "[3/7] Exporting..."

# Create export options plist
cat > "${BUILD_DIR}/ExportOptions.plist" << 'EXPORTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EXPORTEOF

xcodebuild -exportArchive \
    -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
    -exportPath "${BUILD_DIR}/export" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    | tail -5

APP_PATH="${BUILD_DIR}/export/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    # Try to find the app with original target name
    APP_PATH="$(find "${BUILD_DIR}/export" -name "*.app" -maxdepth 1 | head -1)"
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Could not find exported .app"
    exit 1
fi

# Get version
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${APP_PATH}/Contents/Info.plist")
echo "   Version: ${VERSION} (${BUILD_NUMBER})"

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

# Notarize
if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "[4/7] Notarizing..."

    # Create a zip for notarization
    NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    # Staple the notarization ticket
    xcrun stapler staple "$APP_PATH"
    echo "   Notarization complete."
else
    echo "[4/7] Skipping notarization (--skip-notarize)"
fi

# Create DMG
echo "[5/7] Creating DMG..."
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# Sign DMG
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"
fi

echo "   DMG: ${DMG_PATH}"

# Generate appcast
echo "[6/7] Generating appcast..."
if [[ -n "$SPARKLE_BIN" ]]; then
    # sign_update generates the EdDSA signature for the DMG
    SIGNATURE=$("${SPARKLE_BIN}/sign_update" "$DMG_PATH" 2>&1)
    DMG_SIZE=$(stat -f%z "$DMG_PATH")

    cat > "${OUTPUT_DIR}/appcast.xml" << APPCASTEOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>${AZURE_CONTAINER}/appcast.xml</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${AZURE_CONTAINER}/${DMG_NAME}"
                 ${SIGNATURE}
                 length="${DMG_SIZE}"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
APPCASTEOF

    echo "   Appcast: ${OUTPUT_DIR}/appcast.xml"
else
    echo "   WARNING: Sparkle tools not found. Skipping appcast generation."
    echo "   Build the Xcode project first so Sparkle SPM package is fetched."
fi

# Summary
echo "[7/7] Done!"
echo ""
echo "=== Release Artifacts ==="
echo "  DMG:     ${DMG_PATH}"
echo "  Appcast: ${OUTPUT_DIR}/appcast.xml"
echo ""
echo "=== Next Steps ==="
echo "  1. Upload to Azure Blob Storage:"
echo "     az storage blob upload -f '${DMG_PATH}' -c releases -n '${DMG_NAME}'"
echo "     az storage blob upload -f '${OUTPUT_DIR}/appcast.xml' -c releases -n appcast.xml"
echo ""
echo "  Or use azcopy:"
echo "     azcopy copy '${DMG_PATH}' '${AZURE_CONTAINER}/${DMG_NAME}'"
echo "     azcopy copy '${OUTPUT_DIR}/appcast.xml' '${AZURE_CONTAINER}/appcast.xml'"
echo ""
