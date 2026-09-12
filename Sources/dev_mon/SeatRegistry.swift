import CryptoKit
import Foundation

/// 席位状态查询结果（DS-mon 作为 Hybrid 授权权威回答的答案）。
struct SeatStatus: Sendable {
    let revoked: Bool
    let exp: Int
    /// 该席位所属注册表；多注册表后新增，旧调用方可忽略。
    let registryId: String?
}

/// 旧版/兼容格式的单个席位记录（kid/exp/revoked/issuedAt 均可空）。
struct AgentSeat: Codable, Sendable {
    let sub: String
    let kid: String?
    let exp: Int?
    let revoked: Bool?
    let issuedAt: String?
}

/// 旧版导出文件的顶层结构：`{ seats: [...], updatedAt }`
struct AgentSeatsFile: Codable, Sendable {
    let seats: [AgentSeat]
    let updatedAt: String?
}

/// 固定的导出包签名公钥（Ed25519，base64url）。只含公钥 —— 放进公开仓库是安全的。
struct AuthorityKey: Sendable {
    let kid: String
    let publicKey: String
    /// 退役时间（Unix 秒）；到点后该公钥签出的包必须被拒绝。
    let notAfter: Int?
}

/// `export/devmon.json.sig` 的校验结论。
enum BundleSignatureVerdict: Sendable, Equatable {
    /// 尚未检查过。
    case unknown
    /// 签名有效，由 `kid` 对应的公钥签出。
    case valid(kid: String)
    /// 没有签名文件 —— 数据可用但无法验证（旧版 seats.json 就是这种）。
    case absent
    /// 有签名但不匹配 —— 数据被改过，必须拒绝导入。
    case invalid(String)

    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

/// 席位注册表：DS-mon 作为 Hybrid 授权权威，按 sub 回答“该席位是否已被吊销”。
///
/// 数据来源是 personal_key_manager 导出的 `export/devmon.json`
/// （registries ▸ rings ▸ seats），由密钥管理器在每次改动后自动重写。
///
/// 持久化：
/// - 内嵌结构：UserDefaults `seat_registry_v2`（RegistryBundle，JSON）
/// - 可选镜像文件路径（`seat_registry_file`）：JSON，仅用于把席位表带到另一台机器
/// - 检查来源（`license_check_source`）：默认指向密钥管理器的导出文件
///
/// 注意：吊销/过期仅按 sub（与 exp）判定；但**导入前会校验 `devmon.json.sig`**。
/// 校验失败的数据一律不导入 —— 详见 `verifyBundleSignature`。
final class SeatRegistry: @unchecked Sendable {
    static let shared = SeatRegistry()

    private let lock = NSLock()
    private var _bundle = RegistryBundle(bundleVersion: 1, generatedAt: nil, totals: nil, registries: [])
    private var _filePath: String = ""
    private var _lastUpdatedAt: String?
    private var _lastSource: String?
    private var _lastError: String?
    private var _lastSignature: BundleSignatureVerdict = .unknown
    /// 检查来源列表（有序，已展开 `~`）；每个来源最近一次导入的快照见 `_snapshots`。
    private var _checkSources: [String] = []
    private var _snapshots: [SourceSnapshot] = []

    /// 新版存储键（RegistryBundle）。
    static let storageKey = "seat_registry_v2"
    /// 旧版存储键（扁平 [SeatRecord]）—— 仅用于一次性迁移。
    static let legacyStorageKey = "seat_registry"
    static let filePathKey = "seat_registry_file"

    private init() {
        loadFromDefaults()
        _checkSources = Self.storedCheckSources()
        _snapshots = Self.storedSnapshots()
        // 有来源快照时以合并结果为准（与持久化的 bundle 等价，但保证跨来源去重规则一致）。
        if !_snapshots.isEmpty { _bundle = Self.mergeSnapshots(_snapshots) }
        _filePath = UserDefaults.standard.string(forKey: Self.filePathKey) ?? ""
        if !_filePath.isEmpty { reloadFileLocked() }
    }

