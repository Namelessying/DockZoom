#!/bin/bash
# DockZoom 全家桶构建：主应用 + 开关 + 卸载器（均为通用二进制，最低 macOS 13.0）。
# 用法: ./scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CACHE_DIR=".build/modcache"
mkdir -p "$CACHE_DIR" ".build"

# ⚠️ 必须显式指定 -target，否则 swiftc 会用宿主系统版本做最低部署目标
MIN_OS="13.0"
FLAGS=(-sdk "$SDKROOT" -module-cache-path "$CACHE_DIR" -swift-version 5)
if [ "$MODE" = "release" ]; then
    FLAGS+=(-O -whole-module-optimization)
else
    FLAGS+=(-Onone -g)
fi

# 从 Info.plist 提取版本号，生成 AppVersion.swift（裸二进制运行时也能显示真实版本）
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist 2>/dev/null || echo 0.0.0)"
cat > Sources/DockZoom/AppVersion.swift <<EOF
// 自动生成，勿手改（scripts/build.sh 从 Support/Info.plist 生成）
let kDockZoomVersion = "$VERSION"
EOF
echo "版本: $VERSION"

build_universal() {
    local name="$1"
    local sources="$2"
    swiftc "${FLAGS[@]}" -target "arm64-apple-macos$MIN_OS" -o ".build/${name}-arm64" $sources -framework AppKit
    swiftc "${FLAGS[@]}" -target "x86_64-apple-macos$MIN_OS" -o ".build/${name}-x86_64" $sources -framework AppKit
    lipo -create ".build/${name}-arm64" ".build/${name}-x86_64" -output ".build/${name}"
    rm -f ".build/${name}-arm64" ".build/${name}-x86_64"
}

build_universal "DockZoom" "Sources/DockZoom/*.swift"
build_universal "DockZoom 开关" "Sources/Launcher/*.swift"
build_universal "卸载 DockZoom" "Sources/Uninstaller/*.swift"

echo "Built 3 个应用 ($MODE, universal, min macOS $MIN_OS)"
