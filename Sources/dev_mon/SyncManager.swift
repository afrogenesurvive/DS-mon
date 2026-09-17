import Foundation
import Network
import CryptoKit

private func syncLog(_ message: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    AppConfig.appendLog(to: AppConfig.syncLogURL, ts + " " + message + "\n")
}

// 常量时间比较与 Bearer 解析见 TokenAuth.swift（代理与同步服务共用）

// MARK: - 同步配置
struct SyncConfig: Codable, Sendable {
    var enabled: Bool = false
    var mode: SyncMode = .client
    var listenPort: UInt16 = 18888
    var targetAddress: String = ""
    var syncInterval: TimeInterval = 30

    enum SyncMode: String, Codable, Sendable { case server, client }

    static let storageKey = "sync_config"
    static func load() -> SyncConfig {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(SyncConfig.self, from: d) else { return SyncConfig() }
        return c
    }
    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: Self.storageKey)
    }
}

enum SyncConnectionStatus: Equatable, Sendable {
    case idle, listening(port: UInt16), connecting(String), connected(String), error(String)
}

// MARK: - 同步管理器

final class SyncManager: @unchecked Sendable {
    static let shared = SyncManager()

    private let lock = NSLock()
    private var _config: SyncConfig
    var config: SyncConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue }; _config.save() }
    }

    /// 推送令牌：优先取设置（SecureStore 加密存储），fallback 到 DSMON_PUSH_TOKEN 环境变量
    var pushToken: String? {
        if let stored = SecureStore.retrieve(key: Strings.Keys.syncPushToken), !stored.isEmpty {
            return stored
        }
        let env = ProcessInfo.processInfo.environment["DSMON_PUSH_TOKEN"] ?? ""
        return env.isEmpty ? nil : env
    }

    /// 从 HTTP 请求头中解析 Bearer token
    private func bearerToken(from lines: [String]) -> String {
        for line in lines {
            guard line.lowercased().hasPrefix("authorization:") else { continue }
            let value = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bearer ") else { continue }
            return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// 生成 256-bit 随机令牌（64 个十六进制字符，等价 `openssl rand -hex 32`）
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 确保存在推送令牌：没有令牌就意味着服务器以「开放」状态运行，
    /// 所以这里主动签发而不是放行请求。返回 nil 表示无法签发（服务器不应启动）。
    @discardableResult
    func ensurePushToken() -> String? {
        if let token = pushToken, !token.isEmpty { return token }
        let generated = Self.makeToken()
        guard !generated.isEmpty else {
            syncLog("[Sync] Server: cannot generate a token — refusing to start")
            return nil
        }
        SecureStore.save(key: Strings.Keys.syncPushToken, value: generated)
        syncLog("[Sync] Server: generated a new push token (Settings → Services)")
        return generated
    }

    /// 校验入站请求的 Bearer 令牌。失败时发送 401 并返回 false。
    /// **fail-closed**：未配置令牌时一律拒绝，绝不默认放行。注意：不得将令牌写入日志。
    private func requireAuth(_ lines: [String], connection: NWConnection) -> Bool {
        guard let expected = self.pushToken, !expected.isEmpty else {
            syncLog("[Sync] Server: DENIED (no token configured — fail closed)")
            sendUnauthorized(connection)
            return false
        }
        guard constantTimeEquals(bearerToken(from: lines), expected) else {
            syncLog("[Sync] Server: UNAUTHORIZED (missing/mismatched token)")
            sendUnauthorized(connection)
            return false
        }
        return true
    }

    private func sendUnauthorized(_ connection: NWConnection) {
        sendHTTP(connection, 401, Data("{\"error\":\"unauthorized\"}".utf8), "application/json")
    }

    /// 可选信封解密：已配置密钥时尝试解开信封；失败则回退原始 body（兼容明文）
    private func maybeDecryptEnvelope(_ body: Data) -> Data {
        guard EnvelopeCrypto.isConfigured() else { return body }
        if let opened = EnvelopeCrypto.open(body) { return opened }
        return body
    }

    @MainActor @Published private(set) var observableStatus: SyncConnectionStatus = .idle
    /// 同步完成计数器，每次同步完成后递增（用于触发 UI 刷新）
    @MainActor @Published private(set) var syncCount: UInt = 0
    /// 最后同步时间
    @MainActor @Published private(set) var lastSyncTime: Date? = nil

    private var listener: NWListener?
    private var syncTimer: Timer?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
    private var _syncTask: Task<Void, Never>?

    private init() { self._config = SyncConfig.load() }

    func start() {
        stop()
        let cfg = lock.withLock { _config }
        guard cfg.enabled else { return }
        if cfg.mode == .server {
            startServer(port: cfg.listenPort)
        } else {
            startTimer(interval: cfg.syncInterval)
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        syncTimer?.invalidate(); syncTimer = nil
        _syncTask?.cancel(); _syncTask = nil
        Task { @MainActor in self.observableStatus = .idle }
    }

    // MARK: - 服务器

    private func startServer(port: UInt16) {
        // 服务端启动时清理重复数据
        Task.detached { await UsageStore.shared.deduplicate() }
        // fail-closed：没有令牌就拒绝启动，否则 /sync/push、/sync/pull 都是开放的
        guard ensurePushToken() != nil else {
            Task { @MainActor in self.observableStatus = .error(Strings.syncServerNoTokenError) }
            return
        }
        let p = NWEndpoint.Port(rawValue: port) ?? 18888
        // 只监听回环：cloudflared / tailscale 都从本机发起连接，公网入口交给隧道，
        // 同一 Wi-Fi 上的其它设备就无法直接访问未认证的 sync 接口。
        // 注意：端口来自 requiredLocalEndpoint，不能同时传给 `on:`（会抛 EINVAL）。
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
        guard let l = try? NWListener(using: params) else {
            Task { @MainActor in self.observableStatus = .error("无法监听端口 \(port)") }
            return
        }
        listener = l
        Task { @MainActor in self.observableStatus = .listening(port: port) }

        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            syncLog("[Sync] Server: listener state = \(state)")
            if case .failed(let e) = state {
                Task { @MainActor in self.observableStatus = .error("监听失败: \(e.localizedDescription)") }
                self.listener = nil
            } else if case .cancelled = state {
                Task { @MainActor in self.observableStatus = .idle }
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global(qos: .background))
            syncLog("[Sync] Server: new connection from \(conn.endpoint)")
            Task { await self.handleConnection(conn) }
        }

        l.start(queue: .global(qos: .background))
    }

    // MARK: - HTTP 连接处理

    private func handleConnection(_ connection: NWConnection) async {
        let peer = connection.endpoint
        await MainActor.run { self.observableStatus = .connected("\(peer)") }

        // Read full HTTP request (headers + body based on Content-Length)
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var buf = Data()
        var contentLength = -1
        let deadline = Date().addingTimeInterval(AppConfig.syncReadTimeout)
        while true {
            // 慢速 / 挂起的连接不能无限占用这个任务
            if Date() > deadline {
                syncLog("[Sync] Server: read timeout after \(Int(AppConfig.syncReadTimeout))s")
                sendHTTP(connection, 408, Data("{\"error\":\"timeout\"}".utf8), "application/json")
                connection.cancel()
                return
            }
            let (data, _, isDone, error) = await withCheckedContinuation { (cont: CheckedContinuation<(Data?, NWConnection.ContentContext?, Bool, NWError?), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { d, ctx, done, err in
                    cont.resume(returning: (d, ctx, done, err))
                }
            }
            if let d = data { buf.append(d) }
            syncLog("[Sync] Server: read \(data?.count ?? 0) bytes, isDone=\(isDone), total=\(buf.count)")

            // Once we have headers, check Content-Length
            if let headerEnd = buf.firstRange(of: terminator) {
                if contentLength < 0 {
                    if let hdr = String(data: Data(buf[..<headerEnd.upperBound]), encoding: .utf8) {
                        for hdrLine in hdr.components(separatedBy: "\r\n") {
                            if hdrLine.lowercased().hasPrefix("content-length:") {
                                let val = hdrLine.dropFirst(15).trimmingCharacters(in: .whitespaces)
                                contentLength = Int(val) ?? 0
                            }
                        }
                    }
                    if contentLength < 0 { contentLength = 0 }
                    syncLog("[Sync] Server: Content-Length = \(contentLength)")
                    // 对端可以随便声明长度，必须在读取前就拒绝
                    if contentLength > AppConfig.maxSyncBodySize {
                        syncLog("[Sync] Server: rejecting oversized body (\(contentLength) bytes)")
                        sendHTTP(connection, 413, Data("{\"error\":\"payload_too_large\"}".utf8), "application/json")
                        connection.cancel()
                        return
                    }
                }
                // Check if body is complete
                let bodyBytes = Data(buf[headerEnd.upperBound...]).count
                if bodyBytes >= contentLength || error != nil || isDone {
                    break
                }
            }
            if error != nil || isDone { break }
        }

        guard let requestStr = String(data: buf, encoding: .utf8) else {
            syncLog("[Sync] Server: cannot decode UTF-8")
            sendHTTP(connection, 400, Data("Bad Request".utf8))
            connection.cancel()
            return
        }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendHTTP(connection, 400, Data("Bad Request".utf8)); connection.cancel(); return
        }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendHTTP(connection, 400, Data("Bad Request".utf8)); connection.cancel(); return
        }

        let method = parts[0]
        var path = parts[1]
        var queryParams: [String: String] = [:]

        if let qi = path.firstIndex(of: "?") {
            let qs = String(path[path.index(after: qi)...])
            path = String(path[..<qi])
            for pair in qs.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 { queryParams[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
        }

        let body: Data
        if let range = buf.firstRange(of: terminator) {
            body = Data(buf[range.upperBound...])
        } else { body = Data() }

        syncLog("[Sync] Server: \(method) \(path) body=\(body.count) bytes")

        switch (method, path) {
            case ("GET", "/sync/pull"):
                // 读取用量数据与写入同等敏感（含 sourceIP / repo / userAgent），必须校验令牌
                guard requireAuth(lines, connection: connection) else { break }
                let since = queryParams["since"].flatMap { TimeInterval($0) }
                    .map { Date(timeIntervalSince1970: $0) } ?? Date.distantPast
                syncLog("[Sync] Server: query records since \(since.timeIntervalSince1970)")
                let records = await UsageStore.shared.queryRecords(since: since)
                syncLog("[Sync] Server: got \(records.count) records")
                if let d = try? encoder.encode(records) {
                    sendHTTP(connection, 200, d, "application/json")
                } else {
                    sendHTTP(connection, 500, Data())
                }

            case ("POST", "/sync/push"):
                // Extract connecting client IP
                let clientIP: String = {
                    switch peer {
                    case .hostPort(let host, _):
                        switch host {
                        case .ipv4(let addr): return "\(addr)"
                        case .ipv6(let addr): return "\(addr)"
                        default: return ""
                        }
                    default: return ""
                    }
                }()

                // 令牌校验（fail-closed）。注意：不得将令牌写入日志。
                guard requireAuth(lines, connection: connection) else { break }

                if var records = try? decoder.decode([UsageRecord].self, from: maybeDecryptEnvelope(body)) {
                    // Stamp sourceIP if not already set by the client
                    for i in records.indices where records[i].sourceIP.isEmpty {
                        records[i] = UsageRecord(
                            uuid: records[i].uuid,
                            timestamp: records[i].timestamp,
                            providerId: records[i].providerId,
                            model: records[i].model,
                            endpoint: records[i].endpoint,
                            promptTokens: records[i].promptTokens,
                            completionTokens: records[i].completionTokens,
                            totalTokens: records[i].totalTokens,
                            cachedTokens: records[i].cachedTokens,
                            reasoningTokens: records[i].reasoningTokens,
                            latencyMs: records[i].latencyMs,
                            statusCode: records[i].statusCode,
                            userAgent: records[i].userAgent,
                            sourceIP: clientIP,
                            repo: records[i].repo
                        )
                    }
                    syncLog("[Sync] Server: insert \(records.count) records from \(clientIP)")
                    await UsageStore.shared.insertRecords(records)
                    sendHTTP(connection, 200, Data("{\"ok\":true}".utf8), "application/json")
                } else {
                    syncLog("[Sync] Server: FAILED to decode push body")
                    if let bodyStr = String(data: body, encoding: .utf8) {
                        syncLog("[Sync] Server: body preview: " + String(bodyStr.prefix(300)))
                    }
                    sendHTTP(connection, 400, Data("{\"ok\":false}".utf8), "application/json")
                }

            case ("POST", "/license/check"):
                // Hybrid 授权权威：回答“该席位是否已被吊销”。与 push 共用令牌校验。
                guard requireAuth(lines, connection: connection) else { break }

                let payload = maybeDecryptEnvelope(body)

                struct LicenseCheckRequest: Codable {
                    let sub: String
                    let kid: String
                    let ts: Int
                }
                guard let req = try? JSONDecoder().decode(LicenseCheckRequest.self, from: payload) else {
                    syncLog("[Sync] Server: /license/check bad request")
                    sendHTTP(connection, 400, Data("{\"ok\":false,\"error\":\"bad_request\"}".utf8), "application/json")
                    break
                }

                let status = SeatRegistry.shared.status(for: req.sub)
                let revoked = status?.revoked ?? false
                let exp = status?.exp ?? 0
                // 不回显席位元数据（sub/kid/registryId/issuedAt）：调用方已经知道自己是谁，
                // 多给的字段只会把这个接口变成信息泄露面。
                syncLog("[Sync] Server: /license/check revoked=\(revoked) exp=\(exp)")

                struct LicenseCheckResponse: Codable {
                    let ok: Bool
                    let revoked: Bool
                    let exp: Int
                    let checkedAt: String
                }
                let resp = LicenseCheckResponse(
                    ok: true,
                    revoked: revoked,
                    exp: exp,
                    checkedAt: ISO8601DateFormatter().string(from: Date())
                )
                guard let data = try? JSONEncoder().encode(resp) else {
                    sendHTTP(connection, 500, Data())
                    break
                }
                let out = EnvelopeCrypto.isConfigured() ? (EnvelopeCrypto.seal(data) ?? data) : data
                sendHTTP(connection, 200, out, "application/json")

            default:
                syncLog("[Sync] Server: unknown path \(path)")
                sendHTTP(connection, 404, Data("Not Found".utf8))
            }

        connection.cancel()
        await MainActor.run {
            if self.listener != nil {
                self.observableStatus = .listening(port: self._config.listenPort)
            }
        }
        syncLog("[Sync] Server: done")
    }

    private func sendHTTP(_ conn: NWConnection, _ status: Int, _ body: Data, _ type: String = "text/plain") {
        let t: String
        switch status {
        case 200: t = "OK"
        case 400: t = "Bad Request"
        case 401: t = "Unauthorized"
        case 404: t = "Not Found"
        case 408: t = "Request Timeout"
        case 413: t = "Payload Too Large"
        case 500: t = "Internal Server Error"
        default: t = "Unknown"
        }
        let challenge = status == 401 ? "WWW-Authenticate: Bearer\r\n" : ""
        var r = Data("HTTP/1.1 \(status) \(t)\r\nContent-Type: \(type)\r\n\(challenge)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        r.append(body)
        let sem = DispatchSemaphore(value: 0)
        conn.send(content: r, completion: .contentProcessed({ _ in sem.signal() }))
        _ = sem.wait(timeout: .now() + 10)
    }

    // MARK: - 客户端

    private func startTimer(interval: TimeInterval) {
        syncTimer?.invalidate()
        let interval = max(interval, 5)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.triggerSync()
        }
    }

    private func triggerSync() {
        let cfg = lock.withLock { _config }
        guard cfg.enabled, cfg.mode == .client, !cfg.targetAddress.isEmpty else { return }
        guard _syncTask == nil || _syncTask?.isCancelled == true else { return }

        Task { @MainActor in self.observableStatus = .connecting(cfg.targetAddress) }

        let addr = cfg.targetAddress
        _syncTask = Task { [self] in
            defer { self._syncTask = nil }
            do {
                syncLog("[Sync] Client: start sync with \(addr)")
                try await self.performSync(address: addr)
                syncLog("[Sync] Client: sync succeeded")
                await MainActor.run {
                    self.observableStatus = .connected(addr)
                    self.syncCount &+= 1
                    self.lastSyncTime = Date()
                }
            } catch let error as SyncError {
                syncLog("[Sync] Client: error \(error)")
                await MainActor.run {
                    self.observableStatus = .error(self.errorDescription(error))
                    self.syncCount &+= 1
                }
            } catch {
                syncLog("[Sync] Client: error \(error.localizedDescription)")
                await MainActor.run {
                    self.observableStatus = .error(error.localizedDescription)
                    self.syncCount &+= 1
                }
            }
        }
    }

    func performSyncAndWait() { triggerSync() }

    private func performSync(address: String) async throws {
        let localMax = await UsageStore.shared.maxTimestamp()
        let since = localMax.timeIntervalSince1970

        let baseURL: String
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            baseURL = address
        } else {
            baseURL = "http://" + address
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "\(baseURL)/sync/pull?since=\(since)") else {
            throw SyncError.invalidAddress
        }
        syncLog("[Sync] Client: GET \(url)")

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "GET"
        // 拉取同样需要令牌（服务端已改为 fail-closed）
        if let token = SyncManager.shared.pushToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (pullData, pullResp) = try await session.data(for: req)
        guard let httpResp = pullResp as? HTTPURLResponse else { throw SyncError.httpError }
        syncLog("[Sync] Client: GET response \(httpResp.statusCode), \(pullData.count) bytes")
        guard httpResp.statusCode == 200 else { throw SyncError.httpError }

        let pulled = try decoder.decode([UsageRecord].self, from: pullData)
        syncLog("[Sync] Client: pulled \(pulled.count) records")
        if !pulled.isEmpty { await UsageStore.shared.insertRecords(pulled) }

        // 用 lastPushTimestamp 避免每次同步都推送全部本地数据
        let lastPushTS = UserDefaults.standard.double(forKey: "lastPushTimestamp")
        let pushSince: Date
        if lastPushTS > 0 {
            pushSince = Date(timeIntervalSince1970: lastPushTS)
        } else {
            pushSince = pulled.last?.timestamp ?? Date.distantPast
        }
        let local = await UsageStore.shared.queryRecords(since: pushSince)
        syncLog("[Sync] Client: push \(local.count) records (since \(pushSince.timeIntervalSince1970))")
        if !local.isEmpty {
            let body = try encoder.encode(local)
            guard let pushURL = URL(string: "\(baseURL)/sync/push") else { throw SyncError.invalidAddress }
            var pushReq = URLRequest(url: pushURL, timeoutInterval: 30)
            pushReq.httpMethod = "POST"
            pushReq.httpBody = body
            pushReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = SyncManager.shared.pushToken, !token.isEmpty {
                pushReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (_, pushResp) = try await session.data(for: pushReq)
            guard let pushHTTP = pushResp as? HTTPURLResponse, pushHTTP.statusCode == 200 else {
                throw SyncError.httpError
            }
            // 推送成功后更新 lastPushTimestamp 为本地最新记录的时间戳
            if let latestTS = local.map({ $0.timestamp.timeIntervalSince1970 }).max() {
                UserDefaults.standard.set(latestTS, forKey: "lastPushTimestamp")
            }
            syncLog("[Sync] Client: push succeeded, lastPushTimestamp updated")
        }
    }

    enum SyncError: Error { case httpError, invalidAddress }

    private func errorDescription(_ error: SyncError) -> String {
        switch error {
        case .httpError: return "服务器返回错误"
        case .invalidAddress: return "服务器地址格式错误"
        }
    }
}
