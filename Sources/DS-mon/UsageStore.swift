import Foundation
import SQLite3

// MARK: - 定价模型

/// 单个模型的 token 单价（USD / 1M tokens）
struct ModelPricing: Codable, Equatable, Sendable {
    var label: String
    var hitPrice: Double   // 缓存命中输入
    var missPrice: Double  // 缓存未命中输入
    var outPrice: Double   // 输出

    /// 仅列出主要模型。deprecated 别名（deepseek-chat, deepseek-reasoner）也在 forModel 中匹配
    static let displayedModels: [String] = ["deepseek-v4-flash", "deepseek-v4-pro"]

    static let `default`: [String: ModelPricing] = [
        "deepseek-v4-flash":  ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
        "deepseek-v4-pro":    ModelPricing(label: "V4 Pro",   hitPrice: 0.026, missPrice: 3.13, outPrice: 6.26),
        "deepseek-chat":      ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
        "deepseek-reasoner":  ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
    ]

    /// 根据模型名匹配定价（前缀匹配：deepseek-v4-flash → flash 定价）
    static func forModel(_ model: String) -> ModelPricing {
        let custom = Self.loadCustom()
        // 自定义覆盖优先
        for (key, pricing) in custom {
            if model == key || model.hasPrefix(key) { return pricing }
        }
        // 内置默认
        for (key, pricing) in Self.default {
            if model == key || model.hasPrefix(key) { return pricing }
        }
        return Self.default["deepseek-v4-flash"]!
    }

    /// 计算单次请求的预估费用
    static func computeCost(promptTokens: Int, completionTokens: Int,
                            cachedTokens: Int, pricing: ModelPricing) -> Double {
        let missInput = Double(promptTokens - cachedTokens) / 1_000_000 * pricing.missPrice
        let hitInput  = Double(cachedTokens) / 1_000_000 * pricing.hitPrice
        let output    = Double(completionTokens) / 1_000_000 * pricing.outPrice
        return missInput + hitInput + output
    }

    // MARK: - 用户自定义定价（存 UserDefaults JSON）

    private static let storageKey = "model_pricing_overrides"

    static func loadCustom() -> [String: ModelPricing] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let dict = try? JSONDecoder().decode([String: ModelPricing].self, from: data)
        else { return [:] }
        return dict
    }

    static func saveCustom(_ overrides: [String: ModelPricing]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func resetCustom() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 合并后的完整定价表（默认 + 自定义覆盖）
    static var allWithOverrides: [String: ModelPricing] {
        var result = Self.default
        for (key, pricing) in Self.loadCustom() {
            result[key] = pricing
        }
        return result
    }
}

// MARK: - 数据模型

struct UsageRecord: Sendable {
    let timestamp: Date
    let model: String
    let endpoint: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let latencyMs: Double
    let statusCode: Int
}

struct AggregatedUsage: Sendable {
    let period: String            // "2026-06-01" / "2026-W22" / "2026-06"
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let avgLatencyMs: Double
    let estimatedCost: Double     // 来自 SUM(cost)，按各自模型定价计算
    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cachedTokens) / Double(promptTokens) * 100 : 0
    }
}

// MARK: - SQLite 存储

final class UsageStore: @unchecked Sendable {
    static let shared = UsageStore()

    private var db: OpaquePointer?
    private let lock = NSLock()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private init() {
        openDatabase()
        createTables()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 初始化

    private var dbPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("DS-mon")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("usage.db").path
    }

