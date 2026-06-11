import Foundation
import SQLite3

// MARK: - 定价模型

/// 单个模型的 token 单价（¥ / 1M tokens）
struct ModelPricing: Codable, Equatable, Sendable {
    var label: String
    var hitPrice: Double   // 缓存命中输入
    var missPrice: Double  // 缓存未命中输入
    var outPrice: Double   // 输出

    static let displayedModels: [String] = ["deepseek-v4-flash", "deepseek-v4-pro"]

    static let `default`: [String: ModelPricing] = [
        "deepseek-v4-flash":  ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
        "deepseek-v4-pro":    ModelPricing(label: "V4 Pro",   hitPrice: 0.026, missPrice: 3.13, outPrice: 6.26),
        "deepseek-chat":      ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
        "deepseek-reasoner":  ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
    ]

    static func forModel(_ model: String, providerId: String? = nil) -> ModelPricing {
        // 先查该提供商的定价
        if let pid = providerId {
            let providers = ProviderConfig.loadAll()
            if let provider = providers.first(where: { $0.id == pid }) {
                for (key, pricing) in provider.pricingOverrides {
                    if model == key || model.hasPrefix(key) { return pricing }
                }
            }
        }
        // 查全局自定义
        let custom = Self.loadCustom()
        for (key, pricing) in custom {
            if model == key || model.hasPrefix(key) { return pricing }
        }
        // 查内置默认
        for (key, pricing) in Self.default {
            if model == key || model.hasPrefix(key) { return pricing }
        }
        return Self.default["deepseek-v4-flash"]!
    }

    static func computeCost(promptTokens: Int, completionTokens: Int,
                            cachedTokens: Int, pricing: ModelPricing, providerId: String? = nil) -> Double {
        let missInput = Double(promptTokens - cachedTokens) / 1_000_000 * pricing.missPrice
        let hitInput  = Double(cachedTokens) / 1_000_000 * pricing.hitPrice
        let output    = Double(completionTokens) / 1_000_000 * pricing.outPrice
        return missInput + hitInput + output
    }

    private static let storageKey = Strings.Keys.modelPricingOverrides

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
    let providerId: String
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
    let period: String
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let avgLatencyMs: Double
    let estimatedCost: Double
    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cachedTokens) / Double(promptTokens) * 100 : 0
    }
}

// MARK: - SQLite 存储 (actor)

