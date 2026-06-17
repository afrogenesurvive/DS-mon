import Foundation
import CryptoKit

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
