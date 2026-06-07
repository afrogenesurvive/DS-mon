import Foundation

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
    static let showMenuIconDidChange = Notification.Name("showMenuIconDidChange")
    static let usageRecorded = Notification.Name("usageRecorded")
    static let moonbridgeStatusChanged = Notification.Name("moonbridgeStatusChanged")
    static let moonbridgeRestartNeeded = Notification.Name("moonbridgeRestartNeeded")
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
    private static var languageCode: String {
        let saved = UserDefaults.standard.string(forKey: "app_language") ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh" ? "zh-Hans" : "en"
        }
        return saved
    }

    private static var isZH: Bool { languageCode == "zh-Hans" }

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

    // Popover header
    static var popoverTitle: String { "DS-mon" }
    static var badgeLoading: String { isZH ? "查询中..." : "Loading..." }
    static var badgeNormal: String { isZH ? "正常" : "NORM" }
    static var badgeError: String { isZH ? "异常" : "ERROR" }

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
    static var apiKeyLabel: String { isZH ? "API Key" : "API Key" }
    static var apiKeyPlaceholder: String { "sk-..." }
    static var saveButton: String { isZH ? "保存" : "Save" }
    static var savedHint: String { isZH ? "已保存，正在刷新..." : "Saved, refreshing..." }
    static var saveFailedHint: String { isZH ? "保存失败，请在钥匙串弹窗中点击「始终允许」" : "Save failed. Click 'Always Allow' in the Keychain prompt" }

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
    static var keychainSaveFailed: String { isZH ? "保存 API Key 失败：需在钥匙串弹窗中点击「始终允许」" : "Failed to save API Key. Click 'Always Allow' in the Keychain prompt" }

    // codex-relay 协议转换器
    static var moonbridgeSection: String { isZH ? "协议转换器" : "Protocol Relay" }
    static var moonbridgeToggle: String { isZH ? "启用协议转换" : "Enable Relay" }
    static var moonbridgeToggleHint: String { isZH ? "将 Codex 的 Responses API 转换为 Chat Completions API，适配 DeepSeek 等供应商" : "Translates Codex Responses API to Chat Completions for DeepSeek and other providers" }
    static var moonbridgeRunning: String { isZH ? "运行中" : "Running" }
    static var moonbridgeStopped: String { isZH ? "已停止" : "Stopped" }
    static var moonbridgeNotice: String { isZH ? "Codex CLI 配置：base_url = http://localhost:{port}/v1（代理端口）" : "Codex CLI: base_url = http://localhost:{port}/v1 (proxy port)" }

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
    static var pricingReset: String { isZH ? "恢复默认" : "Reset to Default" }
    static var pricingResetDone: String { isZH ? "已恢复默认定价" : "Reset to default pricing" }

    // Chart
    static var chartMiss: String { isZH ? "Miss" : "Miss" }
    static var chartHit: String { isZH ? "Hit" : "Hit" }
    static var chartOut: String { isZH ? "Out" : "Out" }
    static var chartTotal: String { isZH ? "合计" : "Total" }
}
