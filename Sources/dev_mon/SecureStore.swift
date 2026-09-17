import Foundation
import CryptoKit
import Security

enum SecureStore {
    private static let keyFile = "\(NSHomeDirectory())/.dev-mon/.enc_key"
    private static let legacyKeyFile = "\(NSHomeDirectory())/.ds-mon/.enc_key"
    private static let keychainService = "com.devmon.app"
    private static let keychainAccount = "master-key"

    // MARK: - 🔑 主密钥：优先存放在登录钥匙串

    /// 进程内缓存：一次运行里**最多读一次**钥匙串。
    ///
    /// 这曾经是弹窗死循环的一半原因：`encrypt` / `decrypt` 每次调用都会走到
    /// `getOrCreateKey()`，而代理在**每个请求**上都要读客户端令牌
    /// （`ProxyConnectionHandler` → `ProxyServer.clientToken` → `SecureStore.retrieve`），
    /// 设置界面的多个 `@State` 初始化器也会反复触发 —— 没有缓存就等于不停敲门。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?
    /// 读钥匙串被拒绝（用户取消 / 密码错误 / ACL 失效）后，本次运行不再写钥匙串。
    nonisolated(unsafe) private static var keychainWriteSuppressed = false
    /// 最近一次钥匙串操作的状态码，供日志与「关于」页诊断。
    nonisolated(unsafe) private static var lastKeychainStatus: OSStatus = errSecSuccess

    /// 从钥匙串读取 32 字节主密钥，**同时返回状态码**。
    ///
    /// 状态码是必需的：以前所有失败都塌缩成 `nil`，于是「条目不存在」和
    /// 「用户刚刚点了取消」走同一条兜底路径 —— 后者会删除并重建条目，
    /// 把用户刚授权的 ACL 一起丢掉，下一次读取又弹窗（死循环）。
    private static func keychainLoad() -> (data: Data?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return (nil, status) }
        return (data, errSecSuccess)
    }

    /// 写入钥匙串（仅设备解锁时可读，不随 iCloud 钥匙串同步）。
    ///
    /// **绝不 delete + add**：`SecItemDelete` 会把条目的 ACL 一并丢弃，
    /// 用户刚点的「始终允许」在下一个读请求上就失效 —— 这正是弹窗无限循环的根因。
    /// 已存在就只更新值；只有确实没有条目（`errSecItemNotFound`）才 add。
    @discardableResult
    private static func keychainSave(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("[SecureStore] keychain write failed: \(status)")
        }
        return status == errSecSuccess
    }

    /// 只在钥匙串里确实没有条目、且本次运行没被拒绝过时补写。
    private static func mirrorToKeychainIfAbsent(_ data: Data) {
        guard !keychainWriteSuppressed else { return }
        if !keychainSave(data) { keychainWriteSuppressed = true }
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

    /// 主密钥写入钥匙串；同时在规范路径保留一份 **0600** 的文件兜底。
    /// 保留兜底是有意的：重新签名的构建可能让 macOS 重新询问钥匙串授权，
    /// 一旦被拒绝，没有兜底文件的话用户已存的 API Key 会全部读不出来。
    private static func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        if !keychainWriteSuppressed, !keychainSave(data) {
            keychainWriteSuppressed = true
            print("[SecureStore] keychain save failed — relying on the 0600 key file")
        }
        let dir = (keyFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: keyFile), options: .atomic)
        AppConfig.secureDirectory(URL(fileURLWithPath: dir))
        AppConfig.secureFile(URL(fileURLWithPath: keyFile))
    }

    /// 主密钥入口：一次运行里只解析一次，其余调用直接命中缓存。
    private static func getOrCreateKey() -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key = resolveKey()
        cachedKey = key
        return key
    }

    /// 迁移顺序：先用旧文件里的密钥接管现有数据，写入成功后再删除旧目录里的副本。
    /// 规范路径上的文件（0600）保留作为兜底，见 saveKey 的注释。
    private static func resolveKey() -> SymmetricKey {
        if let legacy = loadKeyFile(at: legacyKeyFile) {
            mirrorToKeychainIfAbsent(legacy)
            if !FileManager.default.fileExists(atPath: keyFile) {
                try? legacy.write(to: URL(fileURLWithPath: keyFile), options: .atomic)
                AppConfig.secureFile(URL(fileURLWithPath: keyFile))
            }
            removeKeyFile(at: legacyKeyFile)
            return SymmetricKey(data: legacy)
        }

        let (existing, status) = keychainLoad()
        lastKeychainStatus = status
        if let existing { return SymmetricKey(data: existing) }

        if status != errSecItemNotFound {
            // 用户取消 / 拒绝 / ACL 失效：本次运行彻底不再打扰，
            // 也不要「删掉再补写」——那会重置 ACL，弹窗会一直回来。
            keychainWriteSuppressed = true
            print("[SecureStore] keychain read failed (\(status)) — using the key file for this session")
        }

        if let fileKey = loadKeyFile(at: keyFile) {
            // 只有「钥匙串里确实没有条目」才补写；被拒绝的情况下保持原状。
            if status == errSecItemNotFound { mirrorToKeychainIfAbsent(fileKey) }
            return SymmetricKey(data: fileKey)
        }

        let newKey = SymmetricKey(size: .bits256)
        try? saveKey(newKey)
        return newKey
    }

    /// 只读诊断串（日志 / About 页）：是否已缓存、最近状态码、是否已放弃写钥匙串。
    static var keychainDiagnostic: String {
        lock.lock()
        defer { lock.unlock() }
        return "cached=\(cachedKey != nil) status=\(lastKeychainStatus) suppressed=\(keychainWriteSuppressed)"
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
