import Foundation

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
    static let showMenuIconDidChange = Notification.Name("showMenuIconDidChange")
    static let usageRecorded = Notification.Name("usageRecorded")
    static let showIndicatorDidChange = Notification.Name("showIndicatorDidChange")
    static let showBalanceDidChange = Notification.Name("showBalanceDidChange")
    static let menuBarTextDisplayDidChange = Notification.Name("menuBarTextDisplayDidChange")
}

enum Language: String, CaseIterable, Identifiable {
    case auto = "auto"
    case zh = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return isSystemZH ? "简体中文 (跟随系统)" : "English (System)"
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    private var isSystemZH: Bool {
        let locale = Locale.preferredLanguages.first ?? "en"
        return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
    }
}

enum Strings {
    /// UserDefaults keys — 集中管理，避免散落各处的字符串字面量
    enum Keys {
        static let appLanguage      = "app_language"
        static let balanceThreshold = "balance_threshold"
        static let maxBalanceAmount = "max_balance_amount"
        static let proxyPort        = "proxy_port"
        static let proxyEnabled     = "proxy_enabled"
        static let showMenuIcon     = "show_menu_icon"
        static let showIndicator   = "show_indicator"
        static let showBalance     = "show_balance"
        static let menuBarTextDisplay = "menu_bar_text_display"
        static let modelPricingOverrides = "model_pricing_overrides"
        static let syncEnabled = "sync_enabled"
        static let syncMode = "sync_mode"
        static let syncListenPort = "sync_listen_port"
        static let syncTargetAddress = "sync_target_address"
        static let syncInterval = "sync_interval"
    }

