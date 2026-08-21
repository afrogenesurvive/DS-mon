import Foundation

/// 一个已登记的席位（seat）：由 sub 唯一标识，关联 master kid、过期时间与吊销状态。
struct SeatRecord: Codable, Sendable, Identifiable, Equatable {
    var sub: String
    var kid: String
    var exp: Int       // Unix 秒；0 = 不限
    var revoked: Bool

    var id: String { sub }
}

struct SeatStatus: Sendable {
    let revoked: Bool
    let exp: Int
}

/// 席位注册表：DS-mon 作为 Hybrid 授权权威，按 sub 回答“该席位是否已被吊销”。
///
/// 持久化：
/// - 内嵌列表：UserDefaults `seat_registry`
/// - 可选文件路径（`seat_registry_file`）：JSON 数组 `[{sub, kid, exp, revoked}]`。
///   文件为权威来源，设置/加载后覆盖内嵌列表。
///
/// 注意：DS-mon 不做任何签名校验 —— 吊销/过期仅按 sub（与 exp）判定。
final class SeatRegistry: @unchecked Sendable {
    static let shared = SeatRegistry()

    private let lock = NSLock()
    private var _seats: [SeatRecord] = []
    private var filePath: String = ""

    static let storageKey = "seat_registry"
    static let filePathKey = "seat_registry_file"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SeatRecord].self, from: data) {
            _seats = decoded
        }
        filePath = UserDefaults.standard.string(forKey: Self.filePathKey) ?? ""
        if !filePath.isEmpty {
            reloadFileLocked()
        }
    }

    var seats: [SeatRecord] {
        lock.withLock { _seats.sorted { $0.sub < $1.sub } }
    }

    var registryFilePath: String {
        lock.withLock { filePath }
    }

    /// 查询席位状态；sub 未登记返回 nil（调用方按未吊销处理）
    func status(for sub: String) -> SeatStatus? {
        lock.withLock {
            guard let seat = _seats.first(where: { $0.sub == sub }) else { return nil }
            return SeatStatus(revoked: seat.revoked, exp: seat.exp)
        }
    }

    func upsert(_ seat: SeatRecord) {
        lock.withLock {
            if let idx = _seats.firstIndex(where: { $0.sub == seat.sub }) {
                _seats[idx] = seat
            } else {
                _seats.append(seat)
            }
            persistLocked()
        }
    }

    func remove(sub: String) {
        lock.withLock {
            _seats.removeAll { $0.sub == sub }
            persistLocked()
        }
    }

    func setRevoked(_ revoked: Bool, for sub: String) {
        lock.withLock {
            guard let idx = _seats.firstIndex(where: { $0.sub == sub }) else { return }
            _seats[idx].revoked = revoked
            persistLocked()
        }
    }

    func setFilePath(_ path: String) {
        lock.withLock {
            filePath = path.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(filePath, forKey: Self.filePathKey)
            if filePath.isEmpty {
                persistLocked()
                return
            }
            reloadFileLocked()
        }
    }

    // MARK: - 持久化

    private func reloadFileLocked() {
        guard !filePath.isEmpty else { return }
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SeatRecord].self, from: data) else { return }
        _seats = decoded
        persistLocked()
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(_seats) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        guard !filePath.isEmpty else { return }
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(_seats) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
