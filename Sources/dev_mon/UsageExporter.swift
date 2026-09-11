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
    /// 按本地仓库聚合（usage_log.repo）
    let byRepo: [RepoUsageExport]
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

// MARK: - Cloud (AWS / GitHub / Cloudflare / Netlify / 本地服务) Snapshot Export

struct CloudUsageExport: Codable {
    let aws: AWSExport?
    let gitHub: GitHubExport?
    // 新增（后向兼容：旧文件解码时缺省为 nil）
    let cloudflare: CloudflareExport?
    let netlify: NetlifyExport?
    let localDBs: LocalDBsExport?
    let repoStores: RepoStoresExport?
}

// MARK: Cloudflare

struct CloudflareExport: Codable {
    let enabled: Bool
    let daemonState: String
    let daemonRunning: Bool
    let tunnelID: String?
    let tunnelName: String?
    let tunnelStatus: String?
    let connectorCount: Int?
    let publicHostnames: [CFHostnameExport]
    let ipRoutes: [CFIPRouteExport]
    let lastUpdate: String

    @MainActor
    init(_ cf: CloudflareTunnelManager) {
        enabled = cf.isEnabled
        switch cf.daemonState {
        case .running: daemonState = "running"
        case .installed: daemonState = "installed"
        case .notInstalled: daemonState = "notInstalled"
        }
        daemonRunning = cf.daemonRunning
        tunnelID = cf.selectedTunnel?.id
        tunnelName = cf.selectedTunnel?.name
        tunnelStatus = cf.selectedTunnel?.status
        connectorCount = cf.selectedTunnel?.connectorCount
        publicHostnames = cf.ingress.map {
            CFHostnameExport(hostname: $0.hostname, path: $0.path, service: $0.service)
        }
        ipRoutes = cf.ipRoutes.map { CFIPRouteExport(network: $0.network, comment: $0.comment) }
        lastUpdate = cf.lastUpdate
    }
}

struct CFHostnameExport: Codable {
    let hostname: String
    let path: String?
    let service: String
}

struct CFIPRouteExport: Codable {
    let network: String
    let comment: String?
}

// MARK: Netlify

struct NetlifyExport: Codable {
    let enabled: Bool
    let accountName: String?
    let selectedSiteID: String?
    let siteCount: Int
    let sites: [NetlifySiteExport]
    /// 选中站点的最近 10 条部署
    let deploys: [NetlifyDeployExport]
    let lastUpdate: String

    @MainActor
    init(_ nf: NetlifyManager) {
        enabled = nf.isEnabled
        accountName = nf.selectedAccount?.name ?? nf.accountName
        selectedSiteID = nf.selectedSiteID
        siteCount = nf.sites.count
        sites = nf.sites.map {
            NetlifySiteExport(id: $0.id, slug: $0.name, customDomain: $0.customDomain,
                              url: $0.url, adminURL: $0.adminURL, state: $0.state,
                              createdAt: $0.createdAt, publishedDeployID: $0.publishedDeployID,
                              repoURL: $0.repoURL, repoBranch: $0.repoBranch,
                              buildCommand: $0.buildCommand, publishDir: $0.publishDir)
        }
        deploys = nf.deploys.prefix(10).map {
            NetlifyDeployExport(id: $0.id, state: $0.state, context: $0.context, branch: $0.branch,
                                title: $0.title, createdAt: $0.createdAt,
                                errorMessage: $0.errorMessage, locked: $0.locked, url: $0.url)
        }
        lastUpdate = nf.lastUpdate
    }
}

struct NetlifySiteExport: Codable {
    let id: String
    let slug: String
    let customDomain: String?
    let url: String?
    let adminURL: String?
    let state: String?
    let createdAt: Date?
    let publishedDeployID: String?
    let repoURL: String?
    let repoBranch: String?
    let buildCommand: String?
    let publishDir: String?
}

struct NetlifyDeployExport: Codable {
    let id: String
    let state: String
    let context: String?
    let branch: String?
    let title: String?
    let createdAt: Date?
    let errorMessage: String?
    let locked: Bool
    let url: String?
}

// MARK: 本地数据库 / 仓库数据存储

struct LocalDBsExport: Codable {
    let enabled: Bool
    let databases: [LocalDBExport]

    @MainActor
    init(_ db: LocalDBManager) {
        enabled = db.isEnabled
        databases = db.services.map {
            LocalDBExport(id: $0.id.rawValue, running: $0.running,
                          uptimeSeconds: $0.uptimeSeconds,
                          databaseCount: $0.databases.count, error: $0.error)
        }
    }
}

struct LocalDBExport: Codable {
    let id: String
    let running: Bool
    let uptimeSeconds: Int?
    let databaseCount: Int
    let error: String?
}