    /// 判断当前是否为中文界面。直接读取 UserDefaults，无需缓存。
    private static var isZH: Bool {
        let saved = UserDefaults.standard.string(forKey: Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }

    static func notifyLanguageChanged() {
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
    }

    // Language picker
    static var languageLabel: String { isZH ? "语言" : "Language" }
    static var languageSystem: String {
        let locale = Locale.preferredLanguages.first ?? "en"
        let isSysZH = locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        return isSysZH ? "跟随系统" : "System"
    }

    // Status bar
    static var statusNormal: String { isZH ? "正常" : "NORM" }
    static var statusLowBalance: String { isZH ? "余额低" : "LOWBAL" }
    static var statusError: String { isZH ? "异常" : "ERROR" }
    static var statusWarning: String { isZH ? "余额低" : "WARN" }

    // Popover header
    static var popoverTitle: String { "DS-mon" }
    static var badgeLoading: String { isZH ? "查询中..." : "Loading..." }
    static var badgeNormal: String { isZH ? "正常" : "NORM" }
    static var badgeError: String { isZH ? "预警" : "WARN" }
    static var badgeWarning: String { isZH ? "偏低" : "LOW" }

    // Balance section
    static var currentBalance: String { isZH ? "当前余额" : "Balance" }
    static var grantedPrefix: String { isZH ? "赠送 ¥%.2f" : "Granted ¥%.2f" }
    static var toppedUpPrefix: String { isZH ? "充值 ¥%.2f" : "Topped Up ¥%.2f" }

    // Info section
    static var thresholdLabel: String { isZH ? "预警线" : "Alert Line" }
    static var availableModels: String { isZH ? "可用模型" : "Models" }
    static var accountStatus: String { isZH ? "账户状态" : "Status" }
    static var available: String { isZH ? "可用" : "Available" }
    static var insufficient: String { isZH ? "余额不足" : "Insufficient" }
    static var errorLabel: String { isZH ? "错误" : "Error" }

    // Action bar
    static var refresh: String { isZH ? "刷新" : "Refresh" }
    static var settings: String { isZH ? "设置" : "Settings" }
    static var quit: String { isZH ? "退出" : "Quit" }
    static var quitTitle: String { isZH ? "确认退出" : "Quit" }
    static var quitMessage: String { isZH ? "确定要退出 DS-mon 吗？" : "Are you sure you want to quit DS-mon?" }
    static var quitConfirm: String { isZH ? "退出" : "Quit" }
    static var cancel: String { isZH ? "取消" : "Cancel" }

    // Settings window
    static var settingsTitle: String { isZH ? "设置" : "Settings" }
    static var balanceAlert: String { isZH ? "余额预警" : "Balance Alert" }
    static var alertHint: String { isZH ? "余额低于此值时菜单栏红色闪烁" : "Menu bar flashes red when balance drops below" }
    static var maxBalanceLabel: String { isZH ? "环形上限" : "Ring Max" }
    static var maxBalanceHint: String { isZH ? "菜单栏环形百分比以此为基准，默认 ¥100" : "Ring percentage is relative to this amount, default ¥100" }
    static var apiKeyLabel: String { isZH ? "API Key" : "API Key" }
    static var apiKeyPlaceholder: String { "sk-..." }
    static var saveButton: String { isZH ? "保存" : "Save" }
    static var savedHint: String { isZH ? "已保存，正在刷新..." : "Saved, refreshing..." }
    static var saveFailedHint: String { isZH ? "保存失败，请重试" : "Save failed, please retry" }

    // DeepSeekStats errors
    static var noAPIKey: String { isZH ? "未设置 API Key" : "API Key not set" }
    static var invalidResponse: String { isZH ? "查询失败：无效的服务器响应" : "Query failed: invalid server response" }
    static var parseFailed: String { isZH ? "查询失败：解析响应数据失败" : "Query failed: failed to parse response" }
    static var keyInvalid: String { isZH ? "API Key 无效或已过期" : "API Key invalid or expired" }
    static var rateLimited: String { isZH ? "请求过于频繁，请稍后重试" : "Rate limited, please retry later" }
    static var serviceDown: String { isZH ? "DeepSeek 服务暂时不可用" : "DeepSeek service temporarily unavailable" }
    static func queryFailed(code: Int) -> String {
        isZH ? "查询失败（HTTP \(code)）" : "Query failed (HTTP \(code))"
    }
    static var timeout: String { isZH ? "网络连接超时" : "Connection timed out" }
    static var noNetwork: String { isZH ? "网络连接失败" : "Network connection failed" }
    static func networkError(_ msg: String) -> String {
        isZH ? "网络错误：\(msg)" : "Network error: \(msg)"
    }
    static var keychainSaveFailed: String { isZH ? "保存 API Key 失败" : "Failed to save API Key" }


    // Settings tabs
    static var menuBarDisplay: String { isZH ? "菜单栏显示" : "Menu Bar Display" }
    static var menuIconLabel: String { isZH ? "图标" : "Icon" }
    static var indicatorLabel: String { isZH ? "状态指示器" : "Indicator" }
    static var balanceLabel: String { isZH ? "余额" : "Balance" }
    static var hitRateLabel: String { isZH ? "命中率" : "Hit Rate" }
    static var textDisplayLabel: String { isZH ? "菜单栏文字" : "Menu Bar Text" }

    // Provider
    static var activeProviderLabel: String { isZH ? "活跃提供商" : "Active Provider" }
    static var setActiveProvider: String { isZH ? "设为活跃" : "Set Active" }
    static var activeProviderBadge: String { isZH ? "活跃中" : "Active" }
    static var addProviderTitle: String { isZH ? "添加提供商" : "Add Provider" }
    static var addProviderHint: String { isZH ? "恢复内置提供商" : "Restore built-in provider" }
    static var addProviderCustomHint: String { isZH ? "自定义提供商可通过代码配置" : "Custom providers can be configured via code" }
    static var allProvidersAdded: String { isZH ? "所有内置提供商已添加" : "All built-in providers added" }
    static var selectProviderHint: String { isZH ? "请选择一个提供商" : "Select a provider" }
    static var removeProvider: String { isZH ? "移除提供商" : "Remove Provider" }
    static var defaultModelSection: String { isZH ? "默认模型" : "Default Model" }
    static var defaultModelHint: String { isZH ? "代理转发时使用的默认模型" : "Default model used for proxy forwarding" }
    static var defaultModelLabel: String { isZH ? "默认模型" : "Model" }
    static var defaultModelLabel2: String { isZH ? "默认模型" : "Default Model" }
    static var modelOverrideSection: String { isZH ? "模型覆写" : "Model Override" }
    
    // Dev platform
    static var developerPlatformSection: String { isZH ? "开发平台" : "Developer Platform" }
    static var developerPlatformHint: String { isZH ? "提供商开发平台的 URL，如 DeepSeek: platform.deepseek.com" : "URL for the provider's developer platform, e.g. DeepSeek: platform.deepseek.com" }
    static var noBalanceAPI: String { isZH ? "该提供商无余额查询" : "Balance API not available" }
    static var providerBalance: String { isZH ? "余额" : "Balance" }
    static func apiKeyHint(_ name: String) -> String {
        isZH ? "\(name) 的 API Key 将用于代理转发" : "API Key for \(name) will be used for proxy forwarding"
    }
    static var providerList: String { isZH ? "提供商" : "Providers" }
    static var save: String { isZH ? "保存" : "Save" }
    static var keySaved: String { isZH ? "API Key 已保存" : "API Key saved" }
    static var aboutDesc: String { isZH ? "实时监控 DeepSeek API 使用情况" : "Monitors DeepSeek API usage in real-time" }


    // Proxy
    static var proxySection: String { isZH ? "本地代理" : "Proxy" }
    static var proxyToggle: String { isZH ? "启用代理" : "Enable Proxy" }
    static var proxyToggleHint: String { isZH ? "拦截并记录 DeepSeek API 调用数据" : "Intercept and log DeepSeek API calls" }
    static var proxyPortLabel: String { isZH ? "代理端口" : "Proxy Port" }
    static var proxyPortHint: String { isZH ? "客户端设置 base_url 为 http://localhost:{port}" : "Set client base_url to http://localhost:{port}" }
    static var proxyRunning: String { isZH ? "代理已启动" : "Proxy running" }
    static var proxyStopped: String { isZH ? "代理已停止" : "Proxy stopped" }

    // Usage stats
    static var usageTitle: String { isZH ? "用量统计" : "Usage Stats" }
    static var requestsLabel: String { isZH ? "请求数" : "Requests" }
    static var totalTokensLabel: String { isZH ? "总 Tokens" : "Total Tokens" }
    static var cachedTokensLabel: String { isZH ? "缓存命中" : "Cache Hit" }
    static var reasoningTokensLabel: String { isZH ? "推理 Tokens" : "Reasoning" }
    static var costLabel: String { isZH ? "预估费用" : "Est. Cost" }
    static var latencyLabel: String { isZH ? "平均延迟" : "Avg Latency" }
    static var todayLabel: String { isZH ? "今日" : "Today" }
    static var weekLabel: String { isZH ? "周" : "Week" }
    static var monthLabel: String { isZH ? "月" : "Month" }
    static var noUsageData: String { isZH ? "暂无数据" : "No data" }
    static func requestsCount(_ n: Int) -> String {
        isZH ? "\(n) 次" : "\(n)"
    }
    static func tokensShort(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: "%.1fM", m)
        }
        if n >= 1000 {
            return "\(n / 1000)k"
        }
        return "\(n)"
    }
    static func costShort(_ c: Double) -> String {
        if c >= 1.0 {
            return "¥\(String(format: "%.2f", c))"
        } else if c >= 0.001 {
            return "¥\(String(format: "%.4f", c))"
        } else {
            return "¥\(String(format: "%.6f", c))"
        }
    }
    static func latencyMsFormat(_ ms: Double) -> String {
        isZH ? "\(Int(ms))ms" : "\(Int(ms))ms"
    }

    static var balanceText: String { isZH ? "¥%.2f" : "¥%.2f" }
    static var grantedText: String { isZH ? "赠送 ¥%.2f" : "Granted ¥%.2f" }
    static var toppedUpText: String { isZH ? "充值 ¥%.2f" : "Topped Up ¥%.2f" }

    // Pricing
    static var pricingSection: String { isZH ? "模型定价" : "Model Pricing" }
    static var pricingNote: String { isZH ? "修改仅对新请求生效。计价单位为 ¥/1M tokens。" : "Changes apply to new requests only. Prices in ¥/1M tokens." }
    static var pricingHit: String { isZH ? "缓存命中 (Input)" : "Cache Hit (Input)" }
    static var pricingMiss: String { isZH ? "缓存未命中 (Input)" : "Cache Miss (Input)" }
    static var pricingOut: String { isZH ? "输出 (Output)" : "Output" }
    static var pricingDefault: String { isZH ? "使用默认定价" : "Using default pricing" }
    static var pricingReset: String { isZH ? "恢复默认" : "Reset to Default" }
    static var pricingResetDone: String { isZH ? "已恢复默认定价" : "Reset to default pricing" }

    // Chart
    static var chartMiss: String { isZH ? "Miss" : "Miss" }
    static var chartHit: String { isZH ? "Hit" : "Hit" }
    static var chartOut: String { isZH ? "Out" : "Out" }
    static var chartTotal: String { isZH ? "合计" : "Total" }

    // MARK: - 同步
    static var syncSection: String { isZH ? "数据同步" : "Data Sync" }
    static var syncToggle: String { isZH ? "启用同步" : "Enable Sync" }
    static var syncModeServer: String { isZH ? "服务器" : "Server" }
    static var syncModeClient: String { isZH ? "客户端" : "Client" }
    static var syncListenPortLabel: String { isZH ? "本机监听端口" : "Listen Port" }
    static var syncTargetLabel: String { isZH ? "目标服务器" : "Server Address" }
    static var syncIntervalLabel: String { isZH ? "同步间隔（秒）" : "Sync Interval (s)" }
    static var syncStatusListening: String { isZH ? "监听中" : "Listening" }
    static var syncStatusConnected: String { isZH ? "已连接" : "Connected" }
    static var syncStatusDisconnected: String { isZH ? "未连接" : "Disconnected" }
    static var syncStatusError: String { isZH ? "错误" : "Error" }
    static var syncModeHint: String { isZH ? "服务器模式：本机监听端口，供其他设备连接；客户端模式：主动连接服务器拉取/推送数据" : "Server: listen for incoming connections; Client: connect to server to sync data" }
    static var syncPortHint: String { isZH ? "需要确保端口未被占用，且防火墙已放行" : "Ensure port is not in use and firewall allows it" }
    static var syncAddressHint: String { isZH ? "客户端填写目标服务器 IP:端口，如 1.2.3.4:6000" : "Client: target server IP:port, e.g. 1.2.3.4:6000" }
}