    // MARK: - 读取

    /// 全部注册表（含 ring 与席位），按 id 排序。
    var registries: [LicenseRegistry] {
        lock.withLock { _bundle.registries.sorted { $0.id < $1.id } }
    }

    /// 展开后的全部席位（跨注册表），按 sub 排序。
    var seats: [SeatRecord] {
        lock.withLock { _bundle.registries.flatMap(\.allSeats).sorted { $0.sub < $1.sub } }
    }

    var totalCount: Int {
        lock.withLock { _bundle.registries.reduce(0) { $0 + $1.allSeats.count } }
    }

    var registryCount: Int { lock.withLock { _bundle.registries.count } }

    /// 最近一次成功导入的来源文件写入时间（generatedAt / updatedAt）。
    var lastUpdatedAt: String? { lock.withLock { _lastUpdatedAt } }

    /// 最近一次导入的来源路径。
    var lastSource: String? { lock.withLock { _lastSource } }

    /// 最近一次导入失败的原因。
    var lastError: String? { lock.withLock { _lastError } }

    var registryFilePath: String { lock.withLock { _filePath } }

    /// 查询席位状态；sub 未登记返回 nil（调用方按未吊销处理）。
    func status(for sub: String) -> SeatStatus? {
        lock.withLock {
            for registry in _bundle.registries {
                if let seat = registry.allSeats.first(where: { $0.sub == sub }) {
                    return SeatStatus(revoked: seat.revoked, exp: seat.exp, registryId: registry.id)
                }
            }
            return nil
        }
    }

    /// 完整席位记录（含签发日期与所属注册表）；未登记返回 nil。
    func seat(for sub: String) -> SeatRecord? {
        lock.withLock {
            for registry in _bundle.registries {
                if let seat = registry.allSeats.first(where: { $0.sub == sub }) {
                    var copy = seat
                    copy.registryId = registry.id
                    copy.registryName = registry.name
                    return copy
                }
            }
            return nil
        }
    }

    // MARK: - 注册表镜像文件（可选）

    func setFilePath(_ path: String) {
        lock.withLock {
            _filePath = path.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(_filePath, forKey: Self.filePathKey)
            if _filePath.isEmpty {
                persistLocked()
                return
            }
            reloadFileLocked()
        }
    }

    /// 镜像路径是否安全可写 —— 绝不覆盖密钥管理器的导出目录。
    private func mirrorPathIsSafeLocked() -> Bool {
        guard !_filePath.isEmpty else { return false }
        let url = URL(fileURLWithPath: (_filePath as NSString).expandingTildeInPath).standardizedFileURL
        let toolRoot = URL(fileURLWithPath: (Self.defaultToolRoot as NSString).expandingTildeInPath)
            .standardizedFileURL
        return url.path != toolRoot.path && !url.path.hasPrefix(toolRoot.path + "/")
    }

    /// 传入路径的镜像安全性；不安全时返回原因（UI 提示用）。
    /// 密钥管理器仓库（含 export/）永远不能被当成镜像写入。
    func mirrorPathProblem(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        let toolRoot = URL(fileURLWithPath: (Self.defaultToolRoot as NSString).expandingTildeInPath)
            .standardizedFileURL
        let unsafe = url.path == toolRoot.path || url.path.hasPrefix(toolRoot.path + "/")
        return unsafe ? Strings.licenseMirrorUnsafe : nil
    }

