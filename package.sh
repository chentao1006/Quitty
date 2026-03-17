#!/bin/bash

# Configuration
PROJECT_NAME="Quitty"
SCHEME="Quitty"
BUNDLE_ID="com.ct106.quitty"
TEAM_ID="E3237SRTMX" # Found in your project
APP_NAME="${PROJECT_NAME}.app"
RESULT_DIR="./dist"
ARCHIVE_PATH="${RESULT_DIR}/${PROJECT_NAME}.xcarchive"
EXPORT_PATH="${RESULT_DIR}/exported"
DMG_NAME="${PROJECT_NAME}.dmg"
DMG_PATH="${RESULT_DIR}/${DMG_NAME}"

# --- Check for Notarization Credentials ---
# You should set these environment variables or replace them here
# APPLE_ID="your-apple-id@email.com"
# APPLE_PASSWORD="your-app-specific-password"

set -e

echo "🚀 Starting packaging process..."

# 1. Clean and Create result directory
rm -rf "${RESULT_DIR}"
mkdir -p "${RESULT_DIR}"

# 2. Archive
echo "📦 Archiving the app..."
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    ENABLE_HARDENED_RUNTIME=YES

# 3. Export Archive
echo "📤 Exporting the archive..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "${EXPORT_PATH}" \
    -allowProvisioningUpdates

# Find the exported .app
EXPORTED_APP="${EXPORT_PATH}/${APP_NAME}"

if [ ! -d "${EXPORTED_APP}" ]; then
    echo "❌ Exported app not found at ${EXPORTED_APP}"
    exit 1
fi

# 4. Create DMG
echo "💿 Creating DMG..."
# Simple DMG creation using hdiutil
TMP_DMG_DIR="${RESULT_DIR}/dmg_tmp"
mkdir -p "${TMP_DMG_DIR}"
cp -R "${EXPORTED_APP}" "${TMP_DMG_DIR}/"
# Add a link to Applications folder
ln -s /Applications "${TMP_DMG_DIR}/Applications"

hdiutil create -volname "${PROJECT_NAME}" -srcfolder "${TMP_DMG_DIR}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${TMP_DMG_DIR}"

# 5. Notarize (if credentials provided)
if [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ]; then
    echo "🔐 Submitting for notarization..."
    # Using notarytool (modern way)
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    echo "🖋️ Stapling notarization ticket..."
    xcrun stapler staple "${DMG_PATH}"
    
    echo "✅ Notarization and stapling complete!"
else
    echo "⚠️ Notarization skipped because APPLE_ID and APPLE_PASSWORD are not set."
    echo "Please set them to ensure the DMG runs directly on other users' Macs."
fi

echo "🎉 All done! Your DMG is at: ${DMG_PATH}"
