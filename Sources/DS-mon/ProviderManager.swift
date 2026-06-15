import Foundation
import CryptoKit
import Security

// MARK: - AES-GCM 加密存储

/// 用 CryptoKit 对 API Key 进行本地加密存储（替代 Keychain）
enum SecureStore {
    private static let keyFile = "\(NSHomeDirectory())/.ds-mon/.enc_key"

    /// 获取或创建加密密钥
    private static func encryptionKey() -> SymmetricKey {
        let fm = FileManager.default
        if fm.fileExists(atPath: keyFile),
           let data = try? Data(contentsOf: URL(fileURLWithPath: keyFile)),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        // 首次运行：生成新密钥
        let key = SymmetricKey(size: .bits256)
        let dir = URL(fileURLWithPath: keyFile).deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyData = key.withUnsafeBytes { Data($0) }
        try? keyData.write(to: URL(fileURLWithPath: keyFile), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile)
        return key
    }

    /// 加密字符串，返回 base64
    static func encrypt(_ plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        let key = encryptionKey()
        guard let sealed = try? AES.GCM.seal(data, using: key) else { return nil }
        // 组合 nonce + ciphertext + tag
        var combined = Data()
        combined.append(Data(sealed.nonce))
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return combined.base64EncodedString()
    }

    /// 解密 base64，返回原文
    static func decrypt(_ base64: String) -> String? {
        guard let combined = Data(base64Encoded: base64),
              combined.count >= 12 + 16 else { return nil }
        let nonceData = combined[0..<12]
        let ciphertext = combined[12..<combined.count - 16]
        let tagData = combined[combined.count - 16..<combined.count]
        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }
        let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        guard let box = sealed else { return nil }
        guard let data = try? AES.GCM.open(box, using: encryptionKey()) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 提供商管理器

@MainActor
@Observable
final class ProviderManager {
    static let shared = ProviderManager()

    /// 所有已配置的提供商
    private(set) var providers: [ProviderConfig] = []
    /// 当前活跃提供商 ID
    private(set) var activeProviderId: String = "deepseek"

    /// UserDefaults key 前缀
    private static let keyStorePrefix = "encrypted_api_key_"

    /// 活跃提供商的 codex 模型覆写目标模型名（非隔离访问）
    nonisolated(unsafe) static var activeModelOverrideModel: String? = nil
    /// 活跃提供商的默认模型（非隔离访问）
    nonisolated(unsafe) static var activeModelDefaultModel: String? = nil
    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderId && $0.isEnabled }
    }

    /// 当前活跃提供商的 API Key
    var activeAPIKey: String {
        guard let provider = activeProvider else { return "" }
        return apiKey(for: provider)
    }

    /// 所有启用的提供商
    var enabledProviders: [ProviderConfig] {
        providers.filter { $0.isEnabled }.sorted { $0.order < $1.order }
    }

    private init() {
        load()
        migrateLegacyKeyIfNeeded()
    }

    // MARK: - 持久化

    func load() {
        providers = ProviderConfig.loadAll()
        let saved = UserDefaults.standard.string(forKey: Self.activeKey) ?? "deepseek"
        if providers.contains(where: { $0.id == saved && $0.isEnabled }) {
            activeProviderId = saved
        } else {
            activeProviderId = providers.first(where: { $0.isEnabled })?.id ?? "deepseek"
        }
        syncModelOverrides()
    }

    private func syncModelOverrides() {
        Self.activeModelDefaultModel = activeProvider?.defaultModel
            ?? activeProvider?.pricingOverrides.keys.sorted().first

        if let overrideId = activeProvider?.modelOverrideProviderId,
           let target = providers.first(where: { $0.id == overrideId && $0.isEnabled }) {
            Self.activeModelOverrideModel = target.defaultModel
                ?? target.pricingOverrides.keys.sorted().first
        } else {
            Self.activeModelOverrideModel = nil
        }
    }

    func save() {
        ProviderConfig.saveAll(providers)
        UserDefaults.standard.set(activeProviderId, forKey: Self.activeKey)
    }

    // MARK: - 提供商操作

    func setActive(id: String) {
        guard providers.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        activeProviderId = id
        save()
        syncModelOverrides()
        NotificationCenter.default.post(name: .activeProviderDidChange, object: nil)
    }

    func toggleEnabled(id: String) {
        guard let idx = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[idx].isEnabled.toggle()
        if id == activeProviderId && !providers[idx].isEnabled {
            if let first = providers.first(where: { $0.isEnabled }) {
                activeProviderId = first.id
            }
        }
        save()
        NotificationCenter.default.post(name: .activeProviderDidChange, object: nil)
    }

    // MARK: - API Key 加密存储

    func saveAPIKey(_ key: String, for provider: ProviderConfig) -> Bool {
        let storeKey = Self.keyStorePrefix + provider.id
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
        } else {
            guard let encrypted = SecureStore.encrypt(key) else { return false }
            UserDefaults.standard.set(encrypted, forKey: storeKey)
        }
        return true
    }

    func apiKey(for provider: ProviderConfig) -> String {
        let storeKey = Self.keyStorePrefix + provider.id
        guard let encrypted = UserDefaults.standard.string(forKey: storeKey),
              !encrypted.isEmpty else { return "" }
        return SecureStore.decrypt(encrypted) ?? ""
    }

    func hasAPIKey(for provider: ProviderConfig) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    // MARK: - 旧版 Keychain 迁移

    private static let activeKey = "active_provider_id"
    private static let migratedKey = "legacy_key_migrated_v2"

    private func migrateLegacyKeyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migratedKey) else { return }
        let legacyKey = readLegacyKeychain()
        if !legacyKey.isEmpty,
           let ds = providers.first(where: { $0.id == "deepseek" }),
           !hasAPIKey(for: ds) {
            _ = saveAPIKey(legacyKey, for: ds)
            print("[ProviderManager] 已从旧 Keychain 迁移 API Key")
        }
        UserDefaults.standard.set(true, forKey: Self.migratedKey)
    }

    private func readLegacyKeychain() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dsmon_apikey",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
}

// MARK: - 通知扩展

extension Notification.Name {
    static let activeProviderDidChange = Notification.Name("activeProviderDidChange")
}
