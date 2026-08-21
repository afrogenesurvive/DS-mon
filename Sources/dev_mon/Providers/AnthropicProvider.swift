import Foundation

struct AnthropicProvider: Provider {
    let id = "anthropic"
    let name = "Anthropic"
    let baseURL = "https://api.anthropic.com"
    let balanceURL: String? = nil
    let preferredDefaultModel: String? = "claude-sonnet-4-5"
    let developerPlatformURL = "https://console.anthropic.com/settings/usage"
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

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? {
        // Anthropic 无公开余额接口
        nil
    }
}
