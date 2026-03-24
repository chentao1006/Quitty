#!/bin/bash

# Stop on error
set -e

# Project root directory
PROJECT_ROOT="."
BUILD_DIR="${PROJECT_ROOT}/build"
APP_NAME="Quitty.app"
BUNDLE_ID="com.ct106.quitty"
INSTALL_PATH="/Applications/${APP_NAME}"

echo "🚀 Starting build for ${APP_NAME}..."

# 1. Clean old build files
if [ -d "${BUILD_DIR}" ]; then
    echo "🧹 Cleaning old build directory..."
    rm -rf "${BUILD_DIR}"
fi

# 2. Run compilation
echo "🏗️ Compiling Release version..."
xcodebuild -project "${PROJECT_ROOT}/Quitty.xcodeproj" \
           -scheme "Quitty" \
           -configuration "Release" \
           -derivedDataPath "${BUILD_DIR}" \
           CONFIGURATION_BUILD_DIR="${BUILD_DIR}" \
           build > /dev/null

if [ $? -eq 0 ]; then
    echo "✅ Compilation successful!"
else
    echo "❌ Compilation failed, please check errors."
    exit 1
fi

# 3. Check generated App
if [ ! -d "${BUILD_DIR}/${APP_NAME}" ]; then
    echo "❌ ${APP_NAME} not found in build directory"
    exit 1
fi

# 4. Move to /Applications
echo "📦 Installing to system Applications folder (${INSTALL_PATH})..."

# Terminate running instance if any
echo "🛑 Stopping any running instance of Quitty..."
pkill -x "Quitty" || true

# If already exists, remove first
if [ -d "${INSTALL_PATH}" ]; then
    echo "♻️ Replacing old version..."
    rm -rf "${INSTALL_PATH}"
fi

# Reset accessibility permissions to avoid manual deletion
echo "🔐 Resetting Accessibility permissions..."
tccutil reset Accessibility "${BUNDLE_ID}" || true

cp -R "${BUILD_DIR}/${APP_NAME}" "${INSTALL_PATH}"

echo "🚀 Launching ${APP_NAME}..."
open "${INSTALL_PATH}"

echo "🎉 Installation complete!"
