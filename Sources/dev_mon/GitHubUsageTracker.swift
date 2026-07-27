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

    static let empty = GitHubActionsUsage(
        minutesUsed: 0, includedMinutes: 2000,
        storageMB: 0, storageLimitMB: 500,
        paidMinutesUsed: 0, billingCycleDaysLeft: 0
    )
}

// MARK: - GitHub API Client Errors

enum GitHubError: LocalizedError {
    case invalidToken
    case rateLimited
    case notFound
    case freePlan
    case networkError(String)
    case parseFailed

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .invalidToken: return isZH ? "Token 无效或权限不足" : "Invalid token or insufficient permissions"
        case .rateLimited: return isZH ? "API 限流，请稍后重试" : "API rate limited, retry later"
        case .notFound: return isZH ? "用户或组织不存在" : "User or organization not found"
        case .freePlan: return isZH ? "GitHub Actions 用量 API 需要付费计划" : "Billing API requires a paid GitHub plan"
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

        // Fetch minutes usage
        let minutesResult = await callBillingAPI(
            endpoint: "users/\(username)/settings/billing/actions",
            token: token
        )

        // Fetch storage usage
        let storageResult = await callBillingAPI(
            endpoint: "users/\(username)/settings/billing/shared-storage",
            token: token
        )

        switch (minutesResult, storageResult) {
        case let (.success(minutesJSON), .success(storageJSON)):
            let minutesUsed = minutesJSON["total_minutes_used"] as? Int ?? 0
            let includedMinutes = minutesJSON["included_minutes"] as? Int ?? 2000
            let paidMinutes = minutesJSON["total_paid_minutes_used"] as? Int ?? 0

            let storageMB = storageJSON["estimated_storage_for_month"] as? Double ?? 0
            let daysLeft = storageJSON["days_left_in_billing_cycle"] as? Int ?? 0

            usage = GitHubActionsUsage(
                minutesUsed: minutesUsed,
                includedMinutes: includedMinutes,
                storageMB: storageMB,
                storageLimitMB: 500,
                paidMinutesUsed: paidMinutes,
                billingCycleDaysLeft: daysLeft
            )
            errorMessage = nil

        case let (.failure(.freePlan), _), let (_, .failure(.freePlan)):
            // Free plan — billing API not available, use defaults
            usage = .empty
            errorMessage = nil

        case let (.failure(error), _):
            errorMessage = error.localizedDescription
        case let (_, .failure(error)):
            errorMessage = error.localizedDescription
        }
    }

    private func callBillingAPI(endpoint: String, token: String) async -> Result<[String: Any], GitHubError> {
        guard let url = URL(string: "https://api.github.com/\(endpoint)") else {
            return .failure(.networkError("Invalid URL"))
        }

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
                // User exists but billing API returns 404 for free accounts
                return .failure(.freePlan)
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
}

// (isZH helper moved into GitHubError enum)
