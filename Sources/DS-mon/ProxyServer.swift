@preconcurrency import Foundation
import Network

// MARK: - 本地 HTTP 代理服务器

/// 在本地端口监听 HTTP 请求，透明转发到 api.deepseek.com，
/// 并自动记录 chat completions 的 usage 数据到 UsageStore。
final class ProxyServer: @unchecked Sendable {
    static let shared = ProxyServer()

    private let lock = NSLock()

    private var listener: NWListener?
    private var _isRunning = false
    private var _port: UInt16 = 18080
    private var _requestCount = 0
    private var _listenerError: String?
    private var _moonbridgeReachable: Bool?
    private var _moonbridgeError: String?

    var isRunning: Bool { lock.withLock { _isRunning } }
    var port: UInt16 { lock.withLock { _port } }
    var requestCount: Int { lock.withLock { _requestCount } }
    var listenerError: String? { lock.withLock { _listenerError } }
    var moonbridgeReachable: Bool? { lock.withLock { _moonbridgeReachable } }
    var moonbridgeError: String? { lock.withLock { _moonbridgeError } }

    private let store = UsageStore.shared

    /// 每 15 秒检测 Moon Bridge 健康状态，崩溃时通知 DS-mon 自动重启
    private var moonbridgeMonitorTimer: DispatchSourceTimer?

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "proxy_port")
        if saved >= 1024, saved <= 65535 {
            _port = UInt16(saved)
        }
        startMoonBridgeMonitor()
    }

    /// 启动 Moon Bridge 守护监控
    private func startMoonBridgeMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let enabled = UserDefaults.standard.bool(forKey: "moonbridge_enabled")
            guard enabled else { return }
            let reachable = lock.withLock { _moonbridgeReachable }
            if reachable != true {
                // 上次检测不可达或从未检测过 → 尝试 ping 一次
                _ = self.checkMoonBridgeHealth()
            }
        }
        timer.resume()
        moonbridgeMonitorTimer = timer
    }

    // MARK: - Start / Stop

    func start(port: UInt16? = nil) throws {
        guard !lock.withLock({ _isRunning }) else { return }
        if let port { lock.withLock { _port = port } }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let currentPort = lock.withLock { _port }
        guard let nwPort = NWEndpoint.Port(rawValue: currentPort) else {
            throw ProxyError.invalidPort
        }
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                print("[ProxyServer] Listener failed: \(err)")
                self?.lock.withLock { self?._listenerError = "\(err)" }
            }
        }
        // Clear any previous listener error before starting
        lock.withLock { _listenerError = nil }
        listener.start(queue: .global(qos: .utility))
        lock.withLock { _isRunning = true }
        UserDefaults.standard.set(Int(lock.withLock { _port }), forKey: "proxy_port")
        UserDefaults.standard.set(true, forKey: "proxy_enabled")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock { _isRunning = false; _listenerError = nil }
        UserDefaults.standard.set(false, forKey: "proxy_enabled")
    }

    // MARK: - Connection

    private func handleConnection(_ conn: NWConnection) {
        print("[ProxyServer] New connection")
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: conn, message: nil)
            case .failed(let err):
                print("[ProxyServer] Connection failed: \(err)")
            case .cancelled:
                print("[ProxyServer] Connection cancelled")
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    /// 循环接收直到完整 HTTP 请求（支持大 body）
    private func receive(on conn: NWConnection, message: CFHTTPMessage?) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let error {
                print("[ProxyServer] Receive error: \(error)")
                conn.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                conn.cancel()
                return
            }

            let msg: CFHTTPMessage
            if let existing = message {
                msg = existing
            } else {
                msg = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
            }
            let appended = data.withUnsafeBytes { ptr in
                CFHTTPMessageAppendBytes(msg, ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count)
            }
            guard appended else {
                self.sendError(conn: conn, code: 400, body: "Malformed HTTP request")
                return
            }

            // 检查头部完整性
            guard CFHTTPMessageIsHeaderComplete(msg) else {
                self.receive(on: conn, message: msg)
                return
            }

            // 头部完整 — 检查 body 是否完整
            let headers = CFHTTPMessageCopyAllHeaderFields(msg)?.takeRetainedValue() as? [String: String] ?? [:]
            let contentLength = Int(headers["Content-Length"] ?? "0") ?? 0
            let body = CFHTTPMessageCopyBody(msg)?.takeRetainedValue() as Data? ?? Data()

            if body.count < contentLength {
                // body 未收完，继续读取
                self.receive(on: conn, message: msg)
                return
            }

            // 请求完整 — 解析并转发
            guard let rawURL = CFHTTPMessageCopyRequestURL(msg)?.takeRetainedValue() as URL?,
                  let method = CFHTTPMessageCopyRequestMethod(msg)?.takeRetainedValue() as String? else {
                self.sendError(conn: conn, code: 400, body: "Bad request")
                return
            }
            let path = rawURL.path + (rawURL.query.map { "?\($0)" } ?? "")

            Task { [weak self] in
                await self?.forward(method: method, path: path, headers: headers, body: body, conn: conn)
            }
        }
    }

    // MARK: - Forward

    /// 转发请求 — 根据 path 路由到不同上游
    /// - /v1/chat/completions → api.deepseek.com（透明转发，用量统计）
    /// - /v1/responses → codex-relay（127.0.0.1:4446，Responses↔Chat Completions 协议翻译，用量统计）
    private func forward(method: String, path: String, headers: [String: String], body: Data, conn: NWConnection) async {
        let toRelay = path.contains("/v1/responses")

        let upstreamBase: String
        if toRelay {
            let relayPort = UserDefaults.standard.integer(forKey: "codex_relay_port")
            let port = relayPort >= 1024 ? UInt16(relayPort) : 4446
            upstreamBase = "http://127.0.0.1:\(port)"
        } else {
            upstreamBase = "https://api.deepseek.com"
        }

        guard let targetURL = URL(string: "\(upstreamBase)\(path)") else {
            sendError(conn: conn, code: 502, body: "Bad upstream URL")
            return
        }

        var req = URLRequest(url: targetURL)
        req.httpMethod = method
        req.httpBody = body.isEmpty ? nil : body
        req.timeoutInterval = 300

        for (key, value) in headers {
            let lower = key.lowercased()
            guard lower != "host", lower != "content-length", lower != "transfer-encoding" else { continue }
            req.setValue(value, forHTTPHeaderField: key)
        }
        if req.value(forHTTPHeaderField: "Content-Type") == nil, !body.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let start = Date()
        var accumulatedBody = Data()
        var headersSent = false

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502
            let respHeaders = (httpResp?.allHeaderFields as? [String: String]) ?? [:]
            let isChatCompletion = statusCode == 200 && path.contains("/chat/completions")

            // Build and send response headers immediately
            let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            var headerStr = "HTTP/1.1 \(statusCode) \(reason)\r\n"
            for (key, value) in respHeaders {
                let lower = key.lowercased()
                // 跳过逐跳头（hop-by-hop headers）
                guard lower != "connection", lower != "keep-alive",
                      lower != "transfer-encoding",
                      lower != "content-length" else { continue }
                headerStr += "\(key): \(value)\r\n"
            }
            // URLSession 已经解码了 chunked transfer-encoding，body 是裸字节。
            // 我们不透传 Transfer-Encoding，也不加 Content-Length 或 Connection: close，
            // HTTP/1.1 在这种情况下客户端会一直读到连接关闭为止——这正是 SSE 需要的语义。
            headerStr += "\r\n"

            guard let headerData = headerStr.data(using: .utf8) else {
                sendError(conn: conn, code: 502, body: "Header encoding error")
                return
            }

            // Forward headers before any body data
            conn.send(content: headerData, completion: .contentProcessed { _ in })
            headersSent = true
            debugLog("[ProxyServer] → \(statusCode) \(path) | \(respHeaders["content-type"] ?? "-")")

            // Stream body chunks as they arrive from upstream
            var sendBuf = Data()
            for try await byte in bytes {
                accumulatedBody.append(byte)
                sendBuf.append(byte)
                if byte == UInt8(ascii: "\n") || sendBuf.count >= 4096 {
                    conn.send(content: sendBuf, completion: .contentProcessed { _ in })
                    sendBuf = Data()
                }
            }
            if !sendBuf.isEmpty {
                conn.send(content: sendBuf, completion: .contentProcessed { _ in })
            }

            // 上游流结束 → 关闭连接，通知客户端响应完整
            conn.send(content: Data(), completion: .contentProcessed { _ in conn.cancel() })

            // Full response received — log usage stats
            if isChatCompletion {
                logUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed, statusCode: statusCode)
            } else if toRelay {
                logResponsesUsage(requestBody: body, responseBody: accumulatedBody, latencyMs: elapsed)
                // 诊断日志：打印 Moon Bridge 响应摘要
                let preview = String(data: accumulatedBody.prefix(800), encoding: .utf8) ?? "(非文本)"
                debugLog("[ProxyServer] ← \(path) body(\(accumulatedBody.count)B) preview:\n\(preview)")
            }
        } catch {
            let msg: String
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cannotConnectToHost:
                    msg = "Upstream unreachable (\(upstreamBase))"
                case .dnsLookupFailed:
                    msg = "Upstream DNS lookup failed (\(upstreamBase))"
                case .timedOut:
                    msg = "Upstream timed out (\(upstreamBase))"
                case .notConnectedToInternet:
                    msg = "No internet connection"
                default:
                    msg = "Upstream error: \(urlError.localizedDescription)"
                }
            } else {
                msg = "Upstream error: \(error.localizedDescription)"
            }
            print("[ProxyServer] \(msg)")
            // 如果还没发过 headers，可以发 502；否则只能直接断连，
            // 因为已经发过 200 OK，再发 502 会把客户端搞晕。
            if !headersSent {
                sendError(conn: conn, code: 502, body: msg)
            } else {
                conn.send(content: Data(), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: - Usage Logging

    /// 从 Responses API 响应中提取 usage（支持 SSE 流式和阻塞式 JSON 两种格式）
    private func logResponsesUsage(requestBody: Data, responseBody: Data, latencyMs: Double) {
        guard let text = String(data: responseBody, encoding: .utf8) else { return }
        var usage: [String: Any]?

        // 尝试 1：SSE 流式 — 找 event: response.completed 之后的 data: 行
        let lines = text.components(separatedBy: "\n")
        var foundEvent = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "event: response.completed" {
                foundEvent = true
                continue
            }
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

        // 尝试 2：阻塞式 JSON（codex-relay 格式）— usage 在顶层
        if usage == nil,
           let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] {
            usage = json["usage"] as? [String: Any]
        }

        // 尝试 3：SSE 倒序查找最后一个含 usage 的 data chunk（某些流式实现）
        if usage == nil {
            let revLines = text.components(separatedBy: "\n").reversed()
            for line in revLines {
                guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let u = json["usage"] as? [String: Any] {
                    usage = u
                    break
                }
            }
        }

        guard let usage else { return }

        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }

        // 缓存命中 tokens：尝试多个可能的字段名（取决于上游/中继的实现）
        let cachedTokens: Int = {
            // Responses API 格式: input_tokens_details.cached_tokens
            if let details = usage["input_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                return cached
            }
            // DeepSeek Chat Completions 格式
            if let cached = usage["prompt_cache_hit_tokens"] as? Int {
                return cached
            }
            // 某些实现直接放在顶层
            if let cached = usage["cached_tokens"] as? Int {
                return cached
            }
            return 0
        }()

        let details = usage["output_tokens_details"] as? [String: Any]
        let record = UsageRecord(
            timestamp: Date(),
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
        store.insert(record)
        lock.withLock { _requestCount += 1 }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .usageRecorded, object: nil)
        }
    }

    private func logUsage(requestBody: Data, responseBody: Data, latencyMs: Double, statusCode: Int) {
        // 先试标准 JSON（非流式）
        if let respJSON = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let usage = respJSON["usage"] as? [String: Any] {
            writeUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode)
            return
        }

        // SSE 流式格式 — 倒序查找最后一个带 usage 的 data chunk
        if let sseText = String(data: responseBody, encoding: .utf8) {
            let lines = sseText.components(separatedBy: "\n")
            for line in lines.reversed() {
                guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                if let chunkData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                   let usage = json["usage"] as? [String: Any] {
                    writeUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode)
                    return
                }
            }
        }
    }

    private func writeUsage(requestBody: Data, usage: [String: Any], latencyMs: Double, statusCode: Int) {
        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }

        let details = usage["completion_tokens_details"] as? [String: Any]
        let record = UsageRecord(
            timestamp: Date(),
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

        store.insert(record)
        lock.withLock { _requestCount += 1 }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .usageRecorded, object: nil)
        }
    }

    // MARK: - Response helpers

    private func sendResponse(conn: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var raw = "HTTP/1.1 \(statusCode) \(reason)\r\n"

        // 转发原始响应头（跳过 hop-by-hop 头）
        for (key, value) in headers {
            let lower = key.lowercased()
            guard lower != "transfer-encoding", lower != "connection", lower != "keep-alive" else { continue }
            raw += "\(key): \(value)\r\n"
        }
        raw += "Content-Length: \(body.count)\r\n"
        raw += "Connection: close\r\n"
        raw += "\r\n"

        var packet = raw.data(using: .utf8) ?? Data()
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendError(conn: NWConnection, code: Int, body: String) {
        sendResponse(conn: conn, statusCode: code, headers: ["Content-Type": "text/plain"], body: body.data(using: .utf8) ?? Data())
    }

    // MARK: - Moon Bridge Health

    /// 检测 Moon Bridge 是否在目标端口上监听。
    /// 发送 GET /v1/models 并检查是否收到 200。
    /// 结果通过 moonbridgeReachable / moonbridgeError 暴露给 UI。
    @discardableResult
    func checkMoonBridgeHealth(port: UInt16 = 4446) -> Task<Void, Never> {
        Task {
            let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            req.httpMethod = "GET"
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    lock.withLock { _moonbridgeReachable = true; _moonbridgeError = nil }
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    lock.withLock {
                        _moonbridgeReachable = false
                        _moonbridgeError = "Moon Bridge returned HTTP \(code)"
                    }
                }
            } catch {
                let msg: String
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .cannotConnectToHost:
                        msg = "Moon Bridge not listening on :\(port)"
                    case .timedOut:
                        msg = "Moon Bridge timed out on :\(port)"
                    default:
                        msg = "Moon Bridge health check: \(urlError.localizedDescription)"
                    }
                } else {
                    msg = "Moon Bridge health check: \(error.localizedDescription)"
                }
                lock.withLock { _moonbridgeReachable = false; _moonbridgeError = msg }
            }
            let reachable = lock.withLock { _moonbridgeReachable }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .moonbridgeStatusChanged, object: nil)
                // 如果 Moon Bridge 不可达，通知重启
                if reachable == false {
                    NotificationCenter.default.post(name: .moonbridgeRestartNeeded, object: nil)
                }
            }
        }
    }

    /// 带重试的健康检测 — 启动后立即调用，moonbridge 可能还没完成初始化。
    /// retries: 总重试次数，interval: 每次间隔秒数。
    @discardableResult
    func checkMoonBridgeHealthWithRetry(retries: Int = 6, interval: TimeInterval = 0.5, port: UInt16 = 4446) -> Task<Void, Never> {
        Task {
            for attempt in 1...retries {
                let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
                var req = URLRequest(url: url)
                req.timeoutInterval = 1
                req.httpMethod = "GET"
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                        lock.withLock { _moonbridgeReachable = true; _moonbridgeError = nil }
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .moonbridgeStatusChanged, object: nil)
                        }
                        print("[MoonBridge] 健康检测通过 (attempt \(attempt))")
                        return
                    }
                } catch {
                    print("[MoonBridge] 健康检测 attempt \(attempt)/\(retries): \(error.localizedDescription)")
                }
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
            // 所有重试都失败
            lock.withLock {
                _moonbridgeReachable = false
                _moonbridgeError = "Moon Bridge not listening on :\(port)"
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .moonbridgeStatusChanged, object: nil)
            }
        }
    }

    /// 从外部（AppDelegate）接收 Moon Bridge 启动失败/成功状态。
    /// 设置后自动通过 NotificationCenter 通知 UI。
    func reportMoonBridgeError(_ error: String?) {
        lock.withLock {
            _moonbridgeError = error
            _moonbridgeReachable = error == nil ? true : false
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .moonbridgeStatusChanged, object: nil)
        }
    }

    // MARK: - Debug

    /// 诊断日志，仅在 DEBUG 编译时输出
    private func debugLog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        print("[ProxyServer] \(msg())")
        #endif
    }
}

enum ProxyError: Error {
    case invalidPort
    case alreadyRunning
}
