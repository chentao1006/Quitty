#!/bin/bash

# Configuration
PLIST_PATH="Quitty/Info.plist"
PBXPROJ_PATH="Quitty.xcodeproj/project.pbxproj"
RESULT_DIR="./dist"

# Helper function to get current version
get_current_version() {
    grep -A 1 "CFBundleShortVersionString" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/'
}

# Helper function to get current build
get_current_build() {
    grep -A 1 "CFBundleVersion" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/'
}

CURRENT_VERSION=$(get_current_version)
CURRENT_BUILD=$(get_current_build)

echo "----------------------------------------"
echo "Current Version: $CURRENT_VERSION"
echo "Current Build  : $CURRENT_BUILD"
echo "----------------------------------------"

if [ -z "$1" ]; then
    read -p "Enter NEW Version (e.g. 1.0.6): " NEW_VERSION
else
    NEW_VERSION=$1
fi

if [ -z "$NEW_VERSION" ]; then
    echo "❌ Error: New version cannot be empty."
    exit 1
fi

# Determine NEW_BUILD (Always increment to ensure Sparkle compatibility)
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "🚀 Preparing local release $NEW_VERSION (Build $NEW_BUILD)..."

# 1. Update Version Files
sed -i '' -E "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_VERSION<\/string>/;}" "$PLIST_PATH"
sed -i '' -E "/<key>CFBundleVersion<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_BUILD<\/string>/;}" "$PLIST_PATH"
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $NEW_VERSION;/" "$PBXPROJ_PATH"
sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" "$PBXPROJ_PATH"

echo "✅ Local configuration updated."

# 2. Run Local Build (Uses your working local keychain)
chmod +x package.sh
./package.sh "$NEW_VERSION"

if [ ! -f "${RESULT_DIR}/Quitty.dmg" ]; then
    echo "❌ Local Build Failed: Quitty.dmg not found in ${RESULT_DIR}"
    exit 1
fi

# 3. Git Operations
git add .
git commit -m "chore: release version $NEW_VERSION (build $NEW_BUILD)"
git tag "v$NEW_VERSION"

echo "📦 Code committed and tagged locally."

# 4. Push and Upload to GitHub
BRANCH=$(git symbolic-ref --short HEAD)
git push origin "$BRANCH"
git push origin "v$NEW_VERSION"

# Use GitHub CLI to create release and upload assets
if command -v gh >/dev/null 2>&1; then
    echo "📡 Creating GitHub Release and uploading assets..."
    # DMG is the primary asset
    ASSETS=("${RESULT_DIR}/Quitty.dmg")
    
    # If re-releasing the same version, we need to delete the old one first
    echo "🧹 Removing existing release and tag if they exist..."
    gh release delete "v$NEW_VERSION" --yes 2>/dev/null || true
    git push origin --delete "v$NEW_VERSION" 2>/dev/null || true
    git tag -d "v$NEW_VERSION" 2>/dev/null || true

    gh release create "v$NEW_VERSION" \
        "${ASSETS[@]}" \
        --title "Release v$NEW_VERSION" \
        --notes "Automatic local release of version $NEW_VERSION (Build $NEW_BUILD)"
    
    if [ $? -eq 0 ]; then
        echo "🎉 Release completed successfully!"
    else
        echo "❌ Error: GitHub Release failed to create. Please check the error above."
    fi
else
    echo "⚠️  Note: GitHub CLI (gh) not found or not authenticated. Please upload ${RESULT_DIR}/Quitty.dmg and appcast.xml manually to the GitHub release page."
fi
