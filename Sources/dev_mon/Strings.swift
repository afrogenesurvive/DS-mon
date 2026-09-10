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
    static let seatRegistryChanged = Notification.Name("seatRegistryChanged")
    static let peakSettingsDidChange = Notification.Name("peakSettingsDidChange")
    static let popoverResizeRequested = Notification.Name("popoverResizeRequested")
    static let appAlertDidFire = Notification.Name("appAlertDidFire")
    static let appAlertDidUpdate = Notification.Name("appAlertDidUpdate")
    static let appearanceDidChange = Notification.Name("appearanceDidChange")
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
        static let appTheme         = "app_theme"
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
        static let awsMaxCredits = "aws_max_credits"
        static let cloudflareEnabled = "cloudflare_enabled"
        static let cloudflareApiToken = "cloudflare_api_token"
        static let cloudflareAccountId = "cloudflare_account_id"
        static let cloudflareAccountName = "cloudflare_account_name"
        static let cloudflareZoneId = "cloudflare_zone_id"
        static let cloudflareZoneName = "cloudflare_zone_name"
        static let cloudflareTunnelId = "cloudflare_tunnel_id"
        static let cloudflareTunnelName = "cloudflare_tunnel_name"
        static let netlifyEnabled = "netlify_enabled"
        static let netlifyApiToken = "netlify_api_token"
        static let netlifyAccountId = "netlify_account_id"
        static let netlifyAccountName = "netlify_account_name"
        static let netlifySelectedSiteId = "netlify_selected_site_id"
        static let netlifyDeployNotifyEnabled = "netlify_deploy_notification_enabled"
        // Local DBs（本地数据库监控）
        static let localDBsEnabled = "local_dbs_enabled"
        static let localDBsNotifyEnabled = "local_dbs_down_notification_enabled"
        static let localDBsMySQLUser = "local_dbs_mysql_user"
        static let localDBsMySQLPassword = "local_dbs_mysql_password"
        static let localDBsNeo4jUser = "local_dbs_neo4j_user"
        static let localDBsNeo4jPassword = "local_dbs_neo4j_password"
        static let showPeakDot = "show_peak_dot"
        static let peakNotificationEnabled = "peak_notification_enabled"
        static let tunnelDownNotificationEnabled = "tunnel_down_notification_enabled"
        static let balanceAlertEnabled = "balance_alert_enabled"
        static func lastModel(for providerId: String) -> String { "last_model_\(providerId)" }
        /// 按月计费提供商的手填月度预算（用于推导剩余额度）
        static func monthlyBudget(for providerId: String) -> String { "monthly_budget_\(providerId)" }
        /// Z.AI 上游端点选择（coding = Coding Plan 专用 / standard = 标准按量付费）
        static let zaiEndpoint = "zai_endpoint"
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
    static var themeLabel: String { isZH ? "外观" : "Appearance" }
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
    static var resizePopoverHint: String { isZH ? "拖动以缩放" : "Drag to resize" }
    static var badgeLoading: String { isZH ? "查询中..." : "Loading..." }
    static var badgeNormal: String { isZH ? "正常" : "NORM" }
    static var badgeError: String { isZH ? "预警" : "WARN" }
    static var badgeWarning: String { isZH ? "偏低" : "LOW" }

    // Balance section
    static var currentBalance: String { isZH ? "当前余额" : "Balance" }
    static var accountSectionTitle: String { isZH ? "账户" : "Account" }
    static var grantedPrefix: String { isZH ? "赠送 \(currencySymbol)%.2f" : "Granted \(currencySymbol)%.2f" }
    static var toppedUpPrefix: String { isZH ? "充值 \(currencySymbol)%.2f" : "Topped Up \(currencySymbol)%.2f" }

    // Info section
    static var thresholdLabel: String { isZH ? "预警线" : "Alert Line" }
    static var availableModels: String { isZH ? "可用模型" : "Models" }
    static var accountStatus: String { isZH ? "账户状态" : "Status" }
    static var available: String { isZH ? "可用" : "Available" }
    static var insufficient: String { isZH ? "余额不足" : "Insufficient" }
    static var errorLabel: String { isZH ? "错误" : "Error" }

    // DeepSeek pricing window (peak/off-peak)
    static var pricingWindowLabel: String { isZH ? "DeepSeek 计费时段" : "DeepSeek Pricing" }
    static var peakStatusPeak: String { isZH ? "高峰" : "Peak" }
    static var peakStatusOffPeak: String { isZH ? "低谷" : "Off-Peak" }
    static var peakCountdown: String { isZH ? "高峰 · %@ 后切换" : "Peak · %@ left" }
    static var offPeakCountdown: String { isZH ? "低谷 · %@ 后切换" : "Off-Peak · %@ left" }
    static var peakMenuActive: String { isZH ? "高峰剩 %@" : "Peak %@ left" }
    static var peakMenuPending: String { isZH ? "%@ 后高峰" : "Peak in %@" }
    static var peakDotLabel: String { isZH ? "高峰/低谷状态点" : "Peak Status Dot" }
    static var peakNotifyLabel: String { isZH ? "高峰/低谷切换通知" : "Peak Transition Notification" }
    static var peakNotifyTitle: String { isZH ? "DeepSeek 高峰时段开始" : "DeepSeek Peak started" }
    static var peakNotifyBody: String { isZH ? "高峰计费已开始（价格为低谷的 2 倍）" : "Peak pricing is now active (2× off-peak)." }
    static var offPeakNotifyTitle: String { isZH ? "DeepSeek 低谷时段开始" : "DeepSeek Off-Peak started" }
    static var offPeakNotifyBody: String { isZH ? "低谷计费已开始（价格约为高峰一半）——适合跑大批量任务" : "Off-peak discount is now active (~50% off) — good time for batch jobs." }

    // MARK: - 🔔 Notifications / Alerts
    static var alertsTabTitle: String { isZH ? "通知" : "Alerts" }
    static var alertsTabTooltip: String { isZH ? "通知" : "Notifications" }
    static var alertsEmpty: String { isZH ? "暂无通知" : "No notifications yet" }
    static var alertsClearAll: String { isZH ? "清空" : "Clear" }
    static var peakSoonNotifyTitle: String { isZH ? "DeepSeek 高峰即将开始" : "DeepSeek peak starting soon" }
    static var peakSoonNotifyBody: String { isZH ? "约 10 分钟后进入高峰计费（价格为低谷 2 倍），大型任务建议错峰。" : "Peak pricing (~2× off-peak) starts in ~10 min — consider queuing heavy jobs now." }
    static var tunnelDownNotifyLabel: String { isZH ? "隧道断开通知" : "Tunnel Down Alert" }
    static var tunnelDownNotifyHint: String { isZH ? "cloudflared 断开或无法连接时发送系统通知" : "Notify when the tunnel drops or can't connect" }
    static var tunnelDownTitle: String { isZH ? "Cloudflare 隧道已断开" : "Cloudflare tunnel is down" }
    static var tunnelDownBody: String { isZH ? "cloudflared 已停止，公网访问可能中断。" : "cloudflared stopped — public access may be interrupted." }
    static var tunnelDownRemoteBody: String { isZH ? "cloudflared 运行中但未能连接 Cloudflare，请检查 token / 日志。" : "cloudflared is running but not connected to Cloudflare — check token/logs." }
    static var tunnelRestoredTitle: String { isZH ? "Cloudflare 隧道已恢复" : "Cloudflare tunnel restored" }
    static var tunnelRestoredBody: String { isZH ? "cloudflared 已重新连接，服务恢复正常。" : "cloudflared reconnected — services are back up." }
    static var balanceAlertLabel: String { isZH ? "余额预警通知" : "Balance Alert" }
    static var balanceAlertHint: String { isZH ? "余额进入预警/不足区间时发送系统通知" : "Notify when balance enters warning / low" }
    static var balanceWarningTitle: String { isZH ? "余额预警" : "Balance warning" }
    static var balanceWarningBody: String { isZH ? "余额已进入预警区间，请留意用量。" : "Balance is in the warning zone." }
    static var balanceLowTitle: String { isZH ? "余额不足" : "Low balance" }
    static var balanceLowBody: String { isZH ? "余额偏低，建议尽快充值以免服务中断。" : "Balance is running low — consider topping up soon." }

    // Action bar
    static var refresh: String { isZH ? "刷新" : "Refresh" }
    static var settings: String { isZH ? "设置" : "Settings" }
    static var quit: String { isZH ? "退出" : "Quit" }
    static var quitTitle: String { isZH ? "确认退出" : "Quit" }
    static var quitMessage: String { isZH ? "确定要退出 dev_mon 吗？" : "Are you sure you want to quit dev_mon?" }
    static var quitConfirm: String { isZH ? "退出" : "Quit" }
    static var cancel: String { isZH ? "取消" : "Cancel" }
    static var openConsole: String { isZH ? "打开控制台" : "Open Console" }
    static var configExportButton: String { isZH ? "导出配置" : "Export Config" }
    static var configImportButton: String { isZH ? "导入配置" : "Import Config" }
    static var configExportTitle: String { isZH ? "导出配置" : "Export Config" }
    static var configExportSave: String { isZH ? "导出" : "Export" }
    static var configImportTitle: String { isZH ? "导入配置" : "Import Config" }
    static var configImportOpen: String { isZH ? "导入" : "Import" }
    static var ok: String { isZH ? "好" : "OK" }
    static var configExportWarningTitle: String { isZH ? "导出包含密钥" : "Export contains keys" }
    static var configExportWarningMessage: String { isZH ? "导出的 JSON 将以明文包含 API Key 与密钥，请妥善保管，不要上传到公共位置。" : "The exported JSON includes your API keys and secrets in plaintext. Keep it private and secure." }
    static var configImportInvalid: String { isZH ? "配置文件无效或版本不匹配" : "Invalid or unsupported config file" }
    static var configImportDone: String { isZH ? "配置已导入" : "Config imported" }

    // Settings window
    static var settingsTitle: String { isZH ? "设置" : "Settings" }
    static var settingsTabGeneral: String { isZH ? "通用" : "General" }
    static var settingsTabServices: String { isZH ? "服务" : "Services" }
    static var settingsTabAbout: String { isZH ? "关于" : "About" }
    static var settingsTabGuide: String { isZH ? "指南" : "Guide" }

    // Guide (docs/*.md) — 设置窗口里的文档查看页
    static var guideOpenExternal: String { isZH ? "在外部打开" : "Open Externally" }
    static var guideReveal: String { isZH ? "在 Finder 中显示" : "Reveal in Finder" }
    static var guideNoDocsTitle: String { isZH ? "未找到可用文档" : "No documentation found" }
    static var guideNoDocsHint: String {
        isZH ? "未在应用资源或仓库 docs/ 目录下找到可展示的 .md 文档（CHANGELOG.md 除外）。" :
               "No .md files (other than CHANGELOG.md) were found in the app resources or the repo docs/ folder."
    }
    static var guideLoadFailed: String { isZH ? "无法读取文档内容" : "Unable to load document" }
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
    static var licenseNoSeats: String { isZH ? "暂无席位。请通过“检查许可”从 seats.json 导入。" : "No seats. Import via \"Check Licenses\" from seats.json." }
    static var licenseUnlimited: String { isZH ? "不限" : "Unlimited" }
    /// 剩余有效期：dd:hh:mm:ss（exp<=0 显示不限；已过期显示“已过期”）
    static func licenseCountdown(_ exp: Int) -> String {
        guard exp > 0 else { return isZH ? "不限" : "Unlimited" }
        let seconds = exp - Int(Date().timeIntervalSince1970)
        guard seconds > 0 else { return isZH ? "已过期" : "Expired" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d:%02d", days, hours, minutes, secs)
    }
    static var licenseFileLabel: String { isZH ? "注册表文件" : "Registry File" }
    static var licenseFileHint: String { isZH ? "可选 JSON 文件路径（[{sub,kid,exp,revoked}]）。文件优先于内嵌列表。" : "Optional JSON file path ([{sub,kid,exp,revoked}]). File takes precedence over the inline list." }
    static var licenseTabTitle: String { isZH ? "许可" : "License" }
    static var licenseActiveBadge: String { isZH ? "正常" : "Active" }
    static var licenseRevokedBadge: String { isZH ? "已吊销" : "Revoked" }
    static var licensePopoverManageHint: String { isZH ? "DS-mon 为吊销授权权威；席位在 设置 → 许可 中管理" : "DS-mon is the revocation authority; manage seats in Settings → License" }
    static var licenseCheckTitle: String { isZH ? "检查许可" : "Check Licenses" }
    static var licenseCheckButton: String { isZH ? "检查许可" : "Check Licenses" }
    static var licenseSourceLabel: String { isZH ? "来源文件" : "Source File" }
    static func licenseCheckResult(_ n: Int, _ updatedAt: String?) -> String {
        if let u = updatedAt {
            return isZH ? "已导入 \(n) 个席位（更新于 \(u)）" : "Imported \(n) seats (updated \(u))"
        }
        return isZH ? "已导入 \(n) 个席位" : "Imported \(n) seats"
    }
    static var licenseFilterValid: String { isZH ? "有效" : "Valid" }
    static var licenseFilterRevoked: String { isZH ? "已吊销" : "Revoked" }
    static var licenseFilterExpired: String { isZH ? "已过期" : "Expired" }
    static var licenseCheckIntervalLabel: String { isZH ? "自动检查间隔（小时）" : "Auto-check interval (h)" }
    static var licenseCheckIntervalHint: String { isZH ? "每 N 小时自动读取 seats.json，另有手动“检查许可”按钮" : "Re-checks seats.json every N hours, in addition to the manual Check button" }
    static func licenseNoFilteredSeats(_ label: String) -> String {
        isZH ? "暂无\(label)席位" : "No \(label) seats"
    }
    static var usageTabTitle: String { isZH ? "AI 用量" : "AI Usage" }
    static var exportUsageTitle: String { isZH ? "导出用量数据" : "Export Usage Data" }
    static var exportUsageSave: String { isZH ? "导出" : "Export" }
    static var exportUsageHelp: String { isZH ? "导出全部用量数据（JSON）" : "Export all usage data (JSON)" }
    static var exportUsageButton: String { isZH ? "导出" : "Export" }
    static var revealHint: String { isZH ? "显示/隐藏" : "Show / hide" }

    // Usage stats
    static var usageTitle: String { isZH ? "总用量" : "Total Usage" }
    static var requestHistoryTitle: String { isZH ? "请求记录" : "Request History" }
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
    static var monthSpend: String { isZH ? "本月费用" : "This month" }

    // Z.AI 端点选择（Coding Plan 专用 / 标准按量付费）
    static var endpointLabel: String { isZH ? "Z.AI 接口" : "Z.AI Endpoint" }
    static var endpointCoding: String { isZH ? "Coding Plan" : "Coding Plan" }
    static var endpointStandard: String { isZH ? "标准（按量付费）" : "Standard (pay-as-you-go)" }
    static var endpointHint: String {
        isZH ? "Z.AI for Copilot 走 Coding Plan 专用接口；标准接口按量计费。"
             : "Z.AI for Copilot uses the dedicated Coding Plan endpoint; Standard is pay-as-you-go."
    }

    // 套餐/配额用量（z.ai 内部接口，仅供参考）
    static var quotaPlanName: String { isZH ? "套餐" : "Plan" }
    static var quotaRenewDate: String { isZH ? "续费" : "Renews" }
    static var quotaSession5h: String { isZH ? "会话 (5h)" : "Session (5h)" }
    static var quotaWeekly7d: String { isZH ? "周窗口 (7d)" : "Weekly (7d)" }
    static var quotaSearchMonthly: String { isZH ? "联网搜索/阅读" : "Search/Read" }
    static var quotaUsageHint: String {
        isZH ? "来自 z.ai 内部接口，非官方，仅供参考"
             : "From z.ai internal API — unofficial, for reference only"
    }

    // z.ai 内部钱包余额（非官方，仅供参考）
    static var walletLabel: String { isZH ? "钱包余额" : "Wallet Balance" }
    static var walletHint: String {
        isZH ? "来自 z.ai 内部接口（余额），非官方，仅供参考"
             : "Z.AI console balance — unofficial, for reference only"
    }

    static var tokenInputText: String { isZH ? "输入 %@" : "In %@" }
    static var tokenOutputText: String { isZH ? "输出 %@" : "Out %@" }
    static var tokenCachedText: String { isZH ? "缓存 %@" : "Cache %@" }

    // MARK: - 月度预算 / 剩余额度（按月计费提供商）
    static var spentThisMonthLabel: String { isZH ? "本月已花费" : "Spent this month" }
    static var remainingBudgetLabel: String { isZH ? "剩余额度" : "Remaining" }
    static var monthlyBudgetLabel: String { isZH ? "月度预算" : "Monthly budget" }
    static var budgetSourceSpendLimit: String {
        isZH ? "来源：提供商消费上限"
             : "Source: provider spend limit"
    }
    static var budgetSourceManual: String {
        isZH ? "来源：设置中手填的月度预算" : "Source: monthly budget set in Settings"
    }
    static var budgetSourceNone: String {
        isZH ? "OpenAI 与 Anthropic 均未提供余额查询接口。请在 设置 → 提供商 中填写月度预算以显示剩余额度。"
             : "Neither OpenAI nor Anthropic offers a balance API. Set a monthly budget in Settings → Providers to show remaining."
    }
    static var monthlyBudgetHint: String {
        isZH ? "用于推导剩余额度（本月预算 − 本月费用）。填 0 表示不显示。"
             : "Used to derive remaining (budget − month-to-date cost). 0 hides it."
    }
    static var monthlyBudgetHintOpenAI: String {
        isZH ? "仅在未配置组织消费上限时作为回退值使用。"
             : "Fallback only — used when no org spend limit is configured."
    }

    // MARK: - 图标提示（Tooltip）
    static var providerTabTooltipBalance: String {
        isZH ? "%@ — 查看余额与用量" : "%@ — balance & usage"
    }
    static var providerTabTooltipSpend: String {
        isZH ? "%@ — 查看本月费用与剩余额度" : "%@ — month-to-date spend & remaining"
    }
    static var usageTabTooltip: String { isZH ? "AI 用量统计与请求历史" : "AI Usage stats & request history" }
    static var licenseTabTooltip: String { isZH ? "许可证席位与有效期" : "License seats & expiry" }
    static var githubTabTooltip: String { isZH ? "GitHub Actions 用量与仓库" : "GitHub Actions usage & repositories" }
    static var awsTabTooltip: String { isZH ? "AWS 免费套餐与费用" : "AWS free tier & costs" }
    static var cloudflareTabTooltip: String { isZH ? "Cloudflare 隧道状态与路由" : "Cloudflare tunnel status & routes" }
    static var netlifyTabTooltip: String { isZH ? "Netlify 站点与部署" : "Netlify sites & deploys" }
    static var localDBsTabTooltip: String { isZH ? "本地数据库状态与库列表" : "Local databases — status & DBs" }
    static var showChartTooltip: String { isZH ? "切换为图表视图" : "Switch to chart view" }
    static var showListTooltip: String { isZH ? "切换为列表视图" : "Switch to list view" }

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
    static var githubTokenHint: String { isZH ? "需要 classic PAT；读取私有仓库需勾选 repo 权限" : "Requires a classic PAT; enable the repo scope to include private repos" }
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

    // —— GitHub 页子页签（Actions / 仓库）——
    static var githubSubTabActions: String { isZH ? "Actions" : "Actions" }
    static var githubSubTabRepos: String { isZH ? "仓库" : "Repositories" }
    static var githubRepoListLabel: String { isZH ? "仓库" : "Repositories" }
    static var githubSearchPlaceholder: String { isZH ? "搜索仓库…" : "Search repositories…" }
    static var githubNoSelectionHint: String { isZH ? "选择一个仓库" : "Select a repository" }
    static var githubNotConfigured: String { isZH ? "请先在 设置→服务 配置 GitHub" : "Configure GitHub in Settings → Services" }
    static var githubNoRepos: String { isZH ? "没有可见的仓库" : "No repositories found" }
    static var githubVisibilityLabel: String { isZH ? "可见性" : "Visibility" }
    static var githubPublicLabel: String { isZH ? "公开" : "Public" }
    static var githubPrivateLabel: String { isZH ? "私有" : "Private" }
    static var githubCreatedLabel: String { isZH ? "创建时间" : "Created" }
    static var githubDetailLoading: String { isZH ? "加载详情…" : "Loading…" }
    static var githubCommitsSection: String { isZH ? "最近提交" : "Recent Commits" }
    static var githubBranchesSection: String { isZH ? "分支" : "Branches" }
    static var githubReleasesSection: String { isZH ? "最近发布" : "Recent Releases" }
    static var githubNoCommits: String { isZH ? "暂无提交" : "No commits" }
    static var githubNoBranches: String { isZH ? "暂无分支" : "No branches" }
    static var githubNoReleases: String { isZH ? "暂无发布" : "No releases" }
    static var githubMoreBranches: String { isZH ? "另有 %d 个分支未显示" : "+%d more branches" }
    static var githubCopyAction: String { isZH ? "复制" : "Copy" }
    static var githubCopied: String { isZH ? "已复制" : "Copied" }
    static var githubOpenAction: String { isZH ? "在浏览器打开" : "Open in browser" }

    // MARK: - ☁️ AWS
    static var awsSection: String { isZH ? "AWS EC2 免费套餐" : "AWS EC2 Free Tier" }
    static var awsToggle: String { isZH ? "启用 AWS 追踪" : "Enable AWS Tracking" }
    static var awsAccessKeyLabel: String { isZH ? "Access Key ID" : "Access Key ID" }
    static var awsSecretKeyLabel: String { isZH ? "Secret Access Key" : "Secret Access Key" }
    static var awsRegionLabel: String { isZH ? "区域" : "Region" }
    static var awsHoursLabel: String { isZH ? "运行小时" : "Running Hours" }
    static var awsHoursFormat: String { isZH ? "%.1f / %.0f 小时" : "%.1f / %.0f hrs" }
    static var awsInstancesLabel: String { isZH ? "实例" : "Instances" }
    static var awsInstancesFormat: String { isZH ? "%d 个 (%d 合格, %d 不合格)" : "%d (%d eligible, %d non-eligible)" }
    static var awsForecastLabel: String { isZH ? "预测月底用量" : "Month-end forecast" }
    static var awsForecastFormat: String { isZH ? "~%.1f 小时" : "~%.1f hrs" }
    static var awsOverageLabel: String { isZH ? "预估超额费用" : "Est. overage cost" }
    static var awsCreditsLabel: String { isZH ? "本月已用抵扣" : "Credits applied" }
    static var awsLifetimeCreditsLabel: String { isZH ? "历史累计抵扣" : "Credits applied (all time)" }
    static var awsEc2CreditsLabel: String { isZH ? "EC2 抵扣" : "EC2 credits" }
    static var awsMaxCreditsLabel: String { isZH ? "抵扣总额（手动填写）" : "Max credits (manual)" }
    static var awsMaxCreditsHint: String { isZH ? "AWS 无公开 API 查询剩余抵扣，请到控制台 账单→抵扣 页查看总额后手动填写" : "AWS has no public API for remaining credits — enter your total from Billing → Credits" }
    static var awsRemainingCreditsLabel: String { isZH ? "剩余抵扣" : "Credits remaining" }
    static var awsRemainingCreditsFormat: String { isZH ? "$%.2f / $%.2f" : "$%.2f / $%.2f" }
    static var awsMtdCostLabel: String { isZH ? "本月已产生费用" : "Month-to-date cost" }
    static var awsCostForecastLabel: String { isZH ? "预计月末费用" : "Forecasted cost" }
    static var awsFreeStatus: String { isZH ? "✅ 在免费套餐内" : "✅ Within free tier" }
    static var awsWarningStatus: String { isZH ? "⚠️ 接近免费套餐上限" : "⚠️ Approaching free tier limit" }
    static var awsExceededStatus: String { isZH ? "❌ 超出免费套餐" : "❌ Exceeded free tier" }
    static var awsEligibleLabel: String { isZH ? "免费资格" : "Free Tier" }
    static var awsYesLabel: String { isZH ? "✅ 免费" : "✅ Free" }
    static var awsNoLabel: String { isZH ? "❌ ~$%.0f/月" : "❌ ~$%.0f/mo" }

    // —— AWS Instances 子页（Overview / Instances）——
    static var awsSubTabOverview: String { isZH ? "概览" : "Overview" }
    static var awsSubTabInstances: String { isZH ? "实例" : "Instances" }
    static var awsInstancesEmpty: String { isZH ? "该区域暂无 EC2 实例" : "No EC2 instances in this region" }
    static var awsSearchPlaceholder: String { isZH ? "搜索实例…" : "Search instances…" }
    static var awsNoSelectionHint: String { isZH ? "选择一个实例" : "Select an instance" }
    static var awsInstTypeLabel: String { isZH ? "类型" : "Type" }
    static var awsStateLabel: String { isZH ? "状态" : "State" }
    static var awsStateRunning: String { isZH ? "运行中" : "Running" }
    static var awsStateStopped: String { isZH ? "已停止" : "Stopped" }
    static var awsStateStopping: String { isZH ? "停止中" : "Stopping" }
    static var awsStatePending: String { isZH ? "启动中" : "Pending" }
    static var awsStateShuttingDown: String { isZH ? "关机中" : "Shutting-down" }
    static var awsStateTerminated: String { isZH ? "已终止" : "Terminated" }
    static var awsLaunchLabel: String { isZH ? "启动时间" : "Launched" }
    static var awsUptimeLabel: String { isZH ? "运行时长" : "Uptime" }
    static var awsPublicIPLabel: String { isZH ? "公网 IP" : "Public IP" }
    static var awsPrivateIPLabel: String { isZH ? "内网 IP" : "Private IP" }
    static var awsSecurityGroupLabel: String { isZH ? "安全组" : "Security group" }
    static var awsRDPIngressLabel: String { isZH ? "我的 IP RDP 3389" : "RDP 3389 from my IP" }
    static var awsMyIPLabel: String { isZH ? "我的公网 IP" : "My public IP" }
    static var awsIngressOpen: String { isZH ? "已开放" : "Open" }
    static var awsIngressClosed: String { isZH ? "未开放" : "Closed" }
    static var awsIngressUnknown: String { isZH ? "未知" : "Unknown" }
    static var awsStartAction: String { isZH ? "启动" : "Start" }
    static var awsStopAction: String { isZH ? "停止" : "Stop" }
    static var awsOpenRDPAction: String { isZH ? "打开 RDP" : "Open RDP" }
    static var awsCopyAction: String { isZH ? "复制" : "Copy" }
    static var awsCopiedMessage: String { isZH ? "已复制到剪贴板" : "Copied to clipboard" }
    static var awsRDPConnectMessage: String { isZH ? "地址已复制，正在打开远程桌面…" : "Address copied — opening Remote Desktop…" }
    static var awsRDPNoAddress: String { isZH ? "实例没有可连接的公网 IP/DNS" : "Instance has no public IP/DNS to connect to" }
    static var awsRDPOpenFailed: String { isZH ? "无法打开远程桌面（未安装 Windows App？）" : "Could not open Remote Desktop (is Windows App installed?)" }
    static var awsAddIngressAction: String { isZH ? "开放 RDP 3389 给我的 IP" : "Open RDP 3389 to my IP" }
    static var awsStartSent: String { isZH ? "已发送启动请求" : "Start requested" }
    static var awsStopSent: String { isZH ? "已发送停止请求" : "Stop requested" }
    static var awsConfirmTitle: String { isZH ? "确认 AWS 操作" : "Confirm AWS action" }
    static var awsStartConfirmMessage: String { isZH ? "启动实例 %@？" : "Start instance %@?" }
    static var awsStopConfirmMessage: String { isZH ? "停止实例 %@？" : "Stop instance %@?" }
    static var awsIngressConfirmMessage: String { isZH ? "向 %@ 的安全组添加 RDP 入站规则（你的公网 IP）？" : "Add RDP ingress rule (your public IP) to %@'s security group?" }
    static var awsNoSecurityGroup: String { isZH ? "该实例没有安全组" : "This instance has no security group" }
    static var awsRdpAdded: String { isZH ? "已添加 RDP 入站规则" : "Added RDP inbound rule" }
    static var awsRdpAlreadyOpen: String { isZH ? "RDP 已对你的 IP 开放" : "RDP already open to your IP" }
    static var awsRdpUnknownState: String { isZH ? "无法读取规则" : "Could not read rules" }
    static var awsIPResolveFailed: String { isZH ? "无法获取你的公网 IP" : "Could not resolve your public IP" }

    // —— SG 入站规则管理 / 公网 DNS ——
    static var awsPublicDNSLabel: String { isZH ? "公网 DNS" : "Public DNS" }
    static var awsRulesHeader: String { isZH ? "入站规则" : "Inbound rules" }
    static var awsNoRules: String { isZH ? "无入站规则" : "No inbound rules" }
    static var awsAddRuleAction: String { isZH ? "添加规则" : "Add rule" }
    static var awsAddRuleTitle: String { isZH ? "添加入站规则" : "Add inbound rule" }
    static var awsEditRuleTitle: String { isZH ? "编辑入站规则" : "Edit inbound rule" }
    static var awsSaveRuleAction: String { isZH ? "保存" : "Save" }
    static var awsRemoveRuleAction: String { isZH ? "删除规则" : "Remove rule" }
    static var awsRemoveRuleConfirmMessage: String { isZH ? "从 %@ 的安全组删除该入站规则？" : "Remove this inbound rule from %@'s security group?" }
    static var awsRuleAdded: String { isZH ? "已添加入站规则" : "Inbound rule added" }
    static var awsRuleUpdated: String { isZH ? "入站规则已更新" : "Inbound rule updated" }
    static var awsRuleRemoved: String { isZH ? "已删除入站规则" : "Inbound rule removed" }
    static var awsPortFrom: String { isZH ? "起始端口" : "From" }
    static var awsPortTo: String { isZH ? "结束端口" : "To" }
    static var awsSourceLabel: String { isZH ? "来源（CIDR / sg-*）" : "Source (CIDR / sg-*)" }
    static var awsMyIPShort: String { isZH ? "我的 IP" : "My IP" }
    static var awsDescLabel: String { isZH ? "描述（可选）" : "Description (optional)" }
    static var awsAllTraffic: String { isZH ? "全部" : "All" }
    static var awsRulePortRequired: String { isZH ? "请输入起始和结束端口" : "Enter From and To ports" }
    static var awsRuleSourceRequired: String { isZH ? "请输入来源（CIDR 或 sg-*）" : "Enter a source (CIDR or sg-*)" }
    static var awsPermHint: String { isZH ? "实例管理需在 IAM 策略中授予 ec2:DescribeSecurityGroups、ec2:StartInstances、ec2:StopInstances、ec2:AuthorizeSecurityGroupIngress、ec2:RevokeSecurityGroupIngress" : "Instance controls need ec2:DescribeSecurityGroups, ec2:StartInstances, ec2:StopInstances, ec2:AuthorizeSecurityGroupIngress, ec2:RevokeSecurityGroupIngress in your IAM policy" }

    // MARK: - ☁️ Cloudflare
    static var cloudflareTabTitle: String { isZH ? "Cloudflare" : "Cloudflare" }
    static var cloudflareSection: String { isZH ? "Cloudflare 隧道" : "Cloudflare Tunnel" }
    static var cloudflareToggle: String { isZH ? "启用 Cloudflare 隧道管理" : "Enable Cloudflare Tunnel" }
    static var cloudflareTokenLabel: String { isZH ? "API Token" : "API Token" }
    static var cloudflareTokenHint: String { isZH ? "需要作用域：Zone:Read + Zone:DNS:Edit、Account:Read + Account:Cloudflare Tunnel:Edit（在 dash.cloudflare.com → My Profile → API Tokens 创建）" : "Needs scopes: Zone:Read + Zone:DNS:Edit, Account:Read + Account:Cloudflare Tunnel:Edit (create at dash.cloudflare.com → My Profile → API Tokens)" }
    static var cloudflareVerifyAction: String { isZH ? "验证并发现" : "Verify & Discover" }
    static var cloudflareVerifyBusy: String { isZH ? "验证中…" : "Verifying…" }
    static var cloudflareAccountLabel: String { isZH ? "账户" : "Account" }
    static var cloudflareZoneLabel: String { isZH ? "Zone" : "Zone" }
    static var cloudflareTunnelLabel: String { isZH ? "隧道" : "Tunnel" }
    static var cloudflareNoSelection: String { isZH ? "—" : "—" }
    static var cloudflareDaemonRow: String { isZH ? "本机服务" : "Local service" }
    static var cloudflareDaemonRunning: String { isZH ? "运行中" : "Running" }
    static var cloudflareDaemonInstalled: String { isZH ? "已停止" : "Stopped" }
    static var cloudflareDaemonNotInstalled: String { isZH ? "未安装" : "Not installed" }
    static var cloudflareTunnelHealth: String { isZH ? "隧道健康" : "Tunnel health" }
    static var cloudflareTunnelHealthy: String { isZH ? "健康" : "Healthy" }
    static var cloudflareTunnelDegraded: String { isZH ? "降级" : "Degraded" }
    static var cloudflareTunnelDown: String { isZH ? "离线" : "Down" }
    static var cloudflareTunnelInactive: String { isZH ? "未激活" : "Inactive" }
    static var cloudflareConnectors: String { isZH ? "连接数" : "Connectors" }
    static var cloudflareConnectorsFormat: String { isZH ? "%d 个连接" : "%d connector(s)" }
    static var cloudflareLastUpdate: String { isZH ? "更新于" : "Updated" }
    static var cloudflareStartAction: String { isZH ? "启动" : "Start" }
    static var cloudflareStopAction: String { isZH ? "停止" : "Stop" }
    static var cloudflareRestartAction: String { isZH ? "重启" : "Restart" }
    static var cloudflareDaemonNote: String { isZH ? "系统服务（LaunchDaemon），启停需要管理员密码。若想免密控制可在终端运行 cloudflared service uninstall && cloudflared service install（改为登录自启）。" : "Runs as a system LaunchDaemon; start/stop prompts for your admin password. For passwordless control run `cloudflared service uninstall && cloudflared service install` (login agent)." }
    static var cloudflareConfirmTitle: String { isZH ? "确认 Cloudflare 操作" : "Confirm Cloudflare action" }
    static var cloudflareStartConfirm: String { isZH ? "启动 cloudflared 隧道服务？" : "Start the cloudflared tunnel service?" }
    static var cloudflareStopConfirm: String { isZH ? "停止 cloudflared 隧道服务？" : "Stop the cloudflared tunnel service?" }
    static var cloudflareRestartConfirm: String { isZH ? "重启 cloudflared 隧道服务？" : "Restart the cloudflared tunnel service?" }
    static var cloudflareDaemonOk: String { isZH ? "已执行" : "Done" }
    static var cloudflareDaemonNotRunning: String { isZH ? "服务仍未运行——请检查 API token 与 LaunchDaemon（sudo launchctl print system/com.cloudflare.cloudflared）" : "Service still not running — check the API token and LaunchDaemon (sudo launchctl print system/com.cloudflare.cloudflared)" }
    static var cloudflareDaemonStillRunning: String { isZH ? "服务仍在运行（可能被 launchd 自动重启）" : "Service is still running (launchd may auto-restart it)" }
    static var cloudflareRunningNotConnected: String { isZH ? "服务已运行但未连接到 Cloudflare——请检查隧道 token / cloudflared 日志" : "Service is running but not connected to Cloudflare — check the tunnel token / cloudflared logs" }
    static var cloudflareRouteChanged: String { isZH ? "路由已更新" : "Route updated" }
    static var cloudflareSubTabOverview: String { isZH ? "概览" : "Overview" }
    static var cloudflareSubTabHostnames: String { isZH ? "公开主机名" : "Public Hostnames" }
    static var cloudflareSubTabRoutes: String { isZH ? "私有 IP 路由" : "Private IP Routes" }
    static var cloudflareHostnamesEmpty: String { isZH ? "暂无公开主机名" : "No public hostnames" }
    static var cloudflareRoutesEmpty: String { isZH ? "暂无私有 IP 路由" : "No private IP routes" }
    static var cloudflareCopyAction: String { isZH ? "复制" : "Copy" }
    static var cloudflareCopied: String { isZH ? "已复制" : "Copied" }
    static var cloudflareAddHostnameTitle: String { isZH ? "添加公开主机名" : "Add public hostname" }
    static var cloudflareAddRouteTitle: String { isZH ? "添加私有 IP 路由" : "Add private IP route" }
    static var cloudflareHostnameField: String { isZH ? "主机名 (e.g. app.example.com)" : "Hostname (e.g. app.example.com)" }
    static var cloudflareServiceField: String { isZH ? "本地服务 (e.g. http://localhost:8080)" : "Local service (e.g. http://localhost:8080)" }
    static var cloudflareNetworkField: String { isZH ? "网络/CIDR (e.g. 10.0.0.0/24)" : "Network/CIDR (e.g. 10.0.0.0/24)" }
    static var cloudflareCommentField: String { isZH ? "备注（可选）" : "Comment (optional)" }
    static var cloudflareAddAction: String { isZH ? "添加" : "Add" }
    static var cloudflareRemoveAction: String { isZH ? "删除" : "Remove" }
    static var cloudflareRemoveHostnameConfirm: String { isZH ? "删除公开主机名 %@ 及其 DNS 记录？" : "Remove public hostname %@ and its DNS record?" }
    static var cloudflareRemoveRouteConfirm: String { isZH ? "删除私有 IP 路由 %@？" : "Remove private IP route %@?" }
    static var cloudflareHostnameRequired: String { isZH ? "请输入主机名" : "Enter a hostname" }
    static var cloudflareServiceRequired: String { isZH ? "请输入本地服务地址" : "Enter a local service URL" }
    static var cloudflareNetworkRequired: String { isZH ? "请输入网络/CIDR" : "Enter a network/CIDR" }
    static var cloudflareConfigHint: String { isZH ? "Settings → Services → Cloudflare 配置" : "Settings → Services → Cloudflare to configure" }

    // MARK: - Netlify
    static var netlifySection: String { isZH ? "Netlify" : "Netlify" }
    static var netlifyToggle: String { isZH ? "启用 Netlify 管理" : "Enable Netlify" }
    static var netlifyTokenLabel: String { isZH ? "Personal Access Token" : "Personal Access Token" }
    static var netlifyTokenHint: String { isZH ? "在 app.netlify.com → User settings → Applications → Personal access tokens 创建；重置 Netlify 密码会使旧令牌失效。令牌需能访问目标账户（SAML 团队需在创建时勾选允许）。" : "Create at app.netlify.com → User settings → Applications → Personal access tokens. Resetting your Netlify password invalidates tokens; grant access to your team (incl. SAML) when creating." }
    static var netlifyVerifyAction: String { isZH ? "验证并发现" : "Verify & Discover" }
    static var netlifyVerifyBusy: String { isZH ? "验证中…" : "Verifying…" }
    static var netlifyAccountLabel: String { isZH ? "账户" : "Account" }
    static var netlifyDeployNotifyLabel: String { isZH ? "部署状态通知" : "Deploy notifications" }
    static var netlifyDeployNotifyHint: String { isZH ? "部署成功 / 失败 / 回滚时发送系统通知" : "Notify when a deploy succeeds, fails, or is rolled back" }
    static var netlifySettingsNote: String { isZH ? "令牌仅保存在本机钥匙串（SecureStore）。Netlify API 限速：部署相关 3 次/分、100 次/天；普通请求约 500 次/分。" : "Token is stored only in your local keychain (SecureStore). Netlify rate limits: deploys 3/min & 100/day; general API ~500/min." }

    // —— Netlify 站点与部署 ——
    static var netlifyConfigHint: String { isZH ? "Settings → Services → Netlify 配置" : "Settings → Services → Netlify to configure" }
    static var netlifySiteSection: String { isZH ? "站点" : "Site" }
    static var netlifySearchPlaceholder: String { isZH ? "搜索站点…" : "Search sites…" }
    static var netlifySitesEmpty: String { isZH ? "该账户暂无站点" : "No sites in this account" }
    static var netlifyNoSelectionHint: String { isZH ? "选择一个站点" : "Select a site" }
    static var netlifyProjectIDLabel: String { isZH ? "Project ID" : "Project ID" }
    static var netlifyMainURLLabel: String { isZH ? "主链接" : "URL" }
    static var netlifyCustomDomainLabel: String { isZH ? "自定义域名" : "Custom domain" }
    static var netlifyAdminLabel: String { isZH ? "管理后台" : "Admin" }
    static var netlifyPublishedDeployLabel: String { isZH ? "线上部署" : "Published" }
    static var netlifyBuildHeader: String { isZH ? "构建设置" : "Build settings" }
    static var netlifyRepoLabel: String { isZH ? "仓库" : "Repo" }
    static var netlifyBranchLabel: String { isZH ? "分支" : "Branch" }
    static var netlifyBuildCmdLabel: String { isZH ? "构建命令" : "Build command" }
    static var netlifyPublishDirLabel: String { isZH ? "发布目录" : "Publish dir" }
    static var netlifyDeploysHeader: String { isZH ? "部署历史" : "Deploys" }
    static var netlifyDeploysEmpty: String { isZH ? "暂无部署" : "No deploys" }
    static var netlifyLastUpdate: String { isZH ? "更新于" : "Updated" }
    static var netlifyLiveBadge: String { isZH ? "线上" : "Live" }
    static var netlifyLockedBadge: String { isZH ? "已锁定" : "Locked" }
    static var netlifyContextProduction: String { isZH ? "生产" : "Production" }
    static var netlifyContextBranch: String { isZH ? "分支" : "Branch" }
    static var netlifyContextPreview: String { isZH ? "预览" : "Preview" }
    static var netlifyStateReady: String { isZH ? "已就绪" : "Ready" }
    static var netlifyStateCurrent: String { isZH ? "线上" : "Live" }
    static var netlifyStateOld: String { isZH ? "旧版" : "Old" }
    static var netlifyStateError: String { isZH ? "失败" : "Error" }
    static var netlifyStateBuilding: String { isZH ? "构建中" : "Building" }
    static var netlifyStateEnqueued: String { isZH ? "排队中" : "Queued" }
    static var netlifyStateUploading: String { isZH ? "上传中" : "Uploading" }
    static var netlifyStateProcessing: String { isZH ? "处理中" : "Processing" }

    // —— Netlify 动作 ——
    static var netlifyTriggerAction: String { isZH ? "触发部署" : "Deploy" }
    static var netlifyTriggerClearAction: String { isZH ? "清缓存并部署" : "Clear cache & deploy" }
    static var netlifyDeployFolderAction: String { isZH ? "部署本地目录…" : "Deploy Folder…" }
    static var netlifyNewSiteAction: String { isZH ? "新建站点" : "New Site" }
    static var netlifyOpenSiteAction: String { isZH ? "打开站点" : "Open site" }
    static var netlifyOpenAdminAction: String { isZH ? "打开后台" : "Open admin" }
    static var netlifyRollbackAction: String { isZH ? "回滚到此" : "Rollback" }
    static var netlifyLockAction: String { isZH ? "锁定线上版本" : "Lock live" }
    static var netlifyUnlockAction: String { isZH ? "解锁线上版本" : "Unlock live" }
    static var netlifyCopyAction: String { isZH ? "复制" : "Copy" }
    static var netlifyCopied: String { isZH ? "已复制" : "Copied" }

    // —— Netlify 确认与结果 ——
    static var netlifyConfirmTitle: String { isZH ? "确认 Netlify 操作" : "Confirm Netlify action" }
    static var netlifyTriggerConfirm: String { isZH ? "为 %@ 触发一次生产部署？" : "Trigger a production deploy for %@?" }
    static var netlifyTriggerClearConfirm: String { isZH ? "为 %@ 清缓存并触发生产部署？" : "Clear cache and trigger a production deploy for %@?" }
    static var netlifyRollbackConfirm: String { isZH ? "回滚 %@ 到部署 %@？该版本将重新上线。" : "Roll back %@ to deploy %@? This version will go live again." }
    static var netlifyLockConfirm: String { isZH ? "锁定部署 %@？将停止自动发布新的生产部署。" : "Lock deploy %@? This stops auto-publishing new production deploys." }
    static var netlifyUnlockConfirm: String { isZH ? "解锁部署 %@？将恢复自动发布。" : "Unlock deploy %@? This resumes auto-publishing." }
    static var netlifyTriggerSent: String { isZH ? "已触发部署" : "Deploy triggered" }
    static var netlifyTriggerClearSent: String { isZH ? "已触发（清缓存）" : "Deploy triggered (clear cache)" }
    static var netlifyRolledBack: String { isZH ? "已回滚" : "Rolled back" }
    static var netlifyLocked: String { isZH ? "已锁定部署" : "Deploy locked" }
    static var netlifyUnlocked: String { isZH ? "已解锁部署" : "Deploy unlocked" }
    static var netlifySiteCreated: String { isZH ? "站点已创建" : "Site created" }
    static var netlifyDeployUploaded: String { isZH ? "已上传，等待构建" : "Uploaded — building" }
    static var netlifyZipDeployTitle: String { isZH ? "%@ · dev_mon 上传" : "%@ · dev_mon upload" }

    // —— Netlify 新建站点 / 本地部署 ——
    static var netlifyNewSiteSheetTitle: String { isZH ? "从本地目录新建站点" : "New site from a local folder" }
    static var netlifySiteNameField: String { isZH ? "站点名称（可选）" : "Site name (optional)" }
    static var netlifyChooseFolderAction: String { isZH ? "选择文件夹…" : "Choose Folder…" }
    static var netlifyFolderHint: String { isZH ? "选择构建后的发布目录（如 dist / public）；dev_mon 会将其打包为 zip 上传到 Netlify。" : "Pick your built publish folder (e.g. dist / public); dev_mon zips and uploads it to Netlify." }
    static var netlifyCreateAndDeploy: String { isZH ? "创建并部署" : "Create & Deploy" }
    static var netlifyDeployTargetNote: String { isZH ? "名称留空 = 用文件夹名新建站点；填写名称 = 新建指定名称的站点；未选文件夹则只创建空站点。" : "Blank name = new site from the folder name; a typed name creates that site; no folder chosen creates an empty site." }
    static var netlifyFolderRequired: String { isZH ? "请先选择文件夹" : "Choose a folder first" }
    static var netlifyNamePlaceholder: String { isZH ? "my-site（留空自动生成）" : "my-site (blank = auto)" }

    // —— Netlify 部署通知 ——
    static var netlifyDeployReadyTitle: String { isZH ? "Netlify 部署成功" : "Netlify deploy ready" }
    static var netlifyDeployReadyBody: String { isZH ? "%@ 的新部署已上线" : "%@ deploy is live" }
    static var netlifyDeployFailedTitle: String { isZH ? "Netlify 部署失败" : "Netlify deploy failed" }
    static var netlifyDeployFailedBody: String { isZH ? "%@ 的部署失败" : "%@ deploy failed" }
    static var netlifyDeployRolledBackTitle: String { isZH ? "Netlify 已回滚" : "Netlify rolled back" }
    static var netlifyDeployRolledBackBody: String { isZH ? "已恢复到之前的部署版本" : "Restored a previous deploy" }

    // MARK: - Local DBs（本地数据库 MongoDB / MySQL / Neo4j）
    static var localDBsSection: String { isZH ? "本地数据库" : "Local DBs" }
    static var localDBsToggle: String { isZH ? "启用本地数据库监控" : "Enable local DBs" }
    static var localDBsNotifyLabel: String { isZH ? "数据库状态通知" : "Database status notification" }
    static var localDBsNotifyHint: String { isZH ? "受监控的数据库停止 / 恢复运行时发送系统通知" : "Notify when a monitored database stops or restarts" }
    static var localDBsMySQLUserLabel: String { isZH ? "MySQL 用户名" : "MySQL user" }
    static var localDBsNeo4jUserLabel: String { isZH ? "Neo4j 用户名" : "Neo4j user" }
    static var localDBsPasswordLabel: String { isZH ? "密码（可选，留空 = 无密码）" : "Password (optional, blank = none)" }
    static var localDBsSettingsNote: String {
        isZH ? "状态通过本地端口探测；启动/停止用 `brew services`（用户级，无需管理员密码）。MongoDB 与 Neo4j 注册为登录服务；MySQL 用 ad-hoc `brew services run`（不改变登录自启）。凭据仅存本机钥匙串。"
             : "Status is probed via local ports. Start/Stop use `brew services` (user-level, no admin). MongoDB & Neo4j are login services; MySQL starts ad-hoc (`brew services run`, no login autostart). Credentials stay in your keychain."
    }
    static var localDBsCheckAction: String { isZH ? "检查状态" : "Check status" }
    static var localDBsCheckBusy: String { isZH ? "检查中…" : "Checking…" }
    static var localDBsConfigHint: String { isZH ? "Settings → Services → Local DBs 配置" : "Settings → Services → Local DBs to configure" }
    static var dbStatusRunning: String { isZH ? "运行中" : "Running" }
    static var dbStatusStopped: String { isZH ? "已停止" : "Stopped" }
    static var dbStatusUnknown: String { isZH ? "未知" : "Unknown" }
    static var dbActionStart: String { isZH ? "启动" : "Start" }
    static var dbActionStop: String { isZH ? "停止" : "Stop" }
    static var dbDbsAction: String { isZH ? "库" : "DBs" }
    static var dbDatabasesEmpty: String { isZH ? "无数据库" : "No databases" }
    static var dbFromDisk: String { isZH ? "（离线 · 磁盘）" : "(offline · on disk)" }
    static var localDBBrewMissing: String { isZH ? "未找到 Homebrew（brew）" : "Homebrew (brew) not found" }
    static var localDBStarted: String { isZH ? "%@ 已启动" : "%@ started" }
    static var localDBStopped: String { isZH ? "%@ 已停止" : "%@ stopped" }
    static var localDBStartFailed: String { isZH ? "%@ 启动失败（可能仍在启动）" : "%@ failed to start (may still be starting)" }
    static var dbDownTitle: String { isZH ? "%@ 已停止" : "%@ stopped" }
    static var dbDownBody: String { isZH ? "本地数据库 %@ 已停止运行" : "Local database %@ is no longer running" }
    static var dbRestoredTitle: String { isZH ? "%@ 已恢复" : "%@ restored" }
    static var dbRestoredBody: String { isZH ? "本地数据库 %@ 已恢复运行" : "%@ is running again" }

    static func localDBName(_ id: String) -> String {
        switch id {
        case "mongodb": return "MongoDB"
        case "mysql": return "MySQL"
        case "neo4j": return "Neo4j"
        default: return id
        }
    }
    static func localDBClientMissing(_ tool: String) -> String {
        isZH ? "未找到命令行客户端：\(tool)（请用 Homebrew 安装）" : "Client not found: \(tool) (install via Homebrew)"
    }
    static func dbUptime(_ seconds: Int) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if seconds < 60 { return isZH ? "\(seconds)秒" : "\(seconds)s" }
        if d > 0 { return isZH ? "\(d)天\(h)小时" : "\(d)d \(h)h" }
        if h > 0 { return isZH ? "\(h)小时\(m)分" : "\(h)h \(m)m" }
        return isZH ? "\(m)分" : "\(m)m"
    }

    // —— 通用：搜索选择器 ——
    static var searchNoMatches: String { isZH ? "无匹配结果" : "No matches" }
    static var searchClearTooltip: String { isZH ? "清除搜索" : "Clear search" }
    static var searchListExpand: String { isZH ? "展开列表" : "Expand list" }
    static var searchListCollapse: String { isZH ? "收起列表" : "Collapse list" }
}
