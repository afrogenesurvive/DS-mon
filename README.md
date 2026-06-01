<p align="center">
  <img src="Sources/DS-mon/dslogo1.png" width="120" alt="DS-mon Logo" />
</p>

<h1 align="center">DS-mon</h1>

<p align="center">
  macOS 菜单栏 DeepSeek API 余额监控 + 用量统计工具
  <br/>
  <sub>Swift 6 + SwiftUI + AppKit | macOS 15 Sequoia+ | Apple Silicon</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift" alt="Swift 6.0"/>
  <img src="https://img.shields.io/badge/macOS-15.0+-blue?logo=apple" alt="macOS 15.0+"/>
  <img src="https://img.shields.io/badge/Arch-arm64-brightgreen?logo=apple" alt="Apple Silicon"/>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
  <a href="https://github.com/Cherno76/homebrew-tap"><img src="https://img.shields.io/badge/brew-tap-F5492C?logo=homebrew" alt="Homebrew"/></a>
  <img src="https://img.shields.io/badge/version-2.0-blue" alt="v2.0"/>
</p>

## 截图

<p align="center">
  <img src="screenshot.png" width="400" alt="DS-mon 截图" />
</p>

## 功能

### v2.0 新增

- **本地代理拦截** — 在本地启动 HTTP 代理，透明转发 DeepSeek API 请求并自动记录 token 用量
- **Token 用量统计** — 弹窗面板内按日/周/月查看：请求次数、总 token、缓存命中率、推理 token、预估费用、平均延迟
- **柱状图** — 可视化 Hit/Miss/Out token 分布，今日按小时、本周按日、本月按周
- **Proxy 代理开关** — 设置面板中可随时启用/禁用代理，配置端口

### 原有功能

- **菜单栏余额监控** — 实时显示 DeepSeek 账户余额
- **余额过低预警** — 自定义预警阈值，红色闪烁提醒
- **自动刷新** — 每 60 秒自动拉取最新余额和可用模型
- **Keychain 安全存储** — API Key 通过系统钥匙串加密存储
- **优雅的弹出面板** — 点击菜单栏图标查看余额、用量、模型详情
- **多语言支持** — 自动检测系统语言，支持中文/English
- **柱状图悬浮提示** — 鼠标悬停查看详细 token 数据和预估费用

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

从 [Releases](https://github.com/Cherno76/DS-mon/releases) 下载最新版，解压后：

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

### 余额监控

1. 启动后菜单栏出现图标和余额
2. 点击菜单栏图标打开弹出面板
3. 点击「设置」打开配置窗口
4. 输入 DeepSeek API Key，点击「保存 Key」
5. 钥匙串弹窗 → 点击 **「始终允许」**
6. 余额自动刷新，每 60 秒更新

### 用量统计（v2.0）

DS-mon 通过本地代理服务器自动记录 DeepSeek API 的 token 消耗。

**启用代理：**

1. 打开设置 → **代理** 区域 → 开启「启用代理」
2. 在 DeepSeek 客户端中将 `base_url` 设置为：
   ```
   http://localhost:18080
   ```
3. 保持 DS-mon 运行，代理会自动转发请求并记录用量
4. 应用启动时自动启用代理（可在设置中关闭）

**查看统计：**

- 点击菜单栏图标 → 弹出面板底部「用量统计」
- 使用 **日/周/月** 切换查看不同时间范围
- 柱状图显示 Hit（缓存命中）/ Miss（缓存未命中）/ Out（输出）token 分布
- 鼠标悬停柱子查看详细数据：总数、缓存命中率、预估费用
- 对应 Token 计价：Hit ¥0.02/M、Miss ¥1/M、Out ¥2/M（DeepSeek V4 Flash）

## 限制

- **仅记录通过代理的请求** — 直连 DeepSeek API（不走 localhost:18080）的请求不会被统计
- **本地代理** — 代理仅监听本地（127.0.0.1），不影响系统其他网络流量
- **缓存命中率** — 基于 API 返回的 `prompt_cache_hit_tokens` 字段，部分模型可能不返回此字段
- **费用估算** — 基于 DeepSeek V4 Flash 定价计算，其他模型价格可能不同
- **代理端口** — 默认 18080，可在设置中修改（1024–65535）

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
| 代理开关 | 启用/禁用本地代理 | 启动时自动启用 |
| 代理端口 | 本地监听端口 | 18080 |
| 自动刷新间隔 | 余额自动拉取周期 | 60 秒 |
| 语言 | 界面语言（跟随系统/中文/English） | 跟随系统 |

## 项目结构

```
DS-mon/
├── Sources/
│   └── DS-mon/
│       ├── DSmonApp.swift        # 应用入口 + 状态栏控制器 + 弹出面板 UI
│       ├── DeepSeekStats.swift    # 数据模型 + 网络请求 + Keychain 管理
│       ├── ProxyServer.swift     # 本地 HTTP 代理（v2.0）
│       ├── UsageStore.swift      # SQLite 用量存储与聚合查询（v2.0）
│       ├── ThresholdView.swift   # 设置窗口 UI
│       ├── Strings.swift          # 多语言字符串管理
│       ├── dslogo.png            # 菜单栏图标
│       ├── dslogo1.png           # 应用图标
│       └── Assets.xcassets/      # Xcode 资源目录
├── scripts/
│   └── build.sh                  # 构建打包脚本
├── .github/
│   └── workflows/
│       └── release.yml           # GitHub Actions 自动构建 + 发布
├── Package.swift                 # SPM 构建配置
└── README.md
```

## 技术栈

- **Swift 6** — 使用 `@Observable` 宏、`@MainActor` 严格并发
- **SwiftUI + Charts** — 弹出面板和柱状图
- **AppKit** — 状态栏组件（`NSStatusBar`）、自定义弹出窗口
- **SQLite3** — C 级 SQLite 本地用量存储
- **Network.framework** — 本地 HTTP 代理（`NWListener`）
- **Security.framework** — Keychain 原生 API 安全存储
- **SPM** — Swift Package Manager 构建管理

## 构建 Release

```bash
bash scripts/build.sh [版本号]
```

Or simply push a tag — the **GitHub Actions workflow** handles everything automatically:

```bash
git tag v2.0
git push origin v2.0
```

## 许可证

MIT License © 2026 Cherno76
