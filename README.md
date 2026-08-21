# DockZoom

[![版本](https://img.shields.io/github/v/release/Namelessying/DockZoom?label=版本)](https://github.com/Namelessying/DockZoom/releases/latest)
[![CI](https://github.com/Namelessying/DockZoom/actions/workflows/ci.yml/badge.svg)](https://github.com/Namelessying/DockZoom/actions/workflows/ci.yml)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-1575F9?logo=apple)](#构建与运行)

macOS Dock 缩放/最小化增强工具（菜单栏应用）。当前正式版：**v0.2.6**。

点击 Dock 图标 → 窗口带着**苹果原生 genie/scale 动画**缩进 Dock；再点一次 → 恢复。
适配所有应用，包括微信（WeChat）、Finder、Electron 无边框窗口等特殊应用。

## 功能

### 核心：点 Dock 图标最小化/恢复（保留原生动画）
- 点击**当前前台应用**的 Dock 图标 → 该应用所有可见窗口最小化到 Dock，动画为系统原生
  genie（神奇效果）或 scale（缩放效果，跟随「系统设置 → 桌面与程序坞」的选择）。
- 应用最小化后再次点击图标 → **全部找回**（恢复所有最小化窗口并激活，补上了
  GetBackMyWindows 缺失的通用恢复逻辑）。
- 应用隐藏时点击 → 恢复显示；后台应用点击 → 激活。
- 最小化失败自动降级链：`kAXMinimizedAttribute → kAXHidden → hide() → 合成⌘M`。

### 微信专属适配
- 主聊天窗口（标题「微信/WeChat」）与文章/小程序窗口（WeChatAppEx.app 辅助进程）分别处理。
- 过滤 280×380 搜索浮窗与 `kCGWindowSharingState==0` 僵尸窗口（微信/WPS 更新提示鬼影）。
- 恢复走手动 AX 序列（比系统 activate 更稳定，企业微信同理）。

### Finder 专属适配
- 永不 hide（桌面也是 Finder 窗口）；多窗口恢复优先 AppleScript
  （`set collapsed of every window to false`），AX 串行兜底。

### DockMinimize 功能对等
- 🖼️ **悬停预览**：鼠标悬停 Dock 图标弹出窗口缩略图条；点击缩略图最小化/恢复单个窗口
  （Windows 任务栏风格状态条）；鼠标离开 0.35s 自动收起（可设保持显示）。
- 🫨 **摇窗聚焦**：按住窗口横向摇晃 ≥3 次 → 最小化其它所有窗口；再摇 → 恢复。
- ⌨️ **全局快捷键**：为任意应用绑定快捷键（按一次唤出、再按一次隐藏）；
  内置**老板键**（默认 ⌃A）一键最小化所有窗口。
- 🚫 **黑名单**：贴边隐藏/会拦截点击的特殊软件加黑名单后完全跳过。
- ⚙️ **设置面板**：通用 / 预览 / 黑名单 / 快捷键 / 权限 / 关于。
- 开机自启（SMAppService）、菜单栏图标、日志、崩溃保护、
  EventTap 被禁用时立即恢复并定时自检、防 App Nap、权限状态轮询。

### v0.2.6 稳定性更新

- Dock 点击回调改为读取后台窗口快照，以 O(1) 完成接管/放行决策，移除超时放行造成的“双重点击”。
- 应用启动、退出和切换时立即刷新运行应用缓存；EventTap 超时或被系统禁用时立即恢复。
- 增加窗口决策单元测试、macOS 14/15 双版本构建，以及 Address/Thread Sanitizer 检查。
- 发布包包含 Launcher、卸载器，以及可复现的 DMG 签名、公证与校验流程。

直接下载：[DockZoom v0.2.6 DMG](https://github.com/Namelessying/DockZoom/releases/download/v0.2.6/DockZoom-0.2.6.dmg)

## 界面概览

<p align="center">
  <img src="images/app-icon.png" width="128" alt="DockZoom 应用图标">
</p>

**应用图标**（窗口沿 genie 曲线缩入 Dock，不再使用容易误认成“下载”的箭头）

| 设置面板 | 菜单栏 | DockZoom 开关 |
|---|---|---|
| <img src="images/settings.png" width="280" alt="设置面板"> | <img src="images/menu-bar.png" width="280" alt="DockZoom 菜单栏菜单"> | <img src="images/launcher.png" width="280" alt="开关控制台"> |

> 悬停预览、genie 最小化动画等动态效果建议直接下载体验：
> [Releases 下载](https://github.com/Namelessying/DockZoom/releases/latest)

## 技术要点

| 项 | 说明 |
|---|---|
| 原生动画 | `AXUIElementSetAttributeValue(kAXMinimizedAttribute)` 触发，动画由系统 Dock 播放（无独立 genie 私有 API，此为正解） |
| 点击检测 | CGEventTap（session + headInsert）+ Dock 图标 AX 缓存 + `AXUIElementCopyElementAtPosition` 兜底；后台窗口快照让回调以 O(1) 同步决策 |
| Dock 适配 | 底部/左侧/右侧、自动隐藏、多显示器、放大效果（读 com.apple.dock 偏好，实时刷新） |
| 窗口枚举 | AX `kAXWindows` + `CGWindowList` 双通道合并；`_AXUIElementGetWindow` 关联 windowID |
| 缩略图 | 私有 `CGSHWCaptureWindowList`（可截最小化窗口），需屏幕录制权限 |
| 权限 | 辅助功能（必需）+ 屏幕录制（缩略图可选）；无沙盒；无需关 SIP |
| 构建 | 纯 swiftc（`scripts/build.sh`），无 Xcode 工程；`scripts/make-app.sh` 打包 .app |
| 系统要求 | macOS 13+（本机开发环境 macOS 27 / Xcode 26.6） |

## 构建与运行

```bash
./scripts/build.sh             # 调试构建
./scripts/build.sh release     # 发布构建
./scripts/make-app.sh release  # 打包 .build/DockZoom.app
open .build/DockZoom.app       # 运行
```

> 标准终端里也可以 `swift build`（SwiftPM，Package.swift 已提供）；
> 本项目开发环境受限，故另提供直接 swiftc 的构建脚本。

### 对外发布签名与公证

本机构建默认使用固定开发签名（若存在）或 ad-hoc 签名，仅适合自己使用。公开分发请准备 Apple Developer 的 `Developer ID Application` 证书和 `notarytool` 钥匙串配置：

```bash
DOCKZOOM_SIGN_IDENTITY="Developer ID Application: 你的名称 (TEAMID)" \
DOCKZOOM_NOTARY_PROFILE="DockZoom-Notary" \
DOCKZOOM_REQUIRE_DISTRIBUTION=1 \
./scripts/make-dmg.sh 0.2.6
```

脚本会为三个 App 启用 Hardened Runtime（主 App 同时带 Finder 自动化 entitlement）、签名 DMG、提交苹果公证并装订公证票据；任一步失败都会终止发布。

### 首次运行授权

1. 打开应用后按提示授予**辅助功能**权限（系统设置 → 隐私与安全性 → 辅助功能 → 勾选 DockZoom）。
2. 如需悬停缩略图预览，再授予**屏幕录制**权限。
3. 恢复 Finder 多窗口首次会弹「DockZoom 想要控制 Finder」，点允许。

### 建议测试清单

- [ ] 前台应用点 Dock 图标 → 带 genie 动画最小化；再点 → 恢复
- [ ] **微信**：聊天窗口点击最小化/恢复；打开文章后点图标回聊天；文章窗口独立最小化
- [ ] Finder：多窗口最小化后点击图标全部恢复
- [ ] 无边框/Electron 应用（如 VS Code 无边框、聊天工具）
- [ ] 悬停 Dock 图标 → 预览条出现；点缩略图最小化/恢复单窗口
- [ ] 摇窗聚焦；老板键 ⌃A；设置面板各项开关

## 项目结构

```
DockZoom/
├── Package.swift                       # SwiftPM 清单（标准环境用）
├── scripts/
│   ├── build.sh                        # swiftc 直接构建
│   ├── make-app.sh                     # 打包 .app bundle
│   ├── make-dmg.sh                     # 签名、公证与 DMG 发布包
│   ├── make-icon.swift                 # 生成全尺寸应用图标与 ICNS
│   └── make-menu-preview.swift         # 生成 README 菜单预览图
├── Support/                            # Info.plist、图标与签名权限
├── Tests/DockZoomTests/                # 窗口决策单元测试
├── .github/workflows/ci.yml            # 双系统构建、测试与 Sanitizer
└── Sources/DockZoom/
    ├── main.swift                      # 入口
    ├── AppDelegate.swift               # 生命周期/权限/健康检查/崩溃保护
    ├── MenuBarController.swift         # 状态栏
    ├── DockEventMonitor.swift          # 点击监听 + 图标缓存 + 同步接管判定
    ├── DockDecision.swift              # 可测试的纯窗口决策逻辑
    ├── WindowStateTracker.swift        # 后台窗口状态快照（O(1) 查询）
    ├── HoverEventMonitor.swift         # 悬停监听
    ├── PreviewBarController.swift      # 悬停预览条（SwiftUI）
    ├── WindowManager.swift             # 核心：最小化/恢复/降级链/摇窗/老板键
    │   ├── FinderHandler               # Finder 特判
    │   └── WeChatHandler               # 微信特判
    ├── WindowThumbnailService.swift    # 窗口枚举/僵尸与浮窗过滤
    ├── ShakeMonitor.swift              # 摇窗手势检测
    ├── HotkeyManager.swift             # Carbon 全局热键
    ├── ScreenCaptureManager.swift      # 私有截图
    ├── SettingsManager.swift           # 偏好持久化/黑名单/老板键默认
    ├── SettingsWindowController.swift  # 设置面板（6 标签页）
    ├── AccessibilityManager.swift      # 权限
    ├── PrivateApis.swift               # CGS/SkyLight/Dock 位置/坐标
    ├── UpdateChecker.swift             # GitHub 更新检查（指向本仓库 Releases）
    └── DebugLogger.swift               # 文件日志（~/Library/Logs/DockZoom/）
```

## 作者与贡献者

| 头像 | 贡献者 | 角色 |
|---|---|---|
| <img src="https://github.com/Namelessying.png" width="64" height="64" style="border-radius:50%"> | [Namelessying](https://github.com/Namelessying) | 项目发起人 / 维护者 |
| <img src="https://raw.githubusercontent.com/Namelessying/DockZoom/main/images/app-icon.png" width="64" height="64" style="border-radius:22%"> | DockZoom AI（DeepSeek 驱动） | 协作开发 / 调试 / 发布维护 |
| <img src="https://github.com/openai.png" width="64" height="64" style="border-radius:22%"> | [OpenAI Codex](https://openai.com/codex/) | 协作开发 / 代码审查 / 测试与文档维护 |

欢迎通过 Issue 反馈问题、Pull Request 提交代码，新贡献者会在此列出。

## 参考项目与致谢

| 项目 | 借鉴内容 |
|---|---|
| [oidd/DockMinimize](https://github.com/oidd/DockMinimize) (MIT) | 整体架构、Dock 位置/放大适配、私有 API 声明、Finder 特判、健康检查 |
| [Avi7ii/GetBackMyWindows](https://github.com/Avi7ii/GetBackMyWindows) (MIT) | 微信适配方案（主窗口/文章窗口/辅助进程）、AX 点击命中 |
| [JackTonyMa/DockMinimizer](https://github.com/JackTonyMa/DockMinimizer) | Dock 图标 AX 枚举反查、权限真可用判定 |
| [ejbills/DockDoor](https://github.com/ejbills/DockDoor) | 私有 API 用法参考 |
| [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos) | 最小化 API 与全屏窗口处理经验 |
| [Liu223344/traffic-light-plus](https://github.com/Liu223344/traffic-light-plus) | listen-only EventTap、窗口筛选与自动化测试思路参考 |

## 已知限制与计划

- 原位预览/聚焦预览为计划功能（设置项已就位）。
- SideBar 联动是 DockMinimize 与其自家商业应用的私有协议，未移植。
- 自动隐藏 Dock 场景：首次点击用于唤出 Dock，点击图标本身仍可正常拦截。
- 悬停缩略图依赖未公开的窗口截图接口，未来 macOS 版本可能需要继续适配。

## 仓库

- GitHub: https://github.com/Namelessying/DockZoom
- 下载: https://github.com/Namelessying/DockZoom/releases/latest