    private func reloadFileLocked() {
        guard mirrorPathIsSafeLocked() else { return }
        let url = URL(fileURLWithPath: (_filePath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let decoded = RegistryBundleDecoder.decode(data) else { return }
        // 镜像与来源列表用同一套合并规则（按注册表 id 去重），而不是整份替换 ——
        // 否则读一次旧镜像就会把来源里的注册表全部盖掉。
        let verdict = Self.verifyBundleSignature(bundleData: data, sourceURL: url)
        let mirror = SourceSnapshot(path: url.path,
                                    isBundle: decoded.isBundle,
                                    updatedAt: decoded.updatedAt,
                                    importedAt: nil,
                                    registries: Self.relabelRegistries(decoded.bundle.registries,
                                                                      path: url.path,
                                                                      isBundle: decoded.isBundle),
                                    signatureCode: SourceSnapshot.code(of: verdict),
                                    signatureDetail: SourceSnapshot.detail(of: verdict),
                                    error: nil)
        _bundle = Self.mergeSnapshots(_snapshots + [mirror])
        _lastUpdatedAt = decoded.updatedAt
        _lastSource = url.path
        persistLocked()
    }

    // MARK: - 从密钥管理器导出导入

    /// 许可检查来源 UserDefaults key（单值，保留给旧版本 / 旧配置导出读取）
    static let checkSourceKey = "license_check_source"

    /// 许可检查来源列表 UserDefaults key（有序数组，已展开 `~`）。
    ///
    /// 一个来源 = 一个可读文件：既可以是密钥管理器的合并 bundle（`export/devmon.json`，
    /// 内含全部注册表），也可以是某个注册表的旧格式导出（`export/<registry>.json`）。
    /// 多个来源按注册表 id 合并（见 `mergeSnapshots`），所以以后新增的注册表只要加进
    /// 这个列表就能看到，不会覆盖已有注册表。
    static let checkSourcesKey = "license_check_sources"

    /// 每个来源最近一次良好导入的快照。
    private static let sourceSnapshotsKey = "seat_registry_source_snapshots"

    /// 单个来源文件的快照：路径 + 格式 + 签名结论 + 已导入的注册表。
    ///
    /// 保存 `registries` 是为了在来源临时不可用（文件被删 / 签名不符 / 解析失败）时
    /// **保留它上一次的良好数据**，而不是让整个席位表塌掉。
    struct SourceSnapshot: Codable, Sendable, Equatable {
        enum SignatureCode: String, Codable, Sendable {
            case unknown, valid, absent, invalid
        }

        var path: String
        /// 是否为新版 bundle（false = 旧版 `{seats:[…]}` / 裸数组兼容格式）。
        var isBundle: Bool
        var updatedAt: String?
        var importedAt: Date?
        var registries: [LicenseRegistry]
        var signatureCode: SignatureCode = .unknown
        /// 签名 kid 或拒绝原因（UI 提示用）。
        var signatureDetail: String?
        var error: String?

        init(path: String, isBundle: Bool) {
            self.path = path
            self.isBundle = isBundle
            self.registries = []
        }

        init(path: String, isBundle: Bool, updatedAt: String?, importedAt: Date?,
             registries: [LicenseRegistry], signatureCode: SignatureCode,
             signatureDetail: String?, error: String?) {
            self.path = path
            self.isBundle = isBundle
            self.updatedAt = updatedAt
            self.importedAt = importedAt
            self.registries = registries
            self.signatureCode = signatureCode
            self.signatureDetail = signatureDetail
            self.error = error
        }

        var seatCount: Int { registries.reduce(0) { $0 + $1.allSeats.count } }
        var registryCount: Int { registries.count }

        static func code(of verdict: BundleSignatureVerdict) -> SignatureCode {
            switch verdict {
            case .valid: return .valid
            case .absent: return .absent
            case .invalid: return .invalid
            case .unknown: return .unknown
            }
        }

        static func detail(of verdict: BundleSignatureVerdict) -> String? {
            switch verdict {
            case .valid(let kid): return kid
            case .invalid(let why): return why
            case .absent, .unknown: return nil
            }
        }
    }

    /// 密钥管理器仓库根目录（默认约定位置）。
    static let defaultToolRoot = "\(NSHomeDirectory())/Documents/GitHub/personal_key_manager"

    /// 默认许可检查来源：personal_key_manager 的 devmon.json
    /// （可用 `license_check_source` 覆盖）
    static var defaultLicensesSourceURL: URL {
        let path = UserDefaults.standard.string(forKey: checkSourceKey)
            ?? "\(defaultToolRoot)/export/devmon.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    struct CheckResult: Sendable {
        let imported: Int
        let source: String
        let updatedAt: String?
        let error: String?
        /// 导入结果包含的注册表数量
        let registries: Int
        /// 这次导入的签名结论（多来源时取最差的一个）
        let signature: BundleSignatureVerdict
        /// 参与本次检查的来源数量
        let sources: Int

        static func failure(_ message: String, source: String,
                            signature: BundleSignatureVerdict = .unknown) -> CheckResult {
            CheckResult(imported: 0, source: source, updatedAt: nil, error: message,
                        registries: 0, signature: signature, sources: 0)
        }
    }

    // MARK: - 导出包签名校验

    /// 固定的导出包签名公钥。
    ///
    /// 轮换时在数组里**追加**新的 kid、给旧条目设 `notAfter`，不要直接删 ——
    /// 已发布的 dev_mon 只认它编译时就存在的那几条。
    static let authorityKeys: [AuthorityKey] = [
        AuthorityKey(kid: "authority-1",
                     publicKey: "tyz9Bu_7ywAprU5wVryhN_cPicRhSpislwWhytJJgT8",
                     notAfter: nil),
    ]

    /// 最近一次导入时的签名结论。
    var signatureVerdict: BundleSignatureVerdict { lock.withLock { _lastSignature } }

    /// 校验 `devmon.json` 旁边的 `.sig` 是否匹配给定的 bundle 字节。
    ///
    /// 接受两种格式：`{"v":1,"kid":"…","sig":"…"}`（当前）或裸 base64url 签名（旧版）。
    /// 依次尝试所有固定公钥，所以轮换期间新旧签名都能通过；声明了 kid 就先试它。
    static func verifyBundleSignature(bundleData: Data, sourceURL: URL) -> BundleSignatureVerdict {
        let sigURL = URL(fileURLWithPath: sourceURL.path + ".sig")
        guard let raw = try? String(contentsOf: sigURL, encoding: .utf8) else { return .absent }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .absent }

        var sigB64 = trimmed
        var declaredKid: String?
        if trimmed.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            sigB64 = (obj["sig"] as? String) ?? ""
            declaredKid = obj["kid"] as? String
        }
        guard let signature = decodeBase64URL(sigB64), !signature.isEmpty else {
            return .invalid(Strings.licenseSignatureMalformed)
        }

        let now = Int(Date().timeIntervalSince1970)
        let ordered = authorityKeys.filter { $0.kid == declaredKid }
            + authorityKeys.filter { $0.kid != declaredKid }

        for key in ordered {
            if let notAfter = key.notAfter, notAfter > 0, now >= notAfter { continue }
            guard let rawKey = decodeBase64URL(key.publicKey),
                  let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
                  pub.isValidSignature(signature, for: bundleData)
            else { continue }
            return .valid(kid: key.kid)
        }
        return .invalid(Strings.licenseSignatureInvalid(declaredKid))
    }

