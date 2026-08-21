import Foundation

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
    static let showMenuIconDidChange = Notification.Name("showMenuIconDidChange")
    static let usageRecorded = Notification.Name("usageRecorded")
    static let showIndicatorDidChange = Notification.Name("showIndicatorDidChange")
    static let menuBarTextDisplayDidChange = Notification.Name("menuBarTextDisplayDidChange")
    static let menuBarColorDidChange = Notification.Name("menuBarColorDidChange")
    static let currencyDidChange = Notification.Name("currencyDidChange")
    static let providerChanged = Notification.Name("providerChanged")
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
        static let syncPushToken = "sync_push_token"
        static let seatRegistry = "seat_registry"
        static let seatRegistryFilePath = "seat_registry_file"
        static let defaultProviderId = "default_provider_id"
        static let menuBarColor = "menu_bar_color"
        static let currencySymbol = "currency_symbol"
        static let githubToken = "github_token"
        static let githubUsername = "github_username"
        static let githubEnabled = "github_enabled"
        static let awsAccessKey = "aws_access_key"
        static let awsSecretKey = "aws_secret_key"
        static let awsRegion = "aws_region"
        static let awsEnabled = "aws_enabled"
        static func lastModel(for providerId: String) -> String { "last_model_\(providerId)" }
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

    // Currency
    static var currencySymbol: String {
        UserDefaults.standard.string(forKey: Keys.currencySymbol) ?? "¥"
    }

    // Status bar

    // Popover header
    static var popoverTitle: String { "dev_mon" }
    static var badgeLoading: String { isZH ? "查询中..." : "Loading..." }
    static var badgeNormal: String { isZH ? "正常" : "NORM" }
    static var badgeError: String { isZH ? "预警" : "WARN" }
    static var badgeWarning: String { isZH ? "偏低" : "LOW" }

    // Balance section
    static var currentBalance: String { isZH ? "当前余额" : "Balance" }
    static var grantedPrefix: String { isZH ? "赠送 \(currencySymbol)%.2f" : "Granted \(currencySymbol)%.2f" }
    static var toppedUpPrefix: String { isZH ? "充值 \(currencySymbol)%.2f" : "Topped Up \(currencySymbol)%.2f" }

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
    static var quitMessage: String { isZH ? "确定要退出 dev_mon 吗？" : "Are you sure you want to quit dev_mon?" }
    static var quitConfirm: String { isZH ? "退出" : "Quit" }
    static var cancel: String { isZH ? "取消" : "Cancel" }
    static var openConsole: String { isZH ? "打开控制台" : "Open Console" }

    // Settings window
    static var settingsTitle: String { isZH ? "设置" : "Settings" }
    static var settingsTabGeneral: String { isZH ? "通用" : "General" }
    static var settingsTabServices: String { isZH ? "服务" : "Services" }
    static var settingsTabAbout: String { isZH ? "关于" : "About" }
    static var balanceAlert: String { isZH ? "余额预警" : "Balance Alert" }
    static var alertHint: String { isZH ? "余额低于此值时菜单栏红色闪烁" : "Menu bar flashes red when balance drops below" }
    static var maxBalanceHint: String { isZH ? "菜单栏环形百分比以此为基准，默认 \(currencySymbol)100" : "Ring percentage is relative to this amount, default \(currencySymbol)100" }
    static var apiKeyLabel: String { isZH ? "API Key" : "API Key" }

    // DeepSeekStats errors
    static var noAPIKey: String { isZH ? "未设置 API Key" : "API Key not set" }
    static var invalidResponse: String { isZH ? "查询失败：无效的服务器响应" : "Query failed: invalid server response" }
    static var parseFailed: String { isZH ? "查询失败：解析响应数据失败" : "Query failed: failed to parse response" }
    static var keyInvalid: String { isZH ? "API Key 无效或已过期" : "API Key invalid or expired" }
    static var rateLimited: String { isZH ? "请求过于频繁，请稍后重试" : "Rate limited, please retry later" }
    static var serviceDown: String { isZH ? "服务暂时不可用" : "Service temporarily unavailable" }
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
    static var costLabel: String { isZH ? "费用" : "Cost" }
    static var hitRateLabel: String { isZH ? "命中率" : "Hit Rate" }
    static var textDisplayLabel: String { isZH ? "菜单栏文字" : "Menu Bar Text" }
    static var menuBarColorLabel: String { isZH ? "菜单栏文字颜色" : "Menu Bar Color" }
    static var menuBarColorAuto: String { isZH ? "自动" : "Auto" }
    static var menuBarColorWhite: String { isZH ? "白色" : "White" }
    static var menuBarColorBlack: String { isZH ? "黑色" : "Black" }
    static var currencyLabel: String { isZH ? "货币" : "Currency" }

    // Provider
    static var providerTitle: String { isZH ? "提供商" : "Provider" }
    static var baseURLHelpTitle: String { isZH ? "如何配置 opencode 客户端" : "How to configure opencode"}
    static var baseURLHelpDesc: String { isZH ? "在 opencode 的配置文件 (opencode.jsonc) 中添加以下 provider 配置，将 API 请求转发到本地 dev_mon 代理。" : "Add the following provider config in your opencode.jsonc to route API requests through the local dev_mon proxy."}
    static var defaultModelLabel2: String { isZH ? "当前模型" : "Current Model" }
    static func apiKeyHint(_ name: String) -> String {
        isZH ? "\(name) 的 API Key 将用于代理转发" : "API Key for \(name) will be used for proxy forwarding"
    }
    static var save: String { isZH ? "保存" : "Save" }
    static var aboutDesc: String { isZH ? "实时监控 AI API 使用情况" : "Monitors AI API usage in real-time" }


    // Proxy
    static var proxySection: String { isZH ? "本地代理" : "Proxy" }
    static var proxyToggle: String { isZH ? "启用代理" : "Enable Proxy" }
    static var proxyToggleHint: String { isZH ? "拦截并记录 API 调用数据" : "Intercept and log API calls" }
    static var proxyPortLabel: String { isZH ? "代理端口" : "Proxy Port" }
    static var proxyPortHint: String { isZH ? "客户端设置 base_url 为 http://localhost:{port}" : "Set client base_url to http://localhost:{port}" }
    static var proxyRunning: String { isZH ? "代理已启动" : "Proxy running" }
    static var proxyStopped: String { isZH ? "代理已停止" : "Proxy stopped" }

    // License
    static var settingsTabLicense: String { isZH ? "许可" : "License" }
    static var licenseSection: String { isZH ? "席位注册表（吊销授权）" : "Seat Registry (revocation)" }
    static func licenseSeatCount(_ n: Int) -> String {
        isZH ? "共 \(n) 个席位" : "\(n) seats"
    }
    static var licenseNoSeats: String { isZH ? "暂无席位。添加一个 sub（座位标识）以管理吊销。" : "No seats. Add a sub to manage revocations." }
    static var licenseAddSeat: String { isZH ? "添加席位" : "Add Seat" }
    static var licenseAddButton: String { isZH ? "添加" : "Add" }
    static var licenseSubPlaceholder: String { isZH ? "sub（座位标识）" : "sub" }
    static var licenseKidPlaceholder: String { isZH ? "kid（可选）" : "kid (optional)" }
    static var licenseExpPlaceholder: String { isZH ? "过期（unix 秒，0=不限）" : "exp (unix sec, 0=unlimited)" }
    static var licenseUnlimited: String { isZH ? "不限" : "Unlimited" }
    static func licenseExpires(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return isZH ? "过期 \(f.string(from: date))" : "exp \(f.string(from: date))"
    }
    static var licenseFileLabel: String { isZH ? "注册表文件" : "Registry File" }
    static var licenseFileHint: String { isZH ? "可选 JSON 文件路径（[{sub,kid,exp,revoked}]）。文件优先于内嵌列表。" : "Optional JSON file path ([{sub,kid,exp,revoked}]). File takes precedence over the inline list." }
    static var licenseRevokedHint: String { isZH ? "吊销此席位" : "Revoke this seat" }
    static var licenseRemoveHint: String { isZH ? "移除席位" : "Remove seat" }
    static var usageTabTitle: String { isZH ? "用量" : "Usage" }

    // Usage stats
    static var usageTitle: String { isZH ? "总用量" : "Total Usage" }
    static var requestsLabel: String { isZH ? "请求数" : "Requests" }
    static var totalTokensLabel: String { isZH ? "总 Tokens" : "Total Tokens" }
    static var cachedTokensLabel: String { isZH ? "缓存命中" : "Cache Hit" }
    static var reasoningTokensLabel: String { isZH ? "推理 Tokens" : "Reasoning" }
    static var estimatedCostLabel: String { isZH ? "预估费用" : "Est. Cost" }
    static var latencyLabel: String { isZH ? "响应时间" : "Response Time" }
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
        let sym = currencySymbol
        if c >= 1.0 {
            return "\(sym)\(String(format: "%.2f", c))"
        } else if c >= 0.001 {
            return "\(sym)\(String(format: "%.4f", c))"
        } else {
            return "\(sym)\(String(format: "%.6f", c))"
        }
    }
    static func latencyMsFormat(_ ms: Double) -> String {
        isZH ? "\(Int(ms))ms" : "\(Int(ms))ms"
    }
    // Source Usage
    static var sourceUsageTitle: String { isZH ? "来源用量" : "Source Usage" }
    static var allSources: String { isZH ? "全部来源" : "All Sources" }
    static var aggregateLabel: String { isZH ? "汇总" : "Aggregate" }
    static var individualLabel: String { isZH ? "明细" : "Individual" }
    static var lastSeenLabel: String { isZH ? "最近活跃" : "Last Seen" }
    static var localSourceLabel: String { isZH ? "本机" : "local" }
    static var balanceText: String { "\(currencySymbol)%.2f" }
    static var grantedText: String { isZH ? "赠送余额 \(currencySymbol)%.2f" : "Granted \(currencySymbol)%.2f" }
    static var toppedUpText: String { isZH ? "充值余额 \(currencySymbol)%.2f" : "Topped Up \(currencySymbol)%.2f" }

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
    static var syncPushTokenLabel: String { isZH ? "推送令牌" : "Push Token" }
    static var syncPushTokenHint: String { isZH ? "共享令牌：客户端推送 /sync/push 时需携带 Authorization: Bearer <token>；留空则接受开放推送" : "Shared token: clients must send Authorization: Bearer <token> on POST /sync/push; leave blank to accept open pushes" }
    static var syncPushTokenGenerateHint: String { isZH ? "生成随机推送令牌" : "Generate a random push token" }
    static var syncPushTokenRevealHint: String { isZH ? "显示/隐藏令牌" : "Show / hide token" }
    static var syncPushTokenCopyHint: String { isZH ? "复制令牌" : "Copy token" }

    // MARK: - ☁️ GitHub
    static var githubSection: String { isZH ? "GitHub Actions" : "GitHub Actions" }
    static var githubToggle: String { isZH ? "启用 GitHub 追踪" : "Enable GitHub Tracking" }
    static var githubTokenLabel: String { isZH ? "Personal Access Token" : "Personal Access Token" }
    static var githubTokenHint: String { isZH ? "需要 classic PAT（read:user 权限）" : "Requires a classic PAT with read:user scope" }
    static var githubTokenRevealHint: String { isZH ? "显示/隐藏令牌" : "Show / hide token" }
    static var githubTokenCopyHint: String { isZH ? "复制令牌" : "Copy token" }
    static var githubUserLabel: String { isZH ? "用户名/组织" : "Username/Org" }
    static var githubComputeLabel: String { isZH ? "计算分钟" : "Compute Minutes" }
    static var githubStorageLabel: String { isZH ? "存储" : "Storage" }
    static var githubMinutesFormat: String { isZH ? "%d / %d 分钟" : "%d / %d min" }
    static var githubStorageFormat: String { isZH ? "%.0f / %.0f MB" : "%.0f / %.0f MB" }
    static var githubDaysLeft: String { isZH ? "账单周期剩余 %d 天" : "%d days left in cycle" }
    static var githubFreeStatus: String { isZH ? "✅ 在免费额度内" : "✅ Within free tier" }
    static var githubWarningStatus: String { isZH ? "⚠️ 接近免费额度上限" : "⚠️ Approaching free tier limit" }
    static var githubExceededStatus: String { isZH ? "❌ 超过免费额度" : "❌ Exceeded free tier" }

    // MARK: - ☁️ AWS
    static var awsSection: String { isZH ? "AWS EC2 免费套餐" : "AWS EC2 Free Tier" }
    static var awsToggle: String { isZH ? "启用 AWS 追踪" : "Enable AWS Tracking" }
    static var awsAccessKeyLabel: String { isZH ? "Access Key ID" : "Access Key ID" }
    static var awsSecretKeyLabel: String { isZH ? "Secret Access Key" : "Secret Access Key" }
    static var awsRegionLabel: String { isZH ? "区域" : "Region" }
    static var awsHoursLabel: String { isZH ? "运行小时" : "Running Hours" }
    static var awsHoursFormat: String { isZH ? "%.0f / %.0f 小时" : "%.0f / %.0f hrs" }
    static var awsInstancesLabel: String { isZH ? "实例" : "Instances" }
    static var awsInstancesFormat: String { isZH ? "%d 个 (%d 合格, %d 不合格)" : "%d (%d eligible, %d non-eligible)" }
    static var awsForecastLabel: String { isZH ? "预测月底用量" : "Month-end forecast" }
    static var awsForecastFormat: String { isZH ? "~%.0f 小时" : "~%.0f hrs" }
    static var awsOverageLabel: String { isZH ? "预估超额费用" : "Est. overage cost" }
    static var awsFreeStatus: String { isZH ? "✅ 在免费套餐内" : "✅ Within free tier" }
    static var awsWarningStatus: String { isZH ? "⚠️ 接近免费套餐上限" : "⚠️ Approaching free tier limit" }
    static var awsExceededStatus: String { isZH ? "❌ 超出免费套餐" : "❌ Exceeded free tier" }
    static var awsEligibleLabel: String { isZH ? "免费资格" : "Free Tier" }
    static var awsYesLabel: String { isZH ? "✅ 免费" : "✅ Free" }
    static var awsNoLabel: String { isZH ? "❌ ~$%.0f/月" : "❌ ~$%.0f/mo" }
}
