import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 导出数据模型（verbose）

struct UsageExportPayload: Codable {
    let format: String
    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String
    let summary: PeriodSummary
    let periods: Periods
    let breakdowns: Breakdowns
    let providers: [ProviderExport]
    let bySource: [SourceUsageExport]
    let records: [UsageRecord]
}

struct PeriodSummary: Codable {
    let today: AggregatedUsageExport?
    let week: AggregatedUsageExport?
    let month: AggregatedUsageExport?
    let allTime: AggregatedUsageExport?
}

struct Periods: Codable {
    let daily: [AggregatedUsageExport]
    let weekly: [AggregatedUsageExport]
    let monthly: [AggregatedUsageExport]
}

struct Breakdowns: Codable {
    let todayByHour: [TokenBarExport]
    let weekByDay: [TokenBarExport]
    let monthByWeek: [TokenBarExport]
}

struct ProviderExport: Codable {
    let providerId: String
    let name: String
    let summary: PeriodSummary
    let daily: [AggregatedUsageExport]
    let weekly: [AggregatedUsageExport]
    let monthly: [AggregatedUsageExport]
}

struct AggregatedUsageExport: Codable {
    let period: String
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let avgLatencyMs: Double
    let estimatedCost: Double
    let cacheHitRate: Double

    init(_ a: AggregatedUsage) {
        self.init(period: a.period, requestCount: a.requestCount,
                  promptTokens: a.promptTokens, completionTokens: a.completionTokens,
                  totalTokens: a.totalTokens, cachedTokens: a.cachedTokens,
                  reasoningTokens: a.reasoningTokens, avgLatencyMs: a.avgLatencyMs,
                  estimatedCost: a.estimatedCost, cacheHitRate: a.cacheHitRate)
    }

    init(period: String, requestCount: Int, promptTokens: Int, completionTokens: Int,
         totalTokens: Int, cachedTokens: Int, reasoningTokens: Int,
         avgLatencyMs: Double, estimatedCost: Double, cacheHitRate: Double) {
        self.period = period
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.avgLatencyMs = avgLatencyMs
        self.estimatedCost = estimatedCost
        self.cacheHitRate = cacheHitRate
    }
}

struct SourceUsageExport: Codable {
    let sourceIP: String
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let totalCost: Double
    let lastTimestamp: Date

    init(_ s: SourceUsage) {
        sourceIP = s.sourceIP
        requestCount = s.requestCount
        promptTokens = s.promptTokens
        completionTokens = s.completionTokens
        totalTokens = s.totalTokens
        cachedTokens = s.cachedTokens
        totalCost = s.totalCost
        lastTimestamp = s.lastTimestamp
    }
}

struct TokenBarExport: Codable {
    let label: String
    let missTokens: Int
    let hitTokens: Int
    let outTokens: Int
    let requestCount: Int

    init(_ t: TokenBar) {
        label = t.label
        missTokens = t.missTokens
        hitTokens = t.hitTokens
        outTokens = t.outTokens
        requestCount = t.requestCount
    }
}

// MARK: - 导出器

/// 导出全部用量数据为 verbose JSON（通过文件选择器选择保存位置）。
enum UsageExporter {

    /// 弹出保存面板并把完整用量数据导出为 JSON
    @MainActor
    static func exportUsage() {
        let panel = NSSavePanel()
        panel.title = Strings.exportUsageTitle
        panel.prompt = Strings.exportUsageSave
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let payload = await buildPayload()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                guard let data = try? encoder.encode(payload) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "dev-mon-usage-\(f.string(from: Date())).json"
    }

