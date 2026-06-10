import Foundation

// MARK: - 提供商模型

/// 余额查询策略
enum BalanceStrategy: String, Codable, Sendable {
    /// DeepSeek 格式: { "balance_infos": [{ "total_balance": "100", "granted_balance": "0", "topped_up_balance": "100", "currency": "CNY" }], "is_available": true }
    case deepseek
    /// OpenRouter 格式: { "data": { "credits": "100", "usage": "50" } }
    case openrouter
    /// Moonshot (Kimi) 格式: { "code": 0, "data": { "available_balance": 49.59, "voucher_balance": 46.59, "cash_balance": 3.00 }, "status": true }
    case moonshot
    /// 无余额 API
    case none
}

/// 单个提供商配置
struct ProviderConfig: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var baseURL: String
    /// 请求头前缀，如 "Bearer"
    var authHeaderPrefix: String
    /// 是否有余额查询 API
    var hasBalanceAPI: Bool
    /// 余额 API 路径（相对于 baseURL），如 "/user/balance"
    var balanceURL: String?
    /// 余额解析策略
    var balanceStrategy: BalanceStrategy
    /// 货币符号
    var currency: String
    /// 是否在列表中启用（用户可关闭）
    var isEnabled: Bool
    /// 显示排序
    var order: Int

    /// Codex Relay 使用的提供商 ID（nil = 使用当前活跃提供商）
    var relayProviderId: String?
    /// 默认模型（nil = 使用定价列表第一个）
    var defaultModel: String?
    /// API 路径前缀，如 "/v1"（Relay 使用）
    var apiPath: String = "/v1"
    /// RPM 限制（nil = 无限制）
    var rateLimitRPM: Int?

    /// 模型定价覆盖（key = 模型ID 或前缀）
    var pricingOverrides: [String: ModelPricing]

    init(id: String, name: String, baseURL: String,
         authHeaderPrefix: String = "Bearer",
         hasBalanceAPI: Bool = false,
         balanceURL: String? = nil,
         balanceStrategy: BalanceStrategy = .none,
         currency: String = "CNY",
         isEnabled: Bool = true,
         order: Int = 0,
         relayProviderId: String? = nil,
         defaultModel: String? = nil,
         pricingOverrides: [String: ModelPricing] = [:],
         apiPath: String = "/v1",
         rateLimitRPM: Int? = nil)
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
        self.relayProviderId = relayProviderId
        self.defaultModel = defaultModel
        self.apiPath = apiPath
        self.rateLimitRPM = rateLimitRPM
        self.pricingOverrides = pricingOverrides
    }

}

// MARK: - 内置预设提供商

extension ProviderConfig {
    static let builtIns: [ProviderConfig] = [
        ProviderConfig(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            hasBalanceAPI: true,
            balanceURL: "/user/balance",
            balanceStrategy: .deepseek,
            currency: "CNY",
            order: 0,
            pricingOverrides: [
                "deepseek-v4-flash": ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0, outPrice: 2.0),
                "deepseek-v4-pro":   ModelPricing(label: "V4 Pro",   hitPrice: 0.026, missPrice: 3.13, outPrice: 6.26),
                "deepseek-chat":     ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0, outPrice: 2.0),
                "deepseek-reasoner": ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0, outPrice: 2.0),
            ],
            rateLimitRPM: 200
        ),
        ProviderConfig(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com",
            hasBalanceAPI: false,
            currency: "USD",
            order: 1,
            pricingOverrides: [
                "gpt-4o":         ModelPricing(label: "GPT-4o",        hitPrice: 1.25, missPrice: 2.50,  outPrice: 10.00),
                "gpt-4o-mini":    ModelPricing(label: "GPT-4o Mini",   hitPrice: 0.075, missPrice: 0.15,  outPrice: 0.60),
                "gpt-4.5":        ModelPricing(label: "GPT-4.5",       hitPrice: 37.50, missPrice: 75.0,  outPrice: 150.0),
                "o1":             ModelPricing(label: "o1",            hitPrice: 7.50,  missPrice: 15.0,  outPrice: 60.0),
                "o3-mini":        ModelPricing(label: "o3-mini",       hitPrice: 0.55,  missPrice: 1.10,  outPrice: 4.40),
            ],
            rateLimitRPM: 200
        ),
        ProviderConfig(
            id: "anthropic",
            name: "Anthropic",
            baseURL: "https://api.anthropic.com",
            authHeaderPrefix: "Bearer",
            hasBalanceAPI: false,
            currency: "USD",
            order: 2,
            pricingOverrides: [
                "claude-sonnet-4":      ModelPricing(label: "Claude Sonnet 4",  hitPrice: 1.50, missPrice: 3.0, outPrice: 15.0),
                "claude-haiku-3.5":     ModelPricing(label: "Claude Haiku",     hitPrice: 0.40, missPrice: 0.80, outPrice: 4.0),
                "claude-opus-4":        ModelPricing(label: "Claude Opus 4",    hitPrice: 7.50, missPrice: 15.0, outPrice: 75.0),
            ],
            rateLimitRPM: 200
        ),
        ProviderConfig(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai",
            hasBalanceAPI: true,
            balanceURL: "/auth/key",
            balanceStrategy: .openrouter,
            currency: "USD",
            order: 3,
            pricingOverrides: [:],
            apiPath: "/api/v1",
            rateLimitRPM: 200
        ),
        ProviderConfig(
            id: "google",
            name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com",
            authHeaderPrefix: "Bearer",
            hasBalanceAPI: false,
            currency: "USD",
            order: 4,
            pricingOverrides: [
                "gemini-2.5-pro": ModelPricing(label: "Gemini 2.5 Pro", hitPrice: 0.625, missPrice: 1.25, outPrice: 10.0),
                "gemini-2.0-flash": ModelPricing(label: "Gemini 2.0 Flash", hitPrice: 0.05, missPrice: 0.10, outPrice: 0.40),
            ],
            apiPath: "/v1beta",
            rateLimitRPM: 200
        ),
        ProviderConfig(
            id: "moonshot",
            name: "Kimi (Moonshot)",
            baseURL: "https://api.moonshot.cn",
            hasBalanceAPI: true,
            balanceURL: "/v1/users/me/balance",
            balanceStrategy: .moonshot,
            currency: "CNY",
            order: 5,
            pricingOverrides: [
                "kimi-k2.6":                  ModelPricing(label: "K2.6",     hitPrice: 2.0, missPrice: 4.0, outPrice: 12.0),
                "moonshot-v1-8k":             ModelPricing(label: "V1 8K",   hitPrice: 0.06, missPrice: 0.12, outPrice: 0.12),
                "moonshot-v1-32k":            ModelPricing(label: "V1 32K",  hitPrice: 0.24, missPrice: 0.48, outPrice: 0.48),
                "moonshot-v1-128k":           ModelPricing(label: "V1 128K", hitPrice: 0.96, missPrice: 1.92, outPrice: 1.92),
                "moonshot-v1-32k-vision-preview": ModelPricing(label: "V1 Vision", hitPrice: 0.24, missPrice: 0.48, outPrice: 0.48),
            ],
            rateLimitRPM: 200
        ),
    ]

    /// 查找内置提供商，找不到则返回 nil
    static func builtIn(id: String) -> ProviderConfig? {
        builtIns.first { $0.id == id }
    }
}

