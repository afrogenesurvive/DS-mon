import Foundation
import CryptoKit

// MARK: - AWS Signature V4 Signer

/// Lightweight AWS SigV4 signing implementation for service API calls.
/// No SDK dependency — uses CryptoKit for HMAC-SHA256.
struct SigV4Signer {
    let region: String
    let service: String
    let accessKey: String
    let secretKey: String

    func sign(request: inout URLRequest, payload: Data? = nil) {
        let now = Date()
        let amzDate = amzDateFormat(now)
        let dateStamp = dateStampFormat(now)

        let bodyData = payload ?? Data()
        let bodyHash = SHA256.hash(data: bodyData).compactMap { String(format: "%02x", $0) }.joined()

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(bodyHash, forHTTPHeaderField: "X-Amz-Content-SHA256")

        guard let url = request.url,
              let host = url.host else { return }

        request.setValue(host, forHTTPHeaderField: "Host")

        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = url.query ?? ""

        let headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", bodyHash),
            ("x-amz-date", amzDate)
        ].sorted { $0.0 < $1.0 }

        let signedHeaders = headers.map { $0.0.lowercased() }.joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0.lowercased()):\($0.1)\n" }.joined()

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            bodyHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        ].joined(separator: "\n")

        let signature = computeSignature(secretKey: secretKey, dateStamp: dateStamp, region: region, service: service, stringToSign: stringToSign)

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private func computeSignature(secretKey: String, dateStamp: String, region: String, service: String, stringToSign: String) -> String {
        let kSecret = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(dateStamp.utf8), using: kSecret)
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: Data(kDate)))
        let kService = HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: SymmetricKey(data: Data(kRegion)))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: Data(kService)))

        let hmac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: Data(kSigning)))
        return hmac.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func amzDateFormat(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func dateStampFormat(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
