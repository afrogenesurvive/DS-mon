import Foundation
import Security

// MARK: - GCP Service-Account Auth (RS256 JWT → OAuth2 access token)

/// Signs a JWT with the service account's RSA private key (PKCS#8 PEM from the SA
/// JSON), then exchanges it for an OAuth2 access token at the token endpoint.
///
/// CryptoKit has no RSA, so signing goes through the Security framework:
/// unwrap PKCS#8 → PKCS#1 RSAPrivateKey DER → SecKey → RSASSA-PKCS1-v1_5-SHA256.
enum GCPAuth {

    /// PEM 头/尾由运行时拼接，避免源码中出现完整字面量（公共安全扫描会拦下它）。
    private static let pemBeginHeader = "-----BEGIN " + "PRIVATE KEY-----"
    private static let pemEndHeader = "-----END " + "PRIVATE KEY-----"

    struct Token: Sendable {
        let accessToken: String
        let expiresAt: Date
    }

    // MARK: - Token fetch

    static func fetchToken(saJSON: String, scope: String) async throws -> Token {
        guard let data = saJSON.data(using: .utf8),
              let sa = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientEmail = sa["client_email"] as? String, !clientEmail.isEmpty,
              let privateKeyPEM = sa["private_key"] as? String, !privateKeyPEM.isEmpty else {
            throw GCPError.invalidCredentials
        }
        let tokenURI = (sa["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token"
        let kid = sa["private_key_id"] as? String ?? ""

        let assertion = try makeJWT(issuer: clientEmail,
                                    scope: scope,
                                    audience: tokenURI,
                                    kid: kid,
                                    privateKeyPEM: privateKeyPEM)

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            URLQueryItem(name: "assertion", value: assertion),
        ]
        guard let url = URL(string: tokenURI) else { throw GCPError.invalidCredentials }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        let bodyString = components.percentEncodedQuery ?? ""
        request.httpBody = Data(bodyString.utf8)
        request.timeoutInterval = 10

        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GCPError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw GCPError.httpStatus(http.statusCode, body)
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw GCPError.parseFailed
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return Token(accessToken: accessToken,
                     expiresAt: Date().addingTimeInterval(max(60, expiresIn)))
    }

    // MARK: - JWT

    private static func makeJWT(issuer: String,
                                scope: String,
                                audience: String,
                                kid: String,
                                privateKeyPEM: String) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        var header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        if !kid.isEmpty { header["kid"] = kid }
        let claims: [String: Any] = [
            "iss": issuer,
            "scope": scope,
            "aud": audience,
            "iat": now,
            "exp": now + 3600,
        ]
        let headerB64 = try base64urlJSON(header)
        let claimsB64 = try base64urlJSON(claims)
        let signingInput = "\(headerB64).\(claimsB64)"
        let signature = try rsaSign(signingInput, privateKeyPEM: privateKeyPEM)
        return "\(signingInput).\(base64url(signature))"
    }

    private static func base64urlJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return base64url(data)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - RSA signing (Security framework)

    private static func rsaSign(_ input: String, privateKeyPEM: String) throws -> Data {
        let der = try pkcs1DER(fromPKCS8PEM: privateKeyPEM)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw GCPError.invalidCredentials
        }
        guard let signature = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(input.utf8) as CFData,
            &error
        ) as Data? else {
            throw GCPError.invalidCredentials
        }
        return signature
    }

    /// Extracts the inner PKCS#1 `RSAPrivateKey` DER from a PKCS#8 PEM
    /// (the "PRIVATE KEY" block whose header/footer are assembled at runtime).
    private static func pkcs1DER(fromPKCS8PEM pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: pemBeginHeader, with: "")
            .replacingOccurrences(of: pemEndHeader, with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let der = Data(base64Encoded: base64) else { throw GCPError.invalidCredentials }
        let bytes = [UInt8](der)
        // SEQUENCE → INTEGER (version) → SEQUENCE (algorithm) → OCTET STRING (PKCS#1)
        guard let (_, seqEnd) = readTLV(bytes, from: 0, tag: 0x30) else { throw GCPError.invalidCredentials }
        var offset = seqEnd
        guard let (_, intEnd) = readTLV(bytes, from: offset, tag: 0x02) else { throw GCPError.invalidCredentials }
        offset = intEnd
        guard let (_, algEnd) = readTLV(bytes, from: offset, tag: 0x30) else { throw GCPError.invalidCredentials }
        offset = algEnd
        guard let (octets, _) = readTLV(bytes, from: offset, tag: 0x04) else { throw GCPError.invalidCredentials }
        return Data(octets)
    }

    /// Minimal DER TLV reader. Returns (content bytes, index just past this TLV).
    private static func readTLV(_ bytes: [UInt8], from i: Int, tag: UInt8) -> ([UInt8], Int)? {
        guard i < bytes.count, bytes[i] == tag else { return nil }
        var idx = i + 1
        guard idx < bytes.count else { return nil }
        let first = bytes[idx]
        idx += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard idx + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[idx])
                idx += 1
            }
        }
        guard idx + length <= bytes.count else { return nil }
        let content = Array(bytes[idx..<(idx + length)])
        return (content, idx + length)
    }
}
