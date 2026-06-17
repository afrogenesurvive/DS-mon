<p align="center">
  <img src="Sources/DS-mon/dslogo1.png" width="120" alt="DS-mon Logo" />
</p>

<h1 align="center">DS-mon</h1>

<p align="center">
  macOS 菜单栏 API 余额监控 · 用量统计 · 本地代理转发（多提供商支持）
  <br/>
  <sub>Swift 6 · SwiftUI + AppKit · macOS 15 Sequoia+ · Apple Silicon</sub>
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

### API 余额监控

- 支持 **DeepSeek** / **Moonshot（Kimi）** 等多提供商，弹窗顶部一键切换
- 每 5 分钟自动刷新余额和可用模型
- 可自定义预警阈值（低于阈值红色闪烁）
- 弹出面板查看详细余额（总余额 / 赠送余额 / 充值余额）

### 菜单栏状态指示器

三根实心柱，一目了然：

| 柱 | 含义 | 颜色 |
|----|------|------|
| **① VU 电平** | 最近请求活动频率 | 绿色→橙色渐变（越高越偏橙），空闲时灰色底色 |
| **② 缓存命中率** | 最近一次请求命中率 | 红 < 70% → 橙 → 青 → 绿 ≥ 95% |
| **③ 余额比率** | 余额 / 预设上限 | 正常绿 / 警告橙 / 低余额红色呼吸闪烁 |

菜单栏文字支持多选显示：余额、今日费用、命中率，可自由组合排序，用 `|` 分隔。

### 本地代理 + 用量统计

在本地启动 HTTP 代理，客户端将 API 地址指向本地端口后，DS-mon 自动：

- **透明转发**请求到对应上游 API（DeepSeek / Moonshot）
- **记录**每次请求的 token 用量（输入 / 缓存命中 / 推理 / 输出）和客户端标识（User-Agent）
- **统计**日/周/月的请求次数、缓存命中率、预估费用、响应时间
- **柱状图**可视化 Hit/Miss/Out token 分布（按小时/日/周），叠加请求数曲线
- **请求列表**最近 5 条请求详情（时间/客户端/协议/响应时间/状态码）
- 支持 **codex（opencode）协议转换**：Responses API ↔ Chat Completions 透明翻译

### 弹出面板

- 顶部：提供商名称 + 状态徽章
- 余额区：总余额、赠送余额、充值余额
- 信息区：预警阈值、默认模型、可用模型列表、账户状态
- 用量区：日/周/月切换，柱状图/请求列表切换，柱状图支持鼠标悬停查看明细
- 底部操作栏：刷新 / 设置 / 退出

### 其他

- 中英双语（自动跟随系统语言）
- 菜单栏图标开关
- 设置面板：通用 / 提供商 / 服务 / 关于

## 前置条件

- macOS 15 Sequoia 或更高版本
- Apple Silicon Mac（M1/M2/M3/M4）
- DeepSeek / Moonshot API Key

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
3. 点击菜单栏图标 → 设置 → 提供商 → 输入 API Key

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
2. 点击「设置」→「提供商」标签页
3. 输入 API Key
4. 余额自动刷新，每 5 分钟更新

### 用量统计

**启用代理：**

1. 设置 → **服务** → 开启「启用代理」
2. 客户端中 `base_url` 设为 `http://localhost:18080`
3. 代理自动转发请求并记录用量

**查看统计：**

- 点击菜单栏图标，弹出面板底部查看用量
- **日/周/月** 切换不同时间范围
- 点击柱状图 / 列表图标切换视图
- 鼠标悬停柱子查看详细数据

## 限制

- **仅记录通过代理的请求** — 直连 API 的请求不会被统计
- **本地代理** — 代理仅监听本地（127.0.0.1）
- **缓存命中率** — 基于 API 返回的 `prompt_cache_hit_tokens` 或 `prompt_tokens_details.cached_tokens` 字段
- **费用估算** — 基于模型定价计算
- **代理端口** — 默认 18080，可在设置中修改（1024–65535）

## opencode 配置

在 `~/.config/opencode/opencode.jsonc` 中配置 provider 的 `baseURL`，将请求转发到 DS-mon 代理（DS-mon 会自动注入 API Key）：

```jsonc
{
  "provider": {
    "deepseek": {
      "options": {
        "baseURL": "http://localhost:18080"
      }
    },
    "moonshotai-cn": {
      "options": {
        "baseURL": "http://localhost:18080"
      }
    }
  }
}
```

模型选择：`moonshotai-cn/kimi-k2.7-code`、`deepseek/deepseek-v4-pro` 等。

## 项目结构

```
DS-mon/
├── Sources/DS-mon/
│   ├── DSmonApp.swift                    # @main 入口 + AppDelegate
│   ├── Constants.swift                   # 应用常量集中管理
│   ├── Strings.swift                     # 多语言字符串
│   ├── Providers/
│   │   ├── Provider.swift                  # Provider 协议定义
│   │   ├── ProviderManager.swift           # 多提供商注册、路由、API Key 管理
│   │   ├── DeepSeekProvider.swift          # DeepSeek 提供商配置
│   │   └── KimiProvider.swift             # Moonshot (Kimi) 提供商配置
│   ├── ProxyServer.swift                 # NWListener 本地 HTTP 代理
│   ├── ProxyConnectionHandler.swift      # 代理请求转发 + URL 构建
│   ├── ProxyConnectionHandler+Responses.swift  # Responses API 处理
│   ├── RateLimiter.swift                 # RPM 限流
│   ├── UsageStore.swift                  # SQLite actor 用量存储
│   ├── UsageLogger.swift                 # 用量记录
│   ├── StatusBarController.swift         # AppKit 状态栏控制器
│   ├── StatusBarView.swift               # 自定义菜单栏视图绘制
│   ├── StatsPopoverView.swift            # SwiftUI 弹出面板
│   ├── UsageBarChart.swift               # 用量柱状图 + 请求曲线
│   ├── RequestListView.swift             # 最近请求列表
│   ├── ThresholdView.swift               # 设置窗口（标签页容器）
│   ├── GeneralSettingsView.swift         # 通用设置
│   ├── ProviderSettingsView.swift        # 提供商设置（API Key + baseURL 帮助）
│   ├── ServicesSettingsView.swift        # 代理 + 同步设置
│   ├── AboutSettingsView.swift           # 关于页面
│   ├── DeepSeekStats.swift               # @Observable 数据模型
│   ├── ResponsesTranslator.swift         # Responses API ↔ Chat Completions
│   ├── ResponsesTypes.swift              # 类型定义
│   ├── ResponsesSession.swift            # SSE 会话状态
│   ├── ToolConverter.swift               # 工具名称转换
│   ├── SyncManager.swift                 # 多机用量同步
│   └── Resources/                        # 图标 + Assets
├── scripts/build.sh                      # 构建打包脚本
├── Package.swift                         # SPM 构建配置
└── README.md
```

## 技术栈

- **Swift 6** — 严格并发检查（`@MainActor`, `Sendable`, `actor`）, `@Observable` 宏
- **SwiftUI + Charts** — 弹出面板、柱状图、设置界面
- **AppKit** — `NSStatusBar`、`NSWindow`、Core Graphics 菜单栏绘制
- **SQLite3** — actor 隔离的 C 级 SQLite 用量存储
- **Network.framework** — `NWListener` / `NWConnection` TCP 代理
- **CryptoKit** — AES-GCM 加密存储 API Key
- **SPM** — Swift Package Manager 构建管理

## 构建 Release

```bash
bash scripts/build.sh [版本号]
```

## 许可证

MIT License © 2026 Cherno76
