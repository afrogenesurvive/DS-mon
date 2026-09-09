import Foundation
import UserNotifications

/// DeepSeek 高峰/低谷切换的系统通知（可选，默认关闭）
enum PeakNotifier {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Strings.Keys.peakNotificationEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.peakNotificationEnabled) }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 高峰开始前的提前提醒（建议类通知）。
    private static let advanceInterval: TimeInterval = 600   // 10 分钟

    /// 安排下一次高峰/低谷切换提醒 + （若进入高峰）提前 10 分钟的提醒；关闭时清空待发送通知。
    static func scheduleNextTransition() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["ds_peak_transition", "ds_peak_advance"])
        guard enabled else { return }

        let next = DeepSeekPricing.nextTransition()
        let becomingPeak = DeepSeekPricing.isPeak(next)

        schedule(title: becomingPeak ? Strings.peakNotifyTitle : Strings.offPeakNotifyTitle,
                 body: becomingPeak ? Strings.peakNotifyBody : Strings.offPeakNotifyBody,
                 at: next, identifier: "ds_peak_transition", center: center)

        // 建议：进入高峰前 10 分钟提醒（仅在即将进入高峰时触发）。
        if becomingPeak {
            let advance = next.addingTimeInterval(-Self.advanceInterval)
            schedule(title: Strings.peakSoonNotifyTitle,
                     body: Strings.peakSoonNotifyBody,
                     at: advance, identifier: "ds_peak_advance", center: center)
        }
    }

    private static func schedule(title: String, body: String, at date: Date,
                                 identifier: String, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                AppConfig.appendLog(to: AppConfig.proxyLogURL, "peak notify: \(error)")
            }
        }
    }
}
