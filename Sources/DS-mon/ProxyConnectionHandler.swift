@preconcurrency import CFNetwork
import Foundation
import Network

// MARK: - 单连接代理处理器

/// 处理一条代理连接的生命周期：
///   1. 接收完整 HTTP 请求
///   2. 路由到上游（DeepSeek API / codex-relay）
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

final class ProxyConnectionHandler: @unchecked Sendable {
    private let conn: NWConnection
    private let store: UsageStore
    private let onRequestCompleted: () -> Void
    private let onConnectionStateChanged: ((NWConnection.State) -> Void)?
    private let onRequestStarted: ((_ isCodexRelay: Bool) -> Void)?

    /// 连接结束时回调，用于释放本对象的强引用
    var onFinished: (() -> Void)?

    init(connection: NWConnection, store: UsageStore, onConnectionStateChanged: ((NWConnection.State) -> Void)? = nil, onRequestStarted: ((_ isCodexRelay: Bool) -> Void)? = nil, onRequestCompleted: @escaping () -> Void) {
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

            let isCodexRelay = path.contains("/v1/responses")
            onRequestStarted?(isCodexRelay)

            Task { [weak self] in
                await self?.forward(method: method, path: path, headers: headers, body: body)
            }
        }
    }

    // MARK: - 转发

    private func forward(method: String, path: String, headers: [String: String], body: Data) async {
        let toCodexRelay = path.contains("/v1/responses")
        let upstreamBase: String
        var pendingAuthHeader: String?
        var activeProviderId: String = ""

        // 从主 actor 获取活跃提供商信息
        let providerInfo = await MainActor.run { () -> (baseURL: String, authHeader: String?, providerId: String)? in
            guard let p = ProviderManager.shared.activeProvider else { return nil }
            let key = ProviderManager.shared.activeAPIKey
            let auth = key.isEmpty ? nil : "\(p.authHeaderPrefix) \(key)"
            return (p.baseURL, auth, p.id)
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
        let logLine = "[\(ts)] 请求 → \(toCodexRelay ? "relay" : "直连") | 提供商: \(providerInfo?.providerId ?? "?"), 模型: \(requestModel)\n"
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

        if toCodexRelay {
            let savedPort = UserDefaults.standard.integer(forKey: Strings.Keys.codexRelayPort)
            let port = savedPort >= AppConfig.minProxyPort ? UInt16(savedPort) : AppConfig.codexRelayHealthPort
            upstreamBase = "http://localhost:\(port)"
            appendLog("→ relay 转发: localhost:\(port) | \(path) | 模型: \(requestModel)")
            activeProviderId = providerInfo?.providerId ?? ""
        } else {
            if let info = providerInfo {
                upstreamBase = info.baseURL
                pendingAuthHeader = info.authHeader
                activeProviderId = info.providerId
            } else {
                upstreamBase = "https://api.deepseek.com"
            }
        }

        guard let targetURL = URL(string: "\(upstreamBase)\(path)") else {
            sendError(code: 502, body: "Bad upstream URL"); return
        }

        var req = URLRequest(url: targetURL)
        req.httpMethod = method
        req.httpBody = body.isEmpty ? nil : body
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
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502
            if toCodexRelay { appendLog("← relay 响应状态码: \(statusCode)") }
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
            } else if toCodexRelay {
                logResponsesUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed, providerId: activeProviderId)
                let preview = String(data: accumulatedBody.prefix(800), encoding: .utf8) ?? "(非文本)"
                debugLog("← \(path) body(\(accumulatedBody.count)B) preview:\n\(preview)")
                appendLog("← relay body \(accumulatedBody.count)B | \(preview.replacingOccurrences(of: "\n", with: " ").prefix(200))")
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
            appendLog("✗ relay 错误: \(msg)")
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
