import Foundation
import CryptoKit

enum SecureStore {
    private static let keyFile = "\(NSHomeDirectory())/.dev-mon/.enc_key"

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
        // 迁移: 始终优先使用旧加密密钥（如有），确保旧数据可解密
        let oldKeyFile = "\(NSHomeDirectory())/.ds-mon/.enc_key"
        if FileManager.default.fileExists(atPath: oldKeyFile) {
            if let oldData = try? Data(contentsOf: URL(fileURLWithPath: oldKeyFile)),
               oldData.count == 32 {
                try? saveKey(SymmetricKey(data: oldData))
                return SymmetricKey(data: oldData)
            }
        }
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
              let decoded = try? AES.GCM.open(sealed, using: key) else {
            // Fallback: try old key file location
            let oldKeyFile = "\(NSHomeDirectory())/.ds-mon/.enc_key"
            if let oldData = try? Data(contentsOf: URL(fileURLWithPath: oldKeyFile)),
               oldData.count == 32,
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
