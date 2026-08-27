import Foundation
import SwiftUI

/// dev_mon 数据模型
@MainActor
@Observable
final class DeepSeekStats {
    // Task 本身是 Sendable，cancel() 线程安全，此标记仅用于 deinit 访问
    @ObservationIgnored
    private var blinkTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    private(set) var balance: Double = 0
    private(set) var grantedBalance: Double = 0
    private(set) var toppedUpBalance: Double = 0
    private(set) var isAvailable = true
    private(set) var currency = "CNY"
    private(set) var models: [String] = [] {
        didSet { if models != oldValue { lastModelsFetch = Date() } }
    }
    private(set) var lastUpdate = "-"
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var blinkOn = false  // 用于闪烁动画

    // ☁️ Cloud tracking
    private(set) var gitHub = GitHubUsageTracker()
    private(set) var aws = AWSUsageTracker()

    // 活跃提供商信息
    private(set) var providerName: String = "DeepSeek"
    private(set) var providerID: String = "deepseek"
    private(set) var hasBalanceAPI: Bool = true
    private(set) var hasTokenUsageAPI: Bool = false
    private(set) var providerIsFree: Bool = false
    private(set) var providerIsSpendBased: Bool = false
    private(set) var tokenUsage = ProviderTokenUsage.empty

    // MARK: - 月度预算（按月计费提供商的"剩余额度"来源）

    /// 剩余额度的推导依据。OpenAI/Anthropic 均无余额查询接口，
    /// 只能用提供商消费上限（若可用）或用户手填预算减去本月费用。
    enum BudgetSource {
        case spendLimit  // provider-reported limit
        case manual      // 设置中手填
        case none        // 未知
    }

    private(set) var monthlyBudget: Double = 0
    private(set) var budgetSource: BudgetSource = .none

