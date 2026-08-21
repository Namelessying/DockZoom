#!/bin/bash
# 打包「DockZoom 全套」DMG：主应用 + 开关 + 卸载器 + 「应用程序」快捷方式。
# 用法: ./scripts/make-dmg.sh [版本号]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist 2>/dev/null || echo 0.1.0)}"
SIGN_IDENTITY="${DOCKZOOM_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${DOCKZOOM_NOTARY_PROFILE:-}"
./scripts/make-app.sh release

STAGE=".build/dmg-root"
TEMP_DMG_DIR="$(mktemp -d /private/tmp/com.dockzoom.dmg.XXXXXX)"
cleanup() {
    rm -rf "$STAGE" "$TEMP_DMG_DIR"
}
trap cleanup EXIT

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R .build/DockZoom.app "$STAGE/"
cp -R ".build/DockZoom 开关.app" "$STAGE/"
cp -R ".build/卸载 DockZoom.app" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"

DMG=".build/DockZoom-全套-${VERSION}.dmg"
TEMP_DMG="$TEMP_DMG_DIR/DockZoom-全套-${VERSION}.dmg"
# 先在独立临时目录生成完整镜像，再原子替换正式产物。
# 这样重复构建不会被 .build 内残留状态影响，失败时也不会破坏上一份有效 DMG。
hdiutil create \
    -volname "DockZoom 全套" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$TEMP_DMG" >/dev/null
mv -f "$TEMP_DMG" "$DMG"
cleanup
trap - EXIT

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "错误: 公证前必须设置 DOCKZOOM_SIGN_IDENTITY" >&2
        exit 1
    fi
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
elif [ -z "$SIGN_IDENTITY" ]; then
    echo "警告: 当前为本机开发包；网络分发前请使用 Developer ID 签名并完成苹果公证。" >&2
fi

echo "DMG: $DMG"
echo "提示：打开 DMG 后把三个应用拖入「应用程序」即可。"
