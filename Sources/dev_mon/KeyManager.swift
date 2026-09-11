import Foundation

/// 通过 personal_key_manager 的 `pkm` CLI 执行密钥管理操作。
///
/// dev_mon **从不持有 master 私钥**：
/// - 读取：直接解析密钥管理器导出的 `export/devmon.json`（见 `SeatRegistry`）
/// - 写入（签发 / 吊销）：以子进程方式调用 `pkm`，私钥始终留在仓库内
///
/// 工具或 Node 不存在时（普通用户机器）整体降级为只读 —— `isWritable()` 返回 false。
enum KeyManager {

    // MARK: - 类型

    enum KeyManagerError: LocalizedError, Sendable {
        case toolMissing(String)
        case nodeMissing
        case commandFailed(String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .toolMissing(let path): return Strings.licenseToolMissing(path)
            case .nodeMissing: return Strings.licenseNodeMissing
            case .commandFailed(let msg): return msg
            case .decodeFailed(let msg): return msg
            }
        }
    }

    struct CommandResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    struct IssuedKey: Sendable, Identifiable {
        let registry: String
        let sub: String
        let kid: String
        let exp: Int
        let issuedAt: String?
        let licenseKey: String

        var id: String { "\(registry)|\(sub)" }
    }

    struct RevokeOutcome: Sendable {
        let registry: String
        let sub: String
        let blocklistSize: Int
        let alreadyRevoked: Bool
        let archived: [String]
    }

    // MARK: - 路径解析

    /// 密钥管理器仓库路径的 UserDefaults key（可在 设置 → 许可 中覆盖）
    static let toolPathKey = "license_tool_path"

    /// 密钥管理器仓库根目录。
    static var toolRoot: String {
        let stored = (UserDefaults.standard.string(forKey: toolPathKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let raw = stored.isEmpty ? SeatRegistry.defaultToolRoot : stored
        return (raw as NSString).expandingTildeInPath
    }

    static var scriptPath: String { "\(toolRoot)/bin/pkm.mjs" }

    /// 导出文件路径 —— 与 `SeatRegistry.defaultLicensesSourceURL` 保持一致。
    static var exportPath: String { "\(toolRoot)/export/devmon.json" }

    static func toolExists() -> Bool {
        FileManager.default.fileExists(atPath: scriptPath)
    }

    // MARK: - Node 解析

    /// 查找 `node`。
    ///
    /// ⚠️ `ProcessRunner.searchPaths` 只有 Homebrew / 系统目录，**不含 nvm**，
    /// 而本机的 Node 由 nvm 管理（`~/.nvm/versions/node/*/bin/node`）——
    /// 从 Finder 启动的 app 必须显式枚举 nvm 目录，否则永远找不到 node。
    ///
    /// 故意不做缓存：命中候选路径时只是几次 stat，省掉一个跨线程可变全局状态。
    static func nodePath() -> String? {
        var candidates: [String] = []
        let nvmRoot = "\(NSHomeDirectory())/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: isVersionNewer) {
                candidates.append("\(nvmRoot)/\(version)/bin/node")
            }
        }
        candidates += [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/homebrew/opt/node/bin/node",
            "/usr/bin/node",
        ]

        return ProcessRunner.firstExecutable(candidates, fallbackName: "node")
    }

    /// 版本号比较：`v20.11.0` 比 `v18.12.1` 新。
    private static func isVersionNewer(_ a: String, _ b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop { $0 == "v" || $0 == "V" }
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return a > b
    }

    /// 可以执行写操作吗？（工具脚本 + node 都在）
    static func isWritable() -> Bool {
        toolExists() && nodePath() != nil
    }

    /// 供 UI 展示的不可写原因；可写时返回 nil。
    static func unavailableReason() -> String? {
        if !toolExists() { return Strings.licenseToolMissing(scriptPath) }
        if nodePath() == nil { return Strings.licenseNodeMissing }
        return nil
    }

    // MARK: - 执行

    static func run(_ args: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        guard toolExists() else { throw KeyManagerError.toolMissing(scriptPath) }
        guard let node = nodePath() else { throw KeyManagerError.nodeMissing }

        let script = scriptPath
        let raw = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(launchPath: node, args: [script] + args, timeout: timeout)
        }.value

        return CommandResult(status: raw.status, stdout: raw.stdout, stderr: raw.stderr)
    }

    /// 把命令失败信息整理成一行可读文本（优先 stderr 的最后一条 error:）。
    private static func failureMessage(_ result: CommandResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stderr.isEmpty ? stdout : stderr
        if text.isEmpty { return "pkm 退出码 \(result.status)" }
        // 只保留最后一个 error: 行，避免把整个 stack 塞进 UI。
        let lines = text.split(separator: "\n").map(String.init)
        if let last = lines.last(where: { $0.hasPrefix("error:") }) {
            return last.replacingOccurrences(of: "error: ", with: "")
        }
        return lines.suffix(3).joined(separator: " ")
    }

    // MARK: - 具体操作

    private struct IssuePayload: Decodable {
        let registry: String
        let sub: String
        let kid: String
        let exp: Int
        let issuedAt: String?
        let licenseKey: String
    }

    private struct RevokePayload: Decodable {
        let registry: String
        let sub: String
        let alreadyRevoked: Bool
        let blocklistSize: Int
        let archived: [String]?
    }

    /// 签发一个席位密钥（`--json` 输出被解析为 `IssuedKey`）。
    static func issue(registry: String, sub: String, exp: String, kid: String?) async throws -> IssuedKey {
        var args = ["issue", registry, sub, "--exp", exp, "--json"]
        if let kid, !kid.isEmpty { args += ["--kid", kid] }

        let result = try await run(args)
        guard result.ok else { throw KeyManagerError.commandFailed(failureMessage(result)) }

        guard let payload = try? JSONDecoder().decode(IssuePayload.self, from: Data(result.stdout.utf8)) else {
            throw KeyManagerError.decodeFailed(Strings.licenseIssueDecodeFailed)
        }
        return IssuedKey(registry: payload.registry, sub: payload.sub, kid: payload.kid,
                         exp: payload.exp, issuedAt: payload.issuedAt, licenseKey: payload.licenseKey)
    }

    /// 吊销一个席位。
    static func revoke(registry: String, sub: String, reason: String?) async throws -> RevokeOutcome {
        var args = ["revoke", registry, sub, "--json"]
        if let reason, !reason.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--reason", reason]
        }

        let result = try await run(args)
        guard result.ok else { throw KeyManagerError.commandFailed(failureMessage(result)) }

        guard let payload = try? JSONDecoder().decode(RevokePayload.self, from: Data(result.stdout.utf8)) else {
            throw KeyManagerError.decodeFailed(Strings.licenseRevokeDecodeFailed)
        }
        return RevokeOutcome(registry: payload.registry, sub: payload.sub,
                             blocklistSize: payload.blocklistSize,
                             alreadyRevoked: payload.alreadyRevoked,
                             archived: payload.archived ?? [])
    }

    /// 重新导出（工具通常已在改动后自动导出，这里用于手动兜底）。
    static func exportAll() async throws {
        let result = try await run(["export", "--json"], timeout: 60)
        guard result.ok else { throw KeyManagerError.commandFailed(failureMessage(result)) }
    }

    /// 校验一个密钥字符串（只读，不写入任何东西）。
    static func validate(registry: String, licenseKey: String) async throws -> String {
        let result = try await run(["validate", registry, licenseKey, "--json"], timeout: 20)
        guard result.ok else { throw KeyManagerError.commandFailed(failureMessage(result)) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 写操作完成后重新导入导出文件，让 UI 立刻反映变化。
    @discardableResult
    static func reloadFromExport() -> SeatRegistry.CheckResult {
        SeatRegistry.shared.checkLicenses()
    }
}
