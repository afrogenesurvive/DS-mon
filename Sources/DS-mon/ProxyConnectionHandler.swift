@preconcurrency import CFNetwork
import Foundation
import Network

// MARK: - 单连接代理处理器

/// 处理一条代理连接的生命周期：
///   1. 接收完整 HTTP 请求
///   2. 路由到上游（DeepSeek API）
///   3. 流式转发响应
///   4. 记录用量数据到 UsageStore
final class ProxyConnectionHandler: @unchecked Sendable {
    let conn: NWConnection
    private let store: UsageStore
    let onRequestCompleted: () -> Void
    lazy var usageLogger = UsageLogger(store: store, onComplete: onRequestCompleted)
    private let onConnectionStateChanged: ((NWConnection.State) -> Void)?
    private let onRequestStarted: ((_ isResponses: Bool) -> Void)?

    /// 连接结束时回调，用于释放本对象的强引用
    var onFinished: (() -> Void)?

    init(connection: NWConnection, store: UsageStore, onConnectionStateChanged: ((NWConnection.State) -> Void)? = nil, onRequestStarted: ((_ isResponses: Bool) -> Void)? = nil, onRequestCompleted: @escaping () -> Void) {
        self.conn = connection
        self.store = store
        self.onConnectionStateChanged = onConnectionStateChanged
        self.onRequestStarted = onRequestStarted
        self.onRequestCompleted = onRequestCompleted
    }

