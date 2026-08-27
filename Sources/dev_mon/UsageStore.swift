import Foundation
import SQLite3

// MARK: - 定价模型

/// 单个模型的 token 单价（¥ / 1M tokens）
struct ModelPricing: Codable, Equatable, Sendable {
    var label: String
    var hitPrice: Double   // 缓存命中输入
    var missPrice: Double  // 缓存未命中输入
    var outPrice: Double   // 输出

    static let displayedModels: [String] = [
        "deepseek-v4-flash", "deepseek-v4-pro",
        "gpt-4o", "gpt-4o-mini",
        "claude-sonnet-4", "claude-opus-4",
        "kimi-k2.6",
    ]

    static let `default`: [String: ModelPricing] = [
        "deepseek-v4-flash":  ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
        "deepseek-v4-pro":    ModelPricing(label: "V4 Pro",   hitPrice: 0.026, missPrice: 3.13, outPrice: 6.26),
        "deepseek-chat":      ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
        "deepseek-reasoner":  ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0,  outPrice: 2.0),
    ]

    /// OpenAI 定价（USD / 1M tokens）
    static let openaiDefault: [String: ModelPricing] = [
        "gpt-4o-mini": ModelPricing(label: "GPT-4o mini", hitPrice: 0.075, missPrice: 0.15, outPrice: 0.60),
        "gpt-4o":      ModelPricing(label: "GPT-4o",      hitPrice: 1.25,  missPrice: 2.50, outPrice: 10.00),
        "gpt-4.1":     ModelPricing(label: "GPT-4.1",     hitPrice: 0.50,  missPrice: 2.00, outPrice: 8.00),
        "gpt-4":       ModelPricing(label: "GPT-4",       hitPrice: 15.0,  missPrice: 30.0, outPrice: 60.0),
        "o1":          ModelPricing(label: "o1",          hitPrice: 7.5,   missPrice: 15.0, outPrice: 60.0),
        "o3":          ModelPricing(label: "o3",          hitPrice: 1.0,   missPrice: 2.0,  outPrice: 8.0),
        "o4-mini":     ModelPricing(label: "o4-mini",     hitPrice: 0.55,  missPrice: 1.10, outPrice: 4.40),
        "o4":          ModelPricing(label: "o4",          hitPrice: 1.0,   missPrice: 2.0,  outPrice: 8.0),
    ]

    /// Anthropic 定价（USD / 1M tokens）
    static let anthropicDefault: [String: ModelPricing] = [
        "claude-opus-5":       ModelPricing(label: "Claude Opus 5",       hitPrice: 0.50, missPrice: 5.00, outPrice: 25.00),
        "claude-sonnet-5":     ModelPricing(label: "Claude Sonnet 5",     hitPrice: 0.20, missPrice: 2.00, outPrice: 10.00),
        "claude-haiku-4-5":    ModelPricing(label: "Claude Haiku 4.5",    hitPrice: 0.10, missPrice: 1.00, outPrice: 5.00),
        "claude-opus-4-8":     ModelPricing(label: "Claude Opus 4.8",     hitPrice: 0.50, missPrice: 5.00, outPrice: 25.00),
        "claude-opus-4-7":     ModelPricing(label: "Claude Opus 4.7",     hitPrice: 0.50, missPrice: 5.00, outPrice: 25.00),
        "claude-opus-4-6":     ModelPricing(label: "Claude Opus 4.6",     hitPrice: 0.50, missPrice: 5.00, outPrice: 25.00),
        "claude-sonnet-4-6":   ModelPricing(label: "Claude Sonnet 4.6",   hitPrice: 0.30, missPrice: 3.00, outPrice: 15.00),
        "claude-3-5-sonnet": ModelPricing(label: "Claude 3.5 Sonnet", hitPrice: 0.30, missPrice: 3.00, outPrice: 15.00),
        "claude-3-7-sonnet": ModelPricing(label: "Claude 3.7 Sonnet", hitPrice: 0.30, missPrice: 3.00, outPrice: 15.00),
        "claude-sonnet-4":   ModelPricing(label: "Claude Sonnet 4",   hitPrice: 0.30, missPrice: 3.00, outPrice: 15.00),
        "claude-sonnet-4-5": ModelPricing(label: "Claude Sonnet 4.5", hitPrice: 0.30, missPrice: 3.00, outPrice: 15.00),
        "claude-opus-4":     ModelPricing(label: "Claude Opus 4",     hitPrice: 1.50, missPrice: 15.0, outPrice: 75.00),
        "claude-opus-4-1":   ModelPricing(label: "Claude Opus 4.1",   hitPrice: 1.50, missPrice: 15.0, outPrice: 75.00),
        "claude-haiku":      ModelPricing(label: "Claude Haiku",      hitPrice: 0.10, missPrice: 1.00, outPrice: 5.00),
        "claude-haiku-3-5":  ModelPricing(label: "Claude Haiku 3.5",  hitPrice: 0.08, missPrice: 0.80, outPrice: 4.00),
    ]

    /// Kimi 定价（CNY / 1M tokens）
    static let kimiDefault: [String: ModelPricing] = [
        "kimi-k2.6":              ModelPricing(label: "K2.6",     hitPrice: 2.0, missPrice: 4.0, outPrice: 12.0),
        "moonshot-v1-8k":         ModelPricing(label: "V1 8K",    hitPrice: 0.06, missPrice: 0.12, outPrice: 0.12),
        "moonshot-v1-32k":        ModelPricing(label: "V1 32K",   hitPrice: 0.24, missPrice: 0.48, outPrice: 0.48),
        "moonshot-v1-128k":       ModelPricing(label: "V1 128K",  hitPrice: 0.96, missPrice: 1.92, outPrice: 1.92),
        "moonshot-v1-32k-vision-preview": ModelPricing(label: "V1 Vision", hitPrice: 0.24, missPrice: 0.48, outPrice: 0.48),
    ]

    static func forModel(_ model: String, providerId: String? = nil) -> ModelPricing {
        // 1) 全局自定义（用户覆盖）优先
        if let pricing = match(model, in: Self.loadCustom()) { return pricing }
        // 2) 按提供商定价表查询
        switch providerId ?? "" {
        case "openai":
            if let pricing = match(model, in: Self.openaiDefault) { return pricing }
        case "anthropic":
            if let pricing = match(model, in: Self.anthropicDefault) { return pricing }
        case "kimi":
            if let pricing = match(model, in: Self.kimiDefault) { return pricing }
        default:
            if let pricing = match(model, in: Self.default) { return pricing }
        }
        // 3) 兜底：全局默认表，最后 deepseek-v4-flash
        if let pricing = match(model, in: Self.default) { return pricing }
        return Self.default["deepseek-v4-flash"]!
    }

    /// 先精确匹配，再按 key 长度降序做前缀匹配，避免 "gpt-4o" 误配 "gpt-4o-mini"
    private static func match(_ model: String, in table: [String: ModelPricing]) -> ModelPricing? {
        if let exact = table[model] { return exact }
        let keys = table.keys.sorted { $0.count > $1.count }
        for key in keys where model.hasPrefix(key) {
            return table[key]
        }
        return nil
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
        for (key, pricing) in Self.kimiDefault { result[key] = pricing }
        for (key, pricing) in Self.openaiDefault { result[key] = pricing }
        for (key, pricing) in Self.anthropicDefault { result[key] = pricing }
        for (key, pricing) in Self.loadCustom() { result[key] = pricing }
        return result
    }
}

