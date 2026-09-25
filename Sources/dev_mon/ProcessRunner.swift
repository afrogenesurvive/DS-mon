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

    /// 不应传给子进程的环境变量：这些是 dev_mon 自己的凭据 / 共享密钥，
    /// 而 `node`、`brew`、`lsof`、`osascript`、`tailscale` 都不需要它们。
    private static let blockedEnvironmentKeys: Set<String> = [
        "DSMON_ENCRYPTION_KEY",
        "DSMON_ENCRYPTION_KEY_ID",
        "DSMON_PUSH_TOKEN",
        "DSMON_PUSH_URL",
    ]

    /// 形如 `*_API_KEY` / `*_TOKEN` / `*_SECRET` / `*_PASSWORD` 的继承变量同样剔除。
    /// 注意：`extra` 在剔除之后写入，所以显式传给某个子进程的变量不受影响。
    private static func looksLikeSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.hasSuffix("_API_KEY")
            || upper.hasSuffix("_TOKEN")
            || upper.hasSuffix("_SECRET")
            || upper.hasSuffix("_PASSWORD")
            || upper.hasSuffix("_SECRET_KEY")
    }

    /// 继承父进程环境，并把 `searchPaths` 前置到 PATH（保留原有尾部、去重）。
    /// `extra` 里的变量最后写入，用于给单个子进程附加专用变量（如 TAILSCALE_BE_CLI）。
    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // 子进程没有理由拿到本应用的密钥：先剔除，再应用显式 extra
        for key in env.keys where blockedEnvironmentKeys.contains(key) || looksLikeSecret(key) {
            env.removeValue(forKey: key)
        }
        let inherited = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = (searchPaths + inherited).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
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
    ///
    /// `stdin` 非空时写入子进程标准输入并**立即关闭写端** —— 这一步在等待退出之前完成，
    /// 否则“读到 EOF 才返回”的子命令（如 pkm 的 `--password-stdin`）会一直阻塞到超时。
    /// 只适合小载荷：内容超过管道缓冲区且子进程不读时，写入会阻塞且不受 `timeout` 约束。
    @discardableResult
    static func run(launchPath: String, args: [String], timeout: TimeInterval = 15,
                    extraEnvironment: [String: String] = [:],
                    stdin: String? = nil) -> (status: Int32, stdout: String, stderr: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = environment(extra: extraEnvironment)

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let input: Pipe? = stdin == nil ? nil : Pipe()
        if let input {
            // 子进程可能先退出（参数错误等），此时写入会收到 SIGPIPE 而直接终止本进程。
            // 只对这一个 fd 关掉该信号，不动全局 handler。
            fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            p.standardInput = input
        }

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

        // 写完并关闭写端必须发生在 sem.wait 之前：读到 EOF 才会返回的子命令否则会死锁。
        if let input, let payload = stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            try? input.fileHandleForWriting.close()
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
    static func runAsync(launchPath: String, args: [String], timeout: TimeInterval = 15,
                         extraEnvironment: [String: String] = [:],
                         stdin: String? = nil) async -> (status: Int32, stdout: String, stderr: String)
    {
        await Task.detached(priority: .userInitiated) {
            run(launchPath: launchPath, args: args, timeout: timeout,
                extraEnvironment: extraEnvironment, stdin: stdin)
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

    // MARK: - Tailscale

    /// Tailscale 的 macOS 应用可执行文件**同时充当 GUI 与 CLI**：它会检查
    /// `SHLVL` / `TERM` / `TERM_PROGRAM` / `PS1` 来决定这次调用是哪种模式。
    /// GUI 应用 fork 出来的子进程这些变量都不存在，于是它会**弹出 GUI 窗口
    /// 而不是执行命令**（命令静默丢失）。所有调用必须显式带上这个变量。
    static let tailscaleCLIEnvironment = ["TAILSCALE_BE_CLI": "1"]

    /// 解析 tailscale 二进制路径。
    /// CLI integration 装的是 `/usr/local/bin/tailscale`（一个转发到 app bundle 的 sh 包装脚本）；
    /// Standalone 变体即使没装 CLI integration，也能直接用 bundle 内的可执行文件。
    static func tailscalePath() -> String? {
        firstExecutable([
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/bin/tailscale",
        ], fallbackName: "tailscale")
    }

    /// 运行 tailscale CLI（自动注入 `TAILSCALE_BE_CLI=1`）。
    /// ⚠️ `tailscale serve|funnel <target>` 在 tailnet 未启用对应功能时会**无限阻塞**
    /// 等待浏览器授权（不会自己退出），所以调用方必须给出较小的 timeout ——
    /// `run` 会在超时后 terminate 子进程。
    @discardableResult
    static func runTailscale(_ args: [String], timeout: TimeInterval = 15)
        -> (status: Int32, stdout: String, stderr: String)
    {
        guard let bin = tailscalePath() else {
            return (127, "", "tailscale CLI not found")
        }
        return run(launchPath: bin, args: args, timeout: timeout,
                   extraEnvironment: tailscaleCLIEnvironment)
    }

    /// 以管理员权限运行 tailscale CLI（osascript 密码框），并保留 `TAILSCALE_BE_CLI=1`
    /// （`do shell script` 起的是全新环境，变量必须写进命令行里）。
    static func runTailscaleAdmin(_ args: [String], timeout: TimeInterval = 120)
        -> (ok: Bool, message: String)
    {
        guard let bin = tailscalePath() else { return (false, "tailscale CLI not found") }
        return runAdmin(command: shellCommand(executable: bin, args: args,
                                              env: tailscaleCLIEnvironment),
                        timeout: timeout)
    }

    /// 拼一条可安全交给 `do shell script` 执行的命令行：环境变量前缀 + 单引号包裹的每个实参。
    /// `runAdmin` 只会转义反斜杠和双引号，所以这里一律用单引号包住含空格/特殊字符的参数。
    static func shellCommand(executable: String, args: [String],
                             env: [String: String] = [:]) -> String {
        func quote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var parts: [String] = []
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(quote(value))")
        }
        parts.append(quote(executable))
        parts.append(contentsOf: args.map(quote))
        return parts.joined(separator: " ")
    }

    /// 以管理员权限运行命令（弹出 macOS 密码框）。
    /// 通过 osascript 的 `do shell script … with administrator privileges` 实现。
    static func runAdmin(command: String, timeout: TimeInterval = 120) -> (ok: Bool, message: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let r = run(launchPath: "/usr/bin/osascript", args: ["-e", script], timeout: timeout)
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 { return (true, msg) }
        return (false, msg.isEmpty ? "osascript exit \(r.status)" : msg)
    }
}