    func start() {
        print("[ProxyConnectionHandler] start() called")
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { print("[ProxyConnectionHandler] self deallocated in state handler"); return }
            self.onConnectionStateChanged?(state)
            print("[ProxyConnectionHandler] state: \(state)")
            switch state {
            case .ready: print("[ProxyConnectionHandler] ready, calling receive"); self.receive(message: nil)
            case .failed(let err):
                print("[ProxyConnectionHandler] Connection failed: \(err)")
                self.onFinished?()
            case .cancelled:
                print("[ProxyConnectionHandler] Connection cancelled")
                self.onFinished?()
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    // MARK: - HTTP 接收

    /// 循环接收直到完整 HTTP 请求（支持大 body）
    private func receive(message: CFHTTPMessage?) {
        let c = conn
        c.receive(minimumIncompleteLength: 1, maximumLength: AppConfig.maxHTTPBodySize)
        { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { print("[ProxyServer] Receive error: \(error)"); conn.cancel(); onFinished?(); return }
            guard let data, !data.isEmpty else { conn.cancel(); onFinished?(); return }

            let msg: CFHTTPMessage
            if let existing = message {
                msg = existing
            } else {
                guard let parsed = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
                    as CFHTTPMessage? else { conn.cancel(); return }
                msg = parsed
            }

            if !CFHTTPMessageAppendBytes(msg, (data as NSData).bytes, data.count) {
                sendError(code: 400, body: "Bad request"); return
            }
            guard CFHTTPMessageIsHeaderComplete(msg) else {
                // 头部未收完，继续读
                receive(message: msg); return
            }

            let headers = (CFHTTPMessageCopyAllHeaderFields(msg)?.takeRetainedValue()
                           as? [String: String]) ?? [:]
            let contentLength = Int(headers["Content-Length"] ?? "0") ?? 0
            let body = CFHTTPMessageCopyBody(msg)?.takeRetainedValue() as Data? ?? Data()

            guard body.count >= contentLength else {
                receive(message: msg); return
            }

            guard let rawURL = CFHTTPMessageCopyRequestURL(msg)?.takeRetainedValue() as URL?,
                  let method = CFHTTPMessageCopyRequestMethod(msg)?.takeRetainedValue() as String?
            else { sendError(code: 400, body: "Bad request"); return }

            let path = rawURL.path + (rawURL.query.map { "?\($0)" } ?? "")

            let isResponsesApi = path.contains("/v1/responses")
            onRequestStarted?(isResponsesApi)

            Task { [weak self] in
                await self?.forward(method: method, path: path, headers: headers, body: body)
            }
        }
    }

    // MARK: - 转发

    private func forward(method: String, path: String, headers: [String: String], body: Data) async {
        let isResponsesApi = path.contains("/v1/responses")
        let userAgent = headers["User-Agent"] ?? headers["user-agent"] ?? ""
        let upstreamBase: String
        var pendingAuthHeader: String?
        var activeProviderId: String = ""

        // 从主 actor 获取活跃提供商信息
        let providerInfo = await MainActor.run { () -> (baseURL: String, authHeader: String?, providerId: String, apiPath: String, defaultModel: String?)? in
            guard let p = ProviderManager.shared.activeProvider else { return nil }
            let key = ProviderManager.shared.activeAPIKey
            let auth = key.isEmpty ? nil : "\(p.authHeaderPrefix) \(key)"
            return (p.baseURL, auth, p.id, p.apiPath, p.defaultModel)
        }

        // RPM 限流检查
        let rpmLimit = await MainActor.run { ProviderManager.shared.activeProvider?.rateLimitRPM }
        if let pid = providerInfo?.providerId, let limit = rpmLimit {
            guard RateLimiter.shared.check(providerId: pid, rpmLimit: limit) else {
                let retryAfter = "60"
                sendError(code: 429, body: "Rate limit exceeded: \(limit) RPM. Retry after \(retryAfter)s.")
                return
            }
        }

        // 日志：记录请求
        let requestModel = (try? JSONSerialization.jsonObject(with: body)).flatMap { $0 as? [String: Any] }?["model"] as? String ?? "unknown"
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        AppConfig.appendLog(to: AppConfig.proxyLogURL, "[\(ts)] 请求 → 直连 | 提供商: \(providerInfo?.providerId ?? "?"), 模型: \(requestModel)\n")

        // 检查是否为 Responses API 请求，直接处理
        if isResponsesApi {
            await handleResponsesDirectly(
                method: method, path: path, headers: headers, body: body,
                providerInfo: providerInfo, requestModel: requestModel,
                userAgent: userAgent
            )
            return
        }

        let targetURL: URL
        if let info = providerInfo {
            upstreamBase = info.baseURL
            pendingAuthHeader = info.authHeader
            activeProviderId = info.providerId

            let baseWithoutSlash = info.baseURL.hasSuffix("/")
                ? String(info.baseURL.dropLast())
                : info.baseURL
            let apiWithSlash: String
            if info.apiPath.isEmpty {
                apiWithSlash = ""
            } else if info.apiPath.hasPrefix("/") {
                apiWithSlash = info.apiPath
            } else {
                apiWithSlash = "/" + info.apiPath
            }
            let pathWithoutApi = path.hasPrefix(apiWithSlash)
                ? String(path.dropFirst(apiWithSlash.count))
                : path
            let fullPath = "\(apiWithSlash)\(pathWithoutApi.hasPrefix("/") ? pathWithoutApi : "/" + pathWithoutApi)"
            guard let url = URL(string: "\(baseWithoutSlash)\(fullPath)") else {
                sendError(code: 502, body: "Bad upstream URL"); return
            }
            targetURL = url
        } else {
            upstreamBase = "https://api.deepseek.com"
            guard let url = URL(string: "\(upstreamBase)\(path)") else {
                sendError(code: 502, body: "Bad upstream URL"); return
            }
            targetURL = url
        }

        var req = URLRequest(url: targetURL)
        req.httpMethod = method
        req.httpBody = applyDefaultModel(body, providerInfo?.defaultModel)
        req.timeoutInterval = AppConfig.proxyRequestTimeout

        for (key, value) in headers {
            let lower = key.lowercased()
            guard lower != "host", lower != "content-length", lower != "transfer-encoding" else { continue }
            req.setValue(value, forHTTPHeaderField: key)
        }
        if req.value(forHTTPHeaderField: "Content-Type") == nil, !body.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // 使用活跃提供商的 API Key 覆盖 Authorization 头
        if let auth = pendingAuthHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let start = Date()
        var accumulatedBody = Data()
        var headersSent = false

        do {
            let (bytes, resp) = try await AppConfig.directURLSession.bytes(for: req)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            let respHeaders = (httpResp?.allHeaderFields as? [String: String]) ?? [:]

            // 发送响应头
            let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            var headerStr = "HTTP/1.1 \(statusCode) \(reason)\r\n"

            // 判断是否为 SSE 流式响应（没有固定 Content-Length）
            let contentType = respHeaders["Content-Type"] ?? respHeaders["content-type"] ?? ""
            let isStreamingResponse = contentType.contains("text/event-stream")

            for (key, value) in respHeaders {
                let lower = key.lowercased()
                // 总是剥离逐跳头（hop-by-hop headers）
                guard lower != "connection", lower != "keep-alive",
                      lower != "transfer-encoding"
                else { continue }
                // 对流式响应剥离 Content-Length（长度未知）；非流式保留
                if lower == "content-length" && isStreamingResponse { continue }
                headerStr += "\(key): \(value)\r\n"
            }
            // Connection: close 明确告知客户端连接将关闭，避免 keep-alive 等待
            headerStr += "Connection: close\r\n"
            headerStr += "\r\n"

            guard let headerData = headerStr.data(using: .utf8) else {
                sendError(code: 502, body: "Header encoding error"); return
            }

            conn.send(content: headerData, completion: .contentProcessed { _ in })
            headersSent = true
            debugLog("→ \(statusCode) \(path) | \(respHeaders["content-type"] ?? "-")")

            // 流式转发 body
            var sendBuf = Data()
            for try await byte in bytes {
                accumulatedBody.append(byte)
                sendBuf.append(byte)
                if byte == UInt8(ascii: "\n") || sendBuf.count >= AppConfig.sseStreamChunkSize {
                    let c = conn; c.send(content: sendBuf, completion: .contentProcessed { _ in })
                    sendBuf = Data()
                }
            }
            if !sendBuf.isEmpty {
                let c = conn; c.send(content: sendBuf, completion: .contentProcessed { _ in })
            }

            // 上游流结束 → 发送空数据标记结束，关闭连接
            conn.send(content: Data(), completion: .contentProcessed { [weak conn] _ in
                conn?.cancel()
            })

            // 记录用量
            let isChatCompletion = statusCode == 200 && path.contains("/chat/completions")
            if isChatCompletion {
                usageLogger.logChatUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed, statusCode: statusCode, providerId: activeProviderId, userAgent: userAgent)
            } else {
                usageLogger.logResponsesUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed, providerId: activeProviderId, userAgent: userAgent)
                let preview = String(data: accumulatedBody.prefix(800), encoding: .utf8) ?? "(非文本)"
                debugLog("← \(path) body(\(accumulatedBody.count)B) preview:\n\(preview)")
                appendLog("← body \(accumulatedBody.count)B | \(preview.replacingOccurrences(of: "\n", with: " ").prefix(200))")
            }
        } catch {
            let msg: String
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cannotConnectToHost: msg = "Upstream unreachable (\(upstreamBase))"
                case .dnsLookupFailed:     msg = "Upstream DNS lookup failed (\(upstreamBase))"
                case .timedOut:            msg = "Upstream timed out (\(upstreamBase))"
                case .notConnectedToInternet: msg = "No internet connection"
                default:                   msg = "Upstream error: \(urlError.localizedDescription)"
                }
            } else {
                msg = "Upstream error: \(error.localizedDescription)"
            }
            print("[ProxyServer] \(msg)")
            appendLog("✗ 错误: \(msg)")
            if !headersSent {
                sendError(code: 502, body: msg)
            } else {
                conn.cancel()
            }
        }
    }

    // MARK: - 模型覆写

    /// 将请求 body 中的 model 替换为提供商的默认模型
    private func applyDefaultModel(_ body: Data, _ defaultModel: String?) -> Data {
        guard !body.isEmpty else { return body }
        let model = defaultModel ?? ProviderConfig.default.defaultModel ?? "deepseek-v4-pro"
        guard !model.isEmpty else { return body }
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        json["model"] = model
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    // MARK: - 响应辅助

    func sendError(code: Int, body: String) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: code)
        var raw = "HTTP/1.1 \(code) \(reason)\r\n"
        raw += "Content-Type: text/plain\r\n"
        raw += "Content-Length: \(body.utf8.count)\r\n"
        raw += "Connection: close\r\n\r\n"
        var packet = raw.data(using: .utf8) ?? Data()
        packet.append(body.data(using: .utf8) ?? Data())
        conn.send(content: packet, completion: .contentProcessed { [weak conn] _ in
            conn?.cancel()
        })
    }


    func appendLog(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        AppConfig.appendLog(to: AppConfig.proxyLogURL, "[\(ts)] \(message)\n")
    }

    func debugLog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        print("[ProxyServer] \(msg())")
        #endif
    }
}


