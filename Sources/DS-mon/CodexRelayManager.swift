import Foundation

// MARK: - codex-relay 子进程管理器

/// 管理 codex-relay 二进制子进程的生命周期：
///   1. 从 .app bundle 复制到 ~/.ds-mon/
///   2. 启动/停止子进程
///   3. 健康检测与崩溃自动重启
@MainActor
final class CodexRelayManager {
    static let shared = CodexRelayManager()

    // MARK: 常量
    let port: UInt16 = AppConfig.codexRelayHealthPort
    private var process: Process?
    private var lastRestartAttempt: Date?
    private let restartCooldown: TimeInterval = 5.0  // 最小重启间隔
    private var upstreamBaseURL: String {
        // 优先使用 relay 指定的提供商，否则使用当前活跃提供商
        let targetId = ProviderManager.shared.activeProvider?.relayProviderId
        let provider = targetId.flatMap { pid in
            ProviderManager.shared.providers.first(where: { $0.id == pid && $0.isEnabled })
        } ?? ProviderManager.shared.activeProvider
        
        if let p = provider {
            return "\(p.baseURL)\(p.apiPath)"
        }
        return "https://api.deepseek.com/v1"
    }

    private var binaryPath: String {
        "\(NSHomeDirectory())/.ds-mon/codex-relay"
    }

    private var apiKey: String {
        // 优先使用 relay 指定的提供商
        let targetId = ProviderManager.shared.activeProvider?.relayProviderId
        if let pid = targetId,
           let provider = ProviderManager.shared.providers.first(where: { $0.id == pid && $0.isEnabled }) {
            return ProviderManager.shared.apiKey(for: provider)
        }
        return ProviderManager.shared.activeAPIKey
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Strings.Keys.codexRelayEnabled)
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// codex-relay 版本号（从二进制 --version 读取，缓存）
    private static var _cachedVersion: String?

