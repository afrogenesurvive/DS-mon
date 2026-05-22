<p align="center">
  <img src="Sources/DS-mon/dslogo1.png" width="120" alt="DS-mon Logo" />
</p>

<h1 align="center">DS-mon</h1>

<p align="center">
  macOS 菜单栏 DeepSeek API 余额实时监控工具
  <br/>
  <sub>Swift 6 + SwiftUI + AppKit | macOS 15 Sequoia+ | Apple Silicon</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift" alt="Swift 6.0"/>
  <img src="https://img.shields.io/badge/macOS-15.0+-blue?logo=apple" alt="macOS 15.0+"/>
  <img src="https://img.shields.io/badge/Arch-arm64-brightgreen?logo=apple" alt="Apple Silicon"/>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
  <a href="https://github.com/Cherno76/homebrew-tap"><img src="https://img.shields.io/badge/brew-tap-F5492C?logo=homebrew" alt="Homebrew"/></a>
</p>

## 截图

<p align="center">
  <img src="screenshot.png" width="400" alt="DS-mon 截图" />
</p>

## 功能

- **菜单栏余额监控** — 在菜单栏实时显示 DeepSeek 账户余额，一目了然
- **余额过低预警** — 可自定义预警阈值，余额低于阈值时红色闪烁提醒
- **自动刷新** — 每 60 秒自动拉取最新余额和可用模型列表
- **Keychain 安全存储** — API Key 通过系统钥匙串加密存储，不落盘明文
- **优雅的弹出面板** — 点击菜单栏图标查看余额、模型、状态详情
- **直观的错误提示** — 细分 API Key 无效、网络超时、服务器错误等场景
- **多语言支持** — 自动检测系统语言，设置中可手动切换中文/English

## 前置条件

- macOS 15 Sequoia 或更高版本
- Apple Silicon Mac（M1/M2/M3/M4）
- DeepSeek API Key（[deepseek.com](https://platform.deepseek.com/api_keys)）

## 安装

### 方式一：Homebrew（推荐）

```bash
brew tap Cherno76/tap
brew install --cask ds-mon
```

### 方式二：下载预编译包

从 [Releases](https://github.com/Cherno76/DS-mon/releases) 下载最新版 `DS-mon-v*.zip`，解压后：

1. 将 `DS-mon.app` 拖入 `应用程序` 文件夹
2. **右键 → 打开**（首次运行需绕过 Gatekeeper）
3. 点击菜单栏图标 → 设置 → 输入 API Key → 保存

### 方式三：从源码构建

```bash
git clone https://github.com/Cherno76/DS-mon.git
cd DS-mon
swift build -c release --disable-sandbox
open .build/release/DS-mon
```

## 使用方法

1. 启动后菜单栏出现 Logo 图标和余额 `¥0.00`
2. 点击菜单栏图标打开弹出面板
3. 点击「设置」打开配置窗口
4. 输入 DeepSeek API Key，点击「保存 Key」
5. 钥匙串弹窗 → 点击 **「始终允许」**
6. 余额自动刷新显示，之后每 60 秒自动更新

### 状态指示

| 状态 | 菜单栏 | 面板徽章 |
|------|--------|---------|
| 余额充足（≥阈值） | 默认颜色 | 🟢 正常 |
| 余额低于阈值 | 🔴 红色闪烁 | 🔴 红色闪烁 |
| 网络错误 / Key 无效 | 灰色 | 🟠 异常 |

## 配置

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| 余额预警阈值 | 低于此值时红色闪烁 | ¥20 |
| API Key | DeepSeek 平台 API 密钥 | — |
| 自动刷新间隔 | 余额自动拉取周期 | 60 秒 |
| 语言 | 界面语言（跟随系统/中文/English） | 跟随系统 |

## 项目结构

```
DS-mon/
├── Sources/
│   └── DS-mon/
│       ├── DSmonApp.swift        # 应用入口 + 状态栏控制器 + 弹出面板 UI
│       ├── DeepSeekStats.swift    # 数据模型 + 网络请求 + Keychain 管理
│       ├── ThresholdView.swift   # 设置窗口 UI
│       ├── Strings.swift          # 多语言字符串管理
│       ├── dslogo.png            # 菜单栏图标（鲸鱼 + 放大镜）
│       ├── dslogo1.png           # 应用图标（鲸鱼 + 数据图表）
│       └── Assets.xcassets/      # Xcode 资源目录
├── .github/
│   └── workflows/
│       └── release.yml           # GitHub Actions 自动构建 + 发布
├── build/
│   └── DS-mon.app/               # 预编译应用包
├── Package.swift                 # SPM 构建配置
└── .gitignore
```

## 技术栈

- **Swift 6** — 使用 `@Observable` 宏、`@MainActor` 严格并发
- **SwiftUI** — 弹出面板和设置窗口 UI
- **AppKit** — 状态栏组件（`NSStatusBar`）、弹出面板（`NSPopover`）
- **Security.framework** — Keychain 原生 API 安全存储
- **SPM** — Swift Package Manager 构建管理

## 构建 Release

```bash
# Build
swift build -c release --disable-sandbox

# Package .app
mkdir -p build/DS-mon.app/Contents/{MacOS,Resources}
cp .build/release/DS-mon build/DS-mon.app/Contents/MacOS/
cp -R .build/release/DS-mon_DS-mon.bundle build/DS-mon.app/

# Generate icon (requires dslogo1.png)
mkdir -p /tmp/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" dslogo1.png --out "/tmp/AppIcon.iconset/icon_${s}x${s}.png"
  sips -z "$((s*2))" "$((s*2))" dslogo1.png --out "/tmp/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns /tmp/AppIcon.iconset -o build/DS-mon.app/Contents/Resources/AppIcon.icns

cp Info.plist build/DS-mon.app/Contents/
codesign --force --deep --sign - build/DS-mon.app
open build/DS-mon.app
```

Or simply push a tag — the **GitHub Actions workflow** handles everything automatically:

```bash
git tag v1.0
git push origin v1.0
```

## 许可证

MIT License © 2026 Cherno76
