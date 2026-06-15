@preconcurrency import CFNetwork
import Foundation
import Network

// MARK: - 单连接代理处理器

/// 处理一条代理连接的生命周期：
///   1. 接收完整 HTTP 请求
///   2. 路由到上游（DeepSeek API）
///   3. 流式转发响应
///   4. 记录用量数据到 UsageStore
// MARK: - 简单 RPM 限流器（按提供商）
private final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()
    private var buckets: [String: [Date]] = [:]
    private let lock = NSLock()

    func check(providerId: String, rpmLimit: Int?) -> Bool {
        guard let limit = rpmLimit, limit > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let window = now.addingTimeInterval(-60)
        var timestamps = buckets[providerId] ?? []
        timestamps.removeAll { $0 < window }
        guard timestamps.count < limit else { return false }
        timestamps.append(now)
        buckets[providerId] = timestamps
        return true
    }
}

/// 不走系统代理的 URLSession — 用于 ds-mon 到 upstream 的出站连接，
/// 避免 VPN (Shadowrocket/ClashX) 的 DNS 劫持和代理干扰。
private let directURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = AppConfig.proxyRequestTimeout
    config.timeoutIntervalForResource = AppConfig.proxyRequestTimeout
    return URLSession(configuration: config)
}()

final class ProxyConnectionHandler: @unchecked Sendable {
    private let conn: NWConnection
    private let store: UsageStore
    private let onRequestCompleted: () -> Void
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
        let logPath = NSHomeDirectory() + "/Library/Caches/com.dsmon.app/proxy.log"
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(ts)] 请求 → 直连 | 提供商: \(providerInfo?.providerId ?? "?"), 模型: \(requestModel)\n"
        if let d = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(d)
                    fh.closeFile()
                }
            } else {
                try? d.write(to: URL(fileURLWithPath: logPath))
            }
        }

        // 检查是否为 Responses API 请求，直接处理
        if isResponsesApi {
            await handleResponsesDirectly(
                method: method, path: path, headers: headers, body: body,
                providerInfo: providerInfo, requestModel: requestModel
            )
            return
        }

        let targetURL: URL
        if let info = providerInfo {
            appendLog("[buildURL] using apiPath=\(info.apiPath) defaultModel=\(info.defaultModel ?? "nil")")
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
            let (bytes, resp) = try await directURLSession.bytes(for: req)
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
                logChatUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed, statusCode: statusCode, providerId: activeProviderId)
            } else {
                logResponsesUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed, providerId: activeProviderId)
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

    // MARK: - 用量记录

    /// Chat Completions 用量 — 非流式 JSON 或 SSE 流式
    private func logChatUsage(requestBody: Data, responseBody: Data, latencyMs: Double, statusCode: Int, providerId: String = "") {
        if let respJSON = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let usage = respJSON["usage"] as? [String: Any] {
            writeUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode, providerId: providerId)
            return
        }

        // SSE 流式 — 倒序找最后一个带 usage 的 data chunk
        guard let sseText = String(data: responseBody, encoding: .utf8) else { return }
        let lines = sseText.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
            let jsonStr = String(line.dropFirst(6))
            if let chunkData = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
               let usage = json["usage"] as? [String: Any] {
                writeUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode, providerId: providerId)
                return
            }
        }
    }

    /// Responses API 用量 — 支持 SSE 流式和阻塞式 JSON
    private func logResponsesUsage(requestBody: Data, responseBody: Data, latencyMs: Double, providerId: String = "") {
        guard let text = String(data: responseBody, encoding: .utf8) else { return }
        var usage: [String: Any]?

        // 方案 1: SSE — event: response.completed 之后的 data:
        let lines = text.components(separatedBy: "\n")
        var foundEvent = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "event: response.completed" { foundEvent = true; continue }
            if foundEvent, trimmed.hasPrefix("data: ") {
                let jsonStr = String(trimmed.dropFirst(6))
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let responseObj = json["response"] as? [String: Any] {
                    usage = responseObj["usage"] as? [String: Any]
                }
                break
            }
        }

        // 方案 2: 阻塞式 JSON
        if usage == nil,
           let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] {
            usage = json["usage"] as? [String: Any]
        }

        // 方案 3: SSE 倒序
        if usage == nil {
            for line in lines.reversed() {
                guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let u = json["usage"] as? [String: Any] {
                    usage = u; break
                }
            }
        }

        guard let usage else { return }

        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }

        let cachedTokens: Int = {
            if let details = usage["input_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int { return cached }
            if let cached = usage["prompt_cache_hit_tokens"] as? Int { return cached }
            if let cached = usage["cached_tokens"] as? Int { return cached }
            return 0
        }()

        let details = usage["output_tokens_details"] as? [String: Any]
        let record = UsageRecord(
            uuid: UUID().uuidString,
            timestamp: Date(),
            providerId: providerId,
            model: model,
            endpoint: "/v1/responses",
            promptTokens: usage["input_tokens"] as? Int ?? 0,
            completionTokens: usage["output_tokens"] as? Int ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0,
            cachedTokens: cachedTokens,
            reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
            latencyMs: latencyMs,
            statusCode: 200
        )
        insertAndNotify(record)
    }

    private func writeUsage(requestBody: Data, usage: [String: Any], latencyMs: Double, statusCode: Int, providerId: String = "") {
        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }
        let details = usage["completion_tokens_details"] as? [String: Any]
        let record = UsageRecord(
            uuid: UUID().uuidString,
            timestamp: Date(),
            providerId: providerId,
            model: model,
            endpoint: "/v1/chat/completions",
            promptTokens: usage["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage["completion_tokens"] as? Int ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0,
            cachedTokens: usage["prompt_cache_hit_tokens"] as? Int ?? 0,
            reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
            latencyMs: latencyMs,
            statusCode: statusCode
        )
        insertAndNotify(record)
    }

    private func insertAndNotify(_ record: UsageRecord) {
        Task { [weak self] in
            guard let self else { return }
            await store.insert(record)
            onRequestCompleted()
            Task { @MainActor in
                NotificationCenter.default.post(name: .usageRecorded, object: nil)
            }
        }
    }

    // MARK: - 模型覆写

    /// 将请求 body 中的 model 替换为提供商的默认模型（仅 Chat Completions 路径）
    private func applyDefaultModel(_ body: Data, _ defaultModel: String?) -> Data {
        guard !body.isEmpty else { return body }
        let model = defaultModel ?? ProviderManager.activeModelDefaultModel
        appendLog("[applyDefault] param=\(defaultModel ?? "nil") active=\(ProviderManager.activeModelDefaultModel ?? "nil") resolved=\(model ?? "nil")")
        guard let model, !model.isEmpty else { return body }
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        json["model"] = model
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    // MARK: - 响应辅助

    private func sendError(code: Int, body: String) {
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


    private func appendLog(_ message: String) {
        let logPath = NSHomeDirectory() + "/Library/Caches/com.dsmon.app/proxy.log"
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(ts)] \(message)\n"
        if let d = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(d)
                    fh.closeFile()
                }
            } else {
                try? d.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    private func debugLog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        print("[ProxyServer] \(msg())")
        #endif
    }
}


