import Foundation

// MARK: - 余额查询策略

enum BalanceStrategy: String, Codable, Sendable {
    case deepseek
    case none
}

// MARK: - DeepSeek 提供商配置

struct ProviderConfig: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var baseURL: String
    var authHeaderPrefix: String
    var hasBalanceAPI: Bool
    var balanceURL: String?
    var balanceStrategy: BalanceStrategy
    var currency: String
    var isEnabled: Bool
    var order: Int

    var defaultModel: String?
    var apiPath: String = "/v1"
    var rateLimitRPM: Int?

    var pricingOverrides: [String: ModelPricing]

    var developerPlatformURL: String

    init(id: String = "deepseek", name: String = "DeepSeek",
         baseURL: String = "https://api.deepseek.com",
         authHeaderPrefix: String = "Bearer",
         hasBalanceAPI: Bool = true,
         balanceURL: String? = "/user/balance",
         balanceStrategy: BalanceStrategy = .deepseek,
         currency: String = "CNY",
         isEnabled: Bool = true,
         order: Int = 0,
         defaultModel: String? = "deepseek-v4-pro",
         pricingOverrides: [String: ModelPricing] = ModelPricing.default,
         apiPath: String = "/v1",
         rateLimitRPM: Int? = 200,
         developerPlatformURL: String = "https://platform.deepseek.com/usage")
    {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authHeaderPrefix = authHeaderPrefix
        self.hasBalanceAPI = hasBalanceAPI
        self.balanceURL = balanceURL
        self.balanceStrategy = balanceStrategy
        self.currency = currency
        self.isEnabled = isEnabled
        self.order = order
        self.defaultModel = defaultModel
        self.apiPath = apiPath
        self.rateLimitRPM = rateLimitRPM
        self.pricingOverrides = pricingOverrides
        self.developerPlatformURL = developerPlatformURL
    }

    static let `default` = ProviderConfig()

    private static let storageKey = "provider_config"

    static func load() -> ProviderConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
