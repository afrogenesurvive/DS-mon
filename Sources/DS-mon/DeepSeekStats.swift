import Foundation
import SwiftUI
import Security

/// DS-mon 数据模型
@MainActor
@Observable
final class DeepSeekStats {
    // swift-ignore: isolated property accessed from deinit
    nonisolated(unsafe) private var blinkTimer: Timer?
    nonisolated(unsafe) private var refreshTimer: Timer?
    private(set) var balance: Double = 0
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
            errorMessage = "保存 API Key 失败：需在钥匙串弹窗中点击「始终允许」"
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
        String(format: "¥%.2f", balance)
    }

    var modelsText: String {
        models.isEmpty ? "—" : models.prefix(3).joined(separator: "\n")
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
            errorMessage = "未设置 API Key"
            return
        }
        isLoading = true
        errorMessage = nil

        Task {
            await fetchBalance()
            await fetchModels()
            isLoading = false
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            lastUpdate = f.string(from: Date())
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
                errorMessage = "查询失败：无效的服务器响应"
                return
            }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let infos = json["balance_infos"] as? [[String: Any]] else {
                    errorMessage = "查询失败：解析响应数据失败"
                    return
                }
                for info in infos where info["currency"] as? String == "CNY" {
                    if let s = info["total_balance"] as? String {
                        balance = Double(s) ?? 0
                    }
                }
            case 401:
                errorMessage = "API Key 无效或已过期"
            case 429:
                errorMessage = "请求过于频繁，请稍后重试"
            case 500...599:
                errorMessage = "DeepSeek 服务暂时不可用"
            default:
                errorMessage = "查询失败（HTTP \(http.statusCode)）"
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                errorMessage = "网络连接超时"
            case .notConnectedToInternet, .networkConnectionLost:
                errorMessage = "网络连接失败"
            default:
                errorMessage = "网络错误：\(error.localizedDescription)"
            }
        } catch {
            errorMessage = "网络错误：\(error.localizedDescription)"
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
