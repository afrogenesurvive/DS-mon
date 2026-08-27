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
    let logoAsset: String? = "logo-anthropic"
    let iconName = "asterisk"
    // Anthropic 管理端未提供余额/额度接口（仅 usage_report 与 cost_report），
    // 因此 spendLimitURL 保持 nil，剩余额度改由用户在设置中手填的月度预算推导。

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
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let startOfToday = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return [
            URLQueryItem(name: "starting_at", value: f.string(from: start)),
            URLQueryItem(name: "ending_at", value: f.string(from: end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
    }

    func liveCostQueryItems(since: Date) -> [URLQueryItem] {
        let f = ISO8601DateFormatter()
        return [
            URLQueryItem(name: "starting_at", value: f.string(from: since)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
            URLQueryItem(name: "group_by[]", value: "model"),
        ]
    }

    func latestFinalizedCostEnd(_ pages: [[String: Any]]) -> Date? {
        let f = ISO8601DateFormatter()
        return pages
            .flatMap { $0["data"] as? [[String: Any]] ?? [] }
            .compactMap { ($0["ending_at"] as? String).flatMap(f.date(from:)) }
            .max()
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

    /// Estimate the still-open UTC cost bucket from organization usage. The Cost API
    /// only exposes closed daily buckets, while spend enforcement includes live usage.
    func estimateLiveCost(_ json: [String: Any]) -> Double {
        guard let data = json["data"] as? [[String: Any]] else { return 0 }
        var total = 0.0
        for bucket in data {
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                guard let model = result["model"] as? String,
                      let pricing = Self.livePricing(for: model) else { continue }
                let cache = result["cache_creation"] as? [String: Any]
                let serverTools = result["server_tool_use"] as? [String: Any]
                let multiplier = Self.priceMultiplier(for: result)
                var resultCost = 0.0
                resultCost += Self.number(result["uncached_input_tokens"]) / 1_000_000 * pricing.input
                resultCost += Self.number(cache?["ephemeral_5m_input_tokens"]) / 1_000_000 * pricing.cacheWrite5m
                resultCost += Self.number(cache?["ephemeral_1h_input_tokens"]) / 1_000_000 * pricing.cacheWrite1h
                resultCost += Self.number(result["cache_read_input_tokens"]) / 1_000_000 * pricing.cacheRead
                resultCost += Self.number(result["output_tokens"]) / 1_000_000 * pricing.output
                let webSearchCost = Self.number(serverTools?["web_search_requests"]) * 0.01
                total += resultCost * multiplier + webSearchCost
            }
        }
        return total
    }

    private struct LivePricing {
        let input: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let output: Double
    }

    private static func livePricing(for model: String) -> LivePricing? {
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-opus-4-5")
            || model.hasPrefix("claude-opus-4-6") || model.hasPrefix("claude-opus-4-7")
            || model.hasPrefix("claude-opus-4-8") {
            return LivePricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25)
        }
        if model.hasPrefix("claude-sonnet-5") {
            return LivePricing(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2, output: 10)
        }
        if model.hasPrefix("claude-sonnet-4") {
            return LivePricing(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3, output: 15)
        }
        if model.hasPrefix("claude-haiku-4-5") {
            return LivePricing(input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5)
        }
        if model.hasPrefix("claude-haiku-3-5") {
            return LivePricing(input: 0.8, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08, output: 4)
        }
        if model.hasPrefix("claude-opus-4") {
            return LivePricing(input: 15, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5, output: 75)
        }
        return nil
    }

    private static func priceMultiplier(for result: [String: Any]) -> Double {
        var multiplier = result["service_tier"] as? String == "batch" ? 0.5 : 1.0
        if result["inference_geo"] as? String == "us" {
            multiplier *= 1.1
        }
        return multiplier
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }
}
