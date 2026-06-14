import SwiftUI
import AppKit
import Charts

@main
struct DSmonApp: App {
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
        // Dock 图标
        if let url = Bundle.main.url(forResource: "dslogo1", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }

        StatusBarController.shared.stats = Self.sharedStats
        StatusBarController.shared.setup()
        restoreProxy()
        SyncManager.shared.start()

    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyServer.shared.stop()
        Task { await UsageStore.shared.close() }
    }

    private func restoreProxy() {
        try? ProxyServer.shared.start()
    }
}
