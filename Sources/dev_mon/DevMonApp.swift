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
        try? ProxyServer.shared.start()
    }
}
