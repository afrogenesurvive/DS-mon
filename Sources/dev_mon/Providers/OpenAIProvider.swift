import Foundation

struct OpenAIProvider: Provider {
    let id = "openai"
    let name = "OpenAI"
    let baseURL = "https://api.openai.com"
    // 官方 Admin Usage/Cost API：需要 sk-admin-... 管理密钥
    let balanceURL: String? = "/v1/organization/costs"
    let tokenUsageURL: String? = "/v1/organization/usage/completions"
    // OpenAI does not expose the dashboard's billing limit as an Admin API endpoint.
    let spendLimitURL: String? = nil
    let isSpendBased = true
    let preferredDefaultModel: String? = "gpt-4o"
    let developerPlatformURL = "https://platform.openai.com/usage"
    let opencodeProviderId = "openai"
    let currency = "USD"
    let logoAsset: String? = "logo-openai"
    let iconName = "circle.hexagongrid.fill"

    // 定价与 ModelPricing.openaiDefault 保持一致（USD / 1M tokens）
    let fallbackModels: [String: ModelPricing] = ModelPricing.openaiDefault

    var balanceQueryItems: [URLQueryItem]? {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let startOfToday = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        return [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
    }

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? {
        // /v1/organization/costs → data[].results[].amount.value（USD）
        guard let data = json["data"] as? [[String: Any]] else { return nil }
        var total = 0.0
        for bucket in data {
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                if let amount = result["amount"] as? [String: Any],
                   let value = amount["value"] as? Double {
                    total += value
                }
            }
        }
        return (total, 0, 0)
    }

    func parseTokenUsage(_ json: [String: Any]) -> ProviderTokenUsage? {
        // /v1/organization/usage/completions → data[].results[]
        guard let data = json["data"] as? [[String: Any]] else { return nil }
        var usage = ProviderTokenUsage()
        for bucket in data {
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                usage.inputTokens += (result["input_tokens"] as? Double) ?? 0
                usage.outputTokens += (result["output_tokens"] as? Double) ?? 0
                usage.cachedInputTokens += (result["input_cached_tokens"] as? Double) ?? 0
                usage.cachedInputTokens += (result["input_cached_tokens_write"] as? Double) ?? 0
            }
        }
        return usage
    }
}