extension ProxyConnectionHandler {
    // MARK: - Responses API 直接处理

    /// 直接处理 /v1/responses 请求：翻译 → URLSession 发送 → 返回响应
    private func handleResponsesDirectly(
        method: String, path: String, headers: [String: String], body: Data,
        providerInfo: (baseURL: String, authHeader: String?, providerId: String, apiPath: String, defaultModel: String?)?,
        requestModel: String
    ) async {
        // 解析 Responses API 请求
        guard let reqJSON = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reqData = try? JSONSerialization.data(withJSONObject: reqJSON),
              let responsesReq = try? JSONDecoder().decode(ResponsesRequest.self, from: reqData)
        else {
            appendLog("[Responses] 无法解析请求: \(requestModel)")
            sendError(code: 400, body: "Invalid request body")
            onRequestCompleted()
            onFinished?()
            return
        }

        let isStreaming = responsesReq.stream ?? false
        let sessions = ResponsesSessionStore.shared

        // 获取历史消息
        let history = responsesReq.previousResponseId.flatMap {
            sessions.getHistory(responseId: $0)
        } ?? []

        // 转换为 Chat Completions 请求
        let chatReq = toChatRequest(req: responsesReq, history: history, sessions: sessions)

        guard let info = providerInfo else {
            sendError(code: 502, body: "No active provider")
            onRequestCompleted()
            onFinished?()
            return
        }

        // 构建上游 URL: baseURL + apiPath + "/chat/completions"
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
        guard let url = URL(string: "\(baseWithoutSlash)\(apiWithSlash)/chat/completions") else {
            sendError(code: 502, body: "Invalid upstream URL")
            onRequestCompleted()
            onFinished?()
            return
        }

        appendLog("[Responses] URL: \(url.absoluteString)")
        appendLog("[Responses] 翻译: \(chatReq.model) stream=\(isStreaming) tools=\(chatReq.tools?.count ?? 0) msgs=\(chatReq.messages.count)")

        // 编码 Chat Completions 请求
        if let chatBodyDebug = try? JSONEncoder().encode(chatReq),
           let bodyStr = String(data: chatBodyDebug, encoding: .utf8) {
            appendLog("[Responses] 请求body: \(bodyStr.prefix(2000))")
        }
        guard let chatBody = try? JSONEncoder().encode(chatReq) else {
            sendError(code: 502, body: "Failed to encode chat request")
            onRequestCompleted()
            onFinished?()
            return
        }

        // 发起请求到 upstream
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.httpBody = chatBody
        urlReq.timeoutInterval = AppConfig.proxyRequestTimeout
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = info.authHeader {
            urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let start = Date()

        if isStreaming {
            await handleResponsesStreaming(
                urlReq: urlReq, responseId: sessions.newId(),
                model: chatReq.model, chatReq: chatReq,
                sessions: sessions, start: start
            )
        } else {
            await handleResponsesBlocking(
                urlReq: urlReq, responseId: sessions.newId(),
                model: chatReq.model, start: start
            )
        }
    }

    /// 处理流式 Responses API 请求
    private func handleResponsesStreaming(
        urlReq: URLRequest, responseId: String, model: String,
        chatReq: ChatRequest, sessions: ResponsesSessionStore, start: Date
    ) async {
        var state = StreamTranslationState()
        var headersSent = false
        var accumulatedBody = Data()

        do {
            let (bytes, resp) = try await directURLSession.bytes(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502
            _ = (httpResp?.allHeaderFields as? [String: String]) ?? [:]

            if statusCode != 200 {
                appendLog("[Responses] 上游错误 status=\(statusCode)")
                sendError(code: 502, body: "Upstream error: \(statusCode)")
                onRequestCompleted()
                onFinished?()
                return
            }

            // 发送 SSE 响应头
            var headerStr = "HTTP/1.1 200 OK\r\n"
            headerStr += "Content-Type: text/event-stream; charset=utf-8\r\n"
            headerStr += "Connection: close\r\n"
            headerStr += "Cache-Control: no-cache\r\n\r\n"
            guard let headerData = headerStr.data(using: .utf8) else {
                sendError(code: 502, body: "Header encoding error")
                onRequestCompleted()
                onFinished?()
                return
            }
            conn.send(content: headerData, completion: .contentProcessed { _ in })
            headersSent = true

            // 逐行读取 SSE 流（使用 Data 缓冲区避免 UTF-8 多字节字符乱码）
            var lineBuf = Data()
            for try await byte in bytes {
                accumulatedBody.append(byte)
                if byte == UInt8(ascii: "\n") {
                    if let line = String(data: lineBuf, encoding: .utf8),
                       line.hasPrefix("data: ") {
                        let dataContent = String(line.dropFirst(6))
                        if dataContent.trimmingCharacters(in: .whitespacesAndNewlines) != "[DONE]" {
                            let events = translateSSEToResponsesEvent(
                                sseData: dataContent,
                                responseId: responseId,
                                model: model,
                                state: &state
                            )
                            for event in events {
                                if let eventData = (event + "\n").data(using: .utf8) {
                                    conn.send(content: eventData, completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    lineBuf.removeAll(keepingCapacity: true)
                } else {
                    lineBuf.append(byte)
                }
            }

            // 流结束，确保 response.completed 或 tool call items 已关闭
            if !state.streamDone {
                if state.didEmitMessageItem {
                    let doneEvent = "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"\(state.messageItemId)\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(state.accumulatedText.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"}]}}\n\n"
                    if let d = doneEvent.data(using: .utf8) { conn.send(content: d, completion: .contentProcessed { _ in }) }
                }
                for (idx, accum) in state.toolCallAccums.sorted(by: { $0.key < $1.key }) {
                    let fcItemId = state.toolCallItemIds[idx] ?? ""
                    let args = accum.arguments.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let doneEvent = "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":\(idx+1),\"item\":{\"type\":\"function_call\",\"id\":\"\(fcItemId)\",\"call_id\":\"\(accum.id)\",\"name\":\"\(accum.name)\",\"arguments\":\"\(args)\",\"status\":\"completed\"}}\n\n"
                    if let d = doneEvent.data(using: .utf8) { conn.send(content: d, completion: .contentProcessed { _ in }) }
                }
                let completedEvent = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"\(responseId)\",\"status\":\"completed\",\"model\":\"\(model)\",\"output\":[],\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n"
                if let d = completedEvent.data(using: .utf8) { conn.send(content: d, completion: .contentProcessed { _ in }) }
            }

            conn.send(content: Data(), completion: .contentProcessed { [weak conn] _ in
                conn?.cancel()
            })

            // 保存会话
            let assistantToolCalls: [JSONValue]? = {
                if state.toolCallAccums.isEmpty { return nil }
                return state.toolCallAccums.sorted(by: { $0.key < $1.key }).map { (_, accum) in
                    .object([
                        "id": .string(accum.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(accum.name),
                            "arguments": .string(accum.arguments)
                        ])
                    ])
                }
            }()
            let assistantMsg = ChatMessage(
                role: "assistant",
                content: state.accumulatedText.isEmpty ? nil : .string(state.accumulatedText),
                reasoningContent: state.accumulatedReasoning.isEmpty ? nil : state.accumulatedReasoning,
                toolCalls: assistantToolCalls,
                toolCallId: nil, name: nil
            )
            var fullHistory = chatReq.messages
            fullHistory.append(assistantMsg)
            if !state.accumulatedReasoning.isEmpty {
                sessions.storeTurnReasoning(messages: chatReq.messages, assistantMsg: assistantMsg, reasoning: state.accumulatedReasoning)
            }
            sessions.saveWithId(id: responseId, messages: fullHistory)

        } catch {
            appendLog("[Responses] 流错误: \(error.localizedDescription)")
            if !headersSent {
                sendError(code: 502, body: "Upstream error: \(error.localizedDescription)")
            } else {
                conn.cancel()
            }
        }
        onRequestCompleted()
        onFinished?()
    }

    /// 处理非流式 Responses API 请求
    private func handleResponsesBlocking(
        urlReq: URLRequest, responseId: String, model: String, start: Date
    ) async {
        do {
            let (data, resp) = try await directURLSession.data(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            guard statusCode == 200 else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                appendLog("[Responses] 上游错误 \(statusCode): \(bodyText.prefix(200))")
                sendError(code: 502, body: "Upstream error: \(statusCode)")
                onRequestCompleted()
                onFinished?()
                return
            }

            guard let chatResp = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
                appendLog("[Responses] 解析上游响应失败")
                sendError(code: 502, body: "Failed to parse upstream response")
                onRequestCompleted()
                onFinished?()
                return
            }

            let (respJSON, _) = fromChatResponse(
                responseId: responseId, model: model,
                chatResp: chatResp, namespaceTools: [:]
            )

            let responseData = try JSONSerialization.data(withJSONObject: respJSON)

            // 发送响应
            var headerStr = "HTTP/1.1 200 OK\r\n"
            headerStr += "Content-Type: application/json; charset=utf-8\r\n"
            headerStr += "Connection: close\r\n"
            headerStr += "Content-Length: \(responseData.count)\r\n\r\n"
            guard let headerData = headerStr.data(using: .utf8) else {
                sendError(code: 502, body: "Header encoding error")
                onRequestCompleted()
                onFinished?()
                return
            }
            conn.send(content: headerData, completion: .contentProcessed { _ in })
            conn.send(content: responseData, completion: .contentProcessed { [weak conn] _ in
                conn?.cancel()
            })

        } catch {
            appendLog("[Responses] 阻塞请求错误: \(error.localizedDescription)")
            sendError(code: 502, body: "Upstream error: \(error.localizedDescription)")
        }
        onRequestCompleted()
        onFinished?()
    }

}
