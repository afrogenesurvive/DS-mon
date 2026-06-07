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

    /// 当前运行的 codex-relay 子进程（Responses API ↔ Chat Completions 协议转换）
    private var relayProcess: Process?
    private let relayPort: UInt16 = 4446

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置 Dock 图标
        if let url = Bundle.main.url(forResource: "dslogo1", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        StatusBarController.shared.stats = Self.sharedStats
        StatusBarController.shared.setup()
        restoreProxy()
        restoreRelay()
        // 监听崩溃通知，自动重启
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartRelay),
            name: .moonbridgeRestartNeeded, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyServer.shared.stop()
        stopRelay()
    }

    private func restoreProxy() {
        try? ProxyServer.shared.start()
    }

    // MARK: - codex-relay 管理

    /// codex-relay 二进制路径：始终指向 ~/.ds-mon/codex-relay
    private var relayBinaryPath: String {
        "\(NSHomeDirectory())/.ds-mon/codex-relay"
    }

    private var upstreamBaseURL: String {
        "https://api.deepseek.com/v1"
    }

    /// 从 Keychain 读取 API Key
    private var apiKey: String {
        DeepSeekStats.readAPIKeyFromKeychain()
    }

    /// 启动 codex-relay 子进程
    func startRelay() {
        guard UserDefaults.standard.bool(forKey: "moonbridge_enabled") else { return }
        guard relayProcess == nil || !relayProcess!.isRunning else { return }
        guard !apiKey.isEmpty else {
            let msg = "API Key 未设置，无法启动协议转换器"
            print("[Relay] \(msg)")
            UserDefaults.standard.set(false, forKey: "moonbridge_enabled")
            ProxyServer.shared.reportMoonBridgeError(msg)
            return
        }

        // 如果 .app 包内带了 codex-relay，尝试复制到 ~/.ds-mon/
        if let bundled = Bundle.main.path(forResource: "codex-relay", ofType: nil) {
            do {
                let dest = URL(fileURLWithPath: relayBinaryPath)
                let fm = FileManager.default
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: relayBinaryPath) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: URL(fileURLWithPath: bundled), to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relayBinaryPath)
                print("[Relay] 已从包内复制到 \(relayBinaryPath)")
            } catch {
                print("[Relay] 复制到 ~/.ds-mon/ 失败: \(error.localizedDescription)")
                if !FileManager.default.isExecutableFile(atPath: relayBinaryPath) {
                    let msg = "codex-relay 复制失败且旧文件不可用: \(error.localizedDescription)"
                    print("[Relay] \(msg)")
                    UserDefaults.standard.set(false, forKey: "moonbridge_enabled")
                    ProxyServer.shared.reportMoonBridgeError(msg)
                    return
                }
                print("[Relay] 使用已有文件: \(relayBinaryPath)")
            }
        }

        guard FileManager.default.isExecutableFile(atPath: relayBinaryPath) else {
            let msg = "codex-relay not found at \(relayBinaryPath)"
            print("[Relay] \(msg)")
            UserDefaults.standard.set(false, forKey: "moonbridge_enabled")
            ProxyServer.shared.reportMoonBridgeError(msg)
            return
        }

        // 杀掉可能残留的旧进程
        killExistingProcess(on: relayPort)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: relayBinaryPath)
        process.arguments = ["--port", "\(relayPort)", "--upstream", upstreamBaseURL]

        // 通过环境变量传递 API Key
        var env = ProcessInfo.processInfo.environment
        env["CODEX_RELAY_API_KEY"] = apiKey
        env["CODEX_RELAY_PORT"] = "\(relayPort)"
        env["CODEX_RELAY_UPSTREAM"] = upstreamBaseURL
        process.environment = env

        // 读取 stdout/stderr
        let outPipe = Pipe()
        process.standardOutput = outPipe
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print("[Relay] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try process.run()
            relayProcess = process
            print("[Relay] 已启动，PID: \(process.processIdentifier)")

            process.terminationHandler = { [weak self] proc in
                let reason = proc.terminationReason == .exit ? "exit code \(proc.terminationStatus)" : "uncaught signal"
                print("[Relay] 已停止 (\(reason))")
                Task { @MainActor [weak self] in
                    self?.relayProcess = nil
                }
            }

            ProxyServer.shared.reportMoonBridgeError(nil)
            ProxyServer.shared.checkMoonBridgeHealthWithRetry(retries: 6, interval: 0.5, port: relayPort)
        } catch {
            let msg = "codex-relay failed to launch: \(error.localizedDescription)"
            print("[Relay] \(msg)")
            UserDefaults.standard.set(false, forKey: "moonbridge_enabled")
            ProxyServer.shared.reportMoonBridgeError(msg)
        }
    }

    /// 杀掉占用目标端口的旧进程，避免端口冲突
    private func killExistingProcess(on port: UInt16) {
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
        for pid in pids.split(whereSeparator: \.isNewline) {
            let pidStr = pid.trimmingCharacters(in: .whitespaces)
            guard !pidStr.isEmpty, let pidInt = Int32(pidStr) else { continue }
            if pidInt == getpid() { continue }
            print("[Relay] 杀掉旧进程 PID=\(pidInt)")
            kill(pidInt, SIGTERM)
            usleep(300_000)
            kill(pidInt, SIGKILL)
        }
    }

    /// 停止 codex-relay 子进程
    func stopRelay() {
        guard let process = relayProcess, process.isRunning else { return }
        process.terminate()
        relayProcess = nil
        print("[Relay] 已停止")
        ProxyServer.shared.reportMoonBridgeError("codex-relay stopped")
    }

    /// 在设置面板中切换
    func toggleRelay(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "moonbridge_enabled")
        if enabled {
            startRelay()
        } else {
            stopRelay()
        }
    }

    private func restoreRelay() {
        if UserDefaults.standard.object(forKey: "moonbridge_enabled") == nil {
            UserDefaults.standard.set(true, forKey: "moonbridge_enabled")
        }
        guard UserDefaults.standard.bool(forKey: "moonbridge_enabled") else { return }
        startRelay()
    }

    /// 由 ProxyServer 定时健康检测触发 — 崩溃后自动重启
    @objc private func restartRelay() {
        guard UserDefaults.standard.bool(forKey: "moonbridge_enabled") else { return }
        guard relayProcess == nil || !relayProcess!.isRunning else { return }
        print("[Relay] 检测到进程未运行，自动重启...")
        // 启动前确保端口释放干净
        killExistingProcess(on: relayPort)
        usleep(500_000)  // 500ms 等端口释放
        startRelay()
    }
}

/// 全局访问（供设置面板调用）
@MainActor
func RelayAction(_ action: String) {
    let delegate = NSApplication.shared.delegate as? AppDelegate
    switch action {
    case "start":
        delegate?.startRelay()
    case "stop":
        delegate?.stopRelay()
    case "toggle":
        let enabled = UserDefaults.standard.bool(forKey: "moonbridge_enabled")
        delegate?.toggleRelay(enabled: enabled)
    default:
        break
    }
}
