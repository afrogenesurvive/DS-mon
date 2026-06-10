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
        CodexRelayManager.shared.restore()

        // 监听崩溃通知，自动重启 codex-relay
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartCodexRelay),
            name: .codexRelayRestartNeeded, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyServer.shared.stop()
        CodexRelayManager.shared.stop()
        Task { await UsageStore.shared.close() }
    }

    private func restoreProxy() {
        try? ProxyServer.shared.start()
    }

    @objc private func restartCodexRelay() {
        CodexRelayManager.shared.restartIfNeeded()
    }
}

/// 全局访问（供设置面板调用）
@MainActor
func CodexRelayAction(_ action: String) {
    switch action {
    case "start":  CodexRelayManager.shared.start()
    case "stop":   CodexRelayManager.shared.stop()
    case "toggle":
        let enabled = UserDefaults.standard.bool(forKey: Strings.Keys.codexRelayEnabled)
        CodexRelayManager.shared.toggle(enabled: enabled)
    default: break
    }
}
