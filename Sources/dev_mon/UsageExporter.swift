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
    let cloud: CloudUsageExport?
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
    /// 该来源使用过的去重提供商 id（逗号连接）
    let providerIds: String
    let requestCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let totalCost: Double
    let lastTimestamp: Date

    init(_ s: SourceUsage) {
        sourceIP = s.sourceIP
        providerIds = s.providerIds
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

// MARK: - Cloud (AWS / GitHub) Snapshot Export

struct CloudUsageExport: Codable {
    let aws: AWSExport?
    let gitHub: GitHubExport?
}

struct AWSExport: Codable {
    // Free tier
    let ec2RunningHours: Double
    let freeTierLimitHours: Double
    let usagePercentage: Double
    let hoursRemaining: Double
    let isWithinFreeTier: Bool
    let isWarning: Bool
    let instanceCount: Int
    let eligibleCount: Int
    let nonEligibleCount: Int
    let nonEligibleInstances: [NonEligibleInstanceExport]
    let forecastedHours: Double?
    let estimatedOverageCost: Double
    // Billing & credits
    let monthToDateCost: Double
    let ec2Cost: Double
    let creditsApplied: Double
    let ec2CreditsApplied: Double
    let maxCredits: Double
    let remainingCredits: Double
    let forecastedCost: Double?
    let lastUpdate: String

    init(status: AWSFreeTierStatus, billing: AWSBillingSnapshot, lastUpdate: String) {
        ec2RunningHours = status.ec2RunningHours
        freeTierLimitHours = status.freeTierLimitHours
        usagePercentage = status.usagePercentage
        hoursRemaining = status.hoursRemaining
        isWithinFreeTier = status.isWithinFreeTier
        isWarning = status.isWarning
        instanceCount = status.instanceCount
        eligibleCount = status.eligibleCount
        nonEligibleCount = status.nonEligibleCount
        nonEligibleInstances = status.nonEligibleInstances.map {
            NonEligibleInstanceExport(instanceId: $0.instanceId, instanceType: $0.instanceType)
        }
        forecastedHours = status.forecastedHours
        estimatedOverageCost = status.estimatedOverageCost
        monthToDateCost = billing.monthToDateCost
        ec2Cost = billing.ec2Cost
        creditsApplied = billing.creditsApplied
        ec2CreditsApplied = billing.ec2CreditsApplied
        maxCredits = billing.maxCredits
        remainingCredits = billing.remainingCredits
        forecastedCost = billing.forecastedCost
        self.lastUpdate = lastUpdate
    }
}

struct NonEligibleInstanceExport: Codable {
    let instanceId: String
    let instanceType: String
}

struct GitHubExport: Codable {
    let minutesUsed: Int
    let includedMinutes: Int
    let minutesRemaining: Int
    let minutesPercentage: Double
    let storageMB: Double
    let storageLimitMB: Double
    let storagePercentage: Double
    let paidMinutesUsed: Int
    let billingCycleDaysLeft: Int
    let isWithinFreeTier: Bool
    let lastUpdate: String

    init(_ usage: GitHubActionsUsage, lastUpdate: String) {
        minutesUsed = usage.minutesUsed
        includedMinutes = usage.includedMinutes
        minutesRemaining = usage.minutesRemaining
        minutesPercentage = usage.minutesPercentage
        storageMB = usage.storageMB
        storageLimitMB = usage.storageLimitMB
        storagePercentage = usage.storagePercentage
        paidMinutesUsed = usage.paidMinutesUsed
        billingCycleDaysLeft = usage.billingCycleDaysLeft
        isWithinFreeTier = usage.isWithinFreeTier
        self.lastUpdate = lastUpdate
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

        let cloud: CloudUsageExport? = {
            let aws = AppDelegate.sharedStats.aws
            let gh = AppDelegate.sharedStats.gitHub
            return CloudUsageExport(
                aws: AWSExport(status: aws.status, billing: aws.billing, lastUpdate: aws.lastUpdate),
                gitHub: GitHubExport(gh.usage, lastUpdate: gh.lastUpdate)
            )
        }()

        return UsageExportPayload(
            format: "dev-mon-usage-export",
            formatVersion: 2,
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
            records: allRecords,
            cloud: cloud
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

// MARK: - 配置导出/导入

/// 带类型标签的 UserDefaults 值，导入时可恢复原始类型（Data 以 base64 存储）。
enum ConfigValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case base64Data(String)
    case date(Double)

    private enum Kind: String, Codable { case string, number, bool, data, date }
    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .string: self = .string(try c.decode(String.self, forKey: .value))
        case .number: self = .number(try c.decode(Double.self, forKey: .value))
        case .bool: self = .bool(try c.decode(Bool.self, forKey: .value))
        case .data: self = .base64Data(try c.decode(String.self, forKey: .value))
        case .date: self = .date(try c.decode(Double.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let s): try c.encode(Kind.string, forKey: .type); try c.encode(s, forKey: .value)
        case .number(let n): try c.encode(Kind.number, forKey: .type); try c.encode(n, forKey: .value)
        case .bool(let b): try c.encode(Kind.bool, forKey: .type); try c.encode(b, forKey: .value)
        case .base64Data(let d): try c.encode(Kind.data, forKey: .type); try c.encode(d, forKey: .value)
        case .date(let t): try c.encode(Kind.date, forKey: .type); try c.encode(t, forKey: .value)
        }
    }
}

struct ConfigPayload: Codable {
    let format: String
    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String
    let settings: [String: ConfigValue]
    let providerApiKeys: [String: String]
    let secrets: [String: String]
}

/// 导出/导入全部设置与密钥（JSON）。
enum ConfigExporter {

    private static let formatName = "dev_mon_config"
    private static let formatVersion = 1

    // 需要导出的非密钥 UserDefaults 键
    @MainActor private static var settingsKeys: [String] {
        var keys = [
            Strings.Keys.appLanguage,
            Strings.Keys.balanceThreshold,
            Strings.Keys.maxBalanceAmount,
            Strings.Keys.proxyPort,
            Strings.Keys.proxyEnabled,
            Strings.Keys.showMenuIcon,
            Strings.Keys.showIndicator,
            Strings.Keys.showBalance,
            Strings.Keys.menuBarTextDisplay,
            Strings.Keys.modelPricingOverrides,
            Strings.Keys.syncEnabled,
            Strings.Keys.syncMode,
            Strings.Keys.syncListenPort,
            Strings.Keys.syncTargetAddress,
            Strings.Keys.syncInterval,
            Strings.Keys.seatRegistry,
            Strings.Keys.seatRegistryFilePath,
            Strings.Keys.defaultProviderId,
            Strings.Keys.menuBarColor,
            Strings.Keys.currencySymbol,
            Strings.Keys.githubUsername,
            Strings.Keys.githubEnabled,
            Strings.Keys.awsRegion,
            Strings.Keys.awsEnabled,
            Strings.Keys.awsMaxCredits,
            Strings.Keys.showPeakDot,
            Strings.Keys.peakNotificationEnabled,
        ]
        // 每个提供商最近使用的模型 + 手填月度预算
        for p in ProviderManager.shared.providers {
            keys.append(Strings.Keys.lastModel(for: p.id))
            keys.append(Strings.Keys.monthlyBudget(for: p.id))
        }
        return keys
    }

    // 需要导出（并以明文存储）的密钥类键
    private static var secretKeys: [String] {
        [
            Strings.Keys.githubToken,
            Strings.Keys.awsAccessKey,
            Strings.Keys.awsSecretKey,
            Strings.Keys.syncPushToken,
        ]
    }

    // MARK: - Export

    @MainActor
    static func exportConfig() {
        let alert = NSAlert()
        alert.messageText = Strings.configExportWarningTitle
        alert.informativeText = Strings.configExportWarningMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.configExportSave)
        alert.addButton(withTitle: Strings.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.title = Strings.configExportTitle
        panel.prompt = Strings.configExportSave
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let payload = buildPayload()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                guard let data = try? encoder.encode(payload) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @MainActor static func buildPayload() -> ConfigPayload {
        let ud = UserDefaults.standard

        var settings: [String: ConfigValue] = [:]
        for key in settingsKeys {
            guard let value = ud.object(forKey: key) else { continue }
            switch value {
            case let s as String: settings[key] = .string(s)
            case let b as Bool: settings[key] = .bool(b)
            case let n as NSNumber: settings[key] = .number(n.doubleValue)
            case let d as Date: settings[key] = .date(d.timeIntervalSince1970)
            case let data as Data: settings[key] = .base64Data(data.base64EncodedString())
            default: break
            }
        }

        // Provider API keys（解密后导出，含 OpenAI/Anthropic 管理密钥）
        var providerApiKeys: [String: String] = [:]
        for p in ProviderManager.shared.providers {
            let k = ProviderManager.shared.apiKey(for: p.id)
            if !k.isEmpty { providerApiKeys[p.id] = k }
        }

        var secrets: [String: String] = [:]
        for key in secretKeys {
            if let v = SecureStore.retrieve(key: key), !v.isEmpty {
                secrets[key] = v
            }
        }

        return ConfigPayload(
            format: formatName,
            formatVersion: formatVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            settings: settings,
            providerApiKeys: providerApiKeys,
            secrets: secrets
        )
    }

    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "dev-mon-config-\(f.string(from: Date())).json"
    }

    // MARK: - Import

    @MainActor
    static func importConfig() {
        let panel = NSOpenPanel()
        panel.title = Strings.configImportTitle
        panel.prompt = Strings.configImportOpen
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let data = try? Data(contentsOf: url) else { return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let payload = try? decoder.decode(ConfigPayload.self, from: data),
                      payload.format == formatName else {
                    presentMessage(Strings.configImportInvalid, style: .critical)
                    return
                }
                apply(payload)
                presentMessage(Strings.configImportDone, style: .informational)
            }
        }
    }

    @MainActor static func apply(_ payload: ConfigPayload) {
        let ud = UserDefaults.standard
        for (key, value) in payload.settings {
            switch value {
            case .string(let s): ud.set(s, forKey: key)
            case .number(let n): ud.set(n, forKey: key)
            case .bool(let b): ud.set(b, forKey: key)
            case .base64Data(let s):
                if let d = Data(base64Encoded: s) { ud.set(d, forKey: key) }
            case .date(let t): ud.set(Date(timeIntervalSince1970: t), forKey: key)
            }
        }

        for (pid, key) in payload.providerApiKeys where !key.isEmpty {
            ProviderManager.shared.saveAPIKey(key, for: pid)
        }
        for (key, value) in payload.secrets where !value.isEmpty {
            SecureStore.save(key: key, value: value)
        }

        if case .string(let id)? = payload.settings[Strings.Keys.defaultProviderId], !id.isEmpty {
            ProviderManager.shared.setDefaultProvider(id: id)
        }

        // 通知各组件重新加载
        NotificationCenter.default.post(name: .providerChanged, object: nil)
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .currencyDidChange, object: nil)
        NotificationCenter.default.post(name: .showMenuIconDidChange, object: nil)
        NotificationCenter.default.post(name: .showIndicatorDidChange, object: nil)
        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
        NotificationCenter.default.post(name: .menuBarColorDidChange, object: nil)
        NotificationCenter.default.post(name: .peakSettingsDidChange, object: nil)
    }

    @MainActor private static func presentMessage(_ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = style
        alert.addButton(withTitle: Strings.ok)
        alert.runModal()
    }
}
