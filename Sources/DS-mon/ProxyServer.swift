import Foundation
import Network

// MARK: - 本地 HTTP 代理服务器

/// 在本地端口监听 HTTP 请求，透明转发到 api.deepseek.com，
/// 并自动记录 chat completions 的 usage 数据到 UsageStore。
final class ProxyServer: @unchecked Sendable {
    static let shared = ProxyServer()

    private var listener: NWListener?
    nonisolated(unsafe) private(set) var isRunning = false
    nonisolated(unsafe) private(set) var port: UInt16 = 18080
    nonisolated(unsafe) private(set) var requestCount: Int = 0

    private let store = UsageStore.shared

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "proxy_port")
        if saved >= 1024, saved <= 65535 {
            port = UInt16(saved)
        }
    }

    // MARK: - Start / Stop

    func start(port: UInt16? = nil) throws {
        guard !isRunning else { return }
        if let port { self.port = port }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
            throw ProxyError.invalidPort
        }
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                print("[ProxyServer] Listener failed: \(err)")
            }
        }
        listener.start(queue: .global(qos: .utility))
        isRunning = true
        UserDefaults.standard.set(Int(self.port), forKey: "proxy_port")
        UserDefaults.standard.set(true, forKey: "proxy_enabled")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
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

    private func forward(method: String, path: String, headers: [String: String], body: Data, conn: NWConnection) async {
        guard var comps = URLComponents(string: "https://api.deepseek.com") else {
            sendError(conn: conn, code: 500, body: "Internal error")
            return
        }
        comps.path = path.hasPrefix("/") ? path : "/\(path)"
        guard let targetURL = comps.url else {
            sendError(conn: conn, code: 500, body: "Invalid target URL")
            return
        }

        var req = URLRequest(url: targetURL)
        req.httpMethod = method
        req.httpBody = body.isEmpty ? nil : body
        req.timeoutInterval = 300

        for (key, value) in headers {
            let lower = key.lowercased()
            guard lower != "host", lower != "content-length" else { continue }
            req.setValue(value, forHTTPHeaderField: key)
        }
        if req.value(forHTTPHeaderField: "Content-Type") == nil, !body.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let start = Date()
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502
            let respHeaders = (httpResp?.allHeaderFields as? [String: String]) ?? [:]

            if statusCode == 200, path.contains("/chat/completions") {
                logUsage(requestBody: body, responseBody: respData, latencyMs: elapsed, statusCode: statusCode)
            }

            sendResponse(conn: conn, statusCode: statusCode, headers: respHeaders, body: respData)
        } catch {
            sendError(conn: conn, code: 502, body: "Upstream error")
        }
    }

    // MARK: - Usage Logging

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
        requestCount += 1
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
        // send(isComplete: true) 会等数据发完再关闭，不需要手动 cancel
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendError(conn: NWConnection, code: Int, body: String) {
        sendResponse(conn: conn, statusCode: code, headers: ["Content-Type": "text/plain"], body: body.data(using: .utf8) ?? Data())
    }
}

enum ProxyError: Error {
    case invalidPort
    case alreadyRunning
}
