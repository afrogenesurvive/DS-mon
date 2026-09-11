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

// MARK: - AWS EC2 Instance (for the Instances management pane)

struct AWSInstance: Sendable, Equatable, Identifiable {
    let instanceId: String
    let instanceType: String
    let state: String              // pending | running | shutting-down | terminating | stopping | stopped
    let launchTime: Date?
    let publicIp: String?
    let publicDns: String?         // EC2 公网 DNS 名（实例运行后才有值）
    let privateIp: String?
    let name: String?              // from the "Name" tag
    let securityGroupIds: [String]
    let securityGroupNames: [String]

    var id: String { instanceId }
    var isRunning: Bool { state == "running" }
    var isStopped: Bool { state == "stopped" }
    var isTransitional: Bool { ["pending", "stopping", "shutting-down", "terminating"].contains(state) }
    var isEligibleFreeTier: Bool { Self.eligibleTypes.contains(instanceType) }
    var primarySecurityGroupId: String? { securityGroupIds.first }

    /// Uptime in hours since last launch (only meaningful while running).
    var runningHours: Double? {
        guard isRunning, let launchTime else { return nil }
        return max(0, Date().timeIntervalSince(launchTime)) / 3600
    }

    static let eligibleTypes = ["t2.micro", "t3.micro", "t4g.micro"]
}

// MARK: - AWS Ingress Helpers

enum AWSIngressCheck: Sendable, Equatable {
    case unknown   // couldn't resolve IP or read the SG
    case open      // RDP (tcp/3389) already reachable from myIP/32, 0.0.0.0/0, or ::/0
    case closed    // needs a rule added
}

struct AWSIngressRule: Sendable, Equatable, Identifiable {
    enum Source: Sendable, Equatable {
        case cidr(String)                            // IPv4 网段，如 0.0.0.0/0
        case ipv6(String)                            // IPv6 网段，如 ::/0
        case group(groupId: String, groupName: String?)  // 对端安全组
    }

    let proto: String       // "tcp" | "udp" | "icmp" | "-1"
    let fromPort: Int?
    let toPort: Int?
    let source: Source
    let description: String?

    var id: String {
        let src: String
        switch source {
        case .cidr(let c): src = "cidr:" + c
        case .ipv6(let c): src = "ipv6:" + c
        case .group(let gid, let name): src = "group:" + gid + ":" + (name ?? "")
        }
        return "\(proto)|\(fromPort ?? 0)|\(toPort ?? 0)|\(description ?? "")|\(src)"
    }

    var protocolDisplay: String {
        switch proto {
        case "-1": return Strings.awsAllTraffic
        case "tcp": return "TCP"
        case "udp": return "UDP"
        case "icmp": return "ICMP"
        default: return proto.uppercased()
        }
    }

    var sourceDisplay: String {
        switch source {
        case .cidr(let c): return c
        case .ipv6(let c): return c
        case .group(let gid, let name): return name ?? gid
        }
    }

    /// 该规则是否允许来自 `cidrs` 中任一段的 `port`（用于 RDP 快速检查）。
    func allows(port: Int, from cidrs: [String]) -> Bool {
        let protoOK = proto == "tcp" || proto == "6" || proto == "-1"
        guard protoOK else { return false }
        if proto != "-1" {
            let lo = fromPort ?? 0
            let hi = toPort ?? 65535
            guard (lo...hi).contains(port) else { return false }
        }
        switch source {
        case .cidr(let c): return cidrs.contains(c)
        case .ipv6(let c): return cidrs.contains(c)
        case .group: return false
        }
    }
}

