#!/bin/bash
# 打包 DockZoom 全家桶（3 个 .app bundle）。
# 用法: ./scripts/make-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
./scripts/build.sh "$MODE"

# 应用图标（不存在则生成）
if [ ! -f Support/AppIcon.icns ]; then
    ./scripts/make-icon.sh
fi

make_bundle() {
    local app_name="$1"    # e.g. DockZoom.app
    local binary="$2"      # .build 下的二进制名
    local plist="$3"       # Info.plist 路径
    local app=".build/${app_name}"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp ".build/${binary}" "$app/Contents/MacOS/${binary}"
    cp "$plist" "$app/Contents/Info.plist"
    cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    # 优先用稳定自签名证书（同一身份跨版本重签，辅助功能授权不会失效）；无则 ad-hoc
    codesign --force --sign "DockZoom Dev" "$app" 2>/dev/null \
        || codesign --force --sign - "$app" 2>/dev/null \
        || echo "警告: $app_name 签名失败"
    echo "打包完成: $app"
}

make_bundle "DockZoom.app"       "DockZoom"       "Support/Info.plist"
make_bundle "DockZoom 开关.app"  "DockZoom 开关"  "Support/Launcher-Info.plist"
make_bundle "卸载 DockZoom.app"  "卸载 DockZoom"  "Support/Uninstaller-Info.plist"
