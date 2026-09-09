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

// MARK: - GitHub Repositories Data Models

/// A single repository (from `GET /users/{username}/repos`).
struct GitHubRepo: Identifiable, Equatable, Sendable {
    let owner: String
    let name: String
    let isPrivate: Bool
    let createdAt: Date?
    let defaultBranch: String
    let htmlURL: String
    let desc: String?

    var id: String { "\(owner)/\(name)" }
    var fullName: String { id }
    var cloneURL: String { "https://github.com/\(id).git" }
}

struct GitHubCommit: Identifiable, Equatable, Sendable {
    let sha: String
    let message: String
    let author: String
    let date: Date?
    let htmlURL: String

    var id: String { sha }
    var shortSha: String { String(sha.prefix(7)) }
}

struct GitHubBranch: Identifiable, Equatable, Sendable {
    let name: String
    /// 分支最近一次提交时间（用于按新旧排序；取不到时为 nil）
    let lastCommitAt: Date?
    var id: String { name }
}

struct GitHubRelease: Identifiable, Equatable, Sendable {
    let tag: String
    let name: String
    let published: Date?
    let htmlURL: String

    var id: String { tag }
}

struct GitHubRepoDetail: Equatable, Sendable {
    var commits: [GitHubCommit] = []
    var branches: [GitHubBranch] = []
    var releases: [GitHubRelease] = []
}

// MARK: - GitHub API Client Errors

enum GitHubError: LocalizedError {
    case invalidToken
    case rateLimited
    case billingUnavailable
    case notFound
    case networkError(String)
    case parseFailed

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .invalidToken: return isZH ? "Token 无效或权限不足" : "Invalid token or insufficient permissions"
        case .rateLimited: return isZH ? "API 限流，请稍后重试" : "API rate limited, retry later"
        case .billingUnavailable: return isZH ? "当前账号无法访问 GitHub 账单用量 API（404）" : "Billing usage API not available for this account (404)"
        case .notFound: return isZH ? "用户或组织不存在（404），或 token 无权访问" : "GitHub user/org not found (404), or token lacks access"
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

/// Tracks GitHub Actions usage (Billing API) and the account's repositories
/// (repos/commits/branches/releases API).
/// Uses a Personal Access Token (classic); `repo` scope is required to include
/// private repositories.
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
            refreshRepos()
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
                    self.refreshRepos()
                    if let last = self.lastRequestedRepo {
                        self.loadRepoDetail(fullName: last)
                    }
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

    // MARK: - Repositories (list + per-repo detail)

    private(set) var repos: [GitHubRepo] = []
    private(set) var reposLoading = false
    private(set) var reposError: String?
    private(set) var repoDetail: GitHubRepoDetail?
    private(set) var repoDetailLoading = false
    private(set) var repoDetailFor: String?
    private var lastRequestedRepo: String?
    private var reposLastFetched: Date?
    private var repoDetailCache: [String: (detail: GitHubRepoDetail, at: Date)] = [:]
    private let repoDetailCacheTTL: TimeInterval = 300

    /// Fetches the repo list. Throttled (~30s) so re-shows of the tab don't re-hit the API.
    func refreshRepos() {
        guard isEnabled else {
            repos = []
            reposError = nil
            return
        }
        if let last = reposLastFetched, Date().timeIntervalSince(last) < 30 { return }
        if reposLoading { return }
        reposLoading = true
        reposLastFetched = Date()
        let token = self.token
        let username = self.username
        Task {
            let result = await fetchRepos(username: username, token: token)
            reposLoading = false
            switch result {
            case .success(let list):
                repos = list
                reposError = nil
            case .failure(let error):
                // Keep an already-loaded list on transient failures; only surface
                // errors when there is nothing to show yet.
                if repos.isEmpty { reposError = error.localizedDescription }
            }
        }
    }

    /// Loads detail (commits/branches/releases) for the selected repo, with a short cache.
    func loadRepoDetail(fullName: String) {
        lastRequestedRepo = fullName
        guard isEnabled else { return }
        if repoDetailFor == fullName && repoDetailLoading { return }
        if let cached = repoDetailCache[fullName],
           Date().timeIntervalSince(cached.at) < repoDetailCacheTTL {
            repoDetail = cached.detail
            repoDetailFor = fullName
            return
        }
        repoDetailLoading = true
        repoDetailFor = fullName
        let token = self.token
        Task {
            let detail = await fetchRepoDetail(fullName: fullName, token: token)
            repoDetailLoading = false
            if let detail {
                repoDetail = detail
                repoDetailCache[fullName] = (detail, Date())
            } else {
                repoDetail = nil
            }
        }
    }

    // MARK: - Repos networking

