<p align="center">
  <img src="Sources/DS-mon/dslogo1.png" width="120" alt="DS-mon Logo" />
</p>

<h1 align="center">DS-mon</h1>

<p align="center">
  macOS 菜单栏 API 余额监控 · 用量统计 · 本地代理转发
  <br/>
  <sub>Swift 6 · SwiftUI + AppKit · macOS 15 Sequoia+ · Apple Silicon</sub>
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

### 多提供商支持

不再局限于 DeepSeek。内置 6 个预设提供商，可随时切换：

| 提供商 | 余额 API | 货币 |
|--------|----------|------|
| **DeepSeek** | ✅ /user/balance | CNY |
| **OpenAI** | ❌ | USD |
| **Anthropic** | ❌ | USD |
| **OpenRouter** | ✅ /auth/key | USD |
| **Google Gemini** | ❌ | USD |
| **Kimi (Moonshot)** | ✅ /v1/users/me/balance | CNY |

- 每个提供商可独立设置 API Key（AES-GCM 加密存储，取代旧版 Keychain）
- 每个模型可自定义 Hit/Miss/Out 计费单价
- 支持禁用/启用、恢复默认

### 菜单栏状态指示器

菜单栏三项实心柱，一目了然：

| 柱 | 含义 | 颜色含义 |
|----|------|----------|
| **① 左（VU 电平）** | 最近请求活动频率 | 绿色（直连）/ 蓝色（经 Relay）/ 空闲时灰色底色 |
| **② 中（缓存命中率）** | 当前小时缓存命中率 | 红 < 70% → 橙 → 青 → 绿 ≥ 95% |
| **③ 右（余额比率）** | 余额 / 预设上限 | 正常绿 / 警告橙 / 低余额红色呼吸闪烁 |

可在设置中选择关闭指示器，或切换菜单栏显示余额文字 / 命中率百分比。

### 余额监控

- 每 60 秒自动刷新余额和可用模型
- 可自定义预警阈值（低于阈值红色闪烁）
- 弹出面板查看详细余额（总余额 / 赠送余额 / 充值余额）

### 本地代理转发 + 用量统计

在本地启动 HTTP 代理，客户端将 API 地址指向本地端口后，DS-mon 自动：

- **透明转发**请求到上游 API
- **记录**每次请求的 token 用量（输入 / 缓存命中 / 推理 / 输出）
- **统计**日/周/月的请求次数、缓存命中率、预估费用、平均延迟
- **柱状图**可视化 Hit/Miss/Out token 分布（按小时/日/周）

支持 **codex-relay** 协议转换器：将 OpenAI SDK 请求转换为上游 API 格式，任一提供商 SDK 均可通过 relay 兼容。

### 弹出面板

- 顶部：提供商名称 + 状态徽章（正常/警告/异常/加载中）
- 余额区：总余额、赠送余额、充值余额
- 信息区：预警阈值、默认模型、可用模型列表、账户状态
- 用量区：日/周/月切换，带柱状图的详细统计（支持鼠标悬停查看明细）
- 底部操作栏：刷新 / 设置 / 退出

### 其他

- 多语言：自动跟随系统语言（中文 / English）
- 菜单栏图标开关
- 菜单栏文字显示模式（余额 / 命中率 / 关闭）
- codex-relay 崩溃自动重启

## 前置条件

- macOS 15 Sequoia 或更高版本
- Apple Silicon Mac（M1/M2/M3/M4）
- 至少一个 API Key（视提供商而定）

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
3. 点击菜单栏图标 → 设置 → 选择提供商 → 输入 API Key → 保存

### 方式三：从源码构建

```bash
git clone https://github.com/Cherno76/DS-mon.git
cd DS-mon
swift build -c release --disable-sandbox
open .build/release/DS-mon
```

## 使用方法

### 首次配置

1. 启动后菜单栏出现图标，点击打开弹出面板
2. 点击「设置」打开配置窗口
3. 选择「提供商」标签页 → 选中需要的提供商（如 DeepSeek）
4. 输入对应的 API Key，点击「保存」
5. 余额自动刷新，每 60 秒更新

### 用量统计

DS-mon 通过本地代理服务器自动记录 API 的 token 消耗。

**启用代理：**

1. 打开设置 → **服务**标签页 → 代理区域 → 开启「启用代理」
2. 在客户端中将 `base_url` 设置为：
   ```
   http://localhost:18080
   ```
