import Foundation
import CryptoKit

// MARK: - 令牌工具
//
// 入站认证（代理端口 / 同步服务）共用的两件小事：安全的比较，以及从 HTTP 头里取
// Bearer 令牌。放在单独文件里，避免各服务各写一份实现。

/// 常量时间比较：先 SHA-256 哈希到固定长度，再逐字节异或，避免长度 / 前缀侧信道。
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ha = Data(SHA256.hash(data: Data(a.utf8)))
    let hb = Data(SHA256.hash(data: Data(b.utf8)))
    var diff: UInt8 = 0
    for i in 0..<ha.count { diff |= ha[i] ^ hb[i] }
    return diff == 0
}

/// 从 HTTP 头字典中解析 Bearer 令牌（头名大小写不敏感）。
func bearerToken(in headers: [String: String]) -> String? {
    for (key, value) in headers where key.lowercased() == "authorization" {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return nil }
        return String(trimmed.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

/// 解析调用方出示的共享令牌：先看 `Authorization: Bearer`，再看 `x-api-key` / `api-key`。
/// 有些客户端（Anthropic 风格）用后者携带凭据，但校验的是同一个令牌，所以两种都接受。
func presentedToken(in headers: [String: String]) -> String? {
    if let bearer = bearerToken(in: headers) { return bearer }
    for (key, value) in headers {
        let lower = key.lowercased()
        guard lower == "x-api-key" || lower == "api-key" else { continue }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
    }
    return nil
}

/// 令牌指纹（SHA-256 前 8 位十六进制，不可逆）。仅用于日志里判断
/// 「客户端发的是不是另一个令牌」，绝不会把令牌本身写进日志。
func tokenFingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).prefix(4)
        .map { String(format: "%02x", $0) }.joined()
}