    /// `GET /user/repos` returns ALL repositories the token can see — public AND
    /// private (owned + collaborator + org membership). The old
    /// `/users/{username}/repos` endpoint only ever returned PUBLIC repos, so
    /// private repos were missing. Needs a PAT with the `repo` scope to include
    /// private repos. The configured `username` is still used by the Actions
    /// billing call.
    private func fetchRepos(username: String, token: String) async -> Result<[GitHubRepo], GitHubError> {
        guard var url = URL(string: "https://api.github.com/user/repos") else {
            return .failure(.networkError("Invalid URL"))
        }
        url.append(queryItems: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "visibility", value: "all"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member")
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
                guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return .failure(.parseFailed)
                }
                return .success(arr.compactMap { Self.parseRepo($0) })
            case 401, 403:
                return .failure(.invalidToken)
            case 404:
                return .failure(.notFound)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(.networkError("HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    /// Fetches the last few commits + branches + releases for one repo in parallel.
    private func fetchRepoDetail(fullName: String, token: String) async -> GitHubRepoDetail? {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]

        async let c = fetchCommits(owner: owner, repo: repo, token: token)
        async let b = fetchBranches(owner: owner, repo: repo, token: token)
        async let r = fetchReleases(owner: owner, repo: repo, token: token)
        let (commits, branches, releases) = await (c, b, r)
        return GitHubRepoDetail(commits: commits, branches: branches, releases: releases)
    }

    private func fetchCommits(owner: String, repo: String, token: String) async -> [GitHubCommit] {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits?per_page=10"),
              let data = await ghGET(url: url, token: token),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { Self.parseCommit($0) }
    }

    /// Branches sorted most-recent-first: the REST list-branches endpoint has no
    /// recency ordering, so we fetch each branch's latest commit date (bounded
    /// concurrency ~8) and sort descending by it. Branches without a resolvable
    /// date sort to the bottom (by name).
    private func fetchBranches(owner: String, repo: String, token: String) async -> [GitHubBranch] {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/branches?per_page=100"),
              let data = await ghGET(url: url, token: token),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let names = arr.compactMap { $0["name"] as? String }

        // 分批并发取每条分支的最新提交时间（限制同时飞行的请求数）
        var dates: [String: Date] = [:]
        let batchSize = 8
        var index = 0
        while index < names.count {
            let slice = names[index..<min(index + batchSize, names.count)]
            index += batchSize
            await withTaskGroup(of: (String, Date?).self) { group in
                for name in slice {
                    group.addTask {
                        let d = await self.fetchBranchLastCommit(owner: owner, repo: repo,
                                                                 branch: name, token: token)
                        return (name, d)
                    }
                }
                for await (name, d) in group {
                    if let d { dates[name] = d }
                }
            }
        }

        return names
            .map { GitHubBranch(name: $0, lastCommitAt: dates[$0]) }
            .sorted { lhs, rhs in
                let a = lhs.lastCommitAt ?? .distantPast
                let b = rhs.lastCommitAt ?? .distantPast
                if a == b { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return a > b
            }
    }

    /// 某条分支最近一次提交时间（`commits?sha=<分支>&per_page=1` 的首条）。
    private func fetchBranchLastCommit(owner: String, repo: String, branch: String,
                                       token: String) async -> Date? {
        var comps = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/commits")
        comps?.queryItems = [
            URLQueryItem(name: "sha", value: branch),
            URLQueryItem(name: "per_page", value: "1")
        ]
        guard let url = comps?.url,
              let data = await ghGET(url: url, token: token),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let commit = first["commit"] as? [String: Any]
        else { return nil }
        let committerDate = (commit["committer"] as? [String: Any])?["date"] as? String
        let authorDate = (commit["author"] as? [String: Any])?["date"] as? String
        return Self.parseDate(committerDate) ?? Self.parseDate(authorDate)
    }

    private func fetchReleases(owner: String, repo: String, token: String) async -> [GitHubRelease] {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=10"),
              let data = await ghGET(url: url, token: token),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { item in
            guard let tag = item["tag_name"] as? String else { return nil }
            let html = item["html_url"] as? String
                ?? "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)"
            return GitHubRelease(tag: tag,
                                 name: item["name"] as? String ?? tag,
                                 published: Self.parseDate(item["published_at"] as? String),
                                 htmlURL: html)
        }
    }

    /// Simple authed GET that only returns payload data on a 200 (used for detail calls).
    private func ghGET(url: URL, token: String) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = AppConfig.cloudRequestTimeout
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func parseRepo(_ dict: [String: Any]) -> GitHubRepo? {
        guard let full = dict["full_name"] as? String else { return nil }
        let parts = full.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return GitHubRepo(owner: parts[0],
                          name: parts[1],
                          isPrivate: dict["private"] as? Bool ?? false,
                          createdAt: parseDate(dict["created_at"] as? String),
                          defaultBranch: dict["default_branch"] as? String ?? "main",
                          htmlURL: dict["html_url"] as? String ?? "https://github.com/\(full)",
                          desc: dict["description"] as? String)
    }

    private static func parseCommit(_ dict: [String: Any]) -> GitHubCommit? {
        guard let sha = dict["sha"] as? String else { return nil }
        let commit = dict["commit"] as? [String: Any] ?? [:]
        let message = ((commit["message"] as? String) ?? "")
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let author = (dict["author"] as? [String: Any])?["login"] as? String
            ?? (commit["author"] as? [String: Any])?["name"] as? String
            ?? "unknown"
        let date = parseDate((commit["author"] as? [String: Any])?["date"] as? String)
        return GitHubCommit(sha: sha,
                            message: message,
                            author: author,
                            date: date,
                            htmlURL: dict["html_url"] as? String ?? "https://github.com/\(sha)")
    }

    /// GitHub timestamps are ISO-8601 (optionally with fractional seconds).
    private static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// (isZH helper moved into GitHubError enum)