3. 保持 DS-mon 运行，代理会自动转发请求并记录用量
4. 应用启动时自动启用代理（可在设置中关闭）

**启用协议转换器（codex-relay）：**

用于将 OpenAI SDK 的调用转换为上游 API 格式。启用后：

1. 设置 → **服务**标签页 → 协议转换器 → 开启
2. 客户端 SDK 指向 `http://localhost:18080`（经代理转发），或指向 `http://localhost:4446`（直连 relay）
3. relay 支持模型映射，可在提供商配置中设置

**查看统计：**

- 点击菜单栏图标 → 弹出面板底部「用量统计」
- 使用 **日/周/月** 切换查看不同时间范围
- 柱状图显示 Hit / Miss / Out token 分布
- 鼠标悬停柱子查看详细数据：总数、缓存命中率、预估费用

## 设置面板

| 标签页 | 配置项 |
|--------|--------|
| **通用** | 菜单栏图标开关、状态指示器开关、文字显示模式（余额/命中率/关闭）、界面语言 |
| **提供商** | 提供商列表（启用/禁用）、API Key 管理、设置活跃提供商、模型定价覆盖 |
| **服务** | 本地代理开关及端口、协议转换器（codex-relay）开关及状态 |
| **关于** | 版本信息、GitHub 链接 |

## 限制

- **仅记录通过代理的请求** — 直连上游 API 的请求不会被统计
- **本地代理** — 代理仅监听本地（127.0.0.1），不影响系统其他网络流量
- **缓存命中率** — 基于 API 返回的 `prompt_cache_hit_tokens` 字段，部分模型可能不返回此字段
- **费用估算** — 基于各模型定价计算，自定义模型需手动配置价格
- **代理端口** — 默认 18080，可在设置中修改（1024–65535）

## 项目结构

```
DS-mon/
├── Sources/
│   └── DS-mon/
│       ├── DSmonApp.swift             # @main 入口 + AppDelegate
│       ├── DeepSeekStats.swift         # @Observable 数据模型 + 余额/模型 API 请求
│       ├── Provider.swift              # 提供商配置模型 + 6 个内置预设
│       ├── ProviderManager.swift       # @Observable 提供商管理器 + AES-GCM 加密存储
│       ├── ProxyServer.swift           # NWListener 本地 HTTP 代理 + 健康监控
│       ├── ProxyConnectionHandler.swift# 单连接处理：HTTP 解析 + 转发 + 用量记录
│       ├── CodexRelayManager.swift      # codex-relay 子进程生命周期管理
│       ├── UsageStore.swift            # SQLite actor 用量存储 + 聚合查询 + 模型定价
│       ├── StatusBarController.swift   # AppKit 状态栏控制器 + StatusBarView 自定义绘制
│       ├── StatsPopoverView.swift      # SwiftUI 弹出面板
│       ├── ThresholdView.swift         # SwiftUI 设置窗口（4 标签页）
│       ├── Constants.swift             # 应用常量集中管理
│       ├── Strings.swift               # 多语言字符串 + Notification.Name 定义
│       ├── menu_icon.png               # 菜单栏图标
│       ├── dslogo.png                  # README 用 logo
│       ├── dslogo1.png                 # Dock 图标
│       └── Assets.xcassets/            # 资源目录
├── codex-relay-src/                    # 协议转换器 Rust 源码
├── scripts/
│   └── build.sh                        # 构建打包脚本（含 codex-relay 编译）
├── .github/workflows/
│   └── release.yml                     # GitHub Actions 自动构建 + 发布
├── Package.swift                       # SPM 构建配置
└── README.md
```

## 技术栈

- **Swift 6** — 严格并发检查（`@MainActor`, `Sendable`, `actor`）, `@Observable` 宏
- **SwiftUI + Charts** — 弹出面板、柱状图、设置界面
- **AppKit** — `NSStatusBar`、`NSWindow` 自定义弹出、Core Graphics 自定义绘制
- **SQLite3** — actor 隔离的 C 级 SQLite 用量存储
- **Network.framework** — `NWListener` / `NWConnection` TCP 代理与健康检测
- **CryptoKit** — AES-GCM 加密存储 API Key
- **SPM** — Swift Package Manager 构建管理
- **Rust** — codex-relay（协议转换器二进制，打包进 .app bundle）

## 构建 Release

```bash
bash scripts/build.sh [版本号]
```

GitHub Actions 自动构建（tag 触发）：

```bash
git tag v2.x
git push origin v2.x
```

## 许可证

MIT License © 2026 Cherno76
