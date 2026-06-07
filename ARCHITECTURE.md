# DS-mon 架构图

## 整体架构

```mermaid
graph TB
    subgraph "🎯 入口层 Entry"
        A["@main DSmonApp<br/>SwiftUI App"]
        B["AppDelegate<br/>NSApplicationDelegate"]
    end

    subgraph "📊 数据层 Data"
        C["DeepSeekStats<br/>@Observable 数据模型"]
        D["UsageStore<br/>SQLite 存储<br/>/usage.db"]
        E["ModelPricing<br/>定价模型"]
        F["UsageRecord / AggregatedUsage<br/>数据记录"]
    end

    subgraph "🌐 网络层 Network"
        G["ProxyServer<br/>NWListener 本地代理<br/>port: 18080"]
    end

    subgraph "🖥️ 菜单栏 UI (AppKit)"
        H["StatusBarController<br/>NSStatusItem 管理"]
        I["StatusBarView<br/>自定义 NSView 绘制"]
        J["Label Observation<br/>withObservationTracking"]
    end

    subgraph "🪟 Popover UI (SwiftUI)"
        K["StatsPopoverView<br/>弹出内容"]
        L["UsageBarChart<br/>Swift Charts 柱状图"]
        M["StatusDotView<br/>指示灯"]
    end

    subgraph "⚙️ 设置面板 (SwiftUI)"
        N["ThresholdView<br/>设置面板"]
    end

    subgraph "🌍 国际化"
        O["Strings<br/>中/英 多语言"]
        P["Language<br/>auto/zh/en"]
    end

    subgraph "🌙 Moon Bridge"
        Q["moonbridge 子进程<br/>Process 管理"]
        R["moonbridge.yml 配置"]
    end

    subgraph "🔗 外部依赖"
        S["DeepSeek API<br/>api.deepseek.com"]
        T["Keychain<br/>API Key 安全存储"]
        U["Codex CLI<br/>客户端"]
    end

    %% 入口 → 各层
    A --> B
    B --> C
    B --> H
    B --> Q

    %% 数据流
    C -->|"读取 API Key"| T
    C -->|"HTTP 请求"| S
    C --> H

    %% 代理流
    U -->|"HTTP 请求转发"| G
    G -->|"/v1/chat/completions"| S
    G -->|"/v1/responses"| Q
    Q --> R
    G --> D

    %% UI 绑定
    H --> I
    H --> K
    K --> L
    K --> M
    H --> N

    %% 数据 → UI
    D --> K
    C --> K
    N --> C
    N --> G
    N --> B

    %% 国际化
    O -.-> K
    O -.-> N
    O -.-> H

    %% 通知
    G -.->|"NotificationCenter<br/>usageRecorded"| K
    O -.->|"NotificationCenter<br/>languageDidChange"| H
    N -.->|"NotificationCenter<br/>showMenuIconDidChange"| H
```

## 模块依赖关系

```mermaid
graph LR
    subgraph "文件级依赖"
        DSmonApp["DSmonApp.swift"]
        DeepSeekStats["DeepSeekStats.swift"]
        ProxyServer["ProxyServer.swift"]
        UsageStore["UsageStore.swift"]
        StatsPopoverView["StatsPopoverView.swift"]
        StatusBarController["StatusBarController.swift"]
        ThresholdView["ThresholdView.swift"]
        Strings["Strings.swift"]
    end

    DSmonApp --> StatusBarController
    DSmonApp --> DeepSeekStats
    DSmonApp --> ProxyServer

    StatusBarController --> DeepSeekStats
    StatusBarController --> StatsPopoverView
    StatusBarController --> ThresholdView
    StatusBarController --> Strings

    StatsPopoverView --> DeepSeekStats
    StatsPopoverView --> UsageStore
    StatsPopoverView --> Strings

    ThresholdView --> DeepSeekStats
    ThresholdView --> Strings
    ThresholdView --> ProxyServer

    ProxyServer --> UsageStore
    ProxyServer --> DeepSeekStats
```

## 数据流

```mermaid
sequenceDiagram
    participant Client as Codex CLI / 客户端
    participant Proxy as ProxyServer (18080)
    participant DS as DeepSeek API
    participant MB as Moon Bridge (38441)
    participant Store as UsageStore (SQLite)
    participant UI as StatsPopoverView

    Note over Client,UI: 请求转发流程

    Client->>Proxy: HTTP POST /v1/chat/completions
    Proxy->>DS: 透明转发请求
    DS-->>Proxy: SSE 响应流 + usage
    Proxy-->>Client: 转发响应
    Proxy->>Store: 写入 UsageRecord
    Proxy-->>UI: post usageRecorded 通知
    UI->>Store: 重新查询聚合数据

    Client->>Proxy: HTTP POST /v1/responses
    Proxy->>MB: 转发到 Moon Bridge
    MB-->>Proxy: SSE 响应 + event: response.completed
    Proxy-->>Client: 转发响应
    Proxy->>Store: 提取 usage 写入

    Note over UI,Store: 数据查询流程

    UI->>Store: queryDaily / queryWeekly / queryMonthly
    Store-->>UI: AggregatedUsage[]
    UI->>Store: queryHourlyBreakdown / queryDailyBreakdown
    Store-->>UI: TokenBar[] (柱状图数据)
```

## 关键设计说明

| 关注点 | 方案 |
|--------|------|
| **余额监控** | 每 60s 自动轮询 DeepSeek API，余额低于阈值时菜单栏红色闪烁 |
| **API Key 安全** | 通过 macOS Keychain（Security Framework）存储 |
| **用量统计** | 本地 HTTP 代理透明拦截 + 解析 SSE 流中的 usage 数据 |
| **持久化** | SQLite (WAL 模式)，存储 usage 记录并支持按小时/天/周聚合 |
| **国际化** | 枚举式 Strings + NotificationCenter 通知刷新 UI |
| **Moon Bridge** | 子进程管理 + `/v1/responses` 路由到本地 38441 端口 |
| **UI 刷新** | `@Observable` + `withObservationTracking` 增量更新 |
| **Chart** | Apple Swift Charts 框架，支持交互式 tooltip |