private func dedupe(_ arr: [String]) -> [String] {
    var seen = Set<String>()
    return arr.filter { seen.insert($0).inserted }
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
        case .accessDenied: return isZH ? "权限不足（需要 ec2:DescribeInstances、ec2:DescribeSecurityGroups、ec2:Start/StopInstances、ec2:AuthorizeSecurityGroupIngress、ec2:RevokeSecurityGroupIngress 和 ce:GetCostAndUsage）" : "Insufficient permissions (need ec2:DescribeInstances/DescribeSecurityGroups, ec2:Start/StopInstances, ec2:AuthorizeSecurityGroupIngress, ec2:RevokeSecurityGroupIngress and ce:GetCostAndUsage)"
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
    private(set) var instances: [AWSInstance] = []
    private(set) var myPublicIP: String?
    private(set) var myPublicIPUpdatedAt: Date?
    /// groupId -> whether RDP (tcp:3389) is open to the caller's IP (filled lazily).
    private(set) var rdpIngress: [String: AWSIngressCheck] = [:]
    /// groupId -> inbound rules of that security group (loaded on selection).
    private(set) var sgRules: [String: [AWSIngressRule]] = [:]
    /// groupId -> group name (from DescribeSecurityGroups).
    private(set) var sgNames: [String: String] = [:]

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

        instances = parseInstances(from: xml).sorted { $0.instanceId < $1.instanceId }

        // Continuously-running warning: evaluate every refresh so an instance left on
        // alerts after the threshold and repeats while it stays up.
        InstanceRunWatch.shared.evaluate(instances)

        let now = Date()
        let monthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now

        // Only running instances count toward free-tier hours. Hours are measured
        // since the instance was last launched, clamped to the start of the current
        // calendar month (the free tier is 750 hrs per calendar month).
        var totalRunningHours: Double = 0
        for inst in instances where inst.isRunning {
            if let launch = inst.launchTime {
                let effective = max(launch, monthStart)
                totalRunningHours += max(0, now.timeIntervalSince(effective)) / 3600
            }
        }

        let eligibleCount = instances.filter { $0.isEligibleFreeTier }.count
        let nonEligible = instances
            .filter { !$0.isEligibleFreeTier }
            .map { NonEligibleInstance(instanceId: $0.instanceId, instanceType: $0.instanceType) }

        // Calculate forecast: project to end of month
        let calendar = Calendar.current
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = calendar.component(.day, from: now)
        let daysRemaining = max(1, daysInMonth - dayOfMonth + 1)
        let dailyAverage = dayOfMonth > 0 ? totalRunningHours / Double(max(1, dayOfMonth)) : 0
        let forecasted = totalRunningHours + (dailyAverage * Double(daysRemaining))

        // Estimate cost for non-eligible instances (rough: ~$30/mo for t3.medium)
        let overageCost = Double(nonEligible.count) * 30.0 * (Double(dayOfMonth) / Double(daysInMonth))

        status = AWSFreeTierStatus(
            ec2RunningHours: totalRunningHours,
            freeTierLimitHours: 750,
            instanceCount: instances.count,
            eligibleCount: eligibleCount,
            nonEligibleCount: nonEligible.count,
            nonEligibleInstances: nonEligible.sorted(by: { $0.instanceId < $1.instanceId }),
            forecastedHours: forecasted,
            estimatedOverageCost: overageCost
        )
        errorMessage = nil
    }

    /// Parses each EC2 instance block. Blocks are anchored on `<instanceId>` markers
    /// because security groups use nested `<item>` elements that the naive tag scanner
    /// (which pairs the next `</item>`) would mis-handle.
    private func parseInstances(from xml: String) -> [AWSInstance] {
        let marker = "<instanceId>"
        var markers: [Range<String.Index>] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let r = xml.range(of: marker, range: searchRange) {
            markers.append(r)
            searchRange = r.upperBound..<xml.endIndex
        }

        var result: [AWSInstance] = []
        for (i, m) in markers.enumerated() {
            let blockEnd = (i + 1 < markers.count) ? markers[i + 1].lowerBound : xml.endIndex
            let block = String(xml[m.lowerBound..<blockEnd])
            guard let instanceId = extractSingleTag(block, tag: "instanceId"),
                  let instanceType = extractSingleTag(block, tag: "instanceType") else { continue }
            let state = extractSingleTag(block, tag: "name")?.lowercased() ?? "unknown"
            result.append(AWSInstance(
                instanceId: instanceId,
                instanceType: instanceType,
                state: state,
                launchTime: parseISODate(extractSingleTag(block, tag: "launchTime")),
                publicIp: extractSingleTag(block, tag: "publicIp") ?? extractSingleTag(block, tag: "ipAddress"),
                publicDns: extractSingleTag(block, tag: "dnsName") ?? extractSingleTag(block, tag: "publicDnsName"),
                privateIp: extractSingleTag(block, tag: "privateIpAddress"),
                name: extractTagValue(block, key: "Name"),
                securityGroupIds: dedupe(extractAll(block, tag: "groupId")),
                securityGroupNames: dedupe(extractAll(block, tag: "groupName"))
            ))
        }
        return result
    }

    private func parseISODate(_ str: String?) -> Date? {
        guard let str = str, !str.isEmpty else { return nil }
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return df.date(from: str) ?? {
            df.formatOptions = [.withInternetDateTime]
            return df.date(from: str)
        }()
    }

    /// Reads the value of a resource tag with the given key (e.g. `Name`).
    private func extractTagValue(_ xml: String, key: String) -> String? {
        let keyTag = "<key>\(key)</key>"
        guard let keyRange = xml.range(of: keyTag),
              let vStart = xml.range(of: "<value>", range: keyRange.upperBound..<xml.endIndex),
              let vEnd = xml.range(of: "</value>", range: vStart.upperBound..<xml.endIndex) else { return nil }
        return String(xml[vStart.upperBound..<vEnd.lowerBound])
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

    private func extractAll(_ xml: String, tag: String) -> [String] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var results: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let s = xml.range(of: open, range: searchRange),
              let e = xml.range(of: close, range: s.upperBound..<xml.endIndex) {
            results.append(String(xml[s.upperBound..<e.lowerBound]))
            searchRange = e.upperBound..<xml.endIndex
        }
        return results
    }

    // MARK: - Instance Actions (Start / Stop / My-IP Ingress)

    /// Runs an EC2 Query API call and returns (responseXML, localizedError).
    private func ec2Call(action: String, params: [String: String]) async -> (xml: String?, error: String?) {
        let ak = accessKey
        let sk = secretKey
        let r = region
        guard !ak.isEmpty, !sk.isEmpty else {
            return (nil, AWSError.invalidCredentials.localizedDescription)
        }

        var query: [String: String] = ["Action": action, "Version": "2016-11-15"]
        for (k, v) in params { query[k] = v }
        let payload = query.keys.sorted()
            .map { "\($0)=\(Self.formEncode(query[$0] ?? ""))" }
            .joined(separator: "&")

        guard let url = URL(string: "https://ec2.\(r).amazonaws.com/") else {
            return (nil, AWSError.networkError("Invalid URL").localizedDescription)
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
                return (nil, AWSError.networkError("Invalid response").localizedDescription)
            }
            if (200..<300).contains(http.statusCode) {
                return (String(data: data, encoding: .utf8), nil)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if let code = extractSingleTag(body, tag: "Code"),
               let message = extractSingleTag(body, tag: "Message") {
                return (nil, "\(code): \(message)")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                if body.contains("AuthFailure") || body.contains("InvalidClientTokenId") {
                    return (nil, AWSError.invalidCredentials.localizedDescription)
                }
                return (nil, AWSError.accessDenied.localizedDescription)
            }
            return (nil, AWSError.networkError("HTTP \(http.statusCode)").localizedDescription)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return (nil, AWSError.networkError("Timeout").localizedDescription)
            case .notConnectedToInternet, .networkConnectionLost:
                return (nil, AWSError.networkError("No network").localizedDescription)
            default:
                return (nil, AWSError.networkError(error.localizedDescription).localizedDescription)
            }
        } catch {
            return (nil, AWSError.networkError(error.localizedDescription).localizedDescription)
        }
    }

    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Starts a stopped instance. Returns a localized error string, or nil on success.
    func startInstance(_ id: String) async -> String? {
        let (_, err) = await ec2Call(action: "StartInstances", params: ["InstanceId.1": id])
        return err
    }

    /// Stops a running instance. Returns a localized error string, or nil on success.
    func stopInstance(_ id: String) async -> String? {
        let (_, err) = await ec2Call(action: "StopInstances", params: ["InstanceId.1": id])
        return err
    }

    /// Resolves the caller's public IPv4 (used for "allow my IP" rules). Cached 1 hour.
    func fetchMyPublicIP(force: Bool = false) async {
        if !force, myPublicIP != nil, let t = myPublicIPUpdatedAt,
           Date().timeIntervalSince(t) < 3600 { return }
        guard let url = URL(string: "https://api.ipify.org") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                let ip = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !ip.isEmpty {
                    myPublicIP = ip
                    myPublicIPUpdatedAt = Date()
                }
            }
        } catch { /* keep the previous value */ }
    }

    /// Reads an SG's ingress rules and reports whether RDP (tcp/3389) is already
    /// reachable from the caller's IP (0.0.0.0/0, ::/0, or myIP/32). Updates rdpIngress.
    /// Uses the cached rule list (`sgRules`) when present, loading it on demand.
    @discardableResult
    func checkRDPIngress(groupId: String) async -> AWSIngressCheck {
        if myPublicIP == nil { await fetchMyPublicIP() }
        if sgRules[groupId] == nil {
            await loadSecurityGroup(groupId: groupId)
        }
        guard let rules = sgRules[groupId] else {
            rdpIngress[groupId] = .unknown
            return .unknown
        }
        var allowedCIDRs = ["0.0.0.0/0", "::/0"]
        if let ip = myPublicIP { allowedCIDRs.append("\(ip)/32") }
        let check: AWSIngressCheck = rules.contains { $0.allows(port: 3389, from: allowedCIDRs) }
            ? .open : .closed
        rdpIngress[groupId] = check
        return check
    }

    /// Adds an inbound RDP (tcp/3389) rule from the caller's IP to the given SG —
    /// only if one doesn't already exist. Returns (check, localizedMessage).
    @discardableResult
    func addMyIPRDPRule(groupId: String) async -> (check: AWSIngressCheck, message: String) {
        await fetchMyPublicIP(force: true)
        guard let ip = myPublicIP else {
            rdpIngress[groupId] = .unknown
            return (.unknown, Strings.awsIPResolveFailed)
        }
        let check = await checkRDPIngress(groupId: groupId)
        guard check == .closed else {
            return (check, check == .open ? Strings.awsRdpAlreadyOpen : Strings.awsRdpUnknownState)
        }
        let dateStr = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let (_, err) = await ec2Call(action: "AuthorizeSecurityGroupIngress", params: [
            "GroupId": groupId,
            "IpPermissions.1.IpProtocol": "tcp",
            "IpPermissions.1.FromPort": "3389",
            "IpPermissions.1.ToPort": "3389",
            "IpPermissions.1.IpRanges.1.CidrIp": "\(ip)/32",
            "IpPermissions.1.IpRanges.1.Description": "dev_mon RDP \(dateStr)"
        ])
        if let err = err {
            return (.closed, err)
        }
        await loadSecurityGroup(groupId: groupId)   // 刷新规则缓存，供规则列表使用
        rdpIngress[groupId] = .open
        return (.open, Strings.awsRdpAdded)
    }

    /// Parses the ingress (ipPermissions) section of a DescribeSecurityGroups response.
    /// Permission items are anchored on `<ipProtocol>` markers because ipRanges use
    /// nested `<item>` elements that the naive scanner would mis-pair. Each permission
    /// is flattened into one rule per source (IPv4 / IPv6 / peer group), console-style.
    private func parseIngressRules(from xml: String) -> [AWSIngressRule] {
        guard let openRange = xml.range(of: "<ipPermissions>"),
              let closeRange = xml.range(of: "</ipPermissions>", range: openRange.upperBound..<xml.endIndex) else {
            return []
        }
        let ingress = String(xml[openRange.upperBound..<closeRange.lowerBound])

        let marker = "<ipProtocol>"
        var markers: [Range<String.Index>] = []
        var searchRange = ingress.startIndex..<ingress.endIndex
        while let r = ingress.range(of: marker, range: searchRange) {
            markers.append(r)
            searchRange = r.upperBound..<ingress.endIndex
        }

        var rules: [AWSIngressRule] = []
        for (i, m) in markers.enumerated() {
            let blockEnd = (i + 1 < markers.count) ? markers[i + 1].lowerBound : ingress.endIndex
            let block = String(ingress[m.lowerBound..<blockEnd])
            let proto = extractSingleTag(block, tag: "ipProtocol") ?? "-1"
            let fromPort = Int(extractSingleTag(block, tag: "fromPort") ?? "")
            let toPort = Int(extractSingleTag(block, tag: "toPort") ?? "")

            for item in sectionItems(block, section: "ipRanges") {
                guard let c = extractSingleTag(item, tag: "cidrIp") else { continue }
                rules.append(AWSIngressRule(proto: proto, fromPort: fromPort, toPort: toPort,
                                            source: .cidr(c),
                                            description: extractSingleTag(item, tag: "description")))
            }
            for item in sectionItems(block, section: "ipv6Ranges") {
                guard let c = extractSingleTag(item, tag: "cidrIpv6") else { continue }
                rules.append(AWSIngressRule(proto: proto, fromPort: fromPort, toPort: toPort,
                                            source: .ipv6(c),
                                            description: extractSingleTag(item, tag: "description")))
            }
            for item in sectionItems(block, section: "userIdGroupPairs") {
                guard let gid = extractSingleTag(item, tag: "groupId") else { continue }
                rules.append(AWSIngressRule(proto: proto, fromPort: fromPort, toPort: toPort,
                                            source: .group(groupId: gid,
                                                           groupName: extractSingleTag(item, tag: "groupName")),
                                            description: extractSingleTag(item, tag: "description")))
            }
        }
        return rules
    }

    /// Slices the `<item>` children of a single-occurrence section (e.g. `ipRanges`).
    private func sectionItems(_ block: String, section: String) -> [String] {
        guard let openRange = block.range(of: "<\(section)>"),
              let closeRange = block.range(of: "</\(section)>", range: openRange.upperBound..<block.endIndex) else {
            return []
        }
        let inner = String(block[openRange.upperBound..<closeRange.lowerBound])
        let marker = "<item>"
        var markers: [Range<String.Index>] = []
        var searchRange = inner.startIndex..<inner.endIndex
        while let r = inner.range(of: marker, range: searchRange) {
            markers.append(r)
            searchRange = r.upperBound..<inner.endIndex
        }
        var items: [String] = []
        for (i, m) in markers.enumerated() {
            let end = (i + 1 < markers.count) ? markers[i + 1].lowerBound : inner.endIndex
            items.append(String(inner[m.upperBound..<end]))
        }
        return items
    }

    // MARK: - SG Inbound Rule Management (list / add / remove / edit)

    /// Fetches and caches a security group's inbound rules (and its name).
    @discardableResult
    func loadSecurityGroup(groupId: String) async -> [AWSIngressRule] {
        let (xml, _) = await ec2Call(action: "DescribeSecurityGroups", params: [
            "Filter.1.Name": "group-id",
            "Filter.1.Value.1": groupId
        ])
        guard let xml = xml else { return sgRules[groupId] ?? [] }
        sgNames[groupId] = extractSingleTag(xml, tag: "groupName")
        let rules = parseIngressRules(from: xml)
        sgRules[groupId] = rules
        return rules
    }

    /// Adds an inbound rule. Returns a localized error string, or nil on success.
    @discardableResult
    func addIngressRule(_ rule: AWSIngressRule, groupId: String) async -> String? {
        let (_, err) = await ec2Call(action: "AuthorizeSecurityGroupIngress",
                                     params: Self.ingressParams(groupId: groupId, rule: rule))
        if err == nil { await loadSecurityGroup(groupId: groupId) }
        return err
    }

    /// Removes an inbound rule (matched by protocol / ports / source).
    /// Returns a localized error string, or nil on success.
    @discardableResult
    func removeIngressRule(_ rule: AWSIngressRule, groupId: String) async -> String? {
        let (_, err) = await ec2Call(action: "RevokeSecurityGroupIngress",
                                     params: Self.ingressParams(groupId: groupId, rule: rule))
        if err == nil { await loadSecurityGroup(groupId: groupId) }
        return err
    }

    /// "Edit" = revoke the old rule spec, then authorize the new one.
    @discardableResult
    func replaceIngressRule(_ old: AWSIngressRule, with new: AWSIngressRule,
                            groupId: String) async -> String? {
        if let err = await removeIngressRule(old, groupId: groupId) { return err }
        return await addIngressRule(new, groupId: groupId)
    }

    /// Builds the `GroupId` + `IpPermissions.1.*` query params for an action call.
    private static func ingressParams(groupId: String, rule: AWSIngressRule) -> [String: String] {
        let p = "IpPermissions.1"
        var params = [
            "GroupId": groupId,
            "\(p).IpProtocol": rule.proto
        ]
        if let f = rule.fromPort { params["\(p).FromPort"] = "\(f)" }
        if let t = rule.toPort { params["\(p).ToPort"] = "\(t)" }
        switch rule.source {
        case .cidr(let c):
            params["\(p).IpRanges.1.CidrIp"] = c
            if let d = rule.description, !d.isEmpty {
                params["\(p).IpRanges.1.Description"] = d
            }
        case .ipv6(let c):
            params["\(p).Ipv6Ranges.1.CidrIpv6"] = c
            if let d = rule.description, !d.isEmpty {
                params["\(p).Ipv6Ranges.1.Description"] = d
            }
        case .group(let gid, _):
            params["\(p).UserIdGroupPairs.1.GroupId"] = gid
            if let d = rule.description, !d.isEmpty {
                params["\(p).UserIdGroupPairs.1.Description"] = d
            }
        }
        return params
    }
}
