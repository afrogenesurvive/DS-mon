import Foundation

struct AnthropicProvider: Provider {
    let id = "anthropic"
    let name = "Anthropic"
    let baseURL = "https://api.anthropic.com"
    // Admin Usage & Cost API：需要 sk-ant-admin-... 管理密钥
    let balanceURL: String? = "/v1/organizations/cost_report"
    let tokenUsageURL: String? = "/v1/organizations/usage_report/messages"
    let isSpendBased = true
    let preferredDefaultModel: String? = "claude-sonnet-4-5"
    let developerPlatformURL = "https://platform.claude.com/settings/usage"
    let opencodeProviderId = "anthropic"
    let currency = "USD"

    // 定价与 ModelPricing.anthropicDefault 保持一致（USD / 1M tokens）
    let fallbackModels: [String: ModelPricing] = ModelPricing.anthropicDefault

    /// Anthropic 使用 x-api-key + anthropic-version 请求头，而非 Authorization: Bearer
    func authHeaders(for apiKey: String) -> [String: String] {
        [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
    }

    var balanceQueryItems: [URLQueryItem]? {
        let now = Date()
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return [
            URLQueryItem(name: "starting_at", value: f.string(from: start)),
            URLQueryItem(name: "ending_at", value: f.string(from: now)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
    }

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? {
        // /v1/organizations/cost_report → data[].results[].amount（分，USD 的 1/100）
        guard let data = json["data"] as? [[String: Any]] else { return nil }
        var totalCents = 0.0
        for bucket in data {
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                if let s = result["amount"] as? String {
                    totalCents += Double(s) ?? 0
                } else {
                    totalCents += (result["amount"] as? Double) ?? 0
                }
            }
        }
        return (totalCents / 100.0, 0, 0)
    }

    func parseTokenUsage(_ json: [String: Any]) -> ProviderTokenUsage? {
        // /v1/organizations/usage_report/messages → data[].results[]
        guard let data = json["data"] as? [[String: Any]] else { return nil }
        var usage = ProviderTokenUsage()
        for bucket in data {
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                usage.inputTokens += (result["uncached_input_tokens"] as? Double) ?? 0
                usage.outputTokens += (result["output_tokens"] as? Double) ?? 0
                if let cache = result["cache_creation"] as? [String: Any] {
                    usage.cachedInputTokens += (cache["ephemeral_1h_input_tokens"] as? Double) ?? 0
                    usage.cachedInputTokens += (cache["ephemeral_5m_input_tokens"] as? Double) ?? 0
                }
                usage.cachedInputTokens += (result["cache_read_input_tokens"] as? Double) ?? 0
            }
        }
        return usage
    }
}
