import Foundation

// MARK: - GCP Error

enum GCPError: LocalizedError {
    case invalidCredentials
    case noServiceAccount
    case accessDenied(String)
    case networkError(String)
    case parseFailed
    case noProjects
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return isZH
                ? "GCP 服务账号 JSON 无效——请粘贴完整的下载密钥文件（多行原样）"
                : "Invalid GCP service-account JSON — paste the full downloaded key file verbatim"
        case .noServiceAccount:
            return isZH
                ? "请先粘贴服务账号 JSON（需要 client_email 与 private_key）"
                : "Paste the service-account JSON first (needs client_email and private_key)"
        case .accessDenied(let reason):
            return reason
        case .networkError(let msg):
            return isZH ? "网络错误: \(msg)" : "Network error: \(msg)"
        case .parseFailed:
            return isZH ? "解析响应失败" : "Failed to parse response"
        case .noProjects:
            return isZH ? "尚未配置项目" : "No projects configured"
        case .httpStatus(let code, let msg):
            let trimmed = msg.count > 200 ? String(msg.prefix(200)) : msg
            return isZH
                ? "HTTP \(code): \(trimmed)"
                : "HTTP \(code): \(trimmed)"
        }
    }

    private var isZH: Bool {
        let saved = UserDefaults.standard.string(forKey: Strings.Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }
}

// MARK: - GCP Data Models

struct GCPProject: Identifiable, Equatable, Sendable {
    let id: String
    let number: String
    let name: String
    let state: String
}

struct GCPApiService: Identifiable, Equatable, Sendable {
    let id: String      // serviceusage service name, e.g. compute.googleapis.com
    let name: String    // config.name
    let state: String   // ENABLED | DISABLED
    var shortName: String { id.replacingOccurrences(of: ".googleapis.com", with: "") }
    var isEnabled: Bool { state == "ENABLED" }
}

struct GCPApiMetric: Identifiable, Equatable, Sendable {
    let service: String     // consumed API service name, e.g. compute.googleapis.com
    let requests: Int64     // request count over the selected window (ALIGN_SUM)
    let errors: Int64       // 5xx error count over the selected window (ALIGN_SUM)
    let avgLatencyMs: Double // mean latency over the selected window (ALIGN_MEAN, seconds → ms)
    var id: String { service }
}

/// 指标时间范围（与 GCP Metrics Explorer 类似，最长 30 天）。
enum GCPMetricRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "3600"
    case sixHours = "21600"
    case day = "86400"
    case week = "604800"
    case month = "2592000"

    var id: String { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) ?? 86400 }
    var alignmentSeconds: Int {
        switch self {
        case .hour: return 60
        case .sixHours: return 300
        case .day: return 3600
        case .week: return 21600
        case .month: return 86400
        }
    }
    var title: String {
        switch self {
        case .hour: return "1h"
        case .sixHours: return "6h"
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }
}

struct GCPInstance: Identifiable, Equatable, Sendable {
    let id: String            // instance name
    let project: String
    let zone: String
    let machineType: String
    let status: String        // RUNNING | STOPPED | TERMINATED | PROVISIONING ...
    let publicIP: String?
    let privateIP: String?

    var isRunning: Bool { status == "RUNNING" }
    var isStopped: Bool { status == "TERMINATED" }
}

struct GCPServiceAccount: Identifiable, Equatable, Sendable {
    let email: String
    let displayName: String
    var id: String { email }
}

struct GCPUserManagedKey: Identifiable, Equatable, Sendable {
    let id: String            // key id
    let name: String          // key name (full resource name)
    let validAfterTime: String
    let validBeforeTime: String
    let keyType: String       // USER_MANAGED | SYSTEM_MANAGED

    /// Age in days since the key became valid (nil when the timestamp can't be parsed).
    var ageDays: Int? {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = df.date(from: validAfterTime) ?? {
            df.formatOptions = [.withInternetDateTime]
            return df.date(from: validAfterTime)
        }()
        guard let date else { return nil }
        return max(0, Int(Date().timeIntervalSince(date) / 86400))
    }
}

struct GCPIamBinding: Identifiable, Equatable, Sendable {
    let role: String
    let members: [String]
    var id: String { role }
    var roleDisplay: String { role.components(separatedBy: "/").last ?? role }
}

struct GCPTopic: Identifiable, Equatable, Sendable {
    let name: String          // projects/{p}/topics/{t}
    var id: String { name }
    var shortName: String { name.components(separatedBy: "/").last ?? name }
}

struct GCPSubscription: Identifiable, Equatable, Sendable {
    let name: String          // projects/{p}/subscriptions/{s}
    let topic: String         // full topic resource name
    var id: String { name }
    var shortName: String { name.components(separatedBy: "/").last ?? name }
    var shortTopic: String { topic.components(separatedBy: "/").last ?? topic }
}

struct GCPCloudRunService: Identifiable, Equatable, Sendable {
    let name: String          // service name
    let region: String
    let url: String
    let latestRevision: String
    var id: String { name }
}

struct GCPAppEngineService: Identifiable, Equatable, Sendable {
    let name: String          // service id
    let versions: [String]
    var id: String { name }
}

/// GCP "Always Free" compute usage: 1× e2-micro per month in the free regions
/// (us-west1 / us-central1 / us-east1), mirroring AWSFreeTierStatus.
struct GCPAlwaysFreeStatus: Equatable, Sendable {
    let runningInstances: Int
    let limitInstances: Int
    let eligibleCount: Int
    let nonEligibleCount: Int

    static let empty = GCPAlwaysFreeStatus(runningInstances: 0, limitInstances: 1,
                                           eligibleCount: 0, nonEligibleCount: 0)

    var usagePercentage: Double {
        limitInstances > 0 ? min(Double(runningInstances) / Double(limitInstances) * 100, 100) : 0
    }
    var isWithinFreeTier: Bool { runningInstances <= limitInstances && nonEligibleCount == 0 }
    var isWarning: Bool { usagePercentage >= 80 || nonEligibleCount > 0 }

    static let freeRegions = Set(["us-west1", "us-central1", "us-east1"])
    static let freeMachineType = "e2-micro"
}
