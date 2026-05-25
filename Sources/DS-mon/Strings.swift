import Foundation

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
    static let showMenuIconDidChange = Notification.Name("showMenuIconDidChange")
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

    static var balanceText: String { isZH ? "¥%.2f" : "¥%.2f" }
    static var grantedText: String { isZH ? "赠送 ¥%.2f" : "Granted ¥%.2f" }
    static var toppedUpText: String { isZH ? "充值 ¥%.2f" : "Topped Up ¥%.2f" }
}
