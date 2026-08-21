#!/bin/bash
# 生成 DockZoom 应用图标（AppIcon.icns）
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift scripts/make-icon.swift "$ICONSET" Support/AppIcon.icns
cp "$ICONSET/icon_512x512@2x.png" images/app-icon@2x.png
cp "$ICONSET/icon_128x128@2x.png" images/app-icon.png
rm -rf "$ICONSET"
echo "AppIcon.icns 与 README 图标已生成"
