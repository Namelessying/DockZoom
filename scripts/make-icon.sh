#!/bin/bash
# 生成 DockZoom 应用图标（AppIcon.icns）
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
rm -rf "$ICONSET"
echo "AppIcon.icns 已生成"
