#!/bin/bash
set -euo pipefail

VERSION="${1:-0.0.1}"
APP_NAME="Murmur"
BUNDLE_ID="com.fdiazsmith.murmur"
APP_DIR="dist/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-v${VERSION}-macos-arm64.dmg"

echo "==> Building release..."
swift build -c release

echo "==> Creating app bundle..."
rm -rf dist
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy binary (SPM uses arch-specific path)
BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/"

# Info.plist for the app bundle
cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur needs microphone access to record speech for transcription.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Entitlements
cat > dist/entitlements.plist << ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

echo "==> Signing app bundle (ad-hoc)..."
codesign --force --deep --sign - \
    --entitlements dist/entitlements.plist \
    "${APP_DIR}"

echo "==> Verifying signature..."
codesign --verify --verbose "${APP_DIR}"

echo "==> Creating DMG..."
rm -f "dist/${DMG_NAME}"

# Create a temporary DMG directory with app + Applications symlink
DMG_STAGING="dist/dmg-staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_DIR}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "dist/${DMG_NAME}"

rm -rf "${DMG_STAGING}" dist/entitlements.plist

echo ""
echo "==> Done!"
echo "    App:  ${APP_DIR}"
echo "    DMG:  dist/${DMG_NAME}"
echo "    Size: $(du -h "dist/${DMG_NAME}" | cut -f1)"
