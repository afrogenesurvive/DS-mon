import Foundation
import SwiftUI

/// DS-mon 数据模型
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
    private(set) var models: [String] = []
    private(set) var lastUpdate = "-"
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var blinkOn = false  // 用于闪烁动画

    // 活跃提供商信息
    private(set) var providerName: String = "DeepSeek"
    private(set) var providerID: String = "deepseek"
    private(set) var hasBalanceAPI: Bool = true
    private(set) var providerIsFree: Bool = false

    /// 余额预警阈值（默认 20）
    var threshold: Double {
        get { UserDefaults.standard.double(forKey: Strings.Keys.balanceThreshold) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.balanceThreshold) }
    }

    var isLowBalance: Bool {
        balance >= 0 && balance < threshold
    }

    var maxBalanceAmount: Double {
        let val = UserDefaults.standard.double(forKey: Strings.Keys.maxBalanceAmount)
        return val > 0 ? val : AppConfig.defaultMaxBalanceAmount
    }

    var isWarningBalance: Bool {
        guard hasBalanceAPI else { return false }
        return !isLowBalance && balance >= 0 && balance < maxBalanceAmount * 0.5
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

        // 无需监听提供商切换（单提供商）
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
            hasBalanceAPI = provider.hasBalanceAPI
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
        if let provider = ProviderManager.shared.activeProvider,
           let model = provider.defaultModel ?? (provider.pricingOverrides.isEmpty ? models.sorted().first : provider.pricingOverrides.keys.sorted().first) {
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
        guard let url = URL(string: provider.baseURL + balancePath) else { return }

        var req = URLRequest(url: url)
        req.setValue("\(provider.authHeaderPrefix) \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = AppConfig.balanceRequestTimeout
        do {
            let (data, resp) = try await AppConfig.directURLSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                errorMessage = Strings.invalidResponse
                return
            }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = Strings.parseFailed
                    return
                }
                parseDeepSeekBalance(json)
            case 401:
                errorMessage = Strings.keyInvalid
            case 429:
                errorMessage = Strings.rateLimited
            case 500...599:
                errorMessage = Strings.serviceDown
            default:
                errorMessage = Strings.queryFailed(code: http.statusCode)
            }
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

    // MARK: - 余额解析策略

    /// DeepSeek: { "balance_infos": [{ "total_balance": "100", "granted_balance": "0", "topped_up_balance": "100", "currency": "CNY" }], "is_available": true }
    private func parseDeepSeekBalance(_ json: [String: Any]) {
        guard let infos = json["balance_infos"] as? [[String: Any]] else {
            errorMessage = Strings.parseFailed
            return
        }
        isAvailable = json["is_available"] as? Bool ?? true
        for info in infos where (info["currency"] as? String) == currency {
            if let s = info["total_balance"] as? String {
                balance = Double(s) ?? 0
            }
            if let s = info["granted_balance"] as? String {
                grantedBalance = Double(s) ?? 0
            }
            if let s = info["topped_up_balance"] as? String {
                toppedUpBalance = Double(s) ?? 0
            }
            currency = info["currency"] as? String ?? "CNY"
        }
    }

    private func modelsLog(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let ts = df.string(from: Date())
        AppConfig.appendLog(to: AppConfig.proxyLogURL, "[\(ts)] [models] \(msg)\n")
    }

    private func fetchModels(apiKey: String) async -> Bool {
        guard let provider = ProviderManager.shared.activeProvider else { modelsLog("no active provider"); return false }
        let urlStr = provider.baseURL + provider.apiPath + "/models"
        guard let url = URL(string: urlStr) else { modelsLog("bad URL: \(urlStr)"); return false }
        var req = URLRequest(url: url)
        req.setValue("\(provider.authHeaderPrefix) \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = AppConfig.modelsRequestTimeout
        do {
            let (data, resp) = try await AppConfig.directURLSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { modelsLog("not HTTP"); return false }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                modelsLog("HTTP \(http.statusCode): \(body.prefix(300))")
                return false
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                modelsLog("JSON parse failed")
                return false
            }

            // 有的返回 data[]，有的返回 models[]
            if let list = json["data"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }
                modelsLog("parsed \(models.count) models from data[]")
            } else if let list = json["models"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }
                modelsLog("parsed \(models.count) models from models[]")
            } else {
                modelsLog("no data[] or models[] key in response, keys: \(json.keys)")
                return false
            }
            return !models.isEmpty
        } catch {
            modelsLog("error: \(error.localizedDescription)")
            return false
        }
    }
}

