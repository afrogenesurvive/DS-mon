import Foundation

// MARK: - 应用常量集中管理

enum AppConfig {
    // ⏱ 刷新间隔
    static let balanceRefreshInterval: TimeInterval = 300
    static let modelsRefreshInterval: TimeInterval = 3600
    static let balanceRequestTimeout: TimeInterval = 8
    static let modelsRequestTimeout: TimeInterval = 5

    // 🔌 代理默认值
    static let defaultProxyPort: UInt16 = 18080
    static let minProxyPort: Int = 1024
    static let maxProxyPort: Int = 65535
    static let proxyRequestTimeout: TimeInterval = 600

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
    static let maxHTTPBodySize: Int = 20_971_520  // 20MB (supports multimodal base64 images)
    static let sseStreamChunkSize: Int = 4096

    // 🧹 进程管理
    static let portReleaseDelay: useconds_t = 300_000  // 300ms
    static let portReleaseWait: useconds_t = 500_000   // 500ms

    // 📝 日志
    static let cacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.dsmon.app")
    }()
    static let proxyLogURL = cacheDir.appendingPathComponent("proxy.log")
    static let syncLogURL = cacheDir.appendingPathComponent("sync.log")

    static func appendLog(to url: URL, _ message: String) {
        guard let d = message.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let fh = FileHandle(forWritingAtPath: url.path) {
                fh.seekToEndOfFile()
                fh.write(d)
                fh.closeFile()
            }
        } else {
            try? d.write(to: url)
        }
    }

    // 🌐 共享 URLSession（绕过系统代理）
    static let directURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = proxyRequestTimeout
        config.timeoutIntervalForResource = proxyRequestTimeout
        return URLSession(configuration: config)
    }()
}
