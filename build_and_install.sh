#!/bin/bash

# 设置错误即停止
set -e

# 项目根目录
PROJECT_ROOT="/Users/chentao/Projects/chentao1006/quitty"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_NAME="Quitty.app"
INSTALL_PATH="/Applications/${APP_NAME}"

echo "🚀 开始构建 ${APP_NAME}..."

# 1. 清理旧的构建文件
if [ -d "${BUILD_DIR}" ]; then
    echo "🧹 清理旧构建目录..."
    rm -rf "${BUILD_DIR}"
fi

# 2. 执行编译
echo "🏗️ 正在编译 Release 版本..."
xcodebuild -project "${PROJECT_ROOT}/Quitty.xcodeproj" \
           -scheme "Quitty" \
           -configuration "Release" \
           -derivedDataPath "${BUILD_DIR}" \
           CONFIGURATION_BUILD_DIR="${BUILD_DIR}" \
           build > /dev/null

if [ $? -eq 0 ]; then
    echo "✅ 编译成功！"
else
    echo "❌ 编译失败，请检查报错。"
    exit 1
fi

# 3. 检查生成的 App
if [ ! -d "${BUILD_DIR}/${APP_NAME}" ]; then
    echo "❌ 未在 build 目录中找到 ${APP_NAME}"
    exit 1
fi

# 4. 移动到 /Applications
echo "📦 正在安装到系统应用目录 (${INSTALL_PATH})..."

# 如果已存在，先删除（可能需要 sudo 权限的场景下通过 open 执行会由系统提示）
if [ -d "${INSTALL_PATH}" ]; then
    echo "♻️ 替换旧版本..."
    rm -rf "${INSTALL_PATH}"
fi

cp -R "${BUILD_DIR}/${APP_NAME}" "${INSTALL_PATH}"

echo "🎉 安装完成！"
