#!/bin/bash
# 打包「DockZoom 全套」DMG：主应用 + 开关 + 卸载器 + 「应用程序」快捷方式。
# 用法: ./scripts/make-dmg.sh [版本号]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist 2>/dev/null || echo 0.1.0)}"
./scripts/make-app.sh release

STAGE=".build/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R .build/DockZoom.app "$STAGE/"
cp -R ".build/DockZoom 开关.app" "$STAGE/"
cp -R ".build/卸载 DockZoom.app" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"

DMG=".build/DockZoom-全套-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create \
    -volname "DockZoom 全套" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGE"

echo "DMG: $DMG"
echo "提示：打开 DMG 后把三个应用拖入「应用程序」即可。"