// MARK: - 数据模型

struct UsageRecord: Codable, Sendable {
    let uuid: String
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
    let userAgent: String
    let sourceIP: String
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

/// 按来源（sourceIP）聚合的用量（含最近一次请求时间、该来源使用过的提供商）
struct SourceUsage: Sendable {
    let sourceIP: String
    /// 该来源使用过的去重提供商 id（逗号连接，如 "deepseek,openai"；无则为空字符串）
    let providerIds: String
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let totalCost: Double
    let lastTimestamp: Date
}

// MARK: - SQLite 存储 (actor)

/// 用量数据持久化。所有 public 方法都是 actor-isolated，调用方需 await。
actor UsageStore {
    static let shared = UsageStore()

    private var db: OpaquePointer?

    private static let insertColumns = """
    uuid, timestamp, provider_id, model, endpoint,
    prompt_tokens, completion_tokens, total_tokens, cached_tokens,
    reasoning_tokens, latency_ms, status_code, cost, user_agent, source_ip
    """
    private static let insertValues = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

    private func bindRecord(_ stmt: OpaquePointer, _ record: UsageRecord, cost: Double) {
        sqlite3_bind_text(stmt, 1, record.uuid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, record.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, record.providerId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, record.model, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 5, record.endpoint, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 6, Int64(record.promptTokens))
        sqlite3_bind_int64(stmt, 7, Int64(record.completionTokens))
        sqlite3_bind_int64(stmt, 8, Int64(record.totalTokens))
        sqlite3_bind_int64(stmt, 9, Int64(record.cachedTokens))
        sqlite3_bind_int64(stmt, 10, Int64(record.reasoningTokens))
        sqlite3_bind_double(stmt, 11, record.latencyMs)
        sqlite3_bind_int64(stmt, 12, Int64(record.statusCode))
        sqlite3_bind_double(stmt, 13, cost)
        sqlite3_bind_text(stmt, 14, record.userAgent, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 15, record.sourceIP, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

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
        let appDir = dir.appendingPathComponent("dev_mon")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let path = appDir.appendingPathComponent("usage.db").path

        // 迁移: 从旧路径 DS-mon 复制数据库（如果存在且新路径不存在）
        let oldDir = dir.appendingPathComponent("DS-mon")
        let oldPath = oldDir.appendingPathComponent("usage.db").path
        let newExists = FileManager.default.fileExists(atPath: path)
        let oldExists = FileManager.default.fileExists(atPath: oldPath)
        if oldExists && !newExists {
            try? FileManager.default.copyItem(atPath: oldPath, toPath: path)
            print("[UsageStore] Migrated database from \(oldPath) to \(path)")
        }

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            print("[UsageStore] Failed to open database: \(path)")
            return
        }
        db = handle

        sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)

        // 迁移 V1: 添加 provider_id 列（忽略"列已存在"错误）
        if sqlite3_exec(handle, "ALTER TABLE usage_log ADD COLUMN provider_id TEXT DEFAULT ''", nil, nil, nil) != SQLITE_OK {
            // duplicate column - silently ignored
        }
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
        sqlite3_exec(handle, "CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_dedup ON usage_log(timestamp, model, provider_id, prompt_tokens, completion_tokens)", nil, nil, nil)
        // 迁移 V4: 添加 uuid 列（忽略"列已存在"错误）
        if sqlite3_exec(handle, "ALTER TABLE usage_log ADD COLUMN uuid TEXT DEFAULT ''", nil, nil, nil) != SQLITE_OK {
            // duplicate column - silently ignored
        }
        sqlite3_exec(handle, "UPDATE usage_log SET uuid = hex(randomblob(16)) || '-' || hex(randomblob(16)) WHERE uuid = '' OR uuid IS NULL", nil, nil, nil)
        sqlite3_exec(handle, "CREATE INDEX IF NOT EXISTS idx_usage_uuid ON usage_log(uuid)", nil, nil, nil)
        sqlite3_exec(handle, "CREATE INDEX IF NOT EXISTS idx_usage_src_ts ON usage_log(source_ip, timestamp)", nil, nil, nil)
        // 迁移 V5: 添加 user_agent 列（忽略"列已存在"错误）
        if sqlite3_exec(handle, "ALTER TABLE usage_log ADD COLUMN user_agent TEXT DEFAULT ''", nil, nil, nil) != SQLITE_OK {
            // duplicate column - silently ignored
        }
        // 迁移 V6: 添加 source_ip 列（忽略"列已存在"错误）
        if sqlite3_exec(handle, "ALTER TABLE usage_log ADD COLUMN source_ip TEXT DEFAULT ''", nil, nil, nil) != SQLITE_OK {
            // duplicate column - silently ignored
        }

        backfillCost(handle!)
    }

