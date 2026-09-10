import Foundation

/// 本地端口 / 进程探测。
///
/// 本地数据库（`LocalDBManager`）与仓库数据存储（`RepoDataStoreManager`）共用：
/// 端口监听优先（`lsof`），其次 unix socket；uptime 走 `ps -p <pid> -o etime=`。
///
/// 所有函数都是 `nonisolated static`，可在 `Task.detached` 里从后台线程调用。
enum PortProbe {
    /// 单次探测超时（秒）
    private nonisolated static let timeout: TimeInterval = 5

    struct Result: Sendable {
        var running = false
        var pid: Int?
    }

    /// 端口监听优先，其次 unix socket 是否存在。
    nonisolated static func probe(port: Int, sockets: [String] = []) -> Result {
        let lsof = ProcessRunner.run(launchPath: "/usr/sbin/lsof",
                                     args: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
                                     timeout: timeout)
        if lsof.status == 0 {
            if let line = lsof.stdout.split(separator: "\n").first,
               let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                return Result(running: true, pid: pid)
            }
        }
        let anySocket = sockets.contains { FileManager.default.fileExists(atPath: $0) }
        return Result(running: anySocket, pid: nil)
    }

    /// 进程运行时长（秒）；进程不存在返回 nil。
    nonisolated static func uptime(pid: Int) -> Int? {
        let ps = ProcessRunner.run(launchPath: "/bin/ps", args: ["-p", "\(pid)", "-o", "etime="],
                                   timeout: timeout)
        guard ps.status == 0 else { return nil }
        let text = ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return parseEtime(text)
    }

    /// pid 文件 → pid。文件缺失/损坏返回 nil（进程是否存活交给 `uptime` 判断）。
    nonisolated static func pid(fromFile path: String) -> Int? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 解析 ps etime：`[[dd-]hh:]mm:ss`。
    nonisolated static func parseEtime(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        var days = 0
        var rest = s
        if let dash = s.firstIndex(of: "-"), let d = Int(s[..<dash]) {
            days = d
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        switch parts.count {
        case 1: seconds = parts[0]
        case 2: seconds = parts[0] * 60 + parts[1]
        default: seconds = parts[parts.count - 3] * 3600 + parts[parts.count - 2] * 60 + parts[parts.count - 1]
        }
        return days * 86400 + seconds
    }
}