/// 用量数据持久化。所有 public 方法都是 actor-isolated，调用方需 await。
actor UsageStore {
    static let shared = UsageStore()

    nonisolated(unsafe) private var db: OpaquePointer?

    private static let dayLookupFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
    private static let labelFormat: Date.FormatStyle = .dateTime.month(.defaultDigits).day()

    private init() {
        // Actor init is non-isolated; inline DB setup
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("DS-mon")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let path = appDir.appendingPathComponent("usage.db").path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            print("[UsageStore] Failed to open database: \(path)")
            return
        }
        db = handle

        sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)

        // 迁移 V1: 添加 provider_id 列（如果不存在）
        sqlite3_exec(handle, "ALTER TABLE usage_log ADD COLUMN provider_id TEXT DEFAULT ''", nil, nil, nil)
        // 迁移 V2: 旧版数据（provider_id 为空）统一迁移给 DeepSeek（只执行一次）
        let migratedV2Key = "usage_store_migrated_v2"
        if !UserDefaults.standard.bool(forKey: migratedV2Key) {
            sqlite3_exec(handle, "UPDATE usage_log SET provider_id = 'deepseek' WHERE provider_id = '' OR provider_id IS NULL", nil, nil, nil)
            UserDefaults.standard.set(true, forKey: migratedV2Key)
            print("[UsageStore] 已迁移旧数据 provider_id → deepseek")
        }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            provider_id TEXT DEFAULT '',
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
        sqlite3_exec(handle, createSQL, nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE usage_log ADD COLUMN cost REAL DEFAULT 0;", nil, nil, nil)

        backfillCost(handle!)
    }

    /// 关闭数据库连接。在 AppDelegate.applicationWillTerminate 中调用。
    func close() {
        if let db { sqlite3_close(db); self.db = nil }
    }

    // MARK: - 初始化

    private var dbPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("DS-mon")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("usage.db").path
    }

    nonisolated private func backfillCost(_ handle: OpaquePointer) {
        sqlite3_exec(handle, "BEGIN TRANSACTION", nil, nil, nil)
        defer { sqlite3_exec(handle, "COMMIT", nil, nil, nil) }

        let selectSql = """
        SELECT id, model, prompt_tokens, completion_tokens, cached_tokens
        FROM usage_log WHERE cost = 0;
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        let updateSql = "UPDATE usage_log SET cost = ? WHERE id = ?;"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(updateStmt) }

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(selectStmt, 0)
            let model = String(cString: sqlite3_column_text(selectStmt, 1))
            let pt = Int(sqlite3_column_int64(selectStmt, 2))
            let ct = Int(sqlite3_column_int64(selectStmt, 3))
            let ca = Int(sqlite3_column_int64(selectStmt, 4))

            let pricing = ModelPricing.forModel(model)
            let cost = ModelPricing.computeCost(promptTokens: pt, completionTokens: ct, cachedTokens: ca, pricing: pricing)

            sqlite3_bind_double(updateStmt, 1, cost)
            sqlite3_bind_int64(updateStmt, 2, id)
            sqlite3_step(updateStmt)
            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
        }
    }

    // MARK: - 写入

    func insert(_ record: UsageRecord) {
        guard let db else { return }
        let pricing = ModelPricing.forModel(record.model)
        let cost = ModelPricing.computeCost(
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
            cachedTokens: record.cachedTokens,
            pricing: pricing
        )
        let sql = """
        INSERT INTO usage_log (timestamp, provider_id, model, endpoint, prompt_tokens, completion_tokens,
          total_tokens, cached_tokens, reasoning_tokens, latency_ms, status_code, cost)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] insert prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return
        }
        sqlite3_bind_double(stmt, 1, record.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, record.providerId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, record.model, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, record.endpoint, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 5, Int64(record.promptTokens))
        sqlite3_bind_int64(stmt, 6, Int64(record.completionTokens))
        sqlite3_bind_int64(stmt, 7, Int64(record.totalTokens))
        sqlite3_bind_int64(stmt, 8, Int64(record.cachedTokens))
        sqlite3_bind_int64(stmt, 9, Int64(record.reasoningTokens))
        sqlite3_bind_double(stmt, 10, record.latencyMs)
        sqlite3_bind_int64(stmt, 11, Int64(record.statusCode))
        sqlite3_bind_double(stmt, 12, cost)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - 聚合查询

    func queryDaily(limit: Int = 30, providerId: String? = nil) -> [AggregatedUsage] {
        queryAggregated(period: .daily, limit: limit, providerId: providerId)
    }

    func queryWeekly(limit: Int = 12, providerId: String? = nil) -> [AggregatedUsage] {
        queryAggregated(period: .weekly, limit: limit, providerId: providerId)
    }

    func queryMonthly(limit: Int = 12, providerId: String? = nil) -> [AggregatedUsage] {
        queryAggregated(period: .monthly, limit: limit, providerId: providerId)
    }

    /// 今日按小时
    func queryHourlyBreakdown(providerId: String? = nil) -> [TokenBar] {
        guard let db else { return [] }
        let todayStart = Calendar.current.startOfDay(for: Date())
        let startTS = todayStart.timeIntervalSince1970
        let whereClause = providerId.map { " AND provider_id = '\($0)'" } ?? ""
        let sql = """
        SELECT CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS h,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens)
        FROM usage_log
        WHERE timestamp >= ?\(whereClause)
        GROUP BY h ORDER BY h ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, startTS)
        defer { sqlite3_finalize(stmt) }

        var map: [Int: (Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let h = Int(sqlite3_column_int64(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let hit = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            map[h] = (m, hit, o)
        }

        var results: [TokenBar] = []
        for h in 0..<24 {
            let vals = map[h] ?? (0, 0, 0)
            results.append(TokenBar(label: String(format: "%02d:00", h), missTokens: vals.0, hitTokens: vals.1, outTokens: vals.2))
        }
        return results
    }

    /// 当前小时的缓存命中率（0.0 ~ 1.0），无数据时返回 nil
    nonisolated func currentHourCacheHitRate() -> Double? {
        guard let db else { return nil }
        let cal = Calendar.current
        let now = Date()
        let hourStart = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: now))!
        let hourEnd = cal.date(byAdding: .hour, value: 1, to: hourStart)!
        let sql = """
        SELECT SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens)
        FROM usage_log
        WHERE timestamp >= ? AND timestamp < ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_double(stmt, 1, hourStart.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, hourEnd.timeIntervalSince1970)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let miss = Int(sqlite3_column_int64(stmt, 0))
        let hit = Int(sqlite3_column_int64(stmt, 1))
        let total = miss + hit
        guard total > 0 else { return nil }
        return Double(hit) / Double(total)
    }

    /// 今日缓存命中率（0.0 ~ 1.0），无数据时返回 nil
    nonisolated func todayCacheHitRate() -> Double? {
        guard let db else { return nil }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let sql = """
        SELECT SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens)
        FROM usage_log
        WHERE timestamp >= ? AND timestamp < ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_double(stmt, 1, todayStart.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, todayEnd.timeIntervalSince1970)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let miss = Int(sqlite3_column_int64(stmt, 0))
        let hit = Int(sqlite3_column_int64(stmt, 1))
        let total = miss + hit
        guard total > 0 else { return nil }
        return Double(hit) / Double(total)
    }

    /// 本周按日
    func queryDailyBreakdown(providerId: String? = nil) -> [TokenBar] {
        guard let db else { return [] }
        let cal = Calendar.current
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        let startTS = weekStart.timeIntervalSince1970
        let whereClause = providerId.map { " AND provider_id = '\($0)'" } ?? ""
        let sql = """
        SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens)
        FROM usage_log
        WHERE timestamp >= ?\(whereClause)
        GROUP BY day ORDER BY day ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, startTS)
        defer { sqlite3_finalize(stmt) }

        var map: [String: (Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = String(cString: sqlite3_column_text(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let h = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            map[day] = (m, h, o)
        }

        var results: [TokenBar] = []
        for i in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: i, to: weekStart) else { continue }
            let key = Self.dayLookupFormatter.string(from: day)
            let vals = map[key] ?? (0, 0, 0)
            results.append(TokenBar(label: day.formatted(Self.labelFormat), missTokens: vals.0, hitTokens: vals.1, outTokens: vals.2))
        }
        return results
    }

    /// 本月按周
    func queryWeeklyBreakdown(providerId: String? = nil) -> [TokenBar] {
        guard let db else { return [] }
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart)!
        let startTS = monthStart.timeIntervalSince1970
        let whereClause = providerId.map { " AND provider_id = '\($0)'" } ?? ""
        let sql = """
        SELECT strftime('%G-V%V', timestamp, 'unixepoch', 'localtime') AS week,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens)
        FROM usage_log
        WHERE timestamp >= ?\(whereClause)
        GROUP BY week ORDER BY week ASC;
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

        var results: [TokenBar] = []
        var cursor = monthStart
        while cursor <= monthEnd {
            let wk = _isoWeekKey(cursor)
            let vals = map[wk] ?? (0, 0, 0)
            results.append(TokenBar(label: cursor.formatted(Self.labelFormat), missTokens: vals.0, hitTokens: vals.1, outTokens: vals.2))
            cursor = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? cursor
        }
        return results
    }

    private func _isoWeekKey(_ date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.yearForWeekOfYear, from: date)
        let w = cal.component(.weekOfYear, from: date)
        return String(format: "%d-V%02d", y, w)
    }

    private enum AggregationPeriod {
        case daily, weekly, monthly
        var sqlExpr: String {
            switch self {
            case .daily:   return "date(timestamp, 'unixepoch', 'localtime')"
            case .weekly:  return "strftime('%Y-W%W', timestamp, 'unixepoch', 'localtime')"
            case .monthly: return "strftime('%Y-%m', timestamp, 'unixepoch', 'localtime')"
            }
        }
    }

    private func queryAggregated(period: AggregationPeriod, limit: Int, providerId: String? = nil) -> [AggregatedUsage] {
        guard let db else { return [] }
        let whereClause = providerId.map { " WHERE provider_id = '\($0)'" } ?? ""
        let sql = """
        SELECT \(period.sqlExpr) AS period,
               COUNT(*) AS req_count,
               SUM(prompt_tokens), SUM(completion_tokens), SUM(total_tokens),
               SUM(cached_tokens), SUM(reasoning_tokens),
               AVG(latency_ms),
               COALESCE(SUM(cost), 0)
        FROM usage_log\(whereClause)
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
                avgLatencyMs: sqlite3_column_double(stmt, 7),
                estimatedCost: sqlite3_column_double(stmt, 8)
            ))
        }
        return results
    }
}

// MARK: - 柱状图数据

struct TokenBar: Identifiable, Sendable {
    let label: String
    let missTokens: Int
    let hitTokens: Int
    let outTokens: Int
    var id: String { label }
}
