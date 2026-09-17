import Foundation
import CryptoKit
import Security

enum SecureStore {
    private static let keyFile = "\(NSHomeDirectory())/.dev-mon/.enc_key"
    private static let legacyKeyFile = "\(NSHomeDirectory())/.ds-mon/.enc_key"
    private static let keychainService = "com.devmon.app"
    private static let keychainAccount = "master-key"

    // MARK: - 🔑 主密钥：优先存放在登录钥匙串

    /// 从钥匙串读取 32 字节主密钥。
    private static func keychainLoad() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return data
    }

    /// 写入钥匙串（仅设备解锁时可读，不随 iCloud 钥匙串同步）。
    @discardableResult
    private static func keychainSave(_ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// 迁移完成后删除旧密钥文件。失败只打印，不影响解密。
    private static func removeKeyFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            print("[SecureStore] removed migrated key file \(path)")
        } catch {
            print("[SecureStore] could not remove \(path): \(error)")
        }
    }

    /// 读取磁盘上的密钥文件（长度合法才接受），顺手把权限收紧到 0600。
    private static func loadKeyFile(at path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count == 32 else { return nil }
        AppConfig.secureFile(URL(fileURLWithPath: path))
        return data
    }

    private static func loadKey() -> SymmetricKey? {
        if let data = keychainLoad() { return SymmetricKey(data: data) }
        if let data = loadKeyFile(at: keyFile) { return SymmetricKey(data: data) }
        return nil
    }

    /// 主密钥写入钥匙串；同时在规范路径保留一份 **0600** 的文件兜底。
    /// 保留兜底是有意的：重新签名的构建可能让 macOS 重新询问钥匙串授权，
    /// 一旦被拒绝，没有兜底文件的话用户已存的 API Key 会全部读不出来。
    private static func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        if !keychainSave(data) {
            print("[SecureStore] keychain save failed — relying on the 0600 key file")
        }
        let dir = (keyFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: keyFile), options: .atomic)
        AppConfig.secureDirectory(URL(fileURLWithPath: dir))
        AppConfig.secureFile(URL(fileURLWithPath: keyFile))
    }

    private static func getOrCreateKey() -> SymmetricKey {
        // 迁移顺序：先用旧文件里的密钥接管现有数据，写入成功后再删除旧目录里的副本。
        // 规范路径上的文件（0600）保留作为兜底，见 saveKey 的注释。
        if let legacy = loadKeyFile(at: legacyKeyFile) {
            keychainSave(legacy)
            if !FileManager.default.fileExists(atPath: keyFile) {
                try? legacy.write(to: URL(fileURLWithPath: keyFile), options: .atomic)
                AppConfig.secureFile(URL(fileURLWithPath: keyFile))
            }
            removeKeyFile(at: legacyKeyFile)
            return SymmetricKey(data: legacy)
        }
        if let existing = keychainLoad() { return SymmetricKey(data: existing) }
        if let fileKey = loadKeyFile(at: keyFile) {
            keychainSave(fileKey)
            return SymmetricKey(data: fileKey)
        }
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
              let decoded = try? AES.GCM.open(sealed, using: key) else {
            // Fallback: 旧密钥文件位置（迁移中途 / 用户手动恢复过文件）
            if let oldData = loadKeyFile(at: legacyKeyFile),
               let oldSealed = try? AES.GCM.SealedBox(combined: data),
               let oldDecoded = try? AES.GCM.open(oldSealed, using: SymmetricKey(data: oldData)) {
                return String(data: oldDecoded, encoding: .utf8)
            }
            return nil
        }
        return String(data: decoded, encoding: .utf8)
    }

    // MARK: - Convenience: Encrypted UserDefaults storage

    /// Encrypt and save a string value to UserDefaults under the given key.
    static func save(key: String, value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let encrypted = encrypt(value) {
            UserDefaults.standard.set(encrypted, forKey: key)
        }
    }

    /// Retrieve and decrypt a string value from UserDefaults by key.
    static func retrieve(key: String) -> String? {
        guard let encrypted = UserDefaults.standard.data(forKey: key) else { return nil }
        return decrypt(encrypted)
    }
}
