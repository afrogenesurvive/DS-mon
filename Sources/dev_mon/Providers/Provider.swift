import Foundation

// MARK: - Token 用量

struct ProviderTokenUsage: Sendable, Equatable {
    var inputTokens: Double = 0
    var outputTokens: Double = 0
    var cachedInputTokens: Double = 0
    static let empty = ProviderTokenUsage()
}

// MARK: - 提供商协议

protocol Provider: Sendable {
    var id: String { get }
    var name: String { get }
    var baseURL: String { get }
    var apiPath: String { get }
    var authPrefix: String { get }
    var balanceURL: String? { get }
    /// 查询余额/成本时可附加的 query 参数（OpenAI/Anthropic 需要时间范围）。
    var balanceQueryItems: [URLQueryItem]? { get }
    /// 可选的 token 用量接口路径（OpenAI/Anthropic 管理端）。
    var tokenUsageURL: String? { get }
    /// 预付费余额(false) vs 按月计费费用(true)；费用型不触发低余额告警。
    var isSpendBased: Bool { get }
    var fallbackModels: [String: ModelPricing] { get }
    var preferredDefaultModel: String? { get }
    var rpmLimit: Int? { get }
    var developerPlatformURL: String { get }
    var opencodeProviderId: String { get }
    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)?
    func parseTokenUsage(_ json: [String: Any]) -> ProviderTokenUsage?
    var currency: String { get }
    /// 构造访问上游所需的认证请求头（默认 Authorization: Bearer）。
    /// Anthropic 等提供商可覆盖为 x-api-key / anthropic-version。
    func authHeaders(for apiKey: String) -> [String: String]
}

extension Provider {
    var authPrefix: String { "Bearer" }
    var balanceQueryItems: [URLQueryItem]? { nil }
    var tokenUsageURL: String? { nil }
    var isSpendBased: Bool { false }
    func parseTokenUsage(_ json: [String: Any]) -> ProviderTokenUsage? { nil }

    func authHeaders(for apiKey: String) -> [String: String] {
        ["Authorization": "\(authPrefix) \(apiKey)"]
    }
    var apiPath: String { "/v1" }
    var preferredDefaultModel: String? { nil }
    var rpmLimit: Int? { nil }
    var developerPlatformURL: String { "" }
    var opencodeProviderId: String { id }
    var currency: String { "CNY" }
}
