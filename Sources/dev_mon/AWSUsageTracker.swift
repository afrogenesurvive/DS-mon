import Foundation
import SwiftUI

// MARK: - AWS EC2 Free Tier Data Model

struct NonEligibleInstance: Sendable, Equatable, Identifiable {
    let instanceId: String
    let instanceType: String
    var id: String { instanceId }
}

struct AWSFreeTierStatus: Sendable, Equatable {
    let ec2RunningHours: Double
    let freeTierLimitHours: Double
    let instanceCount: Int
    let eligibleCount: Int
    let nonEligibleCount: Int
    let nonEligibleInstances: [NonEligibleInstance]
    let forecastedHours: Double?
    let estimatedOverageCost: Double

    var usagePercentage: Double {
        freeTierLimitHours > 0 ? min(ec2RunningHours / freeTierLimitHours * 100, 100) : 0
    }
    var hoursRemaining: Double { max(0, freeTierLimitHours - ec2RunningHours) }
    var isWithinFreeTier: Bool { ec2RunningHours <= freeTierLimitHours && nonEligibleCount == 0 }
    var isWarning: Bool { usagePercentage >= 80 || nonEligibleCount > 0 }

    static let empty = AWSFreeTierStatus(
        ec2RunningHours: 0, freeTierLimitHours: 750,
        instanceCount: 0, eligibleCount: 0, nonEligibleCount: 0,
        nonEligibleInstances: [],
        forecastedHours: nil, estimatedOverageCost: 0
    )
}

// MARK: - AWS Billing Snapshot (Cost Explorer)

struct AWSBillingSnapshot: Sendable, Equatable {
    let monthToDateCost: Double      // total unblended cost, current month
    let ec2Cost: Double              // EC2-only cost
    let creditsApplied: Double       // all credits applied this month (positive $)
    let ec2CreditsApplied: Double    // credits applied to EC2 (positive $)
    let forecastedCost: Double?      // month-end cost forecast
    let maxCredits: Double           // user-entered total credit balance (manual)

    /// Remaining credit balance = manual max minus credits applied this month.
    var remainingCredits: Double { max(0, maxCredits - creditsApplied) }

    /// Cumulative Credit records summed over Cost Explorer history (positive $).
    let lifetimeCreditsApplied: Double
    let lifetimeEc2CreditsApplied: Double

    static let empty = AWSBillingSnapshot(
        monthToDateCost: 0, ec2Cost: 0,
        creditsApplied: 0, ec2CreditsApplied: 0,
        forecastedCost: nil, maxCredits: 0,
        lifetimeCreditsApplied: 0, lifetimeEc2CreditsApplied: 0
    )
}

// MARK: - AWS Error

enum AWSError: LocalizedError {
    case invalidCredentials
    case accessDenied
    case networkError(String)
    case parseFailed
    case regionRequired

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .invalidCredentials: return isZH ? "AWS 凭证无效" : "Invalid AWS credentials"
        case .accessDenied: return isZH ? "权限不足（需要 ec2:DescribeInstances 和 ce:GetCostAndUsage）" : "Insufficient permissions (need ec2:DescribeInstances and ce:GetCostAndUsage)"
        case .networkError(let msg): return isZH ? "网络错误: \(msg)" : "Network error: \(msg)"
        case .parseFailed: return isZH ? "解析响应失败" : "Failed to parse response"
        case .regionRequired: return isZH ? "请选择区域" : "Please select a region"
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

// MARK: - AWS EC2 Usage Tracker

/// Polls AWS EC2 API to track free tier instance usage.
/// Uses direct EC2 DescribeInstances API + SigV4 signing.
/// Calculates running hours from LaunchTime for running instances.
@MainActor
@Observable
final class AWSUsageTracker {
    private var refreshTask: Task<Void, Never>?

    private(set) var status = AWSFreeTierStatus.empty
    private(set) var billing = AWSBillingSnapshot.empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"

    var isEnabled: Bool {
        !accessKey.isEmpty && !secretKey.isEmpty
    }

