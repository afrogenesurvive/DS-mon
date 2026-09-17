import Foundation

// MARK: - 应用常量集中管理

enum AppConfig {
    // ⏱ 刷新间隔
    static let balanceRefreshInterval: TimeInterval = 300
    static let modelsRefreshInterval: TimeInterval = 3600
    static let balanceRequestTimeout: TimeInterval = 8
    static let modelsRequestTimeout: TimeInterval = 5
    /// DeepSeek 计费时段规则的抓取间隔（小时）。用户可在「设置 → 服务 → 计费时段规则」中调整
    /// （范围 1…168，存于 `PeakRulesStore.intervalKey`）。
    static let peakRulesCheckIntervalDefaultHours: Double = 24

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
    static let popoverWidth: CGFloat = 334
    static let popoverHeight: CGFloat = 550
    /// 弹窗内容可用宽度（减去左右各 14pt 的 padding）
    static var contentWidth: CGFloat { popoverWidth - 28 }
    /// 弹窗缩放（拖右下角把手，UI/字体/图标按比例整体放大）
    static let popoverScaleKey = "popover_ui_scale"
    static let popoverScaleMin: CGFloat = 1.0
    static let popoverScaleMax: CGFloat = 2.2
    static func clampedPopoverScale(_ s: CGFloat) -> CGFloat {
        let v = s.isFinite ? s : 1.0
        return min(max(v, popoverScaleMin), popoverScaleMax)
    }
    static func savedPopoverScale() -> CGFloat {
        let v = UserDefaults.standard.double(forKey: popoverScaleKey)
        return v > 0 ? clampedPopoverScale(CGFloat(v)) : 1.0
    }
    static func setSavedPopoverScale(_ s: CGFloat) {
        UserDefaults.standard.set(clampedPopoverScale(s), forKey: popoverScaleKey)
    }
    static let settingsWidth: CGFloat = 520
    static let settingsHeight: CGFloat = 480

    // 📏 网络
    static let maxHTTPBodySize: Int = 20_971_520  // 20MB (supports multimodal base64 images)
    static let sseStreamChunkSize: Int = 4096
    /// /sync/push 请求体上限。调用方的缓冲区上限是 5 MB（agent-runner 的 MAX_BUFFER_BYTES），
    /// 信封加密会让体积再涨约 1/3，所以这里留到 12 MB —— 比现状宽松，不会把合法批次拒掉。
    static let maxSyncBodySize: Int = 12_582_912  // 12MB
    /// /sync/* 读取整条请求的超时，防止慢速连接长期占用
    static let syncReadTimeout: TimeInterval = 30

    // ☁️ Cloud tracking
    static let cloudRefreshInterval: TimeInterval = 600  // 10 min
    static let cloudRequestTimeout: TimeInterval = 10

    // 🧹 进程管理
    static let portReleaseDelay: useconds_t = 300_000  // 300ms
    static let portReleaseWait: useconds_t = 500_000   // 500ms

    // 📝 日志
    static let cacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.devmon.app")
    }()
    static let proxyLogURL = cacheDir.appendingPathComponent("proxy.log")
    static let syncLogURL = cacheDir.appendingPathComponent("sync.log")

    /// 本应用自己的监听端口（本地代理 / 同步服务）。把它们公开发布到公网，
    /// 等于把一个「用本机 API Key 转发」的服务挂到互联网上。
    static let appOwnedPorts: Set<Int> = [Int(defaultProxyPort), 18888]

    /// 从 service / target 字符串里解析出「指向本机且属于本应用」的端口。
    /// 接受 `http://localhost:18888`、`localhost:18888`、`127.0.0.1:18080` 等写法。
    static func appOwnedServicePort(in service: String) -> Int? {
        let lower = service.lowercased()
        guard lower.contains("localhost") || lower.contains("127.0.0.1") else { return nil }
        guard let range = service.range(of: #":(\d{2,5})"#, options: .regularExpression) else { return nil }
        let digits = service[range].dropFirst()
        guard let port = Int(digits), appOwnedPorts.contains(port) else { return nil }
        return port
    }

    /// 该端口是否已经配好了入站令牌（没令牌就不允许公开发布）。
    static func appOwnedPortIsAuthenticated(_ port: Int) -> Bool {
        if port == Int(defaultProxyPort) { return ProxyServer.shared.clientToken != nil }
        if port == 18888 { return SyncManager.shared.pushToken != nil }
        return true
    }

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

    // MARK: - 🔒 文件权限

    /// 密钥 / 数据库 / 日志一律收紧到仅当前用户可读
    static let privateFileMode: NSNumber = 0o600
    static let privateDirMode: NSNumber = 0o700

    /// 把文件权限收紧到 0600。失败只打印，不抛错（例如文件尚不存在）。
    @discardableResult
    static func secureFile(_ url: URL, mode: NSNumber = privateFileMode) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            print("[AppConfig] chmod failed for \(url.path): \(error)")
            return false
        }
    }

    /// 把目录权限收紧到 0700。
    @discardableResult
    static func secureDirectory(_ url: URL, mode: NSNumber = privateDirMode) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            print("[AppConfig] chmod failed for \(url.path): \(error)")
            return false
        }
    }

    /// 创建目录（若不存在）并收紧权限，返回目录 URL。
    @discardableResult
    static func ensurePrivateDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        secureDirectory(url)
        return url
    }

    /// 启动时自检并修正已知敏感路径的权限（用户误改/旧版本遗留都能纠正）。
    static func enforcePrivatePermissions() {
        secureDirectory(URL(fileURLWithPath: NSHomeDirectory() + "/.dev-mon"))
        secureFile(URL(fileURLWithPath: NSHomeDirectory() + "/.dev-mon/.enc_key"))
        ensurePrivateDirectory(cacheDir)
        secureFile(proxyLogURL)
        secureFile(syncLogURL)
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
