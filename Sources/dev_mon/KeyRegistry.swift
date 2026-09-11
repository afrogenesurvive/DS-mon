import Foundation

/// 一个席位（密钥）：由 sub 唯一标识，关联 master kid、签发日期、过期时间与吊销状态。
///
/// 字段与 personal_key_manager 导出的 `export/devmon.json` 对齐；`issuedAt` 为新增，
/// 其余派生字段（registryId / registryName / ringPublicKey）在解码 bundle 时回填。
struct SeatRecord: Codable, Sendable, Identifiable, Equatable {
    var sub: String
    var kid: String
    var exp: Int          // Unix 秒；0 = 不限
    var revoked: Bool

    /// 签发时间（ISO-8601 字符串，由密钥管理器写入）
    var issuedAt: String?
    /// 过期时间的 ISO-8601 形式（exp > 0 时存在）
    var expUtc: String?
    var revokedAt: String?
    var expired: Bool?
    var expiredAt: String?

    // ── 由 bundle 回填的上下文（不属于席位本身的持久字段）──
    var registryId: String?
    var registryName: String?
    var ringPublicKey: String?

    /// 跨注册表唯一：同一个 sub 可以同时存在于两个注册表中。
    var id: String { "\(registryId ?? "")|\(sub)" }

    /// 是否已过期（exp > 0 且早于当前时间）
    var isExpired: Bool {
        exp > 0 && Date().timeIntervalSince1970 > TimeInterval(exp)
    }

    /// 已吊销或已过期 —— 即“不可用”。
    var isInactive: Bool { revoked || isExpired }

    enum CodingKeys: String, CodingKey {
        case sub, kid, exp, revoked, issuedAt, expUtc, revokedAt, expired, expiredAt
        case registryId, registryName, ringPublicKey
    }

    init(sub: String, kid: String, exp: Int, revoked: Bool, issuedAt: String? = nil) {
        self.sub = sub
        self.kid = kid
        self.exp = exp
        self.revoked = revoked
        self.issuedAt = issuedAt
    }

    /// 宽容解码：导出文件里 kid/exp/revoked 可能为 null（例如仅存在于吊销黑名单的席位）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sub = ((try? c.decodeIfPresent(String.self, forKey: .sub)) ?? nil) ?? ""
        kid = ((try? c.decodeIfPresent(String.self, forKey: .kid)) ?? nil) ?? ""
        exp = ((try? c.decodeIfPresent(Int.self, forKey: .exp)) ?? nil) ?? 0
        revoked = ((try? c.decodeIfPresent(Bool.self, forKey: .revoked)) ?? nil) ?? false
        issuedAt = (try? c.decodeIfPresent(String.self, forKey: .issuedAt)) ?? nil
        expUtc = (try? c.decodeIfPresent(String.self, forKey: .expUtc)) ?? nil
        revokedAt = (try? c.decodeIfPresent(String.self, forKey: .revokedAt)) ?? nil
        expired = (try? c.decodeIfPresent(Bool.self, forKey: .expired)) ?? nil
        expiredAt = (try? c.decodeIfPresent(String.self, forKey: .expiredAt)) ?? nil
        registryId = (try? c.decodeIfPresent(String.self, forKey: .registryId)) ?? nil
        registryName = (try? c.decodeIfPresent(String.self, forKey: .registryName)) ?? nil
        ringPublicKey = (try? c.decodeIfPresent(String.self, forKey: .ringPublicKey)) ?? nil
    }
}

/// 一个 key ring（master 密钥环）：只包含公钥与退役时间。
struct KeyRing: Codable, Sendable, Identifiable, Equatable {
    var kid: String
    var publicKey: String?
    var notAfter: Int?
    var createdAt: String?
    var retired: Bool?
    var seats: [SeatRecord]

    var id: String { kid }

    var isRetired: Bool {
        guard let notAfter, notAfter > 0 else { return retired ?? false }
        return Date().timeIntervalSince1970 >= TimeInterval(notAfter)
    }

    /// 环未在近期退役 —— 用于在 UI 上把可用环排前面。
    var notAfterLabel: String? {
        guard let notAfter, notAfter > 0 else { return nil }
        return Self.dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(notAfter)))
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

/// 一个具名席位注册表 —— 对应一个消费方应用（app id）。
struct LicenseRegistry: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var app: String
    var engine: String?
    var rings: [KeyRing]

    var allSeats: [SeatRecord] { rings.flatMap(\.seats) }
    var validCount: Int { allSeats.filter { !$0.isInactive }.count }
    var revokedCount: Int { allSeats.filter(\.revoked).count }
    var expiredCount: Int { allSeats.filter { !$0.revoked && $0.isExpired }.count }
}