    private func openDatabase() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[UsageStore] Failed to open database: \(dbPath)")
            return
        }
        // WAL 模式，支持并发读
        if sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) != SQLITE_OK {
            print("[UsageStore] Failed to set WAL mode: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            model TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            prompt_tokens INTEGER DEFAULT 0,
            completion_tokens INTEGER DEFAULT 0,
            total_tokens INTEGER DEFAULT 0,
            cached_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            latency_ms REAL DEFAULT 0,
            status_code INTEGER DEFAULT 200,
            cost REAL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_log(timestamp);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("[UsageStore] Failed to create tables: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
        }
        // 兼容旧表：可能没有 cost 列
        if sqlite3_exec(db, "ALTER TABLE usage_log ADD COLUMN cost REAL DEFAULT 0;", nil, nil, nil) != SQLITE_OK {
            print("[UsageStore] ALTER TABLE add cost: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
        }
        backfillCost()
    }

    /// 为旧记录回填 cost（按各自模型定价计算）
    private func backfillCost() {
        let selectSql = """
        SELECT id, model, prompt_tokens, completion_tokens, cached_tokens
        FROM usage_log WHERE cost = 0;
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            print("[UsageStore] backfill select prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return
        }
        defer { sqlite3_finalize(selectStmt) }

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(selectStmt, 0)
            let model = String(cString: sqlite3_column_text(selectStmt, 1))
            let pt = Int(sqlite3_column_int64(selectStmt, 2))
            let ct = Int(sqlite3_column_int64(selectStmt, 3))
            let ca = Int(sqlite3_column_int64(selectStmt, 4))

            let pricing = ModelPricing.forModel(model)
            let cost = ModelPricing.computeCost(promptTokens: pt, completionTokens: ct, cachedTokens: ca, pricing: pricing)

            let updateSql = "UPDATE usage_log SET cost = ? WHERE id = ?;"
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
                print("[UsageStore] backfill update prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
                continue
            }
            sqlite3_bind_double(updateStmt, 1, cost)
            sqlite3_bind_int64(updateStmt, 2, id)
            sqlite3_step(updateStmt)
            sqlite3_finalize(updateStmt)
        }
    }

    // MARK: - 写入

    func insert(_ record: UsageRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        // 按模型定价计算单次请求费用
        let pricing = ModelPricing.forModel(record.model)
        let cost = ModelPricing.computeCost(
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
            cachedTokens: record.cachedTokens,
            pricing: pricing
        )
        let sql = """
        INSERT INTO usage_log (timestamp, model, endpoint, prompt_tokens, completion_tokens,
          total_tokens, cached_tokens, reasoning_tokens, latency_ms, status_code, cost)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] insert prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return
        }
        sqlite3_bind_double(stmt, 1, record.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, record.model, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, record.endpoint, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 4, Int64(record.promptTokens))
        sqlite3_bind_int64(stmt, 5, Int64(record.completionTokens))
        sqlite3_bind_int64(stmt, 6, Int64(record.totalTokens))
        sqlite3_bind_int64(stmt, 7, Int64(record.cachedTokens))
        sqlite3_bind_int64(stmt, 8, Int64(record.reasoningTokens))
        sqlite3_bind_double(stmt, 9, record.latencyMs)
        sqlite3_bind_int64(stmt, 10, Int64(record.statusCode))
        sqlite3_bind_double(stmt, 11, cost)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - 聚合查询

    /// 按天聚合（最近 N 天）
    func queryDaily(limit: Int = 30) -> [AggregatedUsage] {
        return queryAggregated(period: .daily, limit: limit)
    }

    /// 按周聚合（最近 N 周）
    func queryWeekly(limit: Int = 12) -> [AggregatedUsage] {
        return queryAggregated(period: .weekly, limit: limit)
    }

    /// 按月聚合（最近 N 月）
    func queryMonthly(limit: Int = 12) -> [AggregatedUsage] {
        return queryAggregated(period: .monthly, limit: limit)
    }

    // MARK: - 柱状图明细查询

    /// 今日按小时（固定 24 格）
    func queryHourlyBreakdown() -> [TokenBar] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let sql = """
        SELECT CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS hour,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens)
        FROM usage_log
        WHERE timestamp >= ?
        GROUP BY hour
        ORDER BY hour ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] queryHourlyBreakdown prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return []
        }
        sqlite3_bind_double(stmt, 1, todayStart)
        defer { sqlite3_finalize(stmt) }

        var map: [Int: (Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hour = Int(sqlite3_column_int64(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let h = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            map[hour] = (m, h, o)
        }

        var results: [TokenBar] = []
        for hour in 0..<24 {
            let vals = map[hour] ?? (0, 0, 0)
            results.append(TokenBar(
                label: String(format: "%02d:00", hour),
                missTokens: vals.0,
                hitTokens: vals.1,
                outTokens: vals.2
            ))
        }
        return results
    }

    /// 本周按日（固定 7 格，周一起）
    func queryDailyBreakdown() -> [TokenBar] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let cal = Calendar.current
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        let startTS = weekStart.timeIntervalSince1970
        let sql = """
        SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens)
        FROM usage_log
        WHERE timestamp >= ?
        GROUP BY day
        ORDER BY day ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] queryDailyBreakdown prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return []
        }
        sqlite3_bind_double(stmt, 1, startTS)
        defer { sqlite3_finalize(stmt) }

        let dayFmt = Self.dayFormatter
        let labelFmt = Self.labelFormatter
        var map: [String: (Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dayStr = String(cString: sqlite3_column_text(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let h = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            map[dayStr] = (m, h, o)
        }

        var results: [TokenBar] = []
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let dayStr = dayFmt.string(from: day)
            let vals = map[dayStr] ?? (0, 0, 0)
            results.append(TokenBar(
                label: labelFmt.string(from: day),
                missTokens: vals.0,
                hitTokens: vals.1,
                outTokens: vals.2
            ))
        }
        return results
    }

    /// 本月按周（固定当月所有 ISO 周）
    func queryWeeklyBreakdown() -> [TokenBar] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart)!
        let startTS = monthStart.timeIntervalSince1970
        let sql = """
        SELECT strftime('%G-V%V', timestamp, 'unixepoch', 'localtime') AS week,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens)
        FROM usage_log
        WHERE timestamp >= ?
        GROUP BY week
        ORDER BY week ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] queryWeeklyBreakdown prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return []
        }
        sqlite3_bind_double(stmt, 1, startTS)
        defer { sqlite3_finalize(stmt) }

        var map: [String: (Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let weekStr = String(cString: sqlite3_column_text(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let h = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            map[weekStr] = (m, h, o)
        }

        let labelFmt = Self.labelFormatter
        var results: [TokenBar] = []
        var cursor = monthStart
        while cursor <= monthEnd {
            let wk = _isoWeekKey(cursor)
            let vals = map[wk] ?? (0, 0, 0)
            results.append(TokenBar(
                label: labelFmt.string(from: cursor),
                missTokens: vals.0,
                hitTokens: vals.1,
                outTokens: vals.2
            ))
            cursor = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? cursor
        }
        return results
    }

    private func _date(from dayStr: String) -> Date? {
        let fmt = Self.dateParser
        return fmt.date(from: dayStr)
    }

    private func _isoWeekKey(_ date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.yearForWeekOfYear, from: date)
        let w = cal.component(.weekOfYear, from: date)
        return String(format: "%d-V%02d", y, w)
    }

    private enum AggregationPeriod {
        case daily
        case weekly
        case monthly

        var sqlExpr: String {
            switch self {
            case .daily:   return "date(timestamp, 'unixepoch', 'localtime')"
            case .weekly:  return "strftime('%Y-W%W', timestamp, 'unixepoch', 'localtime')"
            case .monthly: return "strftime('%Y-%m', timestamp, 'unixepoch', 'localtime')"
            }
        }
    }

    private func queryAggregated(period: AggregationPeriod, limit: Int) -> [AggregatedUsage] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = """
        SELECT \(period.sqlExpr) AS period,
               COUNT(*) AS req_count,
               SUM(prompt_tokens), SUM(completion_tokens), SUM(total_tokens),
               SUM(cached_tokens), SUM(reasoning_tokens),
               AVG(latency_ms),
               COALESCE(SUM(cost), 0)
        FROM usage_log
        GROUP BY period
        ORDER BY period DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] queryAggregated prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return []
        }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        defer { sqlite3_finalize(stmt) }

        var results: [AggregatedUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let period = String(cString: sqlite3_column_text(stmt, 0))
            results.append(AggregatedUsage(
                period: period,
                requestCount: Int(sqlite3_column_int64(stmt, 1)),
                promptTokens: Int(sqlite3_column_int64(stmt, 2)),
                completionTokens: Int(sqlite3_column_int64(stmt, 3)),
                totalTokens: Int(sqlite3_column_int64(stmt, 4)),
                cachedTokens: Int(sqlite3_column_int64(stmt, 5)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 6)),
                avgLatencyMs: sqlite3_column_double(stmt, 7),
                estimatedCost: sqlite3_column_double(stmt, 8)
            ))
        }
        return results
    }
}

// MARK: - 柱状图数据

struct TokenBar: Identifiable {
    let label: String
    let missTokens: Int
    let hitTokens: Int
    let outTokens: Int
    var id: String { label }
}
