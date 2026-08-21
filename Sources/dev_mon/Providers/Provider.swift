import Foundation

// MARK: - 提供商协议

protocol Provider: Sendable {
    var id: String { get }
    var name: String { get }
    var baseURL: String { get }
    var apiPath: String { get }
    var authPrefix: String { get }
    var balanceURL: String? { get }
    var fallbackModels: [String: ModelPricing] { get }
    var preferredDefaultModel: String? { get }
    var rpmLimit: Int? { get }
    var developerPlatformURL: String { get }
    var opencodeProviderId: String { get }
    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)?
    var currency: String { get }
    /// 构造访问上游所需的认证请求头（默认 Authorization: Bearer）。
    /// Anthropic 等提供商可覆盖为 x-api-key / anthropic-version。
    func authHeaders(for apiKey: String) -> [String: String]
}

extension Provider {
    var authPrefix: String { "Bearer" }

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