// MARK: - 提供商列表持久化

extension ProviderConfig {
    private static let storageKey = "provider_configs"

    static func loadAll() -> [ProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data)
        else {
            // 首次启动或解码失败：返回内置列表
            // 同时尝试修复 UserDefaults 中的旧数据（例如缺失 apiPath 字段）
            if let oldData = UserDefaults.standard.data(forKey: storageKey),
               let oldJSON = try? JSONSerialization.jsonObject(with: oldData) as? [[String: Any]] {
                var fixed = oldJSON
                for i in fixed.indices {
                    let pid = fixed[i]["id"] as? String ?? ""
                    if let builtIn = builtIns.first(where: { $0.id == pid }) {
                        // 补充缺失字段
                        if fixed[i]["apiPath"] == nil {
                            fixed[i]["apiPath"] = builtIn.apiPath
                        }
                        // 修复被破坏的 baseURL
                        if let base = fixed[i]["baseURL"] as? String,
                           let correctBase = URL(string: builtIn.baseURL),
                           let currentURL = URL(string: base),
                           currentURL.host == correctBase.host,
                           base != builtIn.baseURL {
                            fixed[i]["baseURL"] = builtIn.baseURL
                        }
                    }
                }
                if let newData = try? JSONSerialization.data(withJSONObject: fixed),
                   newData != oldData {
                    UserDefaults.standard.set(newData, forKey: storageKey)
                    print("[ProviderConfig] 已修复 UserDefaults 中的旧数据")
                }
            }
            return builtIns
        }
        // 合并内置提供商：补充新增的预设、定价、默认模型
        for builtIn in builtIns {
            if let idx = decoded.firstIndex(where: { $0.id == builtIn.id }) {
                // 已有：只补充内置新增的定价（不覆盖用户已有的）
                for (key, pricing) in builtIn.pricingOverrides {
                    if decoded[idx].pricingOverrides[key] == nil {
                        decoded[idx].pricingOverrides[key] = pricing
                    }
                }
                // 补充默认模型（如果内置有且用户未设置）
                if decoded[idx].defaultModel == nil {
                    decoded[idx].defaultModel = builtIn.defaultModel
                }
            } else {
                // 新增：直接添加
                decoded.append(builtIn)
            }
        }

        // 迁移 V3: 修复 baseURL 嵌入了 apiPath 的历史遗留数据
        // 这些数据来自早期版本，其中 apiPath 被拼接进了 baseURL
        for idx in decoded.indices {
            guard let builtIn = builtIns.first(where: { $0.id == decoded[idx].id }) else { continue }
            // 对内置提供商：总是使用正确的 baseURL 和 apiPath
            let oldBase = decoded[idx].baseURL
            let oldApi = decoded[idx].apiPath
            if oldBase != builtIn.baseURL || oldApi != builtIn.apiPath {
                decoded[idx].baseURL = builtIn.baseURL
                decoded[idx].apiPath = builtIn.apiPath
                print("[ProviderConfig] 修复 \(decoded[idx].id): baseURL \(oldBase) → \(builtIn.baseURL), apiPath \(oldApi) → \(builtIn.apiPath)")
            }
        }

        // 如果数据有变化，写回 UserDefaults
        saveAll(decoded)
        return decoded
    }

    static func saveAll(_ providers: [ProviderConfig]) {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