struct RegistryTotals: Codable, Sendable, Equatable {
    var registries: Int?
    var seats: Int?
    var valid: Int?
    var revoked: Int?
    var expired: Int?
}

/// `export/devmon.json` 的顶层结构。
struct RegistryBundle: Codable, Sendable, Equatable {
    var bundleVersion: Int?
    var generatedAt: String?
    var totals: RegistryTotals?
    var registries: [LicenseRegistry]

    /// 回填每个席位的注册表 / 密钥环上下文，供 UI 直接渲染。
    func withContext() -> RegistryBundle {
        var copy = self
        copy.registries = registries.map { reg in
            var r = reg
            r.rings = r.rings.map { ring in
                var g = ring
                g.seats = g.seats.map { seat in
                    var s = seat
                    s.registryId = reg.id
                    s.registryName = reg.name
                    s.ringPublicKey = ring.publicKey
                    return s
                }
                return g
            }
            return r
        }
        return copy
    }
}

/// 兼容层：解析密钥管理器导出的两种格式，以及历史遗留的扁平列表。
enum RegistryBundleDecoder {
    struct Decoded: Sendable {
        var bundle: RegistryBundle
        /// 导出文件写入的 updatedAt / generatedAt（用于“检查于 …”提示）
        var updatedAt: String?
        /// 是否来自新版 bundle（false = 旧版 seats.json 兼容路径）
        var isBundle: Bool
    }

    static func decode(_ data: Data) -> Decoded? {
        let decoder = JSONDecoder()

        // 1) 新版 bundle：{ bundleVersion, generatedAt, registries:[{ id, rings:[{ seats }] }] }
        if let bundle = try? decoder.decode(RegistryBundle.self, from: data),
           !bundle.registries.isEmpty || data.containsAscii("\"registries\"") {
            return Decoded(bundle: bundle.withContext(), updatedAt: bundle.generatedAt, isBundle: true)
        }

        // 2) 旧版导出：{ seats:[…], updatedAt }
        if let file = try? decoder.decode(AgentSeatsFile.self, from: data) {
            return Decoded(bundle: legacyBundle(from: file.seats), updatedAt: file.updatedAt, isBundle: false)
        }

        // 3) 更早的裸数组：[{sub,kid,exp,revoked}]
        if let arr = try? decoder.decode([AgentSeat].self, from: data) {
            return Decoded(bundle: legacyBundle(from: arr), updatedAt: nil, isBundle: false)
        }

        return nil
    }

    /// 把旧格式的席位包成单个注册表（按 kid 分组为 ring）。
    static func legacyBundle(from seats: [AgentSeat]) -> RegistryBundle {
        let records: [SeatRecord] = seats.compactMap { seat in
            let sub = seat.sub.trimmingCharacters(in: .whitespaces)
            guard !sub.isEmpty else { return nil }
            return SeatRecord(
                sub: sub,
                kid: seat.kid ?? "",
                exp: max(0, seat.exp ?? 0),
                revoked: seat.revoked ?? false,
                issuedAt: seat.issuedAt
            )
        }
        return legacyBundle(fromRecords: records)
    }

    /// 同上，但直接接收已解码的 SeatRecord（用于 v1 UserDefaults 迁移）。
    static func legacyBundle(fromRecords records: [SeatRecord]) -> RegistryBundle {
        var byKid: [String: [SeatRecord]] = [:]
        for record in records {
            let sub = record.sub.trimmingCharacters(in: .whitespaces)
            guard !sub.isEmpty else { continue }
            var r = record
            r.sub = sub
            byKid[r.kid, default: []].append(r)
        }

        let rings: [KeyRing] = byKid
            .map { KeyRing(kid: $0.key.isEmpty ? "(unknown ring)" : $0.key, publicKey: nil,
                           notAfter: nil, createdAt: nil, retired: nil, seats: $0.value) }
            .sorted { $0.kid < $1.kid }

        let registry = LicenseRegistry(id: "default", name: "Default", app: "—",
                                       engine: nil, rings: rings)
        return RegistryBundle(bundleVersion: 1, generatedAt: nil, totals: nil, registries: [registry])
    }
}

private extension Data {
    /// 粗略判断 JSON 文本中是否出现某个键（用于区分 bundle 与旧格式）。
    func containsAscii(_ needle: String) -> Bool {
        guard let text = String(data: self, encoding: .utf8) else { return false }
        return text.contains(needle)
    }
}