    // MARK: - 来源列表

    /// 当前的许可检查来源列表（有序，已展开 `~`）。
    var checkSources: [String] { lock.withLock { _checkSources } }

    /// 每个来源最近一次导入的快照（UI 显示签名 / 数量 / 错误）。
    var sourceSnapshots: [SourceSnapshot] { lock.withLock { _snapshots } }

    /// 设置来源列表：去空白、展开 `~`、去重；空列表回退到默认来源。
    /// - Parameter check: 是否立即在后台重跑一次检查（编辑框逐字写入时传 false）。
    func setCheckSources(_ paths: [String], check: Bool = true) {
        let cleaned = Self.normalizeSources(paths)
        let effective = cleaned.isEmpty ? [Self.defaultLicensesSourceURL.path] : cleaned
        lock.withLock {
            _checkSources = effective
            // 注意：这里**不动** `_snapshots` —— 逐字编辑路径时不能让来源的已知良好数据
            // 提前消失；被移除的来源会在下一次 checkLicenses 里自然不再被合并。
            UserDefaults.standard.set(effective, forKey: Self.checkSourcesKey)
            UserDefaults.standard.set(effective.first ?? "", forKey: Self.checkSourceKey)
        }
        if check { checkNow() }
    }

    /// 规范化来源列表：去空白、展开 `~`、按展开后的路径去重（保持顺序）。
    static func normalizeSources(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { continue }
            out.append(expanded)
        }
        return out
    }

