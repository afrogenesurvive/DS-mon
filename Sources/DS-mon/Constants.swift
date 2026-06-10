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

    // 🩺 健康检测
    static let codexRelayHealthPort: UInt16 = 4446
    static let codexRelayHealthTimeout: TimeInterval = 3
    static let codexRelayHealthRetryTimeout: TimeInterval = 1
    static let codexRelayHealthRetries: Int = 6
    static let codexRelayHealthRetryInterval: TimeInterval = 0.5
    static let codexRelayMonitorInitialDelay: TimeInterval = 10
    static let codexRelayMonitorInterval: TimeInterval = 15

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
    static let codexRelayStartupWait: TimeInterval = 0.5
}
