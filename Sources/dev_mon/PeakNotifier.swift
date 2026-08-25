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

    /// 安排下一次高峰/低谷切换提醒；关闭时清空待发送通知。
    static func scheduleNextTransition() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["ds_peak_transition"])
        guard enabled else { return }

        let next = DeepSeekPricing.nextTransition()
        let becomingPeak = DeepSeekPricing.isPeak(next)

        let content = UNMutableNotificationContent()
        content.title = becomingPeak ? Strings.peakNotifyTitle : Strings.offPeakNotifyTitle
        content.body = becomingPeak ? Strings.peakNotifyBody : Strings.offPeakNotifyBody
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: "ds_peak_transition", content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                AppConfig.appendLog(to: AppConfig.proxyLogURL, "peak notify: \(error)")
            }
        }
    }
}
