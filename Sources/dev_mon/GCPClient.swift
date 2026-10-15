import Foundation

// MARK: - GCP HTTP Transport (Sendable, returns raw Data)

/// Thin `*.googleapis.com` transport. Token lifecycle lives in `GCPTracker`
/// (MainActor) so JSON parsing never crosses an isolation boundary — this struct
/// only moves `Sendable` values (`Data`, `URLResponse`).
struct GCPClient: Sendable {
    let saJSON: String
    let scope: String
    private let session: URLSession

    init(saJSON: String, scope: String) {
        self.saJSON = saJSON
        self.scope = scope
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func fetchToken() async throws -> GCPAuth.Token {
        try await GCPAuth.fetchToken(saJSON: saJSON, scope: scope)
    }

    func get(_ urlString: String, query: [URLQueryItem], token: String) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: urlString)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw GCPError.networkError("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request, token: token)
    }

    func post(_ urlString: String, body: Data, token: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw GCPError.networkError("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, token: token)
    }

    private func send(_ request: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.timeoutInterval = AppConfig.cloudRequestTimeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GCPError.networkError("Invalid response")
        }
        return (data, http)
    }
}

