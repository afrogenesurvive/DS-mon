import Foundation
import SwiftUI
import Security

/// DS-mon 数据模型
@MainActor
@Observable
final class DeepSeekStats {
    @ObservationIgnored
    nonisolated(unsafe) private var blinkTimer: Timer?
    @ObservationIgnored
    nonisolated(unsafe) private var refreshTimer: Timer?
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

    /// 余额预警阈值（默认 20）
    var threshold: Double {
        get { UserDefaults.standard.double(forKey: "balance_threshold") }
        set { UserDefaults.standard.set(newValue, forKey: "balance_threshold") }
    }

    var isLowBalance: Bool {
        balance >= 0 && balance < threshold
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var lastModelsFetch: Date?
    private var apiKey: String = ""

    init() {
        loadAPIKey()
        if UserDefaults.standard.object(forKey: "balance_threshold") == nil {
            threshold = 20
        }
        startBlinkTimer()
        startAutoRefresh()
        refresh()
    }

    deinit {
        blinkTimer?.invalidate()
        refreshTimer?.invalidate()
    }

    // MARK: - 闪烁
	
    private func startBlinkTimer() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.blinkOn.toggle()
            }
        }
    }

    // MARK: - 自动刷新

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    // MARK: - Keychain

    private func loadAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dsmon_apikey",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            apiKey = String(data: data, encoding: .utf8) ?? ""
        }
    }

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dsmon_apikey",
            kSecAttrAccount as String: NSUserName()
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let data = key.data(using: .utf8)!
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dsmon_apikey",
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            errorMessage = Strings.keychainSaveFailed
            return false
        }
        apiKey = key
        errorMessage = nil
        return true
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    static func readAPIKeyFromKeychain() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dsmon_apikey",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    // MARK: - 状态

    var balanceText: String {
        String(format: Strings.balanceText, balance)
    }

    var grantedText: String {
        String(format: Strings.grantedText, grantedBalance)
    }

    var toppedUpText: String {
        String(format: Strings.toppedUpText, toppedUpBalance)
    }

    var availabilityText: String {
        isAvailable ? Strings.available : Strings.insufficient
    }

    var modelsText: String {
        models.isEmpty ? "—" : models.joined(separator: ", ")
    }

    var statusColor: Color {
        if isLoading { return .gray }
        if errorMessage != nil { return .orange }
        if isLowBalance { return blinkOn ? .red : .red.opacity(0.3) }
        return .green
    }

    // MARK: - 刷新

    func refresh() {
        guard !apiKey.isEmpty else {
            errorMessage = Strings.noAPIKey
            return
        }
        isLoading = true
        errorMessage = nil

        Task {
            await fetchBalance()
            // 模型列表每小时刷新一次即可
            if lastModelsFetch == nil || Date().timeIntervalSince(lastModelsFetch!) >= 3600 {
                await fetchModels()
                lastModelsFetch = Date()
            }
            isLoading = false
            lastUpdate = Self.timeFormatter.string(from: Date())
        }
    }

    private func fetchBalance() async {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                errorMessage = Strings.invalidResponse
                return
            }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let infos = json["balance_infos"] as? [[String: Any]] else {
                    errorMessage = Strings.parseFailed
                    return
                }
                isAvailable = json["is_available"] as? Bool ?? true
                for info in infos where info["currency"] as? String == "CNY" {
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

    private func fetchModels() async {
        guard let url = URL(string: "https://api.deepseek.com/models") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else { return }
            models = list.compactMap { $0["id"] as? String }
        } catch {
            // 不覆盖余额请求的错误信息
        }
    }
}