    /// 读取来源列表；首次运行（还没有新键）时从旧的单来源键迁移。
    private static func storedCheckSources() -> [String] {
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: checkSourcesKey) {
            let normalized = normalizeSources(stored)
            if !normalized.isEmpty { return normalized }
        }
        if let legacy = defaults.string(forKey: checkSourceKey)?.trimmingCharacters(in: .whitespaces),
           !legacy.isEmpty {
            return normalizeSources([legacy])
        }
        return [defaultLicensesSourceURL.path]
    }

    private static func storedSnapshots() -> [SourceSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: sourceSnapshotsKey),
              let decoded = try? JSONDecoder().decode([SourceSnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    private static func persistSnapshots(_ snapshots: [SourceSnapshot]) {
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: sourceSnapshotsKey)
        }
    }

    // MARK: - 检查（全部来源）

    /// 使用全部来源执行许可检查（「检查许可」按钮 / 定时器 / 密钥管理器写操作后调用）。
    func checkLicenses() -> CheckResult {
        checkLicenses(fromSources: checkSources)
    }

    /// 依次读取全部来源并合并。
    ///
    /// 每个来源独立校验 `*.sig`：
    /// - **签名不匹配** → 拒绝该来源的**新**数据，保留它上一次良好快照；
    /// - **bundle 但没有 `.sig`** → 同样拒绝（否则删掉那一个文件就能绕过校验）；
    /// - **旧版 `{seats:[…]}`/裸数组** → 照常导入，仅标注“未签名”。
    ///
    /// 全部来源读完后按注册表 id 合并（见 `mergeSnapshots`），再写 UserDefaults + 镜像文件。
    func checkLicenses(fromSources paths: [String]) -> CheckResult {
        let cleaned = Self.normalizeSources(paths)
        let effective = cleaned.isEmpty ? [Self.defaultLicensesSourceURL.path] : cleaned
        let previous = Dictionary(lock.withLock { _snapshots }.map { ($0.path, $0) },
                                  uniquingKeysWith: { first, _ in first })

        let fresh = effective.map { loadSnapshot(path: $0, previous: previous[$0]) }
        let merged = Self.mergeSnapshots(fresh)
        let firstError = fresh.compactMap(\.error).first
        let verdict = Self.worstVerdict(fresh)
        // 只要还有一个来源成功，就不把整体报成失败 —— 失败来源的明细显示在各自的行上。
        let failedEverySource = !fresh.isEmpty && fresh.allSatisfy { $0.error != nil }
        // 所有来源都失败且没有已知良好数据时保持原状：
        // 一次读盘失败（文件被删 / 权限 / 断网盘）不该把整张席位表清空。
        let keepExisting = merged.registries.isEmpty && !fresh.contains { $0.error == nil }

        var effectiveBundle = merged
        lock.withLock {
            _checkSources = effective
            if keepExisting {
                effectiveBundle = _bundle
            } else {
                _snapshots = fresh
                _bundle = merged
                _lastUpdatedAt = merged.generatedAt
                _lastSource = effective.count == 1 ? effective[0] : effective.joined(separator: ", ")
                Self.persistSnapshots(fresh)
            }
            _lastError = failedEverySource ? firstError : nil
            _lastSignature = verdict
            UserDefaults.standard.set(effective, forKey: Self.checkSourcesKey)
            UserDefaults.standard.set(effective.first ?? "", forKey: Self.checkSourceKey)
            persistLocked()
        }

        let seatCount = effectiveBundle.registries.reduce(0) { $0 + $1.allSeats.count }
        return CheckResult(imported: seatCount,
                           source: effective.count == 1 ? effective[0] : effective.joined(separator: ", "),
                           updatedAt: effectiveBundle.generatedAt,
                           error: failedEverySource ? firstError : nil,
                           registries: effectiveBundle.registries.count,
                           signature: verdict,
                           sources: effective.count)
    }

    /// 读取单个来源 → 快照。读不到 / 签名不符 / 解析失败时保留该来源上一次的良好数据
    /// （`registries` 原样带回），只写入 `error` 供 UI 提示。
    private func loadSnapshot(path: String, previous: SourceSnapshot?) -> SourceSnapshot {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var snap = previous ?? SourceSnapshot(path: path, isBundle: true)

        guard let data = try? Data(contentsOf: url) else {
            snap.error = Strings.licenseSourceUnreadable(url.path)
            return snap
        }

        let verdict = Self.verifyBundleSignature(bundleData: data, sourceURL: url)
        snap.signatureCode = SourceSnapshot.code(of: verdict)
        snap.signatureDetail = SourceSnapshot.detail(of: verdict)

        if case .invalid(let why) = verdict {
            snap.error = Strings.licenseSignatureRefused(why)
            return snap
        }
        guard let decoded = RegistryBundleDecoder.decode(data) else {
            snap.error = Strings.licenseSourceUnparsable
            return snap
        }
        // 只删掉 `.sig` 就能绕过校验，所以 bundle 格式**必须**带签名。
        if case .absent = verdict, decoded.isBundle {
            snap.error = Strings.licenseSignatureRequired
            return snap
        }

        return SourceSnapshot(path: path,
                              isBundle: decoded.isBundle,
                              updatedAt: decoded.updatedAt,
                              importedAt: Date(),
                              registries: Self.relabelRegistries(decoded.bundle.registries,
                                                                path: path,
                                                                isBundle: decoded.isBundle),
                              signatureCode: snap.signatureCode,
                              signatureDetail: snap.signatureDetail,
                              error: nil)
    }

    /// 旧格式导出没有注册表 id（兼容层会包成 "Default"）：改用**文件名**作为 id，
    /// 这样 `export/<registry>.json` 会并入 bundle 里的同名 `<registry>` 注册表，
    /// 而不是变成一个孤立的 "Default" 注册表。
    private static func relabelRegistries(_ registries: [LicenseRegistry], path: String,
                                          isBundle: Bool) -> [LicenseRegistry] {
        guard !isBundle else { return registries }
        let stem = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .deletingPathExtension().lastPathComponent
        let id = stem.isEmpty ? "default" : stem
        return registries.map { registry in
            var r = registry
            r.id = id
            // 名称 / app 由 bundle 来源覆盖（见 mergeSnapshots）；这里给可读的兜底值。
            r.name = (registry.name.isEmpty || registry.name == "Default") ? id : registry.name
            r.app = (registry.app.isEmpty || registry.app == "—") ? id : registry.app
            return r
        }
    }

    /// 汇总多个来源的签名结论：任一 invalid → invalid；否则任一 absent → absent；否则 valid。
    private static func worstVerdict(_ snapshots: [SourceSnapshot]) -> BundleSignatureVerdict {
        if let bad = snapshots.first(where: { $0.signatureCode == .invalid }) {
            return .invalid(bad.signatureDetail ?? Strings.licenseSignatureInvalid(nil))
        }
        if snapshots.contains(where: { $0.signatureCode == .absent }) { return .absent }
        if let ok = snapshots.first(where: { $0.signatureCode == .valid }) {
            return .valid(kid: ok.signatureDetail ?? "?")
        }
        return .unknown
    }

    /// 跨来源合并：注册表按 id、密钥环按 kid、席位按 sub。
    ///
    /// 冲突规则（顺序即优先级）：
    /// - 注册表 name / app：**bundle 来源优先**于由文件名推导的旧格式来源；
    /// - 密钥环元数据：任一来源提供即采用（先到先得，nil 不覆盖非 nil）；
    /// - 席位：**吊销优先**（任一来源吊销即吊销，取最早的 `revokedAt`），其次取更紧的
    ///   `exp`（0 = 不限，非 0 中较小者更紧），`issuedAt` 取最早的非空值。
    ///
    /// 席位按 sub 在注册表内去重：同一 sub 出现在不同 ring 时保留先出现的 ring。
    static func mergeSnapshots(_ snapshots: [SourceSnapshot]) -> RegistryBundle {
        struct RegistryAcc {
            var name: String
            var app: String
            var engine: String?
            var fromBundle: Bool
            var ringOrder: [String] = []
            var rings: [String: KeyRing] = [:]
            var subToKid: [String: String] = [:]
        }

        var order: [String] = []
        var accs: [String: RegistryAcc] = [:]
        var updatedAt: String?

        for snap in snapshots {
            if updatedAt == nil, let value = snap.updatedAt { updatedAt = value }
            for registry in snap.registries {
                let id = registry.id.isEmpty ? "default" : registry.id
                if accs[id] == nil {
                    accs[id] = RegistryAcc(name: registry.name, app: registry.app,
                                           engine: registry.engine, fromBundle: snap.isBundle)
                    order.append(id)
                } else if accs[id]?.fromBundle == false, snap.isBundle {
                    accs[id]?.name = registry.name
                    accs[id]?.app = registry.app
                    accs[id]?.engine = registry.engine
                    accs[id]?.fromBundle = true
                }

                for ring in registry.rings {
                    let kid = ring.kid.isEmpty ? "(unknown ring)" : ring.kid
                    if accs[id]?.rings[kid] == nil {
                        accs[id]?.ringOrder.append(kid)
                        accs[id]?.rings[kid] = KeyRing(kid: kid, publicKey: ring.publicKey,
                                                       notAfter: ring.notAfter,
                                                       createdAt: ring.createdAt,
                                                       retired: ring.retired, seats: [])
                    } else {
                        if accs[id]?.rings[kid]?.publicKey == nil { accs[id]?.rings[kid]?.publicKey = ring.publicKey }
                        if accs[id]?.rings[kid]?.notAfter == nil { accs[id]?.rings[kid]?.notAfter = ring.notAfter }
                        if accs[id]?.rings[kid]?.createdAt == nil { accs[id]?.rings[kid]?.createdAt = ring.createdAt }
                        if accs[id]?.rings[kid]?.retired == nil { accs[id]?.rings[kid]?.retired = ring.retired }
                    }

                    for seat in ring.seats {
                        guard !seat.sub.isEmpty else { continue }
                        if let hostKid = accs[id]?.subToKid[seat.sub] {
                            guard let idx = accs[id]?.rings[hostKid]?.seats.firstIndex(where: { $0.sub == seat.sub }),
                                  let existing = accs[id]?.rings[hostKid]?.seats[idx]
                            else { continue }
                            accs[id]?.rings[hostKid]?.seats[idx] = Self.stricterSeat(existing, seat)
                        } else {
                            accs[id]?.subToKid[seat.sub] = kid
                            accs[id]?.rings[kid]?.seats.append(seat)
                        }
                    }
                }
            }
        }

        let registries: [LicenseRegistry] = order.compactMap { id in
            guard let acc = accs[id] else { return nil }
            let rings = acc.ringOrder.compactMap { kid -> KeyRing? in
                guard var ring = acc.rings[kid] else { return nil }
                ring.seats.sort { $0.sub < $1.sub }
                return ring
            }
            return LicenseRegistry(id: id,
                                   name: acc.name.isEmpty ? id : acc.name,
                                   app: acc.app,
                                   engine: acc.engine,
                                   rings: rings)
        }

        return RegistryBundle(bundleVersion: 1, generatedAt: updatedAt, totals: nil,
                              registries: registries).withContext()
    }

    /// 同一 (注册表, sub) 出现在多个来源时的取值：吊销优先，其次更紧的到期时间。
    private static func stricterSeat(_ a: SeatRecord, _ b: SeatRecord) -> SeatRecord {
        func severity(_ s: SeatRecord) -> Int { s.revoked ? 2 : (s.isExpired ? 1 : 0) }
        var out = severity(b) > severity(a) ? b : a
        out.revoked = a.revoked || b.revoked
        if out.revoked {
            out.revokedAt = [a.revokedAt, b.revokedAt].compactMap { $0 }.min() ?? out.revokedAt
        }
        let exps = [a.exp, b.exp].filter { $0 > 0 }
        if let tightest = exps.min(), let source = [a, b].first(where: { $0.exp == tightest }) {
            out.exp = source.exp
            out.expUtc = source.expUtc
            out.expired = source.expired
            out.expiredAt = source.expiredAt
        }
        out.issuedAt = [a.issuedAt, b.issuedAt].compactMap { $0 }.min() ?? out.issuedAt
        return out
    }

    // MARK: - 自动检查（定期读取导出文件）

    /// 自动检查间隔 UserDefaults key（小时）
    static let checkIntervalKey = "license_check_interval_hours"

    /// 自动检查间隔（小时），默认 6，最小 1，最大 168
    var checkIntervalHours: Double { lock.withLock { _checkIntervalHours } }

    private var _checkIntervalHours: Double = {
        let stored = UserDefaults.standard.double(forKey: checkIntervalKey)
        return stored >= 1 ? stored : 6
    }()

    private var checkTimer: Timer?

    /// 设置自动检查间隔并重启定时器
    func setCheckInterval(hours: Double) {
        let clamped = max(1, min(hours, 168))
        lock.withLock { _checkIntervalHours = clamped }
        UserDefaults.standard.set(clamped, forKey: Self.checkIntervalKey)
        startAutoCheck()
    }

    /// 启动定期检查（在 app 启动时调用）。
    ///
    /// 先立即查一次：`Timer` 的首次触发要等整整一个间隔，而 DS-mon 是吊销授权
    /// 权威 —— 刚启动（或刚升级）时席位表可能是空的，未知席位会被当成“未吊销”，
    /// 于是留下最长一个间隔的放行窗口。
    func startAutoCheck() {
        stopAutoCheck()
        checkNow()

        let interval = lock.withLock { _checkIntervalHours } * 3600
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                _ = self.checkLicenses()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        lock.withLock { self.checkTimer = timer }
    }

    /// 在后台立即导入一次许可来源（不阻塞调用方）。
    func checkNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.checkLicenses()
        }
    }

    /// 停止定期检查
    func stopAutoCheck() {
        lock.withLock {
            checkTimer?.invalidate()
            checkTimer = nil
        }
    }

    // MARK: - 持久化

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(RegistryBundle.self, from: data) {
            _bundle = decoded
            return
        }
        // 一次性迁移：旧版扁平 [SeatRecord] → 单个 "Default" 注册表
        if let legacy = defaults.data(forKey: Self.legacyStorageKey),
           let records = try? JSONDecoder().decode([SeatRecord].self, from: legacy),
           !records.isEmpty {
            _bundle = RegistryBundleDecoder.legacyBundle(fromRecords: records)
            persistLocked()
            defaults.removeObject(forKey: Self.legacyStorageKey)
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(_bundle) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        if mirrorPathIsSafeLocked() {
            let url = URL(fileURLWithPath: (_filePath as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(_bundle) {
                try? data.write(to: url, options: .atomic)
            }
        }
        // 通知 UI 刷新（异步投递，避免持锁状态下同步回调导致死锁）
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .seatRegistryChanged, object: nil)
        }
    }
}

/// base64url（无填充）解码 —— 用于签名文件与固定的授权公钥。
private func decodeBase64URL(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}
