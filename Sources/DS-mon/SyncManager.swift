import Foundation
import Network

private let syncLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/com.dsmon.app/sync.log")

private func syncLog(_ message: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = ts + " " + message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: syncLogURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: syncLogURL)
    }
}

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

    @MainActor @Published private(set) var observableStatus: SyncConnectionStatus = .idle
    /// 同步完成计数器，每次同步完成后递增（用于触发 UI 刷新）
    @MainActor @Published private(set) var syncCount: UInt = 0

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
        let p = NWEndpoint.Port(rawValue: port) ?? 18888
        guard let l = try? NWListener(using: .tcp, on: p) else {
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
        while true {
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

        do {
            switch (method, path) {
            case ("GET", "/sync/pull"):
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
                if let records = try? decoder.decode([UsageRecord].self, from: body) {
                    syncLog("[Sync] Server: insert \(records.count) records")
                    await UsageStore.shared.insertRecords(records)
                    sendHTTP(connection, 200, Data("{\"ok\":true}".utf8), "application/json")
                } else {
                    syncLog("[Sync] Server: FAILED to decode push body")
                    if let bodyStr = String(data: body, encoding: .utf8) {
                        syncLog("[Sync] Server: body preview: " + String(bodyStr.prefix(300)))
                    }
                    sendHTTP(connection, 400, Data("{\"ok\":false}".utf8), "application/json")
                }

            default:
                syncLog("[Sync] Server: unknown path \(path)")
                sendHTTP(connection, 404, Data("Not Found".utf8))
            }
        } catch {
            syncLog("[Sync] Server: unexpected error \(error)")
            sendHTTP(connection, 500, Data("Internal Error".utf8))
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
        case 404: t = "Not Found"
        case 500: t = "Internal Server Error"
        default: t = "Unknown"
        }
        var r = Data("HTTP/1.1 \(status) \(t)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
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
