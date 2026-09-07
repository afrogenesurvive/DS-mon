import Foundation

/// 轻量子进程封装：同步运行一个可执行文件并捕获 stdout/stderr。
/// dev_mon 之前不 shell out；Cloudflare 页用 cloudflared/launchctl/osascript 需要它。
enum ProcessRunner {
    private final class Sink: @unchecked Sendable {
        var data = Data()
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

    /// 在 PATH 里查找可执行文件（如 cloudflared）。
    static func which(_ name: String) -> String? {
        let r = run(launchPath: "/usr/bin/which", args: [name], timeout: 5)
        guard r.status == 0 else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// 解析 cloudflared 二进制路径（已知 Homebrew/usr/local 路径优先，再走 which）。
    static func cloudflaredPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/opt/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return which("cloudflared")
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