struct RepoStoresExport: Codable {
    let enabled: Bool
    let roots: [String]
    let repoCount: Int
    let storeCount: Int
    let repos: [RepoStoreGroupExport]
    let lastUpdate: String

    @MainActor
    init(_ rs: RepoDataStoreManager) {
        enabled = rs.isEnabled
        roots = rs.roots
        let groups: [RepoStoreGroupExport] = rs.groups.map { g in
            RepoStoreGroupExport(repoName: g.repoName, serviceUp: g.serviceUp,
                                 stores: g.stores.map { s in
                RepoStoreExport(label: s.descriptor.label,
                                kind: s.descriptor.kind.rawValue,
                                source: s.descriptor.source.rawValue,
                                relPath: s.descriptor.relPath,
                                sizeBytes: s.sizeBytes,
                                sensitive: s.descriptor.sensitive)
            })
        }
        repos = groups
        repoCount = groups.count
        storeCount = groups.reduce(0) { $0 + $1.stores.count }
        lastUpdate = rs.lastUpdate
    }
}

struct RepoStoreGroupExport: Codable {
    let repoName: String
    let serviceUp: Bool
    let stores: [RepoStoreExport]
}

struct RepoStoreExport: Codable {
    let label: String
    let kind: String
    let source: String
    let relPath: String
    let sizeBytes: Int64?
    let sensitive: Bool
}

