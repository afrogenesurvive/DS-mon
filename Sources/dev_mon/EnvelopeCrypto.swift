import Foundation
import CryptoKit

/// 可选 AES-256-GCM 请求/响应信封（向后兼容，明文兜底）。
///
/// 信封格式（base64url）：`{ "kid": "<key id>", "v": 1, "nonce": <12B>, "tag": <16B>, "ct": <ciphertext> }`
///
/// 密钥来源：
/// - 环境变量 `DSMON_ENCRYPTION_KEY`（base64url 32 字节）
/// - `~/.config/dev_mon/dsmon.key`（32 字节原始密钥）
/// - `~/Documents/GitHub/DS-mon/afrogene/dsmon.key`（gitignored）
///
/// 未配置密钥时 `seal` 返回 nil / `open` 返回 nil，调用方回退明文（保持兼容）。
/// 注意：不得将信封内容写入日志。
enum EnvelopeCrypto {
    static let keyID = "dsmon"

    static func loadKey() -> SymmetricKey? {
        if let env = ProcessInfo.processInfo.environment["DSMON_ENCRYPTION_KEY"],
           !env.isEmpty,
           let data = decodeBase64URL(env),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        let candidates = [
            "\(NSHomeDirectory())/.config/dev_mon/dsmon.key",
            "\(NSHomeDirectory())/Documents/GitHub/DS-mon/afrogene/dsmon.key",
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               data.count == 32 {
                return SymmetricKey(data: data)
            }
        }
        return nil
    }

    static func isConfigured() -> Bool {
        loadKey() != nil
    }

    struct Envelope: Codable {
        let kid: String
        let v: Int
        let nonce: String
        let tag: String
        let ct: String
    }

    static func seal(_ plaintext: Data) -> Data? {
        guard let key = loadKey(),
              let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        let env = Envelope(
            kid: keyID,
            v: 1,
            nonce: encodeBase64URL(Data(sealed.nonce)),
            tag: encodeBase64URL(sealed.tag),
            ct: encodeBase64URL(sealed.ciphertext)
        )
        return try? JSONEncoder().encode(env)
    }

    static func open(_ envelopeData: Data) -> Data? {
        guard let key = loadKey(),
              let env = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
              env.v == 1, env.kid == keyID,
              let nonce = decodeBase64URL(env.nonce),
              let tag = decodeBase64URL(env.tag),
              let ct = decodeBase64URL(env.ct),
              let nonceBox = try? AES.GCM.Nonce(data: nonce),
              let sealed = try? AES.GCM.SealedBox(nonce: nonceBox, ciphertext: ct, tag: tag)
        else { return nil }
        return try? AES.GCM.open(sealed, using: key)
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        return Data(base64Encoded: b64)
    }
}
