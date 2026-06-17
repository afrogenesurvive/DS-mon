import Foundation

// MARK: - 提供商管理器

@Observable @MainActor
final class ProviderManager {
    static let shared = ProviderManager()

    private(set) var providers: [any Provider] = []
    /// 模型名 → 提供商ID 映射缓存
    private var modelProviderMap: [String: String] = [:]
    /// API Key 存储（每个提供商独立）
    private var apiKeys: [String: String] = [:]
    private var encryptedKeys: [String: Data] = [:]
    /// 当前默认提供商 ID
    private(set) var defaultProviderId: String = "deepseek"

    private static let apiKeyPrefix = "encrypted_key_"

    private init() {
        registerBuiltInProviders()
        loadAPIKeys()
    }

    // MARK: - 注册提供商

    private func registerBuiltInProviders() {
        register(DeepSeekProvider())
        register(KimiProvider())
    }

    func register(_ provider: any Provider) {
        guard !providers.contains(where: { $0.id == provider.id }) else { return }
        providers.append(provider)
        // 预注册 fallback 模型
        for model in provider.fallbackModels.keys {
            modelProviderMap[model] = provider.id
        }
    }

    // MARK: - 模型→提供商路由

    /// 根据模型名查找提供商，找不到返回 defaultProvider
    func provider(for model: String) -> (any Provider)? {
        if let pid = modelProviderMap[model],
           let p = providers.first(where: { $0.id == pid }) {
            return p
        }
        return providers.first { $0.id == defaultProviderId }
    }

    /// ProviderManager 根据模型名返回提供商id→Provider lookup
    func provider(byId id: String) -> (any Provider)? {
        providers.first { $0.id == id }
    }

    /// 提供商的活跃模型列表（缓存 + API 动态合并后）
    func models(for provider: any Provider) -> [String] {
        // 先返回 fallback，后续异步从 API 拉取合并
        Array(provider.fallbackModels.keys).sorted()
    }

    // MARK: - API Key 管理

    func apiKey(for providerId: String) -> String {
        if let key = apiKeys[providerId], !key.isEmpty { return key }
        guard let encrypted = encryptedKeys[providerId],
              let decrypted = SecureStore.decrypt(encrypted) else { return "" }
        apiKeys[providerId] = decrypted
        return decrypted
    }

    func saveAPIKey(_ key: String, for providerId: String) {
        if key.isEmpty {
            apiKeys.removeValue(forKey: providerId)
            encryptedKeys.removeValue(forKey: providerId)
            UserDefaults.standard.removeObject(forKey: Self.apiKeyPrefix + providerId)
            return
        }
        apiKeys[providerId] = key
        if let encrypted = SecureStore.encrypt(key) {
            encryptedKeys[providerId] = encrypted
            UserDefaults.standard.set(encrypted, forKey: Self.apiKeyPrefix + providerId)
        }
    }

    private func loadAPIKeys() {
        for provider in providers {
            let storeKey = Self.apiKeyPrefix + provider.id
            if let data = UserDefaults.standard.data(forKey: storeKey) {
                encryptedKeys[provider.id] = data
            }
        }
        // 迁移旧 key
        if encryptedKeys.isEmpty {
            let oldKey = "encrypted_api_key_deepseek"
            if let data = UserDefaults.standard.data(forKey: oldKey) {
                encryptedKeys["deepseek"] = data
            }
        }
    }

    // MARK: - 兼容旧 API

    var activeProvider: (any Provider)? {
        providers.first { $0.id == defaultProviderId }
    }

    var activeAPIKey: String {
        apiKey(for: defaultProviderId)
    }

    func saveAPIKey(_ key: String, for provider: any Provider) {
        saveAPIKey(key, for: provider.id)
    }

    func apiKey(for provider: any Provider) -> String {
        apiKey(for: provider.id)
    }

    // MARK: - 模型列表刷新

    func refreshModels() async {
        for provider in providers {
            let key = apiKey(for: provider.id)
            guard !key.isEmpty else { continue }
            let urlStr = provider.baseURL + provider.apiPath + "/models"
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.setValue("\(provider.authPrefix) \(key)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 10
            do {
                let config = URLSessionConfiguration.default
                config.connectionProxyDictionary = [:]
                let (data, _) = try await URLSession(configuration: config).data(for: req)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let models: [String] = {
                    if let list = json["data"] as? [[String: Any]] {
                        return list.compactMap { $0["id"] as? String }
                    }
                    if let list = json["models"] as? [[String: Any]] {
                        return list.compactMap { $0["id"] as? String }
                    }
                    return []
                }()
                for model in models {
                    modelProviderMap[model] = provider.id
                }
            } catch {}
        }
    }
}
