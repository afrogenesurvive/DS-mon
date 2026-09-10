import Foundation
import UserNotifications

// MARK: - 通知中心（系统通知 + popover 横幅 + 「通知」页历史列表）

/// 事件种类。
enum AppAlertKind: String, Codable {
    case peakStart          // DeepSeek 高峰计费开始
    case peakEnd            // DeepSeek 低谷计费开始
    case peakSoon           // 建议：高峰即将开始（提前提醒）
    case tunnelDown         // Cloudflare 隧道断开
    case tunnelRestored     // Cloudflare 隧道恢复
    case dbDown             // 本地数据库停止
    case dbRestored         // 本地数据库恢复
    case storeDegraded      // 仓库自带服务停止
    case storeRestored      // 仓库自带服务恢复
    case netlifyDeployReady // Netlify 部署成功
    case netlifyDeployFailed // Netlify 部署失败
    case netlifyDeployRolledBack // Netlify 回滚成功
    case balanceWarning     // 余额进入预警区间
    case lowBalance         // 余额不足
}

/// 一条通知记录。同时驱动：系统通知（可选）+ popover 横幅 + 「通知」页历史列表。
struct AppAlert: Identifiable, Equatable, Codable {
    let id: UUID
    var kind: AppAlertKind
    var title: String
    var body: String
    var date: Date
    var isUnread: Bool

    init(kind: AppAlertKind, title: String, body: String, date: Date = Date(), isUnread: Bool = true) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.body = body
        self.date = date
        self.isUnread = isUnread
    }
}

/// 统一的告警入口：每条事件可选地发系统通知，并总是进入 popover 横幅 + 历史列表。
@MainActor
enum AppAlertCenter {
    static let didFire = Notification.Name("appAlertDidFire")
    static let didUpdate = Notification.Name("appAlertDidUpdate")

    private static let maxAlerts = 30

    /// 历史列表（新→旧）。进程内保留，不落盘。
    private(set) static var recent: [AppAlert] = []

    static var unreadCount: Int { recent.filter { $0.isUnread }.count }

    /// 发事件：系统通知（可选）+ popover 横幅 + 历史列表。
    /// - Parameter system: 是否同时发送 macOS 系统通知。为 false 时只更新 popover（用于
    ///   已有独立调度器的场景，例如高峰切换的系统通知由 PeakNotifier 调度，避免重复）。
    static func fire(_ kind: AppAlertKind, title: String, body: String, system: Bool = true) {
        postInApp(AppAlert(kind: kind, title: title, body: body))
        guard system else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)   // nil = 立即发送
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppConfig.appendLog(to: AppConfig.proxyLogURL, "alert: \(error.localizedDescription)")
            }
        }
    }

    /// 仅 popover 横幅 + 历史列表（不发系统通知）。
    static func postInApp(_ alert: AppAlert) {
        recent.insert(alert, at: 0)
        if recent.count > maxAlerts {
            recent.removeLast(recent.count - maxAlerts)
        }
        NotificationCenter.default.post(name: didFire, object: alert)
    }

    static func markAllRead() {
        for i in recent.indices { recent[i].isUnread = false }
        NotificationCenter.default.post(name: didUpdate, object: nil)
    }

    static func remove(_ id: UUID) {
        recent.removeAll { $0.id == id }
        NotificationCenter.default.post(name: didUpdate, object: nil)
    }

    static func removeAll() {
        recent.removeAll()
        NotificationCenter.default.post(name: didUpdate, object: nil)
    }
}