    /// 关闭数据库连接。在 AppDelegate.applicationWillTerminate 中调用。
    func close() {
        if let db { sqlite3_close(db); self.db = nil }
    }

    // MARK: - 初始化

    private var dbPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("dev_mon")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("usage.db").path
    }

    nonisolated private func backfillCost(_ handle: OpaquePointer) {
        sqlite3_exec(handle, "BEGIN TRANSACTION", nil, nil, nil)
        defer { sqlite3_exec(handle, "COMMIT", nil, nil, nil) }

        let selectSql = """
        SELECT id, model, prompt_tokens, completion_tokens, cached_tokens, provider_id
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
            let providerId = String(cString: sqlite3_column_text(selectStmt, 5))

            let pricing = ModelPricing.forModel(model, providerId: providerId)
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
        let pricing = ModelPricing.forModel(record.model, providerId: record.providerId)
        let cost = ModelPricing.computeCost(
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
            cachedTokens: record.cachedTokens,
            pricing: pricing
        )
        let sql = """
        INSERT INTO usage_log (\(Self.insertColumns))
        VALUES (\(Self.insertValues));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[UsageStore] insert prepare failed: " + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bindRecord(stmt!, record, cost: cost)
        sqlite3_step(stmt)
    }

    // MARK: - 同步接口

    /// 查询指定时间之后的所有记录
    func queryRecords(since date: Date) -> [UsageRecord] {
        guard let db else { return [] }
        let sql = """
        SELECT uuid, timestamp, provider_id, model, endpoint,
               prompt_tokens, completion_tokens, total_tokens, cached_tokens,
               reasoning_tokens, latency_ms, status_code, user_agent, source_ip
        FROM usage_log
        WHERE timestamp > ?
        ORDER BY timestamp ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        defer { sqlite3_finalize(stmt) }

        var records: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = String(cString: sqlite3_column_text(stmt, 0))
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            records.append(UsageRecord(
                uuid: uuid,
                timestamp: ts,
                providerId: String(cString: sqlite3_column_text(stmt, 2)),
                model: String(cString: sqlite3_column_text(stmt, 3)),
                endpoint: String(cString: sqlite3_column_text(stmt, 4)),
                promptTokens: Int(sqlite3_column_int64(stmt, 5)),
                completionTokens: Int(sqlite3_column_int64(stmt, 6)),
                totalTokens: Int(sqlite3_column_int64(stmt, 7)),
                cachedTokens: Int(sqlite3_column_int64(stmt, 8)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 9)),
                latencyMs: sqlite3_column_double(stmt, 10),
                statusCode: Int(sqlite3_column_int64(stmt, 11)),
                userAgent: String(cString: sqlite3_column_text(stmt, 12)),
                sourceIP: String(cString: sqlite3_column_text(stmt, 13))
            ))
        }
        return records
    }

    /// 批量插入（同步用），按 uuid 去重
    func insertRecords(_ records: [UsageRecord]) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO usage_log (\(Self.insertColumns))
        VALUES (\(Self.insertValues));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for record in records {
            let cost = ModelPricing.computeCost(
                promptTokens: record.promptTokens,
                completionTokens: record.completionTokens,
                cachedTokens: record.cachedTokens,
                pricing: ModelPricing.forModel(record.model, providerId: record.providerId)
            )
            bindRecord(stmt!, record, cost: cost)
            sqlite3_step(stmt!)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func recentRecords(limit: Int = 5, providerId: String? = nil, since: Date? = nil) -> [UsageRecord] {
        guard let db else { return [] }
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let hasSince = since != nil
        let sql = """
        SELECT timestamp, model, endpoint, latency_ms, status_code, user_agent, uuid, source_ip, provider_id,
               prompt_tokens, completion_tokens, total_tokens, cached_tokens, reasoning_tokens
        FROM usage_log
        WHERE 1=1\(hasProvider ? " AND provider_id = ?" : "")\(hasSince ? " AND timestamp >= ?" : "")
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            bindIdx += 1
        }
        if let since {
            sqlite3_bind_double(stmt, bindIdx, since.timeIntervalSince1970)
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))
        defer { sqlite3_finalize(stmt) }
        var results: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(UsageRecord(
                uuid: String(cString: sqlite3_column_text(stmt, 6)),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                providerId: String(cString: sqlite3_column_text(stmt, 8)),
                model: String(cString: sqlite3_column_text(stmt, 1)),
                endpoint: String(cString: sqlite3_column_text(stmt, 2)),
                promptTokens: Int(sqlite3_column_int64(stmt, 9)),
                completionTokens: Int(sqlite3_column_int64(stmt, 10)),
                totalTokens: Int(sqlite3_column_int64(stmt, 11)),
                cachedTokens: Int(sqlite3_column_int64(stmt, 12)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 13)),
                latencyMs: sqlite3_column_double(stmt, 3),
                statusCode: Int(sqlite3_column_int64(stmt, 4)),
                userAgent: String(cString: sqlite3_column_text(stmt, 5)),
                sourceIP: String(cString: sqlite3_column_text(stmt, 7))
            ))
        }
        return results
    }

    /// 查询本地最大时间戳（用于增量同步的 since 参数）
    func maxTimestamp() -> Date {
        guard let db else { return Date.distantPast }
        let sql = "SELECT MAX(timestamp) FROM usage_log;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return Date.distantPast }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
        return Date.distantPast
    }

    /// Aggregate usage grouped by source IP for comparison.
    /// - Parameters:
    ///   - since: only include records at/after this date (period filter); nil = all time
    ///   - sourceIP: restrict to one source; nil/empty = all sources
    func aggregateBySourceIP(since: Date? = nil, sourceIP: String? = nil, providerId: String? = nil) -> [SourceUsage] {
        guard let db else { return [] }
        let hasSince = since != nil
        let hasSource = sourceIP.map { !$0.isEmpty } ?? false
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let sql = """
        SELECT source_ip,
               GROUP_CONCAT(DISTINCT CASE WHEN provider_id IS NULL OR provider_id = '' THEN NULL ELSE provider_id END),
               COUNT(*),
               SUM(prompt_tokens), SUM(completion_tokens), SUM(total_tokens),
               SUM(cached_tokens), SUM(cost), MAX(timestamp)
        FROM usage_log
        WHERE 1=1\(hasSince ? " AND timestamp >= ?" : "")\(hasSource ? " AND source_ip = ?" : "")\(hasProvider ? " AND provider_id = ?" : "")
        GROUP BY source_ip
        ORDER BY SUM(cost) DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        if let since {
            sqlite3_bind_double(stmt, bindIdx, since.timeIntervalSince1970)
            bindIdx += 1
        }
        if let src = sourceIP, hasSource {
            sqlite3_bind_text(stmt, bindIdx, src, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            bindIdx += 1
        }
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            bindIdx += 1
        }
        defer { sqlite3_finalize(stmt) }

        var results: [SourceUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ip = String(cString: sqlite3_column_text(stmt, 0))
            let pidPtr = sqlite3_column_text(stmt, 1)
            let providerIds = pidPtr.map { String(cString: $0) } ?? ""
            results.append(SourceUsage(
                sourceIP: ip,
                providerIds: providerIds,
                requestCount: Int(sqlite3_column_int64(stmt, 2)),
                promptTokens: Int(sqlite3_column_int64(stmt, 3)),
                completionTokens: Int(sqlite3_column_int64(stmt, 4)),
                totalTokens: Int(sqlite3_column_int64(stmt, 5)),
                cachedTokens: Int(sqlite3_column_int64(stmt, 6)),
                totalCost: sqlite3_column_double(stmt, 7),
                lastTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            ))
        }
        return results
    }

    /// Distinct non-empty sources for the source filter dropdown
    func distinctSources() -> [String] {
        guard let db else { return [] }
        let sql = """
        SELECT DISTINCT source_ip FROM usage_log
        WHERE source_ip != ''
        ORDER BY source_ip ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return results
    }

    /// Individual usage records, optionally filtered by period + source, newest first.
    /// When `perSourceLimit` is set (and no specific source filter), balances across sources
    /// so a high-volume source (e.g. the local host) can't hide the others.
    func records(since: Date? = nil, sourceIP: String? = nil, providerId: String? = nil, limit: Int = 50, perSourceLimit: Int? = nil) -> [UsageRecord] {
        let hasSource = sourceIP.map { !$0.isEmpty } ?? false
        let balanced = !hasSource && (perSourceLimit != nil)

        if balanced {
            let per = perSourceLimit ?? 50
            let sources = distinctSources()
            var all: [UsageRecord] = []
            for src in sources {
                all.append(contentsOf: sourceRecords(since: since, sourceIP: src, providerId: providerId, limit: per))
            }
            // local (empty/NULL source_ip) partition — always included so it can't be dropped
            all.append(contentsOf: sourceRecords(since: since, sourceIP: "", providerId: providerId, limit: per))
            all.sort { $0.timestamp > $1.timestamp }
            if all.count > limit {
                all = Array(all.prefix(limit))
            }
            return all
        }

        return sourceRecords(since: since, sourceIP: hasSource ? sourceIP : nil, providerId: providerId, limit: limit)
    }

    /// Per-source records query. `sourceIP` = "" matches the local (empty/NULL) partition;
    /// `nil` matches all sources.
    private func sourceRecords(since: Date?, sourceIP: String?, providerId: String?, limit: Int) -> [UsageRecord] {
        guard let db else { return [] }
        let hasSince = since != nil
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let sourceClause: String
        if let src = sourceIP, src.isEmpty {
            sourceClause = " AND (source_ip = '' OR source_ip IS NULL)"
        } else if sourceIP != nil {
            sourceClause = " AND source_ip = ?"
        } else {
            sourceClause = ""
        }
        let sql = """
        SELECT uuid, timestamp, provider_id, model, endpoint,
               prompt_tokens, completion_tokens, total_tokens, cached_tokens,
               reasoning_tokens, latency_ms, status_code, user_agent, source_ip
        FROM usage_log
        WHERE 1=1\(hasSince ? " AND timestamp >= ?" : "")\(sourceClause)\(hasProvider ? " AND provider_id = ?" : "")
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        if let since {
            sqlite3_bind_double(stmt, bindIdx, since.timeIntervalSince1970)
            bindIdx += 1
        }
        if let src = sourceIP, !src.isEmpty {
            sqlite3_bind_text(stmt, bindIdx, src, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            bindIdx += 1
        }
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))
        defer { sqlite3_finalize(stmt) }

        var results: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(UsageRecord(
                uuid: String(cString: sqlite3_column_text(stmt, 0)),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                providerId: String(cString: sqlite3_column_text(stmt, 2)),
                model: String(cString: sqlite3_column_text(stmt, 3)),
                endpoint: String(cString: sqlite3_column_text(stmt, 4)),
                promptTokens: Int(sqlite3_column_int64(stmt, 5)),
                completionTokens: Int(sqlite3_column_int64(stmt, 6)),
                totalTokens: Int(sqlite3_column_int64(stmt, 7)),
                cachedTokens: Int(sqlite3_column_int64(stmt, 8)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 9)),
                latencyMs: sqlite3_column_double(stmt, 10),
                statusCode: Int(sqlite3_column_int64(stmt, 11)),
                userAgent: String(cString: sqlite3_column_text(stmt, 12)),
                sourceIP: String(cString: sqlite3_column_text(stmt, 13))
            ))
        }
        return results
    }

    /// 清理重复的记录（按 timestamp+model+provider_id+prompt_tokens+completion_tokens 组合去重）
    /// 保留最早的一条，在服务端启动时调用
    func deduplicate() -> Int {
        guard let db else { return 0 }
        let countSQL = "SELECT COUNT(*) FROM (SELECT 1 FROM usage_log GROUP BY timestamp, model, provider_id, prompt_tokens, completion_tokens HAVING COUNT(*) > 1);"
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(countStmt) }
        var dupCount = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            dupCount = Int(sqlite3_column_int64(countStmt, 0))
        }
        guard dupCount > 0 else { return 0 }
    
        let delSQL = "DELETE FROM usage_log WHERE rowid NOT IN (SELECT MIN(rowid) FROM usage_log GROUP BY timestamp, model, provider_id, prompt_tokens, completion_tokens);"
        sqlite3_exec(db, delSQL, nil, nil, nil)
        print("[UsageStore] deduplicate: removed \(dupCount) duplicate record groups (by content)")
        return dupCount
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
    func queryHourlyBreakdown(providerId: String? = nil, sourceIP: String? = nil) -> [TokenBar] {
        guard let db else { return [] }
        let todayStart = Calendar.current.startOfDay(for: Date())
        let startTS = todayStart.timeIntervalSince1970
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let hasSource = sourceIP.map { !$0.isEmpty } ?? false
        let sql = """
        SELECT CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS h,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens),
               COUNT(*)
        FROM usage_log
        WHERE timestamp >= ?\(hasProvider ? " AND provider_id = ?" : "")\(hasSource ? " AND source_ip = ?" : "")
        GROUP BY h ORDER BY h ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        sqlite3_bind_double(stmt, bindIdx, startTS); bindIdx += 1
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); bindIdx += 1
        }
        if let src = sourceIP, hasSource {
            sqlite3_bind_text(stmt, bindIdx, src, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); bindIdx += 1
        }
        defer { sqlite3_finalize(stmt) }

        var map: [Int: (Int, Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let h = Int(sqlite3_column_int64(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let hit = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            let cnt = Int(sqlite3_column_int64(stmt, 4))
            map[h] = (m, hit, o, cnt)
        }

        var results: [TokenBar] = []
        for h in 0..<24 {
            let vals = map[h] ?? (0, 0, 0, 0)
            results.append(TokenBar(label: String(format: "%02d:00", h), missTokens: vals.0, hitTokens: vals.1, outTokens: vals.2, requestCount: vals.3))
        }
        return results
    }

    /// 当前小时的缓存命中率（0.0 ~ 1.0），无数据时返回 nil
    func mostRecentCacheHitRate() -> Double? {
        guard let db else { return nil }
        let sql = """
        SELECT prompt_tokens, cached_tokens
        FROM usage_log
        ORDER BY timestamp DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let prompt = Int(sqlite3_column_int64(stmt, 0))
        let cached = Int(sqlite3_column_int64(stmt, 1))
        guard prompt > 0 else { return nil }
        return Double(cached) / Double(prompt)
    }

    func todayCost() -> Double {
        guard let db else { return 0 }
        let todayStart = Calendar.current.startOfDay(for: Date())
        let sql = "SELECT COALESCE(SUM(cost), 0) FROM usage_log WHERE timestamp >= ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_double(stmt, 1, todayStart.timeIntervalSince1970)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    func todayCacheHitRate() -> Double? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!
        return cacheHitRate(start: todayStart, end: todayEnd)
    }

    private func cacheHitRate(start: Date, end: Date) -> Double? {
        guard let db else { return nil }
        let sql = """
        SELECT SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens)
        FROM usage_log
        WHERE timestamp >= ? AND timestamp < ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let miss = Int(sqlite3_column_int64(stmt, 0))
        let hit = Int(sqlite3_column_int64(stmt, 1))
        let total = miss + hit
        guard total > 0 else { return nil }
        return Double(hit) / Double(total)
    }

    /// 本周按日
    func queryDailyBreakdown(providerId: String? = nil, sourceIP: String? = nil) -> [TokenBar] {
        guard let db else { return [] }
        let cal = Calendar.current
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        let startTS = weekStart.timeIntervalSince1970
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let hasSource = sourceIP.map { !$0.isEmpty } ?? false
        let sql = """
        SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens),
               COUNT(*)
        FROM usage_log
        WHERE timestamp >= ?\(hasProvider ? " AND provider_id = ?" : "")\(hasSource ? " AND source_ip = ?" : "")
        GROUP BY day ORDER BY day ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        sqlite3_bind_double(stmt, bindIdx, startTS); bindIdx += 1
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); bindIdx += 1
        }
        if let src = sourceIP, hasSource {
            sqlite3_bind_text(stmt, bindIdx, src, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); bindIdx += 1
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: (Int, Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = String(cString: sqlite3_column_text(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let h = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            let cnt = Int(sqlite3_column_int64(stmt, 4))
            map[day] = (m, h, o, cnt)
        }

        var results: [TokenBar] = []
        for i in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: i, to: weekStart) else { continue }
            let key = Self.dayLookupFormatter.string(from: day)
            let vals = map[key] ?? (0, 0, 0, 0)
            results.append(TokenBar(label: day.formatted(Self.labelFormat), missTokens: vals.0, hitTokens: vals.1, outTokens: vals.2, requestCount: vals.3))
        }
        return results
    }

    /// 本月按周
    func queryWeeklyBreakdown(providerId: String? = nil, sourceIP: String? = nil) -> [TokenBar] {
        guard let db else { return [] }
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart)!
        let startTS = monthStart.timeIntervalSince1970
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let hasSource = sourceIP.map { !$0.isEmpty } ?? false
        let sql = """
        SELECT strftime('%G-V%V', timestamp, 'unixepoch', 'localtime') AS week,
               SUM(MAX(0, prompt_tokens - cached_tokens)),
               SUM(cached_tokens),
               SUM(completion_tokens),
               COUNT(*)
        FROM usage_log
        WHERE timestamp >= ?\(hasProvider ? " AND provider_id = ?" : "")\(hasSource ? " AND source_ip = ?" : "")
        GROUP BY week ORDER BY week ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        sqlite3_bind_double(stmt, bindIdx, startTS); bindIdx += 1
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); bindIdx += 1
        }
        if let src = sourceIP, hasSource {
            sqlite3_bind_text(stmt, bindIdx, src, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); bindIdx += 1
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: (Int, Int, Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let weekStr = String(cString: sqlite3_column_text(stmt, 0))
            let m = Int(sqlite3_column_int64(stmt, 1))
            let h = Int(sqlite3_column_int64(stmt, 2))
            let o = Int(sqlite3_column_int64(stmt, 3))
            let cnt = Int(sqlite3_column_int64(stmt, 4))
            map[weekStr] = (m, h, o, cnt)
        }

        var results: [TokenBar] = []
        var cursor = monthStart
        while cursor <= monthEnd {
            let wk = _isoWeekKey(cursor)
            let vals = map[wk] ?? (0, 0, 0, 0)
            results.append(TokenBar(label: cursor.formatted(Self.labelFormat), missTokens: vals.0, hitTokens: vals.1, outTokens: vals.2, requestCount: vals.3))
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
        let hasProvider = providerId.map { !$0.isEmpty } ?? false
        let sql = """
        SELECT \(period.sqlExpr) AS period,
               COUNT(*) AS req_count,
               SUM(prompt_tokens), SUM(completion_tokens), SUM(total_tokens),
               SUM(cached_tokens), SUM(reasoning_tokens),
               AVG(latency_ms),
               COALESCE(SUM(cost), 0)
        FROM usage_log\(hasProvider ? " WHERE provider_id = ?" : "")
        GROUP BY period
        ORDER BY period DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bindIdx: Int32 = 1
        if let pid = providerId, hasProvider {
            sqlite3_bind_text(stmt, bindIdx, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))
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
    let requestCount: Int
    var id: String { label }
}
