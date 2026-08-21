import Foundation

/// 一个已登记的席位（seat）：由 sub 唯一标识，关联 master kid、过期时间与吊销状态。
struct SeatRecord: Codable, Sendable, Identifiable, Equatable {
    var sub: String
    var kid: String
    var exp: Int       // Unix 秒；0 = 不限
    var revoked: Bool

    var id: String { sub }

    /// 是否已过期（exp > 0 且早于当前时间）
    var isExpired: Bool {
        exp > 0 && Date().timeIntervalSince1970 > TimeInterval(exp)
    }
}

struct SeatStatus: Sendable {
    let revoked: Bool
    let exp: Int
}

/// AI 转录代理 dev-keys/seats.json 中的单个席位记录（kid/exp/revoked 可空）
struct AgentSeat: Codable, Sendable {
    let sub: String
    let kid: String?
    let exp: Int?
    let revoked: Bool?
}

/// AI 转录代理 dev-keys/seats.json 顶层结构
struct AgentSeatsFile: Codable, Sendable {
    let seats: [AgentSeat]
    let updatedAt: String?
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

    // MARK: - 许可检查（从 AI 转录代理读取 seats.json）

    /// 许可检查来源 UserDefaults key
    static let checkSourceKey = "license_check_source"

    /// 默认许可检查来源：AI 转录代理的 dev-keys/seats.json（可用 `license_check_source` 覆盖）
    static var defaultLicensesSourceURL: URL {
        let path = UserDefaults.standard.string(forKey: checkSourceKey)
            ?? "\(NSHomeDirectory())/Documents/GitHub/ai_transcription_agent/dev-keys/seats.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    struct CheckResult: Sendable {
        let imported: Int
        let source: String
        let updatedAt: String?
        let error: String?
    }

    /// 使用默认来源执行许可检查
    func checkLicenses() -> CheckResult {
        checkLicenses(from: Self.defaultLicensesSourceURL)
    }

    /// 读取并导入许可来源（支持 `{seats:[...]}` 对象或裸数组），返回导入结果
    func checkLicenses(from url: URL) -> CheckResult {
        guard let data = try? Data(contentsOf: url) else {
            return CheckResult(imported: 0, source: url.path, updatedAt: nil, error: "无法读取文件：\(url.path)")
        }
        let updatedAt: String?
        let agentSeats: [AgentSeat]
        if let file = try? JSONDecoder().decode(AgentSeatsFile.self, from: data) {
            updatedAt = file.updatedAt
            agentSeats = file.seats
        } else if let arr = try? JSONDecoder().decode([AgentSeat].self, from: data) {
            updatedAt = nil
            agentSeats = arr
        } else {
            return CheckResult(imported: 0, source: url.path, updatedAt: nil, error: "无法解析 seats.json")
        }

        var count = 0
        lock.withLock {
            for seat in agentSeats {
                guard !seat.sub.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let record = SeatRecord(
                    sub: seat.sub,
                    kid: seat.kid ?? "",
                    exp: max(0, seat.exp ?? 0),
                    revoked: seat.revoked ?? false
                )
                if let idx = _seats.firstIndex(where: { $0.sub == record.sub }) {
                    _seats[idx] = record
                } else {
                    _seats.append(record)
                }
                count += 1
            }
            persistLocked()
        }
        return CheckResult(imported: count, source: url.path, updatedAt: updatedAt, error: nil)
    }

    // MARK: - 自动检查（定期读取 seats.json）

    /// 自动检查间隔 UserDefaults key（小时）
    static let checkIntervalKey = "license_check_interval_hours"

    /// 自动检查间隔（小时），默认 6，最小 1，最大 168
    var checkIntervalHours: Double {
        lock.withLock { _checkIntervalHours }
    }

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

    /// 启动定期检查（在 app 启动时调用）
    func startAutoCheck() {
        stopAutoCheck()
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

    /// 停止定期检查
    func stopAutoCheck() {
        lock.withLock {
            checkTimer?.invalidate()
            checkTimer = nil
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
        if !filePath.isEmpty {
            let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(_seats) {
                try? data.write(to: url, options: .atomic)
            }
        }
        // 通知 UI 刷新（异步投递，避免持锁状态下同步回调导致死锁）
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .seatRegistryChanged, object: nil)
        }
    }
}
