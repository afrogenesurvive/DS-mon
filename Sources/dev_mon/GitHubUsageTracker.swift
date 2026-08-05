import Foundation
import SwiftUI

// MARK: - GitHub Actions Usage Data Model

struct GitHubActionsUsage: Sendable, Equatable {
    let minutesUsed: Int
    let includedMinutes: Int
    let storageMB: Double
    let storageLimitMB: Double
    let paidMinutesUsed: Int
    let billingCycleDaysLeft: Int

    var minutesRemaining: Int { max(0, includedMinutes - minutesUsed) }
    var minutesPercentage: Double {
        includedMinutes > 0 ? min(Double(minutesUsed) / Double(includedMinutes) * 100, 100) : 0
    }
    var storagePercentage: Double {
        storageLimitMB > 0 ? min(storageMB / storageLimitMB * 100, 100) : 0
    }
    var isWithinFreeTier: Bool {
        minutesUsed <= includedMinutes && storageMB <= storageLimitMB
    }
    var isMinutesWarning: Bool {
        minutesPercentage >= 80
    }
    var isStorageWarning: Bool {
        storagePercentage >= 80
    }

    /// GitHub Free defaults — the consolidated billing usage API doesn't return
    /// plan allowances, so these remain static (same as before).
    static let defaultIncludedMinutes = 2000
    static let defaultStorageLimitMB = 500.0

    static let empty = GitHubActionsUsage(
        minutesUsed: 0, includedMinutes: defaultIncludedMinutes,
        storageMB: 0, storageLimitMB: defaultStorageLimitMB,
        paidMinutesUsed: 0, billingCycleDaysLeft: 0
    )
}

// MARK: - GitHub API Client Errors

enum GitHubError: LocalizedError {
    case invalidToken
    case rateLimited
    case billingUnavailable
    case networkError(String)
    case parseFailed

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .invalidToken: return isZH ? "Token 无效或权限不足" : "Invalid token or insufficient permissions"
        case .rateLimited: return isZH ? "API 限流，请稍后重试" : "API rate limited, retry later"
        case .billingUnavailable: return isZH ? "当前账号无法访问 GitHub 账单用量 API（404）" : "Billing usage API not available for this account (404)"
        case .networkError(let msg): return isZH ? "网络错误: \(msg)" : "Network error: \(msg)"
        case .parseFailed: return isZH ? "解析响应失败" : "Failed to parse response"
        }
    }

    private static func checkZH() -> Bool {
        let saved = UserDefaults.standard.string(forKey: Strings.Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }
}

// MARK: - GitHub Actions Usage Tracker

/// Polls the GitHub Billing API to track Actions minutes and storage usage.
/// Uses a Personal Access Token (classic) with `read:user` scope.
@MainActor
@Observable
final class GitHubUsageTracker {
    private var refreshTask: Task<Void, Never>?

    private(set) var usage = GitHubActionsUsage.empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"

    /// Whether GitHub tracking is enabled (user must set token + username)
    var isEnabled: Bool {
        !token.isEmpty && !username.isEmpty
    }

    var token: String {
        SecureStore.retrieve(key: Strings.Keys.githubToken) ?? ""
    }

    var username: String {
        UserDefaults.standard.string(forKey: Strings.Keys.githubUsername) ?? ""
    }

    init() {
        if isEnabled {
            startAutoRefresh()
            refresh()
        }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.refreshTask?.cancel()
        }
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.cloudRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled {
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard isEnabled else {
            errorMessage = "GitHub token or username not set"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            await fetchUsage()
            isLoading = false
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            lastUpdate = df.string(from: Date())
        }
    }

    private func fetchUsage() async {
        let token = self.token
        let username = self.username

        let result = await callUsageAPI(username: username, token: token)

        switch result {
        case let .success(json):
            guard let items = json["usageItems"] as? [[String: Any]] else {
                errorMessage = GitHubError.parseFailed.localizedDescription
                return
            }

            var minutesUsed = 0
            var paidMinutes = 0
            var storageMB = 0.0

            for item in items {
                let product = ((item["product"] as? String) ?? "").lowercased()
                let sku = ((item["sku"] as? String) ?? "").lowercased()
                let unitType = ((item["unitType"] as? String) ?? "").lowercased()

                let quantity = (item["quantity"] as? Int)
                    ?? (item["grossQuantity"] as? Int)
                    ?? 0
                let discountQuantity = item["discountQuantity"] as? Int ?? 0
                let netQuantity = item["netQuantity"] as? Int

                // Only GitHub Actions metered products are relevant here.
                guard product == "actions" || sku.contains("actions") else { continue }

                let isCompute = unitType.contains("minute") || unitType.contains("compute")
                    || sku.contains("compute")
                let isStorage = !isCompute && (unitType.contains("storage")
                    || unitType.contains("byte") || unitType.contains("gb") || unitType.contains("mb"))

                if isCompute {
                    minutesUsed += quantity
                    // Overage minutes = total consumed minus the included/discounted portion.
                    paidMinutes += netQuantity ?? max(0, quantity - discountQuantity)
                } else if isStorage {
                    storageMB += Double(quantity)
                }
            }

            usage = GitHubActionsUsage(
                minutesUsed: minutesUsed,
                includedMinutes: GitHubActionsUsage.defaultIncludedMinutes,
                storageMB: storageMB,
                storageLimitMB: GitHubActionsUsage.defaultStorageLimitMB,
                paidMinutesUsed: paidMinutes,
                billingCycleDaysLeft: Self.daysLeftInCurrentMonth()
            )
            errorMessage = nil

        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    /// Consolidated billing usage report — replaced the deprecated
    /// `/settings/billing/actions` and `/settings/billing/shared-storage`
    /// endpoints (closed down by GitHub on 2025-09-26).
    /// Requires a classic PAT. Scoped to the current year+month (the Actions
    /// billing cycle) to keep the payload small.
    private func callUsageAPI(username: String, token: String) async -> Result<[String: Any], GitHubError> {
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)

        guard var url = URL(string: "https://api.github.com/users/\(username)/settings/billing/usage") else {
            return .failure(.networkError("Invalid URL"))
        }
        url.append(queryItems: [
            URLQueryItem(name: "year", value: String(year)),
            URLQueryItem(name: "month", value: String(month))
        ])

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = AppConfig.cloudRequestTimeout

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(.networkError("Invalid response"))
            }

            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(.parseFailed)
                }
                return .success(json)
            case 401, 403:
                return .failure(.invalidToken)
            case 404:
                return .failure(.billingUnavailable)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(.networkError("HTTP \(http.statusCode)"))
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure(.networkError("Timeout"))
            case .notConnectedToInternet, .networkConnectionLost:
                return .failure(.networkError("No network"))
            default:
                return .failure(.networkError(error.localizedDescription))
            }
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    /// Approximates the old `days_left_in_billing_cycle` field, which the
    /// consolidated API no longer returns. Actions minutes reset monthly.
    private static func daysLeftInCurrentMonth() -> Int {
        let cal = Calendar.current
        let now = Date()
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let day = cal.component(.day, from: now)
        return max(0, daysInMonth - day)
    }
}

// (isZH helper moved into GitHubError enum)