/// 按本地仓库聚合的用量（usage_log.repo）。
struct RepoUsageExport: Codable {
    let repo: String
    let requestCount: Int
    let totalTokens: Int
    let cachedTokens: Int
    let totalCost: Double
    let lastTimestamp: Date
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
    let lifetimeCreditsApplied: Double
    let lifetimeEc2CreditsApplied: Double
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
        lifetimeCreditsApplied = billing.lifetimeCreditsApplied
        lifetimeEc2CreditsApplied = billing.lifetimeEc2CreditsApplied
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
            let s = AppDelegate.sharedStats
            return CloudUsageExport(
                aws: AWSExport(status: s.aws.status, billing: s.aws.billing, lastUpdate: s.aws.lastUpdate),
                gitHub: GitHubExport(s.gitHub.usage, lastUpdate: s.gitHub.lastUpdate),
                cloudflare: CloudflareExport(s.cloudflare),
                netlify: NetlifyExport(s.netlify),
                localDBs: LocalDBsExport(s.localDBs),
                repoStores: RepoStoresExport(s.repoStores)
            )
        }()

        // 按本地仓库聚合（usage_log.repo；未标注仓库的请求不计入）
        let byRepo: [RepoUsageExport] = {
            var agg: [String: (count: Int, total: Int, cached: Int, cost: Double, last: Date)] = [:]
            for r in allRecords {
                guard let repo = r.repo, !repo.isEmpty else { continue }
                let pricing = ModelPricing.forModel(r.model, providerId: r.providerId)
                let cost = ModelPricing.computeCost(promptTokens: r.promptTokens,
                                                    completionTokens: r.completionTokens,
                                                    cachedTokens: r.cachedTokens,
                                                    pricing: pricing, providerId: r.providerId)
                var entry = agg[repo] ?? (0, 0, 0, 0, Date.distantPast)
                entry.count += 1
                entry.total += r.totalTokens
                entry.cached += r.cachedTokens
                entry.cost += cost
                if r.timestamp > entry.last { entry.last = r.timestamp }
                agg[repo] = entry
            }
            return agg.map {
                RepoUsageExport(repo: $0.key, requestCount: $0.value.count, totalTokens: $0.value.total,
                                cachedTokens: $0.value.cached, totalCost: $0.value.cost,
                                lastTimestamp: $0.value.last)
            }
            .sorted { $0.totalCost > $1.totalCost }
        }()

        return UsageExportPayload(
            format: "dev-mon-usage-export",
            formatVersion: 3,
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
            byRepo: byRepo,
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
    /// v2: 补上 Data Sync（sync_config）、许可检查来源、弹窗缩放与 UI 状态（ui.*）
    private static let formatVersion = 2

    // 需要导出的非密钥 UserDefaults 键
    @MainActor private static var settingsKeys: [String] {
        var keys = [
            Strings.Keys.appLanguage,
            Strings.Keys.appTheme,
            Strings.Keys.balanceThreshold,
            Strings.Keys.maxBalanceAmount,
            Strings.Keys.proxyPort,
            Strings.Keys.proxyEnabled,
            Strings.Keys.showMenuIcon,
            Strings.Keys.showIndicator,
            Strings.Keys.showBalance,
            Strings.Keys.menuBarTextDisplay,
            Strings.Keys.modelPricingOverrides,
            // Data Sync 配置实际存于一个 JSON blob（sync_config）——必须导出它，
            // 否则另一台机器导入后同步设置会全部丢失。
            SyncConfig.storageKey,
            // 同步游标（上次推送时间）：一并导出，避免还原后重复推送历史。
            "lastPushTimestamp",
            Strings.Keys.seatRegistry,
            // 新版多注册表结构（RegistryBundle）
            SeatRegistry.storageKey,
            Strings.Keys.seatRegistryFilePath,
            // 许可检查来源（devmon.json 路径）
            SeatRegistry.checkSourceKey,
            // 密钥管理器仓库路径（签发 / 吊销工具位置）
            KeyManager.toolPathKey,
            Strings.Keys.defaultProviderId,
            Strings.Keys.menuBarColor,
            Strings.Keys.currencySymbol,
            // 弹窗缩放倍数（导出后另一台机器保持同样的弹窗大小）
            AppConfig.popoverScaleKey,
            Strings.Keys.githubUsername,
            Strings.Keys.githubEnabled,
            Strings.Keys.awsRegion,
            Strings.Keys.awsEnabled,
            Strings.Keys.awsMaxCredits,
            Strings.Keys.showPeakDot,
            Strings.Keys.peakNotificationEnabled,
            Strings.Keys.balanceAlertEnabled,
            Strings.Keys.tunnelDownNotificationEnabled,
            // AWS 实例持续运行提醒（计时起点 aws_instance_run_first_seen 属运行时状态，不导出）
            Strings.Keys.awsRunNotifyEnabled,
            // Cloudflare 隧道配置
            Strings.Keys.cloudflareEnabled,
            Strings.Keys.cloudflareAccountId,
            Strings.Keys.cloudflareAccountName,
            Strings.Keys.cloudflareZoneId,
            Strings.Keys.cloudflareZoneName,
            Strings.Keys.cloudflareTunnelId,
            Strings.Keys.cloudflareTunnelName,
            // Netlify 配置
            Strings.Keys.netlifyEnabled,
            Strings.Keys.netlifyAccountId,
            Strings.Keys.netlifyAccountName,
            Strings.Keys.netlifySelectedSiteId,
            Strings.Keys.netlifyDeployNotifyEnabled,
            // Local DBs 配置
            Strings.Keys.localDBsEnabled,
            Strings.Keys.localDBsNotifyEnabled,
            Strings.Keys.localDBsMySQLUser,
            Strings.Keys.localDBsNeo4jUser,
            // Repo Data Stores 配置（运行时缓存 repoStoresCache 不导出）
            Strings.Keys.repoStoresEnabled,
            Strings.Keys.repoStoresNotifyEnabled,
            Strings.Keys.repoStoresRoots,
            Strings.Keys.repoStoresDepth,
            Strings.Keys.repoStoresShowDetails,
            Strings.Keys.repoStoresIncludeRemote,
            // Z.AI 端点选择（Coding Plan / Standard）
            Strings.Keys.zaiEndpoint,
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
            Strings.Keys.cloudflareApiToken,
            Strings.Keys.netlifyApiToken,
            Strings.Keys.localDBsMySQLPassword,
            Strings.Keys.localDBsNeo4jPassword,
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

        // UI 状态（页签 / 折叠 / 图表-列表模式）——扁平化为 ui.<key> 存储
        for (key, value) in UIStateStore.shared.exportedValues {
            settings[key] = value
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
            // UI 状态键（ui.<key>）直接交给 UIStateStore
            if UIStateStore.shared.importValue(key, value) { continue }
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

        // Data Sync 配置存于 sync_config blob：重新加载并按新配置重启
        SyncManager.shared.config = SyncConfig.load()
        SyncManager.shared.start()

        // 弹窗缩放：让窗口按导入的倍数调整大小
        NotificationCenter.default.post(name: .popoverResizeRequested,
                                        object: NSNumber(value: Double(AppConfig.savedPopoverScale())))

        // 通知各组件重新加载
        NotificationCenter.default.post(name: .providerChanged, object: nil)
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .currencyDidChange, object: nil)
        NotificationCenter.default.post(name: .showMenuIconDidChange, object: nil)
        NotificationCenter.default.post(name: .showIndicatorDidChange, object: nil)
        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
        NotificationCenter.default.post(name: .menuBarColorDidChange, object: nil)
        NotificationCenter.default.post(name: .peakSettingsDidChange, object: nil)

        // 应用导入的外观主题（System / Light / Dark）
        Theme.apply()
        NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
    }

    @MainActor private static func presentMessage(_ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = style
        alert.addButton(withTitle: Strings.ok)
        alert.runModal()
    }
}
