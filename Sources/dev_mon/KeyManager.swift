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
        /// 本机密钥库里没有该席位的 `<sub>.key`（席位可能来自另一台机器的镜像包）。
        case seatKeyMissing(String)
        /// 密钥文件存在但读不出来（权限 / 编码）。
        case seatKeyUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .toolMissing(let path): return Strings.licenseToolMissing(path)
            case .nodeMissing: return Strings.licenseNodeMissing
            case .commandFailed(let msg): return msg
            case .decodeFailed(let msg): return msg
            case .seatKeyMissing(let sub): return Strings.licenseRevealKeyMissing(sub)
            case .seatKeyUnreadable(let path): return Strings.licenseRevealKeyUnreadable(path)
            }
        }
    }

    struct CommandResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// pkm 的席位声明（claims）摘要：邮箱 + 是否设置了密码。
    /// 密码只以布尔值表态 —— 校验器（pwdv）永不出库，也不需要出库。
    struct Claims: Sendable, Decodable {
        let email: String?
        let hasPassword: Bool?
    }

    /// pkm 对密码长度的下限（`src/creds.mjs` 的 `PASSWORD_MIN_LENGTH`）。
    /// 本地先拦一道，省掉一次注定失败的子进程往返。
    static let passwordMinLength = 8

    struct IssuedKey: Sendable, Identifiable {
        let registry: String
        let sub: String
        let kid: String
        let exp: Int
        let issuedAt: String?
        let licenseKey: String
        /// 本次签发实际写入的声明；未提供邮箱与密码时为 nil。
        let claims: Claims?

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

    // MARK: - 席位密钥文件（揭示 / 复制）

    /// pkm 存储的注册表索引（`registries/registry.json`）。
    ///
    /// 导出包里只有 `id`，磁盘目录却是 `dir` —— `pkm registry create` 在目录名冲突时
    /// 会追加 `-2` 后缀（见 pkm `src/registry.mjs` → `createRegistry`），两者因此可能不同。
    private struct RegistryIndexFile: Decodable {
        struct Entry: Decodable {
            let id: String
            let dir: String?
        }
        let registries: [Entry]
    }

    /// pkm 存储的注册表根目录（`<toolRoot>/registries`）。
    static var registriesRoot: String { "\(toolRoot)/registries" }

    /// 注册表 id 对应的磁盘目录名。先读索引文件（权威），读不到再退回 `dir == id`。
    static func registryDirectory(id: String) -> String? {
        let wanted = id.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let indexURL = URL(fileURLWithPath: ("\(registriesRoot)/registry.json" as NSString).expandingTildeInPath)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(RegistryIndexFile.self, from: data),
           let entry = index.registries.first(where: { $0.id.lowercased() == wanted.lowercased() }) {
            let dir = (entry.dir ?? "").trimmingCharacters(in: .whitespaces)
            return dir.isEmpty ? wanted : dir
        }
        return wanted
    }

    /// 归档目录顺序与 pkm 的 `KINDS` 一致（`src/ledger.mjs`）：现行 → 已吊销 → 已过期。
    /// 已吊销 / 已过期的密钥文件被归档但**从不删除**，所以三处都要找。
    private static let seatKeyKinds = ["issued", "revoked", "expired"]

    /// 一个已定位的席位密钥文件。
    struct SeatKeyFile: Sendable {
        let url: URL
        let registryId: String
        let kid: String
        let sub: String
        /// 去掉 pkm 写入的结尾换行后的 TA1 许可串。
        let licenseKey: String
    }

    /// 定位席位密钥文件（`<sub>.key`）。只读本机文件，不调用 node / pkm。
    ///
    /// 找不到时返回 nil —— 席位可能来自另一台机器的镜像包，本机根本没有它的 `.key`。
    static func seatKeyFileURL(registryId: String, kid: String, sub: String) -> URL? {
        let seat = sub.trimmingCharacters(in: .whitespaces)
        let ring = kid.trimmingCharacters(in: .whitespaces)
        // 孤儿行（kid 不在 ring.json 里）在 UI 上是 `(unknown ring)`，没有对应目录。
        guard !seat.isEmpty, !ring.isEmpty, ring != "(unknown ring)",
              let dir = registryDirectory(id: registryId) else { return nil }

        let root = URL(fileURLWithPath: (registriesRoot as NSString).expandingTildeInPath)
            .standardizedFileURL
        let base = root.appendingPathComponent(dir).appendingPathComponent(ring)

        for kind in seatKeyKinds {
            let candidate = base
                .appendingPathComponent(kind)
                .appendingPathComponent("\(seat).key")
                .standardizedFileURL
            // `sub` 是逐字拼进文件名的，而导出包虽经签名却仍在本机用户手里 ——
            // 因此解析结果必须留在存储目录内，防止 `../` 逃逸。
            guard candidate.path.hasPrefix(root.path + "/") else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 读取一个席位的密钥文件（揭示 / 复制用）。
    static func readSeatKey(registryId: String, kid: String, sub: String) throws -> SeatKeyFile {
        guard let url = seatKeyFileURL(registryId: registryId, kid: kid, sub: sub) else {
            throw KeyManagerError.seatKeyMissing(sub)
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw KeyManagerError.seatKeyUnreadable(url.path)
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw KeyManagerError.seatKeyUnreadable(url.path) }
        return SeatKeyFile(url: url, registryId: registryId, kid: kid, sub: sub, licenseKey: key)
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

    /// 执行 pkm。`stdin` 非空时写入子进程标准输入并立即关闭写端 —— pkm 的
    /// `--password-stdin` 会一直读到 EOF，不关闭写端会让它阻塞到超时。
    static func run(_ args: [String], timeout: TimeInterval = 30,
                    stdin: String? = nil) async throws -> CommandResult {
        guard toolExists() else { throw KeyManagerError.toolMissing(scriptPath) }
        guard let node = nodePath() else { throw KeyManagerError.nodeMissing }

        let script = scriptPath
        let raw = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(launchPath: node, args: [script] + args, timeout: timeout, stdin: stdin)
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
        let claims: Claims?
    }

    private struct RevokePayload: Decodable {
        let registry: String
        let sub: String
        let alreadyRevoked: Bool
        let blocklistSize: Int
        let archived: [String]?
    }

    /// 签发一个席位密钥（`--json` 输出被解析为 `IssuedKey`）。
    ///
    /// `email` / `password` 是可选声明：两者都为空时签发的是一个没有声明的席位，这本身是
    /// 合法状态。密码走 `--password-stdin` —— argv 对同机任何进程的 `ps` 都可见。
    static func issue(registry: String, sub: String, exp: String, kid: String?,
                      email: String?, password: String?) async throws -> IssuedKey {
        var args = ["issue", registry, sub, "--exp", exp, "--json"]
        if let kid, !kid.isEmpty { args += ["--kid", kid] }
        if let email, !email.isEmpty { args += ["--email", email] }
        // 空密码绝不能当成“要设密码”：pkm 会明确拒绝空值，而“没有密码”是合法状态。
        if password != nil { args += ["--password-stdin"] }

        let result = try await run(args, stdin: password.map { $0 + "\n" })
        guard result.ok else { throw KeyManagerError.commandFailed(failureMessage(result)) }

        guard let payload = try? JSONDecoder().decode(IssuePayload.self, from: Data(result.stdout.utf8)) else {
            throw KeyManagerError.decodeFailed(Strings.licenseIssueDecodeFailed)
        }
        return IssuedKey(registry: payload.registry, sub: payload.sub, kid: payload.kid,
                         exp: payload.exp, issuedAt: payload.issuedAt, licenseKey: payload.licenseKey,
                         claims: payload.claims)
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
