import Foundation

/// 本地客户端 → 仓库名解析（仅用于把「本机/local」来源进一步标注为「local - <仓库名>」）。
///
/// 原理：dev_mon 代理的每一条本地 TCP 连接都带一个客户端临时端口（peer port）。
/// 每隔很短的时间用 `lsof` 抓一次「→ 代理端口」的 ESTABLISHED 连接快照，
/// 得到 临时端口 → 客户端进程 pid；再对 pid 取 cwd（`lsof -d cwd`），
/// 向上寻找最近的 `.git` 目录，取其目录名作为仓库名。结果缓存一小段时间，
/// 避免每个请求都跑 lsof。
///
/// GUI 程序（如 VS Code 的扩展宿主）的 cwd 不一定等于工作区，此时解析不到 → 仍显示 "local"。
final class LocalRepoDetector: @unchecked Sendable {
    static let shared = LocalRepoDetector()

    private let lock = NSLock()
    private var byPort: [UInt16: String] = [:]
    private var lastSnapshot = Date.distantPast
    private let snapshotTTL: TimeInterval = 1.0

    /// 每个端口强制补拍的最小间隔；找不到时避免每请求都跑 lsof。
    private var lastAttempt: [UInt16: Date] = [:]
    private let attemptCooldown: TimeInterval = 5.0
    private var lastForcedSnapshot = Date.distantPast
    private let forceCooldown: TimeInterval = 0.2

    private let lsofPath = "/usr/sbin/lsof"

    private init() {
        // fallback（macOS 通常有 /usr/sbin/lsof；旧系统可能只有 /usr/bin）
    }

    /// 返回 peer 临时端口对应的仓库名；解析不到返回 nil（显示为普通 "local"）。
    func repoName(forPeerPort port: UInt16, proxyPort: UInt16) -> String? {
        refreshIfNeeded(proxyPort: proxyPort)
        if let name = lookup(port) { return name }

        // 快照里还没有这个端口：强制补拍一次，捕捉刚建立（或刚好错过 1s 快照）的连接。
        // 限流避免对「永远解析不出仓库」的进程（cwd 不是仓库）反复跑 lsof。
        lock.lock()
        let last = lastAttempt[port] ?? .distantPast
        lastAttempt[port] = Date()
        let portHeld = Date().timeIntervalSince(last) < attemptCooldown
        let globalHeld = Date().timeIntervalSince(lastForcedSnapshot) < forceCooldown
        lock.unlock()
        guard !portHeld, !globalHeld else { return nil }

        lock.lock()
        lastForcedSnapshot = Date()
        lock.unlock()
        forceSnapshot(proxyPort: proxyPort)
        return lookup(port)
    }

    private func lookup(_ port: UInt16) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return byPort[port]
    }

    private func refreshIfNeeded(proxyPort: UInt16) {
        lock.lock()
        let stale = Date().timeIntervalSince(lastSnapshot) > snapshotTTL
        lock.unlock()
        guard stale else { return }
        forceSnapshot(proxyPort: proxyPort)
    }

    private func forceSnapshot(proxyPort: UInt16) {
        let snapshot = Self.buildSnapshot(lsofPath: lsofPath, proxyPort: proxyPort)
        lock.lock()
        byPort = snapshot
        lastSnapshot = Date()
        lock.unlock()
    }

    /// 抓取快照：clientLocalPort → repoName。
    private static func buildSnapshot(lsofPath: String, proxyPort: UInt16) -> [UInt16: String] {
        let r = ProcessRunner.run(launchPath: lsofPath,
                                  args: ["-nP", "-iTCP:\(proxyPort)", "-sTCP:ESTABLISHED"],
                                  timeout: 5)
        guard r.status == 0 else { return [:] }

        var portToPid: [UInt16: UInt32] = [:]
        for rawLine in r.stdout.split(separator: "\n") {
            let parts = rawLine.split(separator: " ").map(String.init)
            guard parts.count >= 2, let pid = UInt32(parts[1]) else { continue }
            // lsof NAME 形如 "TCP 127.0.0.1:59677->127.0.0.1:18080 (ESTABLISHED)"，
            // 其中 TCP 前缀与 "(ESTABLISHED)" 是独立 token；直接找含 "->" 的地址 token 最稳
            // （NODE 列有时为空，固定列下标并不可靠）。
            guard let pair = parts.first(where: { $0.contains("->") }),
                  let arrow = pair.range(of: "->") else { continue }
            let local = String(pair[..<arrow.lowerBound])
            let remote = String(pair[arrow.upperBound...])
            guard let remotePort = Self.port(of: remote), remotePort == proxyPort else { continue }
            guard let localPort = Self.port(of: local), localPort != proxyPort else { continue }
            portToPid[localPort] = pid
        }

        var pidToRepo: [UInt32: String] = [:]
        var result: [UInt16: String] = [:]
        for (port, pid) in portToPid {
            if let repo = pidToRepo[pid] {
                result[port] = repo
                continue
            }
            if let repo = Self.repoName(lsofPath: lsofPath, forPid: pid) {
                pidToRepo[pid] = repo
                result[port] = repo
            }
        }
        return result
    }

    /// 解析进程 cwd，向上找最近的 .git 目录；返回目录名（仓库名）。
    private static func repoName(lsofPath: String, forPid pid: UInt32) -> String? {
        let r = ProcessRunner.run(launchPath: lsofPath,
                                  args: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"],
                                  timeout: 5)
        guard r.status == 0 else { return nil }
        var cwd: String?
        for line in r.stdout.split(separator: "\n") where line.hasPrefix("n") {
            cwd = String(line.dropFirst())
            break
        }
        guard var dirURL = cwd.map({ URL(fileURLWithPath: $0) }) else { return nil }
        // 从 cwd 向上找最近的 .git（仓库可能在 $HOME 之外，故走到文件系统根为止）。
        while dirURL.path != "/" {
            if FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(".git").path) {
                let name = dirURL.lastPathComponent
                return name.isEmpty ? nil : name
            }
            dirURL.deleteLastPathComponent()
        }
        return nil
    }

    /// 从 "127.0.0.1:53214" / "[::1]:53214" 中取端口号。
    private static func port(of endpoint: String) -> UInt16? {
        guard let idx = endpoint.lastIndex(of: ":") else { return nil }
        return UInt16(endpoint[endpoint.index(after: idx)...])
    }
}
