import SwiftUI
import AppKit
import Charts

@main
struct DevMonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static let sharedStats = DeepSeekStats()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动时套用保存的外观主题（System / Light / Dark）
        Theme.apply()

        // Dock 图标
        if let url = Bundle.main.url(forResource: "dslogo1", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }

        StatusBarController.shared.stats = Self.sharedStats
        StatusBarController.shared.setup()
        restoreProxy()
        SyncManager.shared.start()
        SeatRegistry.shared.startAutoCheck()
        PeakNotifier.requestAuthorization()
        PeakNotifier.scheduleNextTransition()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyServer.shared.stop()
        // 立即落盘 UI 状态，避免丢掉 300ms 防抖窗口内的页签 / 折叠改动
        UIStateStore.shared.flush()
        Task { await UsageStore.shared.close() }
    }

    private func restoreProxy() {
        // 启动时修正敏感文件权限（旧版本遗留 / 被外部改动）
        AppConfig.enforcePrivatePermissions()

        // 迁移：旧版本的 ProxyServer 自己写 proxy_enabled，且 exit 时会写成 false，
        // 所以那个键不能代表「用户是否想开代理」。只有设置里的开关写过的
        // proxy_user_intent 才算数；老用户没有这个键时保持原来的「装了就用」。
        let defaults = UserDefaults.standard
        let hasIntent = defaults.object(forKey: Strings.Keys.proxyUserIntent) != nil
        let wanted = hasIntent ? defaults.bool(forKey: Strings.Keys.proxyUserIntent) : true
        // 迁移后把两个键写成一致，「设置 → 服务」里的开关才能反映真实状态
        // （旧版本退出时把 proxyEnabled 写成 false，界面上会显示成关闭但代理其实在跑）
        defaults.set(wanted, forKey: Strings.Keys.proxyUserIntent)
        defaults.set(wanted, forKey: Strings.Keys.proxyEnabled)
        guard wanted else { return }

        do {
            try ProxyServer.shared.start()
        } catch {
            print("[AppDelegate] proxy restore failed: \(error)")
        }
    }
}
