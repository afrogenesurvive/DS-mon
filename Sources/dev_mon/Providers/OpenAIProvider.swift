import Foundation

struct OpenAIProvider: Provider {
    let id = "openai"
    let name = "OpenAI"
    let baseURL = "https://api.openai.com"
    let balanceURL: String? = nil
    let preferredDefaultModel: String? = "gpt-4o"
    let developerPlatformURL = "https://platform.openai.com/usage"
    let opencodeProviderId = "openai"
    let currency = "USD"

    // 定价与 ModelPricing.openaiDefault 保持一致（USD / 1M tokens）
    let fallbackModels: [String: ModelPricing] = ModelPricing.openaiDefault

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? {
        // OpenAI 无公开余额接口
        nil
    }
}
