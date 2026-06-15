import Foundation
import CryptoKit
import Security

// MARK: - AES-GCM 加密存储

enum SecureStore {
    private static let keyFile = "\(NSHomeDirectory())/.ds-mon/.enc_key"

    private static func loadKey() -> SymmetricKey? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: keyFile)),
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private static func saveKey(_ key: SymmetricKey) throws {
        let dir = (keyFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try key.withUnsafeBytes { buf in
            try Data(buf).write(to: URL(fileURLWithPath: keyFile), options: .atomic)
        }
    }

    private static func getOrCreateKey() -> SymmetricKey {
        if let key = loadKey() { return key }
        let newKey = SymmetricKey(size: .bits256)
        try? saveKey(newKey)
        return newKey
    }

    static func encrypt(_ plaintext: String) -> Data? {
        let key = getOrCreateKey()
        guard let plainData = plaintext.data(using: .utf8) else { return nil }
        guard let sealed = try? AES.GCM.seal(plainData, using: key) else { return nil }
        return sealed.combined
    }

    static func decrypt(_ data: Data) -> String? {
        let key = getOrCreateKey()
        guard let sealed = try? AES.GCM.SealedBox(combined: data),
              let decoded = try? AES.GCM.open(sealed, using: key) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }
}

// MARK: - 提供商管理器

@Observable @MainActor
final class ProviderManager {
    static let shared = ProviderManager()

    private(set) var provider: ProviderConfig = .load()

    private static let apiKeyKey = "encrypted_api_key_deepseek"

    /// 当前活跃提供商
    var activeProvider: ProviderConfig? {
        provider.isEnabled ? provider : nil
    }

    var activeAPIKey: String {
        apiKey(for: provider)
    }

    private init() {
        migrateLegacyKeyIfNeeded()
    }

    // MARK: - API Key 加密存储

    func saveAPIKey(_ key: String, for provider: ProviderConfig) -> Bool {
        let storeKey = Self.apiKeyKey
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
            return true
        }
        guard let encrypted = SecureStore.encrypt(key) else { return false }
        UserDefaults.standard.set(encrypted, forKey: storeKey)
        return true
    }

    func apiKey(for provider: ProviderConfig) -> String {
        let storeKey = Self.apiKeyKey
        guard let encrypted = UserDefaults.standard.data(forKey: storeKey),
              let decrypted = SecureStore.decrypt(encrypted),
              !decrypted.isEmpty else { return "" }
        return decrypted
    }

    func save() {
        provider.save()
    }

    func load() {
        provider = ProviderConfig.load()
    }

    // MARK: - 迁移旧版本密钥（合并到单个 key）

    private func migrateLegacyKeyIfNeeded() {
        let newKey = Self.apiKeyKey
        if UserDefaults.standard.data(forKey: newKey) != nil { return }

        let oldKeys = [
            "encrypted_api_key_deepseek",
            "encrypted_api_key_moonshot",
            "encrypted_api_key_agnesai",
        ]
        for old in oldKeys {
            if let data = UserDefaults.standard.data(forKey: old),
               let decrypted = SecureStore.decrypt(data),
               !decrypted.isEmpty {
                UserDefaults.standard.set(data, forKey: newKey)
                break
            }
        }
    }
}