    static var version: String {
        if let cached = _cachedVersion { return cached }
        // 先找 bundle 内的，再找 ~/.ds-mon/ 的
        let paths = [
            Bundle.main.path(forResource: "codex-relay", ofType: nil),
            "\(NSHomeDirectory())/.ds-mon/codex-relay"
        ].compactMap { $0 }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["--version"]
            let outPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = Pipe()
            guard (try? task.run()) != nil else { continue }
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                _cachedVersion = text
                return text
            }
        }
        return "unknown"
    }

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeProviderChanged),
            name: .activeProviderDidChange, object: nil
        )
    }

    @objc private func activeProviderChanged() {
        guard isEnabled else { return }
        print("[CodexRelay] 活跃提供商已变更，重启 relay...")
        stop()
        // 给端口一点释放时间
        usleep(AppConfig.portReleaseWait)
        start()
    }

    // MARK: - 启动

    func start() {
        guard isEnabled else { return }
        guard !isRunning else { return }
        guard !apiKey.isEmpty else {
            let msg = "API Key 未设置，无法启动协议转换器"
            print("[CodexRelay] \(msg)")
            disableAndReport(msg)
            return
        }

        // 复制二进制到 ~/.ds-mon/
        copyBinaryIfNeeded()

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            let msg = "codex-relay not found at \(binaryPath)"
            print("[CodexRelay] \(msg)")
            disableAndReport(msg)
            return
        }

        // 杀掉残留进程
        killExistingProcess(on: port)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--port", "\(port)", "--upstream", upstreamBaseURL]

        var env = ProcessInfo.processInfo.environment
        env["CODEX_RELAY_API_KEY"] = apiKey
        env["CODEX_RELAY_PORT"] = "\(port)"
        env["CODEX_RELAY_UPSTREAM"] = upstreamBaseURL

        // 设置模型映射：将 Codex 常用模型名映射到 relay 提供商（或活跃提供商）的默认模型
        let targetProviderId = ProviderManager.shared.activeProvider?.relayProviderId
        let modelProvider = targetProviderId.flatMap { pid in
            ProviderManager.shared.providers.first(where: { $0.id == pid && $0.isEnabled })
        } ?? ProviderManager.shared.activeProvider
        if let mp = modelProvider,
           let defaultModel = mp.defaultModel ?? mp.pricingOverrides.keys.sorted().first {
            // Codex 模型名 + 常用第三方模型名，全部映射到当前提供商的默认模型
            let sourceModels = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2", "gpt-4o", "claude-sonnet-4", "claude-opus-4", "claude-haiku-3.5", "deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash", "deepseek-v4-pro"]
            let mappings = sourceModels.map { "\($0):\(defaultModel)" }.joined(separator: ",")
            env["CODEX_RELAY_MODEL_MAP"] = mappings
            print("[CodexRelay] 模型映射: \(defaultModel)")
        }
        // 日志：记录 relay 启动
        let relayProviderId = ProviderManager.shared.activeProvider?.relayProviderId ?? ProviderManager.shared.activeProvider?.id ?? "?"
        let logPath = NSHomeDirectory() + "/Library/Caches/com.dsmon.app/proxy.log"
        let logMsg = "[Relay] 启动 → 端口: \(port), 上游: \(upstreamBaseURL), 提供商: \(relayProviderId), API Key: \(apiKey.prefix(8))..." + "\n"
        if let d = logMsg.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(d)
                    fh.closeFile()
                }
            } else {
                try? d.write(to: URL(fileURLWithPath: logPath))
            }
        }

        process.environment = env

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                print("[CodexRelay] \(trimmed)")
                // 同时写到日志文件
                let logPath = NSHomeDirectory() + "/Library/Caches/com.dsmon.app/proxy.log"
                let logLine = "[RelayErr] \(trimmed)\n"
                if let d = logLine.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: logPath) {
                        if let fh = FileHandle(forWritingAtPath: logPath) {
                            fh.seekToEndOfFile()
                            fh.write(d)
                            fh.closeFile()
                        }
                    } else {
                        try? d.write(to: URL(fileURLWithPath: logPath))
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            print("[CodexRelay] 已启动，PID: \(process.processIdentifier)")

            process.terminationHandler = { [weak self] proc in
                let reason = proc.terminationReason == .exit
                    ? "exit code \(proc.terminationStatus)"
                    : "uncaught signal"
                print("[CodexRelay] 已停止 (\(reason))")
                Task { @MainActor [weak self] in
                    guard let self, self.process === proc else { return }
                    self.process = nil
                    // 进程意外终止时通知 UI 并触发自动重启
                    if UserDefaults.standard.bool(forKey: Strings.Keys.codexRelayEnabled) {
                        ProxyServer.shared.reportCodexRelayError("codex-relay stopped (\(reason))")
                        NotificationCenter.default.post(name: .codexRelayRestartNeeded, object: nil)
                    }
                }
            }

            ProxyServer.shared.reportCodexRelayError(nil)
            ProxyServer.shared.checkCodexRelayHealthWithRetry(
                retries: AppConfig.codexRelayHealthRetries,
                interval: AppConfig.codexRelayHealthRetryInterval,
                port: port
            )
        } catch {
            let msg = "codex-relay failed to launch: \(error.localizedDescription)"
            print("[CodexRelay] \(msg)")
            disableAndReport(msg)
        }
    }

    // MARK: - 停止

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
        print("[CodexRelay] 已停止")
        ProxyServer.shared.reportCodexRelayError("codex-relay stopped")
    }

    func toggle(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Strings.Keys.codexRelayEnabled)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// 应用启动时恢复状态
    func restore() {
        if UserDefaults.standard.object(forKey: Strings.Keys.codexRelayEnabled) == nil {
            UserDefaults.standard.set(true, forKey: Strings.Keys.codexRelayEnabled)
        }
        guard isEnabled else { return }
        start()
    }

    /// 崩溃后自动重启（由 ProxyServer 健康检测触发）
    func restartIfNeeded() {
        guard isEnabled else { return }
        guard !isRunning else { return }
        guard Date().timeIntervalSince(lastRestartAttempt ?? .distantPast) >= restartCooldown else {
            print("[CodexRelay] 重启冷却中，跳过")
            return
        }
        lastRestartAttempt = Date()
        print("[CodexRelay] 检测到进程未运行，自动重启...")
        killExistingProcess(on: port)
        usleep(AppConfig.portReleaseWait)
        start()
    }

    // MARK: - Private

    private func copyBinaryIfNeeded() {
        guard let bundled = Bundle.main.path(forResource: "codex-relay", ofType: nil) else { return }
        let dest = URL(fileURLWithPath: binaryPath)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: binaryPath) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: URL(fileURLWithPath: bundled), to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
            print("[CodexRelay] 已从包内复制到 \(binaryPath)")
        } catch {
            print("[CodexRelay] 复制失败: \(error.localizedDescription)")
            if !fm.isExecutableFile(atPath: binaryPath) {
                disableAndReport("codex-relay 复制失败且旧文件不可用: \(error.localizedDescription)")
            } else {
                print("[CodexRelay] 使用已有文件: \(binaryPath)")
            }
        }
    }

    private func killExistingProcess(on port: UInt16) {
        // 方法1: pkill -f 按进程名杀掉所有 codex-relay
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "codex-relay"]
        try? pkill.run()
        pkill.waitUntilExit()
        usleep(AppConfig.portReleaseDelay)

        // 方法2: 如果 pkill 没权限，再尝试 lsof + kill
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = nil
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let pids = String(data: data, encoding: .utf8), !pids.isEmpty else { return }
        for pid in pids.split(whereSeparator: { $0.isNewline }) {
            let pidStr = pid.trimmingCharacters(in: CharacterSet.whitespaces)
            guard !pidStr.isEmpty, let pidInt = Int32(pidStr) else { continue }
            if pidInt == getpid() { continue }
            print("[CodexRelay] 杀掉旧进程 PID=\(pidInt)")
            kill(pidInt, SIGTERM)
            usleep(AppConfig.portReleaseDelay)
            kill(pidInt, SIGKILL)
        }
    }

    private func disableAndReport(_ msg: String) {
        print("[CodexRelay] \(msg)")
        UserDefaults.standard.set(false, forKey: Strings.Keys.codexRelayEnabled)
        ProxyServer.shared.reportCodexRelayError(msg)
    }
}