    /// 余额预警阈值（默认 20）
    var threshold: Double {
        get { UserDefaults.standard.double(forKey: Strings.Keys.balanceThreshold) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.balanceThreshold) }
    }

    var isLowBalance: Bool {
        guard !providerIsSpendBased else { return false }
        return balance >= 0 && balance < threshold
    }

    var maxBalanceAmount: Double {
        let val = UserDefaults.standard.double(forKey: Strings.Keys.maxBalanceAmount)
        return val > 0 ? val : AppConfig.defaultMaxBalanceAmount
    }

    var isWarningBalance: Bool {
        guard hasBalanceAPI, !providerIsSpendBased else { return false }
        return !isLowBalance && balance >= 0 && balance < maxBalanceAmount * 0.5
    }

    // MARK: - 剩余额度

    var hasBudget: Bool { providerIsSpendBased && monthlyBudget > 0 }

    /// 按月计费提供商的 `balance` 保存的是本月累计费用
    var spentThisMonth: Double { balance }

    var remainingBudget: Double { max(0, monthlyBudget - spentThisMonth) }

    /// 已用占预算的比例，0...1
    var budgetFraction: Double {
        guard monthlyBudget > 0 else { return 0 }
        return min(1, max(0, spentThisMonth / monthlyBudget))
    }

    var budgetSourceText: String {
        switch budgetSource {
        case .spendLimit: return Strings.budgetSourceSpendLimit
        case .manual:     return Strings.budgetSourceManual
        case .none:       return Strings.budgetSourceNone
        }
    }

    /// 用户手填的月度预算，按提供商独立保存
    func manualBudget(for providerId: String) -> Double {
        UserDefaults.standard.double(forKey: Strings.Keys.monthlyBudget(for: providerId))
    }

    func setManualBudget(_ value: Double, for providerId: String) {
        UserDefaults.standard.set(max(0, value), forKey: Strings.Keys.monthlyBudget(for: providerId))
        if providerId == providerID { applyManualBudgetFallback() }
    }

    /// 当没有（或未取到）组织消费上限时，回退到手填预算
    private func applyManualBudgetFallback() {
        guard providerIsSpendBased else {
            monthlyBudget = 0
            budgetSource = .none
            return
        }
        let manual = manualBudget(for: providerID)
        if manual > 0 {
            monthlyBudget = manual
            budgetSource = .manual
        } else {
            monthlyBudget = 0
            budgetSource = .none
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var lastModelsFetch: Date?

    init() {
        loadProvider()
        if UserDefaults.standard.object(forKey: Strings.Keys.balanceThreshold) == nil {
            threshold = AppConfig.defaultBalanceThreshold
        }
        startBlinkTimer()
        startAutoRefresh()
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(providerChanged),
            name: .providerChanged,
            object: nil
        )
    }

    deinit {
        blinkTask?.cancel()
        refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func providerChanged() {
        lastModelsFetch = nil
        models = []
        loadProvider()
        refresh()
    }

    private func loadProvider() {
        let mgr = ProviderManager.shared
        if let provider = mgr.activeProvider {
            providerName = provider.name
            providerID = provider.id
            hasBalanceAPI = provider.balanceURL != nil
            hasTokenUsageAPI = provider.tokenUsageURL != nil
            providerIsSpendBased = provider.isSpendBased
            tokenUsage = .empty
            providerIsFree = false
            currency = provider.currency
        } else {
            providerName = "—"
            providerID = ""
            hasBalanceAPI = false
            currency = "CNY"
        }
    }

    // MARK: - 闪烁

    private func startBlinkTimer() {
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.blinkInterval))
                guard !Task.isCancelled, let self else { return }
                self.blinkOn.toggle()
            }
        }
    }

    // MARK: - 自动刷新

    private func startAutoRefresh() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.balanceRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    // MARK: - 状态

    var balanceText: String {
        if providerIsFree { return "FREE" }
        if !hasBalanceAPI { return "—" }
        return String(format: Strings.balanceText, balance)
    }

    var grantedText: String {
        if !hasBalanceAPI { return "" }
        return String(format: Strings.grantedText, grantedBalance)
    }

    var toppedUpText: String {
        if !hasBalanceAPI { return "" }
        return String(format: Strings.toppedUpText, toppedUpBalance)
    }

    var availabilityText: String {
        if !hasBalanceAPI { return "—" }
        return isAvailable ? Strings.available : Strings.insufficient
    }

    var modelsText: String {
        models.isEmpty ? "—" : models.joined(separator: ", ")
    }

    var defaultModelText: String {
        if let provider = ProviderManager.shared.activeProvider {
            let lastModel = UserDefaults.standard.string(forKey: Strings.Keys.lastModel(for: provider.id))
            let model = lastModel ?? provider.preferredDefaultModel ?? provider.fallbackModels.keys.sorted().first ?? models.sorted().first ?? "—"
            return model
        }
        return "—"
    }

    var statusColor: Color {
        if isLoading { return .gray }
        if errorMessage != nil { return .orange }
        if hasBalanceAPI && isLowBalance { return blinkOn ? .red : .red.opacity(0.3) }
        if hasBalanceAPI && isWarningBalance { return .orange }
        return .green
    }

    // MARK: - 高峰/低谷计费时段（DeepSeek）

    /// 仅 DeepSeek 有官方公布的高峰/低谷时段
    var supportsPricingWindow: Bool {
        providerID == "deepseek"
    }

    var isPeakHour: Bool {
        DeepSeekPricing.isPeak()
    }

    var pricingWindowText: String {
        isPeakHour ? Strings.peakStatusPeak : Strings.peakStatusOffPeak
    }

    var pricingWindowColor: Color {
        isPeakHour ? .yellow : .green
    }

    /// 弹窗信息行展示文本（含剩余时间），如 "高峰 · 3h 12m 后切换"
    var pricingWindowDetailText: String {
        let countdown = DeepSeekPricing.timeToTransitionText()
        return String(format: isPeakHour ? Strings.peakCountdown : Strings.offPeakCountdown, countdown)
    }

    // MARK: - 刷新

    func refresh() {
        let apiKey = ProviderManager.shared.activeAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = Strings.noAPIKey
            return
        }
        isLoading = true
        errorMessage = nil
        loadProvider()

        Task {
            if hasBalanceAPI {
                await fetchBalance(apiKey: apiKey)
            } else {
                // 无余额 API 的提供商：跳过余额查询
                if providerIsFree {
                    balance = maxBalanceAmount * 2
                    grantedBalance = 0
                    toppedUpBalance = 0
                } else {
                    balance = 0
                    grantedBalance = 0
                    toppedUpBalance = 0
                }
                isAvailable = true
                isAvailable = true
            }
            if hasTokenUsageAPI {
                await fetchTokenUsage(apiKey: apiKey)
            }
            if providerIsSpendBased {
                await fetchSpendLimit(apiKey: apiKey)
            } else {
                monthlyBudget = 0
                budgetSource = .none
            }
            // 每次 refresh 都重新拉取模型列表
            if await fetchModels(apiKey: apiKey) {
                lastModelsFetch = Date()
            }
            isLoading = false
            lastUpdate = Self.timeFormatter.string(from: Date())
        }
    }

    private func fetchBalance(apiKey: String) async {
        guard let provider = ProviderManager.shared.activeProvider else { return }
        guard let balancePath = provider.balanceURL else { return }
        do {
            let pages = try await fetchReportPages(provider: provider, path: balancePath, apiKey: apiKey)
            var total = 0.0
            var granted = 0.0
            var toppedUp = 0.0
            for json in pages {
                if let result = provider.parseBalance(json) {
                    total += result.total
                    granted += result.granted
                    toppedUp += result.toppedUp
                }
            }
            if let anthropic = provider as? AnthropicProvider {
                total += (try? await fetchAnthropicLiveCost(
                    provider: anthropic,
                    apiKey: apiKey,
                    finalizedPages: pages
                )) ?? 0
            }
            balance = total
            grantedBalance = granted
            toppedUpBalance = toppedUp
            isAvailable = true
        } catch ReportFetchError.httpStatus(401) {
                errorMessage = Strings.keyInvalid
        } catch ReportFetchError.httpStatus(429) {
                errorMessage = Strings.rateLimited
        } catch ReportFetchError.httpStatus(let code) where (500...599).contains(code) {
                errorMessage = Strings.serviceDown
        } catch ReportFetchError.httpStatus(let code) {
            errorMessage = Strings.queryFailed(code: code)
        } catch ReportFetchError.invalidResponse {
            errorMessage = Strings.invalidResponse
        } catch ReportFetchError.parseFailed {
            errorMessage = Strings.parseFailed
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                errorMessage = Strings.timeout
            case .notConnectedToInternet, .networkConnectionLost:
                errorMessage = Strings.noNetwork
            default:
                errorMessage = Strings.networkError(error.localizedDescription)
            }
        } catch {
            errorMessage = Strings.networkError(error.localizedDescription)
        }
    }

    private func fetchTokenUsage(apiKey: String) async {
        guard let provider = ProviderManager.shared.activeProvider else { return }
        guard let path = provider.tokenUsageURL else { return }
        do {
            let pages = try await fetchReportPages(provider: provider, path: path, apiKey: apiKey)
            var combined = ProviderTokenUsage()
            for json in pages {
                guard let usage = provider.parseTokenUsage(json) else { continue }
                combined.inputTokens += usage.inputTokens
                combined.outputTokens += usage.outputTokens
                combined.cachedInputTokens += usage.cachedInputTokens
            }
            tokenUsage = combined
        } catch {}
    }

    private enum ReportFetchError: Error {
        case invalidResponse
        case parseFailed
        case httpStatus(Int)
    }

    /// Fetch every cursor page returned by the OpenAI and Anthropic admin reports.
    private func fetchReportPages(
        provider: any Provider,
        path: String,
        apiKey: String,
        queryItems: [URLQueryItem]? = nil,
        timeout: TimeInterval = AppConfig.balanceRequestTimeout
    ) async throws -> [[String: Any]] {
        guard var baseURL = URL(string: provider.baseURL + path) else {
            throw ReportFetchError.invalidResponse
        }
        if let items = queryItems ?? provider.balanceQueryItems {
            baseURL.append(queryItems: items)
        }

        var pages: [[String: Any]] = []
        var pageToken: String?
        var seenTokens = Set<String>()

        repeat {
            var url = baseURL
            if let pageToken {
                url.append(queryItems: [URLQueryItem(name: "page", value: pageToken)])
            }
            var req = URLRequest(url: url)
            for (name, value) in provider.authHeaders(for: apiKey) {
                req.setValue(value, forHTTPHeaderField: name)
            }
            req.timeoutInterval = timeout

            let (data, response) = try await AppConfig.directURLSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ReportFetchError.invalidResponse
            }
            guard http.statusCode == 200 else {
                throw ReportFetchError.httpStatus(http.statusCode)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReportFetchError.parseFailed
            }
            pages.append(json)

            guard json["has_more"] as? Bool == true,
                  let next = json["next_page"] as? String,
                  !next.isEmpty,
                  seenTokens.insert(next).inserted else {
                pageToken = nil
                break
            }
            pageToken = next
        } while pageToken != nil

        return pages
    }

    private func fetchAnthropicLiveCost(
        provider: AnthropicProvider,
        apiKey: String,
        finalizedPages: [[String: Any]]
    ) async throws -> Double {
        guard let usagePath = provider.tokenUsageURL else { return 0 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: Date())) ?? Date()
        let since = max(provider.latestFinalizedCostEnd(finalizedPages) ?? monthStart, monthStart)
        guard since < Date() else { return 0 }

        let pages = try await fetchReportPages(
            provider: provider,
            path: usagePath,
            apiKey: apiKey,
            queryItems: provider.liveCostQueryItems(since: since),
            timeout: 30
        )
        return pages.reduce(0) { $0 + provider.estimateLiveCost($1) }
    }

    /// 拉取提供商可选的月度硬性消费上限。
    /// 注意：该接口不接受 query 参数，因此不能附加 balanceQueryItems。
    /// 未提供该接口、请求失败或未配置上限时，回退到手填预算。
    private func fetchSpendLimit(apiKey: String) async {
        guard let provider = ProviderManager.shared.activeProvider,
              let path = provider.spendLimitURL,
              let url = URL(string: provider.baseURL + path) else {
            applyManualBudgetFallback()
            return
        }

        var req = URLRequest(url: url)
        for (name, value) in provider.authHeaders(for: apiKey) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.timeoutInterval = AppConfig.balanceRequestTimeout
        do {
            let (data, resp) = try await AppConfig.directURLSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limit = provider.parseSpendLimit(json) else {
                applyManualBudgetFallback()
                return
            }
            monthlyBudget = limit
            budgetSource = .spendLimit
        } catch {
            applyManualBudgetFallback()
        }
    }

    // MARK: - 余额解析策略

    private func modelsLog(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())
        AppConfig.appendLog(to: AppConfig.proxyLogURL, "[\(ts)] [models] \(msg)\n")
    }

    private func fetchModels(apiKey: String) async -> Bool {
        await ProviderManager.shared.refreshModels()
        if let provider = ProviderManager.shared.activeProvider {
            models = ProviderManager.shared.modelProviderMap
                .filter { $0.value == provider.id }
                .map { $0.key }
                .sorted()
        }
        return !models.isEmpty
    }
}
