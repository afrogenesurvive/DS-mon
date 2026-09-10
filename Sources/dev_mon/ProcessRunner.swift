import Foundation

/// 轻量子进程封装：同步运行一个可执行文件并捕获 stdout/stderr。
/// dev_mon 之前不 shell out；Cloudflare 页用 cloudflared/launchctl/osascript 需要它。
enum ProcessRunner {
    private final class Sink: @unchecked Sendable {
        var data = Data()
    }

    /// 可执行文件搜索路径。GUI 应用从 Finder 启动时 PATH 只有
    /// `/usr/bin:/bin:/usr/sbin:/sbin`，Homebrew 不在其中 —— 于是
    /// `which brew` / `which mongosh` 全部失败（即使终端里能用）。
    static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// 继承父进程环境，并把 `searchPaths` 前置到 PATH（保留原有尾部、去重）。
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = (searchPaths + inherited).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// 按候选绝对路径依次查找可执行文件，找不到再回退到 `which`。
    /// （已知路径优先，避免依赖容易缺失的 PATH。）
    static func firstExecutable(_ candidates: [String], fallbackName: String? = nil) -> String? {
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        if let name = fallbackName, let found = which(name) { return found }
        return nil
    }

    /// 同步运行 `launchPath`，最多等 `timeout` 秒（超时会 terminate）。
    /// 返回终止码 + stdout/stderr 文本。stdout/stderr 并行读取，避免管道缓冲死锁。
    @discardableResult
    static func run(launchPath: String, args: [String], timeout: TimeInterval = 15)
        -> (status: Int32, stdout: String, stderr: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = environment()

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let outSink = Sink()
        let errSink = Sink()
        let lock = NSLock()

        func attach(_ pipe: Pipe, sink: Sink) {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else {
                    h.readabilityHandler = nil
                    return
                }
                lock.lock(); sink.data.append(chunk); lock.unlock()
            }
        }
        attach(out, sink: outSink)
        attach(err, sink: errSink)

        do {
            try p.run()
        } catch {
            return (2, "", "failed to launch \(launchPath): \(error.localizedDescription)")
        }

        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        // 追加可能残留的数据（readabilityHandler 未必消费干净）。
        if let tail = try? out.fileHandleForReading.readToEnd() {
            lock.lock(); outSink.data.append(tail); lock.unlock()
        }
        if let tail = try? err.fileHandleForReading.readToEnd() {
            lock.lock(); errSink.data.append(tail); lock.unlock()
        }

        return (p.terminationStatus,
                String(decoding: outSink.data, as: UTF8.self),
                String(decoding: errSink.data, as: UTF8.self))
    }

    /// 异步运行（切到后台线程），避免阻塞主线程；常用于 brew services 等耗时命令。
    static func runAsync(launchPath: String, args: [String], timeout: TimeInterval = 15) async
        -> (status: Int32, stdout: String, stderr: String)
    {
        await Task.detached(priority: .userInitiated) {
            run(launchPath: launchPath, args: args, timeout: timeout)
        }.value
    }

    /// 在 PATH 里查找可执行文件（如 cloudflared）。
    static func which(_ name: String) -> String? {
        let r = run(launchPath: "/usr/bin/which", args: [name], timeout: 5)
        guard r.status == 0 else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// 解析 cloudflared 二进制路径（已知 Homebrew/usr/local 路径优先，再走 which）。
    static func cloudflaredPath() -> String? {
        firstExecutable([
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/opt/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ], fallbackName: "cloudflared")
    }

    /// 以管理员权限运行命令（弹出 macOS 密码框）。
    /// 通过 osascript 的 `do shell script … with administrator privileges` 实现。
    static func runAdmin(command: String) -> (ok: Bool, message: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let r = run(launchPath: "/usr/bin/osascript", args: ["-e", script], timeout: 120)
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 { return (true, msg) }
        return (false, msg.isEmpty ? "osascript exit \(r.status)" : msg)
    }
}
