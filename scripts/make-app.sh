#!/bin/bash
# 打包 DockZoom 全家桶（3 个 .app bundle）。
# 用法: ./scripts/make-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
SIGN_IDENTITY="${DOCKZOOM_SIGN_IDENTITY:-}"
REQUIRE_DISTRIBUTION="${DOCKZOOM_REQUIRE_DISTRIBUTION:-0}"
./scripts/build.sh "$MODE"

# 应用图标（不存在则生成）
if [ ! -f Support/AppIcon.icns ]; then
    ./scripts/make-icon.sh
fi

make_bundle() {
    local app_name="$1"    # e.g. DockZoom.app
    local binary="$2"      # .build 下的二进制名
    local plist="$3"       # Info.plist 路径
    local entitlements="${4:-}"
    local app=".build/${app_name}"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp ".build/${binary}" "$app/Contents/MacOS/${binary}"
    cp "$plist" "$app/Contents/Info.plist"
    cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    if [ -n "$SIGN_IDENTITY" ]; then
        # 对外分发：Developer ID + Hardened Runtime + 时间戳，供后续 notarization。
        if [ -n "$entitlements" ]; then
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements "$entitlements" "$app"
        else
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$app"
        fi
    elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"DockZoom Dev"'; then
        # 本机开发：固定身份可尽量保持辅助功能授权；该签名不适合对外分发。
        if [ -n "$entitlements" ]; then
            codesign --force --sign "DockZoom Dev" --timestamp=none --entitlements "$entitlements" "$app"
        else
            codesign --force --sign "DockZoom Dev" --timestamp=none "$app"
        fi
    else
        # 没有可用证书时仍写入稳定的 designated requirement。
        # 默认 ad-hoc 签名会退化为 cdhash 要求，每次构建哈希都变化，导致 TCC
        # 把同一路径的新版本当成另一应用并丢失辅助功能授权。
        local bundle_id
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
        local adhoc_requirement="=designated => identifier \"${bundle_id}\""
        if [ -n "$entitlements" ]; then
            codesign --force --sign - --requirements "$adhoc_requirement" --entitlements "$entitlements" "$app"
        else
            codesign --force --sign - --requirements "$adhoc_requirement" "$app"
        fi
    fi
    echo "打包完成: $app"
}

if [ "$REQUIRE_DISTRIBUTION" = "1" ] && [ -z "$SIGN_IDENTITY" ]; then
    echo "错误: 正式分发要求设置 DOCKZOOM_SIGN_IDENTITY（Developer ID Application 证书）" >&2
    exit 1
fi

make_bundle "DockZoom.app"       "DockZoom"       "Support/Info.plist" "Support/DockZoom.entitlements"
make_bundle "DockZoom 开关.app"  "DockZoom 开关"  "Support/Launcher-Info.plist"
make_bundle "卸载 DockZoom.app"  "卸载 DockZoom"  "Support/Uninstaller-Info.plist"