    @MainActor
    private static func buildPayload() async -> UsageExportPayload {
        let store = UsageStore.shared

        let daily = await store.queryDaily(limit: 30)
        let weekly = await store.queryWeekly(limit: 12)
        let monthly = await store.queryMonthly(limit: 12)
        let allRecords = await store.queryRecords(since: .distantPast)
        let bySource = await store.aggregateBySourceIP()
        let hourly = await store.queryHourlyBreakdown()
        let weekDays = await store.queryDailyBreakdown()
        let monthWeeks = await store.queryWeeklyBreakdown()

        let today = daily.first.map(AggregatedUsageExport.init)
        let week = weekly.first.map(AggregatedUsageExport.init)
        let month = monthly.first.map(AggregatedUsageExport.init)
        let allTime = aggregate(allRecords)

        var providers: [ProviderExport] = []

        // 收集所有提供商：注册提供商 ∪ 数据中实际出现的 providerId。
        // 跳过空 provider_id（旧版行仍计入全局汇总与 records），确保导出覆盖全部提供商。
        var providerIDs: [String] = []
        for p in ProviderManager.shared.providers where !providerIDs.contains(p.id) {
            providerIDs.append(p.id)
        }
        for r in allRecords where !r.providerId.isEmpty && !providerIDs.contains(r.providerId) {
            providerIDs.append(r.providerId)
        }

        for pid in providerIDs {
            let name = ProviderManager.shared.providers.first { $0.id == pid }?.name ?? pid
            let pd = await store.queryDaily(limit: 30, providerId: pid)
            let pw = await store.queryWeekly(limit: 12, providerId: pid)
            let pm = await store.queryMonthly(limit: 12, providerId: pid)
            let pRecords = allRecords.filter { $0.providerId == pid }
            providers.append(ProviderExport(
                providerId: pid,
                name: name,
                summary: PeriodSummary(today: pd.first.map(AggregatedUsageExport.init),
                                       week: pw.first.map(AggregatedUsageExport.init),
                                       month: pm.first.map(AggregatedUsageExport.init),
                                       allTime: aggregate(pRecords)),
                daily: pd.map(AggregatedUsageExport.init),
                weekly: pw.map(AggregatedUsageExport.init),
                monthly: pm.map(AggregatedUsageExport.init)
            ))
        }

        return UsageExportPayload(
            format: "dev-mon-usage-export",
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            summary: PeriodSummary(today: today, week: week, month: month, allTime: allTime),
            periods: Periods(daily: daily.map(AggregatedUsageExport.init),
                             weekly: weekly.map(AggregatedUsageExport.init),
                             monthly: monthly.map(AggregatedUsageExport.init)),
            breakdowns: Breakdowns(todayByHour: hourly.map(TokenBarExport.init),
                                   weekByDay: weekDays.map(TokenBarExport.init),
                                   monthByWeek: monthWeeks.map(TokenBarExport.init)),
            providers: providers,
            bySource: bySource.map(SourceUsageExport.init),
            records: allRecords
        )
    }

    /// 从原始记录汇总 all-time 聚合（cost 按 ModelPricing 重算）
    private static func aggregate(_ records: [UsageRecord]) -> AggregatedUsageExport {
        var count = 0, prompt = 0, completion = 0, total = 0, cached = 0, reasoning = 0
        var latencySum = 0.0, cost = 0.0
        for r in records {
            count += 1
            prompt += r.promptTokens
            completion += r.completionTokens
            total += r.totalTokens
            cached += r.cachedTokens
            reasoning += r.reasoningTokens
            latencySum += r.latencyMs
            let pricing = ModelPricing.forModel(r.model, providerId: r.providerId)
            cost += ModelPricing.computeCost(promptTokens: r.promptTokens,
                                             completionTokens: r.completionTokens,
                                             cachedTokens: r.cachedTokens,
                                             pricing: pricing, providerId: r.providerId)
        }
        return AggregatedUsageExport(
            period: "all",
            requestCount: count,
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            cachedTokens: cached,
            reasoningTokens: reasoning,
            avgLatencyMs: count > 0 ? latencySum / Double(count) : 0,
            estimatedCost: cost,
            cacheHitRate: prompt > 0 ? Double(cached) / Double(prompt) * 100 : 0
        )
    }
}