    var accessKey: String {
        SecureStore.retrieve(key: Strings.Keys.awsAccessKey) ?? ""
    }
    var secretKey: String {
        SecureStore.retrieve(key: Strings.Keys.awsSecretKey) ?? ""
    }
    var region: String {
        UserDefaults.standard.string(forKey: Strings.Keys.awsRegion) ?? "us-east-1"
    }
    /// User-entered total credit balance (from Billing → Credits). Used to derive remaining credits.
    var maxCredits: Double {
        get { UserDefaults.standard.double(forKey: Strings.Keys.awsMaxCredits) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Strings.Keys.awsMaxCredits) }
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
            errorMessage = AWSError.invalidCredentials.localizedDescription
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            await fetchEC2Usage()
            await fetchBillingCredits()
            isLoading = false
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            lastUpdate = df.string(from: Date())
        }
    }

    private func fetchEC2Usage() async {
        let ak = accessKey
        let sk = secretKey
        let r = region

        guard !ak.isEmpty, !sk.isEmpty else {
            errorMessage = AWSError.invalidCredentials.localizedDescription
            return
        }

        // Build EC2 DescribeInstances request
        let payload = "Action=DescribeInstances&Version=2016-11-15"
        guard let url = URL(string: "https://ec2.\(r).amazonaws.com/") else {
            errorMessage = AWSError.networkError("Invalid URL").localizedDescription
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(payload.utf8)

        let signer = SigV4Signer(region: r, service: "ec2", accessKey: ak, secretKey: sk)
        signer.sign(request: &req, payload: req.httpBody)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                errorMessage = AWSError.networkError("Invalid response").localizedDescription
                return
            }

            switch http.statusCode {
            case 200:
                parseEC2Response(data)
            case 401, 403:
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("AuthFailure") || body.contains("InvalidClientTokenId") {
                    errorMessage = AWSError.invalidCredentials.localizedDescription
                } else {
                    errorMessage = AWSError.accessDenied.localizedDescription
                }
            default:
                errorMessage = AWSError.networkError("HTTP \(http.statusCode)").localizedDescription
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                errorMessage = AWSError.networkError("Timeout").localizedDescription
            case .notConnectedToInternet, .networkConnectionLost:
                errorMessage = AWSError.networkError("No network").localizedDescription
            default:
                errorMessage = AWSError.networkError(error.localizedDescription).localizedDescription
            }
        } catch {
            errorMessage = AWSError.networkError(error.localizedDescription).localizedDescription
        }
    }

    // MARK: - Billing & Credits (Cost Explorer)

    /// Pulls current-month spend, credits applied (RECORD_TYPE = Credit), and a
    /// month-end forecast from the AWS Cost Explorer API (service `ce`).
    private func fetchBillingCredits() async {
        let ak = accessKey
        let sk = secretKey
        guard !ak.isEmpty, !sk.isEmpty else { return }

        let now = Date()
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? now

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(abbreviation: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        let period = "\"Start\":\"\(df.string(from: start))\",\"End\":\"\(df.string(from: end))\""

        // Month-to-date cost grouped by service (EC2 key = "Amazon Elastic Compute Cloud - Compute")
        var monthToDateCost = 0.0
        var ec2Cost = 0.0
        let costBody = """
        {"TimePeriod":{\(period)},"Granularity":"MONTHLY",
         "Metrics":["UnblendedCost","NetUnblendedCost"],
         "GroupBy":[{"Type":"DIMENSION","Key":"SERVICE"}]}
        """
        if let json = await callCostExplorer(action: "GetCostAndUsage", body: costBody, ak: ak, sk: sk) {
            for time in json["ResultsByTime"] as? [[String: Any]] ?? [] {
                for group in time["Groups"] as? [[String: Any]] ?? [] {
                    let keys = group["Keys"] as? [String] ?? []
                    let amountDict = (group["Metrics"] as? [String: Any])?["UnblendedCost"] as? [String: Any]
                    let value = Double(amountDict?["Amount"] as? String ?? "0") ?? 0
                    monthToDateCost += value
                    if keys.first?.contains("Elastic Compute Cloud") == true {
                        ec2Cost += value
                    }
                }
            }
        }

        // Credits applied this month (negative amounts) — total + EC2 only
        var creditsApplied = 0.0
        var ec2CreditsApplied = 0.0
        let creditsBody = """
        {"TimePeriod":{\(period)},"Granularity":"MONTHLY",
         "Metrics":["UnblendedCost"],
         "Filter":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit"]}},
         "GroupBy":[{"Type":"DIMENSION","Key":"SERVICE"}]}
        """
        if let json = await callCostExplorer(action: "GetCostAndUsage", body: creditsBody, ak: ak, sk: sk) {
            for time in json["ResultsByTime"] as? [[String: Any]] ?? [] {
                for group in time["Groups"] as? [[String: Any]] ?? [] {
                    let keys = group["Keys"] as? [String] ?? []
                    let amountDict = (group["Metrics"] as? [String: Any])?["UnblendedCost"] as? [String: Any]
                    let value = abs(Double(amountDict?["Amount"] as? String ?? "0") ?? 0)
                    creditsApplied += value
                    if keys.first?.contains("Elastic Compute Cloud") == true {
                        ec2CreditsApplied += value
                    }
                }
            }
        }

        // Month-end cost forecast
        let forecastedCost = await callCostForecast(ak: ak, sk: sk)

        // Lifetime (cumulative) credits applied across Cost Explorer history.
        let lifetime = await fetchLifetimeCredits(ak: ak, sk: sk)

        billing = AWSBillingSnapshot(
            monthToDateCost: monthToDateCost,
            ec2Cost: ec2Cost,
            creditsApplied: creditsApplied,
            ec2CreditsApplied: ec2CreditsApplied,
            forecastedCost: forecastedCost,
            maxCredits: maxCredits,
            lifetimeCreditsApplied: lifetime.total,
            lifetimeEc2CreditsApplied: lifetime.ec2
        )
    }

    // MARK: - Lifetime Credits (Cost Explorer historical sum)

    /// Sums Credit records across the account's Cost Explorer history, paged in
    /// ~12-month windows (granularity MONTHLY). AWS only retains ~13 months via
    /// this API, so the result is bounded by that window. Non-200 responses are
    /// skipped (partial sums are kept) — never fatal.
    private func fetchLifetimeCredits(ak: String, sk: String) async -> (total: Double, ec2: Double) {
        let now = Date()
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let end = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now
        // Start from the earliest month Cost Explorer retains (~13 months back).
        guard let earliest = cal.date(byAdding: .month, value: -12, to: monthStart) else {
            return (0, 0)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(abbreviation: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")

        var total = 0.0
        var ec2 = 0.0
        var cursor = earliest
        while cursor < end {
            let windowEnd = min(end, cal.date(byAdding: .month, value: 12, to: cursor) ?? end)
            let period = "\"Start\":\"\(df.string(from: cursor))\",\"End\":\"\(df.string(from: windowEnd))\""
            let body = """
            {\"TimePeriod\":{\(period)},\"Granularity\":\"MONTHLY\",
             \"Metrics\":[\"UnblendedCost\"],
             \"Filter\":{\"Dimensions\":{\"Key\":\"RECORD_TYPE\",\"Values\":[\"Credit\"]}},
             \"GroupBy\":[{\"Type\":\"DIMENSION\",\"Key\":\"SERVICE\"}]}
            """
            if let json = await callCostExplorer(action: "GetCostAndUsage", body: body, ak: ak, sk: sk) {
                for time in json["ResultsByTime"] as? [[String: Any]] ?? [] {
                    for group in time["Groups"] as? [[String: Any]] ?? [] {
                        let keys = group["Keys"] as? [String] ?? []
                        let amountDict = (group["Metrics"] as? [String: Any])?["UnblendedCost"] as? [String: Any]
                        let value = abs(Double(amountDict?["Amount"] as? String ?? "0") ?? 0)
                        total += value
                        if keys.first?.contains("Elastic Compute Cloud") == true {
                            ec2 += value
                        }
                    }
                }
            }
            cursor = windowEnd
        }
        return (total, ec2)
    }

    private func callCostExplorer(action: String, body: String, ak: String, sk: String) async -> [String: Any]? {
        guard let url = URL(string: "https://ce.us-east-1.amazonaws.com/") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue("AWSInsightsIndexService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        req.httpBody = Data(body.utf8)
        let signer = SigV4Signer(region: "us-east-1", service: "ce", accessKey: ak, secretKey: sk)
        signer.sign(request: &req, payload: req.httpBody)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func callCostForecast(ak: String, sk: String) async -> Double? {
        let now = Date()
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(abbreviation: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        let body = """
        {"TimePeriod":{"Start":"\(df.string(from: now))","End":"\(df.string(from: monthEnd))"},
         "Granularity":"MONTHLY","Metric":"UNBLENDED_COST"}
        """
        guard let url = URL(string: "https://ce.us-east-1.amazonaws.com/") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue("AWSInsightsIndexService.GetCostForecast", forHTTPHeaderField: "X-Amz-Target")
        req.httpBody = Data(body.utf8)
        let signer = SigV4Signer(region: "us-east-1", service: "ce", accessKey: ak, secretKey: sk)
        signer.sign(request: &req, payload: req.httpBody)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let total = json?["Total"] as? [String: Any],
                  let amount = total["Amount"] as? String else { return nil }
            return Double(amount)
        } catch {
            return nil
        }
    }

    private func parseEC2Response(_ data: Data) {
        guard let xml = String(data: data, encoding: .utf8) else {
            errorMessage = AWSError.parseFailed.localizedDescription
            return
        }

        // Parse the XML response to extract instance information
        // We use a simple XML tag scanner approach to avoid Foundation XML dependency issues
        let instanceTags = extractTags(xml, tag: "item")

        var totalRunningHours: Double = 0
        var totalInstances = 0
        var eligibleInstances = 0
        var nonEligibleInstances: [NonEligibleInstance] = []

        let eligibleTypes = ["t2.micro", "t3.micro", "t4g.micro"]
        let now = Date()

        for instanceXML in instanceTags where instanceXML.contains("<instanceType>") {
            totalInstances += 1

            guard let instanceType = extractSingleTag(instanceXML, tag: "instanceType"),
                  let stateName = extractSingleTag(instanceXML, tag: "name")?.lowercased() else {
                continue
            }

            let isEligible = eligibleTypes.contains(instanceType)

            // Only running instances count toward free-tier hours. Hours are measured
            // since the instance was last launched, clamped to the start of the current
            // calendar month (the free tier is 750 hrs per calendar month).
            if stateName == "running" {
                if let launchTimeStr = extractSingleTag(instanceXML, tag: "launchTime") {
                    let df = ISO8601DateFormatter()
                    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let launchTime = df.date(from: launchTimeStr) ?? {
                        df.formatOptions = [.withInternetDateTime]
                        return df.date(from: launchTimeStr)
                    }() {
                        let monthStart = Calendar.current.date(
                            from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
                        let effective = max(launchTime, monthStart)
                        let hours = max(0, now.timeIntervalSince(effective)) / 3600
                        totalRunningHours += hours
                    }
                }
            }

            let instanceId = extractSingleTag(instanceXML, tag: "instanceId") ?? "unknown"

            if isEligible {
                eligibleInstances += 1
            } else {
                nonEligibleInstances.append(NonEligibleInstance(instanceId: instanceId, instanceType: instanceType))
            }
        }

        // Calculate forecast: project to end of month
        let calendar = Calendar.current
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = calendar.component(.day, from: now) // note: 'now' is already declared above
        let daysRemaining = max(1, (daysInMonth as Int) - dayOfMonth + 1)
        let dailyAverage = max(1, dayOfMonth) > 0 ? totalRunningHours / Double(max(1, dayOfMonth)) : 0
        let forecasted = totalRunningHours + (dailyAverage * Double(daysRemaining))

        // Estimate cost for non-eligible instances (rough: ~$30/mo for t3.medium)
        let overageCost = Double(nonEligibleInstances.count) * 30.0 * (Double(dayOfMonth) / Double(daysInMonth))

        status = AWSFreeTierStatus(
            ec2RunningHours: totalRunningHours,
            freeTierLimitHours: 750,
            instanceCount: totalInstances,
            eligibleCount: eligibleInstances,
            nonEligibleCount: nonEligibleInstances.count,
            nonEligibleInstances: nonEligibleInstances.sorted(by: { $0.instanceId < $1.instanceId }),
            forecastedHours: forecasted,
            estimatedOverageCost: overageCost
        )
        errorMessage = nil
    }

    // MARK: - Simple XML Parser Helpers

    private func extractSingleTag(_ xml: String, tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let startRange = xml.range(of: open),
              let endRange = xml.range(of: close, range: startRange.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[startRange.upperBound..<endRange.lowerBound])
    }

    private func extractTags(_ xml: String, tag: String) -> [String] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var results: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex

        while true {
            guard let startRange = xml.range(of: open, range: searchRange),
                  let endRange = xml.range(of: close, range: startRange.upperBound..<xml.endIndex) else {
                break
            }
            let content = String(xml[startRange.lowerBound..<endRange.upperBound])
            results.append(content)
            searchRange = endRange.upperBound..<xml.endIndex
        }
        return results
    }
}
