import Foundation

// MARK: - 应用常量集中管理

enum AppConfig {
    // ⏱ 刷新间隔
    static let balanceRefreshInterval: TimeInterval = 60
    static let modelsRefreshInterval: TimeInterval = 3600
    static let balanceRequestTimeout: TimeInterval = 8
    static let modelsRequestTimeout: TimeInterval = 5

    // 🔌 代理默认值
    static let defaultProxyPort: UInt16 = 18080
    static let minProxyPort: Int = 1024
    static let maxProxyPort: Int = 65535
    static let proxyRequestTimeout: TimeInterval = 300

    // 💰 余额
    static let defaultBalanceThreshold: Double = 20
    static let defaultMaxBalanceAmount: Double = 100
    static let blinkInterval: TimeInterval = 1.5

    // 🪟 UI
    static let popoverWidth: CGFloat = 290
    static let popoverHeight: CGFloat = 500
    static let settingsWidth: CGFloat = 520
    static let settingsHeight: CGFloat = 480

    // 📏 网络
    static let maxHTTPBodySize: Int = 262_144
    static let sseStreamChunkSize: Int = 4096

    // 🧹 进程管理
    static let portReleaseDelay: useconds_t = 300_000  // 300ms
    static let portReleaseWait: useconds_t = 500_000   // 500ms
}
