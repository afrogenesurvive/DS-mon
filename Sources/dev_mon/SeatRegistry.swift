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

    /// 新版存储键（RegistryBundle）。
    static let storageKey = "seat_registry_v2"
    /// 旧版存储键（扁平 [SeatRecord]）—— 仅用于一次性迁移。
    static let legacyStorageKey = "seat_registry"
    static let filePathKey = "seat_registry_file"

    private init() {
        loadFromDefaults()
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

    private func reloadFileLocked() {
        guard mirrorPathIsSafeLocked() else { return }
        let url = URL(fileURLWithPath: (_filePath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let decoded = RegistryBundleDecoder.decode(data) else { return }
        _bundle = decoded.isBundle ? decoded.bundle : mergeLegacyLocked(decoded.bundle)
        _lastUpdatedAt = decoded.updatedAt
        _lastSource = url.path
        persistLocked()
    }

    // MARK: - 从密钥管理器导出导入

    /// 许可检查来源 UserDefaults key
    static let checkSourceKey = "license_check_source"

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
        /// 这次导入的签名结论
        let signature: BundleSignatureVerdict

        static func failure(_ message: String, source: String,
                            signature: BundleSignatureVerdict = .unknown) -> CheckResult {
            CheckResult(imported: 0, source: source, updatedAt: nil, error: message,
                        registries: 0, signature: signature)
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

    /// 使用默认来源执行许可检查
    func checkLicenses() -> CheckResult {
        checkLicenses(from: Self.defaultLicensesSourceURL)
    }

    /// 读取并导入许可来源；支持新版 bundle、旧版 `{seats:[…]}` 与裸数组三种格式。
    ///
    /// 导入前先校验 `devmon.json.sig`，导入规则分三种：
    /// - **签名不匹配** → 拒绝，保留上一次已知良好的席位表；
    /// - **bundle 但没有 `.sig`** → 拒绝（否则删掉那一个文件就能绕过校验）；
    /// - **旧版 `{seats:[…]}`/裸数组** → 照常导入，仅标注“未签名”。
    func checkLicenses(from url: URL) -> CheckResult {
        guard let data = try? Data(contentsOf: url) else {
            let message = Strings.licenseSourceUnreadable(url.path)
            lock.withLock { _lastError = message }
            return .failure(message, source: url.path)
        }

        let verdict = Self.verifyBundleSignature(bundleData: data, sourceURL: url)
        if case .invalid(let why) = verdict {
            let message = Strings.licenseSignatureRefused(why)
            lock.withLock {
                _lastError = message
                _lastSignature = verdict
            }
            return .failure(message, source: url.path, signature: verdict)
        }

        guard let decoded = RegistryBundleDecoder.decode(data) else {
            let message = Strings.licenseSourceUnparsable
            lock.withLock {
                _lastError = message
                _lastSignature = verdict
            }
            return .failure(message, source: url.path, signature: verdict)
        }

        // 只删掉 `.sig` 就能绕过校验，所以 bundle 格式**必须**带签名。
        // 旧版 `{seats:[…]}` 早于签名机制，仍允许无签名导入（仅标注“未签名”）。
        if case .absent = verdict, decoded.isBundle {
            let message = Strings.licenseSignatureRequired
            lock.withLock {
                _lastError = message
                _lastSignature = verdict
            }
            return .failure(message, source: url.path, signature: verdict)
        }

        let total = lock.withLock { () -> Int in
            _bundle = decoded.isBundle ? decoded.bundle : mergeLegacyLocked(decoded.bundle)
            _lastUpdatedAt = decoded.updatedAt
            _lastSource = url.path
            _lastError = nil
            _lastSignature = verdict
            persistLocked()
            return _bundle.registries.reduce(0) { $0 + $1.allSeats.count }
        }

        return CheckResult(imported: total, source: url.path, updatedAt: decoded.updatedAt,
                           error: nil, registries: decoded.bundle.registries.count,
                           signature: verdict)
    }

    /// 旧格式来源只覆盖虚构的 "default" 注册表，保留其它注册表不动。
    private func mergeLegacyLocked(_ incoming: RegistryBundle) -> RegistryBundle {
        let others = _bundle.registries.filter { $0.id != "default" }
        return RegistryBundle(bundleVersion: 1, generatedAt: incoming.generatedAt, totals: nil,
                              registries: (incoming.registries + others).sorted { $0.id < $1.id })
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
