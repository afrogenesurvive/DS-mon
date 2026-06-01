import Foundation
import SQLite3

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
    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cachedTokens) / Double(promptTokens) * 100 : 0
    }
    var estimatedCost: Double {
        let missInput = Double(promptTokens - cachedTokens) / 1_000_000 * 1.0
        let hitInput  = Double(cachedTokens) / 1_000_000 * 0.02
        let output    = Double(completionTokens) / 1_000_000 * 2.0
        return missInput + hitInput + output
    }
}

// MARK: - SQLite 存储

final class UsageStore: @unchecked Sendable {
    static let shared = UsageStore()

    private var db: OpaquePointer?
    private let lock = NSLock()

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
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
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
            status_code INTEGER DEFAULT 200
        );
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_log(timestamp);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - 写入

    func insert(_ record: UsageRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let sql = """
        INSERT INTO usage_log (timestamp, model, endpoint, prompt_tokens, completion_tokens,
          total_tokens, cached_tokens, reasoning_tokens, latency_ms, status_code)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - 聚合查询

    /// 按天聚合（最近 N 天）
    func queryDaily(limit: Int = 30) -> [AggregatedUsage] {
        let groupExpr = "date(timestamp, 'unixepoch', 'localtime')"
        return queryAggregated(groupBy: groupExpr, groupLabel: groupExpr, limit: limit)
    }

    /// 按周聚合（最近 N 周）
    func queryWeekly(limit: Int = 12) -> [AggregatedUsage] {
        let groupExpr = "strftime('%Y-W%W', timestamp, 'unixepoch', 'localtime')"
        return queryAggregated(groupBy: groupExpr, groupLabel: groupExpr, limit: limit)
    }

    /// 按月聚合（最近 N 月）
    func queryMonthly(limit: Int = 12) -> [AggregatedUsage] {
        let groupExpr = "strftime('%Y-%m', timestamp, 'unixepoch', 'localtime')"
        return queryAggregated(groupBy: groupExpr, groupLabel: groupExpr, limit: limit)
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, startTS)
        defer { sqlite3_finalize(stmt) }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let labelFmt = DateFormatter()
        labelFmt.dateFormat = "M/d"
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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

        let labelFmt = DateFormatter()
        labelFmt.dateFormat = "M/d"
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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt.date(from: dayStr)
    }

    private func _isoWeekKey(_ date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.yearForWeekOfYear, from: date)
        let w = cal.component(.weekOfYear, from: date)
        return String(format: "%d-V%02d", y, w)
    }

    private func queryAggregated(groupBy: String, groupLabel: String, limit: Int) -> [AggregatedUsage] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = """
        SELECT \(groupLabel) AS period,
               COUNT(*) AS req_count,
               SUM(prompt_tokens), SUM(completion_tokens), SUM(total_tokens),
               SUM(cached_tokens), SUM(reasoning_tokens),
               AVG(latency_ms)
        FROM usage_log
        GROUP BY period
        ORDER BY period DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
                avgLatencyMs: sqlite3_column_double(stmt, 7)
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
