import Foundation
import Network


// MARK: - Continuation 防重入包装
private final class ContinuationManager: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    let continuation: CheckedContinuation<NWConnection.State, Never>

    init(continuation: CheckedContinuation<NWConnection.State, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ state: NWConnection.State) {
        lock.withLock {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: state)
        }
    }
}

// MARK: - 本地 HTTP 代理服务器

/// 在本地端口监听 HTTP 请求，透明转发到 api.deepseek.com，
/// 并自动记录 chat completions 的 usage 数据到 UsageStore。
///
/// 职责：
///   - NWListener 生命周期管理
///   - 新连接分发给 ProxyConnectionHandler
///   - codex-relay 健康状态暴露给 UI
///   - codex-relay 健康监控定时器
final class ProxyServer: @unchecked Sendable {
    static let shared = ProxyServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _isRunning = false
    private var _port: UInt16 = AppConfig.defaultProxyPort
    private var _requestCount = 0
    private var _vuLevel: Double = 0.0
    private var _vuPeakLevel: Double = 0.0
    private var _vuPrevPeakLevel: Double = 0.0
    private var _activeConnectionCount = 0
    private var _activeCodexConnectionCount = 0
    private var _listenerError: String?
    private var _codexRelayReachable: Bool?
    private var _codexRelayError: String?
    private var codexRelayMonitorTask: Task<Void, Never>?
    /// 活跃的连接处理器，防止被 ARC 提前释放（用 ObjectIdentifier 做 key，避免 Hashable 约束）
    private var connectionHandlers: [ObjectIdentifier: ProxyConnectionHandler] = [:]
    private var activeCodexConnectionIds: Set<ObjectIdentifier> = []

    var isRunning: Bool { lock.withLock { _isRunning } }
    var port: UInt16 { lock.withLock { _port } }
    var requestCount: Int { lock.withLock { _requestCount } }
    var vuLevel: Double { lock.withLock { _vuLevel } }
    var vuPeakLevel: Double { lock.withLock { _vuPeakLevel } }
    var vuPrevPeakLevel: Double { lock.withLock { _vuPrevPeakLevel } }
    var hasActiveConnection: Bool { lock.withLock { _activeConnectionCount > 0 } }
    var hasActiveCodexConnection: Bool { lock.withLock { !activeCodexConnectionIds.isEmpty } }
    var listenerError: String? { lock.withLock { _listenerError } }
    var codexRelayReachable: Bool? { lock.withLock { _codexRelayReachable } }
    var codexRelayError: String? { lock.withLock { _codexRelayError } }

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Strings.Keys.proxyPort)
        if saved >= AppConfig.minProxyPort, saved <= AppConfig.maxProxyPort {
            _port = UInt16(saved)
        }
        startCodexRelayMonitor()
    }

    // MARK: - Start / Stop


    /// 记录一次请求（VU 电平表用）
    func recordRequest() {
        lock.withLock {
            _requestCount += 1
            let newLevel = min(1.0, _vuLevel + 0.3)

            // 更新当前电平
            _vuLevel = newLevel

            // 历史最高水位（永不下降，只增不减）
            if newLevel > _vuPeakLevel {
                _vuPeakLevel = newLevel
            }

            // 当前这波请求的峰值（每次请求都更新）
            if newLevel > _vuPrevPeakLevel {
                _vuPrevPeakLevel = newLevel
            }
        }
    }

    /// 清除当前波次峰值（电平完全衰减到 0 时调用）
    func clearCurrentPeak() {
        lock.withLock {
            _vuPrevPeakLevel = 0
        }
    }

    /// 每帧衰减 VU 电平
    func decayVU() {
        lock.withLock {
            let oldLevel = _vuLevel
            _vuLevel = max(0, _vuLevel - 0.013)
            // 电平完全衰减到 0，清除当前波次峰值
            if oldLevel > 0 && _vuLevel == 0 {
                _vuPrevPeakLevel = 0
            }
        }
    }
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
            guard let self else { return }
            let connId = ObjectIdentifier(conn as AnyObject)
            let handler = ProxyConnectionHandler(
                connection: conn,
                store: UsageStore.shared,
                onConnectionStateChanged: { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lock.withLock { self._activeConnectionCount += 1 }
                    case .cancelled, .failed:
                        self.lock.withLock {
                            self._activeConnectionCount = max(0, self._activeConnectionCount - 1)
                            self.activeCodexConnectionIds.remove(connId)
                        }
                    default: break
                    }
                },
                onRequestStarted: { [weak self] isCodex in
                    guard let self, isCodex else { return }
                    let _ = self.lock.withLock { self.activeCodexConnectionIds.insert(connId) }
                }
            ) { [weak self] in
                self?.recordRequest()
                // 请求完成 → 触发缓存命中率刷新
                Task { @MainActor in
                    StatusBarController.shared.refreshCacheHitRate()
                }
            }
            // 保持强引用，防止 ARC 释放
            let handlerId = ObjectIdentifier(handler)
            lock.withLock { connectionHandlers[handlerId] = handler }
            handler.onFinished = { [weak self] in
                guard let self else { return }
                let _ = self.lock.withLock {
                    self.connectionHandlers.removeValue(forKey: handlerId)
                    self.activeCodexConnectionIds.remove(connId)
                }
            }
            handler.start()
        }

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                print("[ProxyServer] Listener failed: \(err)")
                self?.lock.withLock { self?._listenerError = "\(err)" }
            }
        }

        lock.withLock { _listenerError = nil }
        listener.start(queue: .global(qos: .utility))
        lock.withLock { _isRunning = true }
        UserDefaults.standard.set(Int(lock.withLock { _port }), forKey: Strings.Keys.proxyPort)
        UserDefaults.standard.set(true, forKey: Strings.Keys.proxyEnabled)
        print("[ProxyServer] Started on :\(currentPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock { _isRunning = false; _listenerError = nil }
        UserDefaults.standard.set(false, forKey: Strings.Keys.proxyEnabled)
        print("[ProxyServer] Stopped")
    }

    // MARK: - Codex Relay Health Monitoring

    private func startCodexRelayMonitor() {
        codexRelayMonitorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConfig.codexRelayMonitorInitialDelay))
            while !Task.isCancelled {
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: Strings.Keys.codexRelayEnabled)
                if enabled {
                    let reachable = lock.withLock { _codexRelayReachable }
                    if reachable != true {
                        checkCodexRelayHealth()
                    }
                }
                try? await Task.sleep(for: .seconds(AppConfig.codexRelayMonitorInterval))
            }
        }
    }

    @discardableResult
    func checkCodexRelayHealth(port: UInt16 = AppConfig.codexRelayHealthPort) -> Task<Void, Never> {
        Task {
            // 直接检查 TCP 端口是否开放，不依赖 HTTP 端点
            let success: Bool
            let msg: String?
            let host = NWEndpoint.Host("127.0.0.1")
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let conn = NWConnection(host: host, port: nwPort, using: .tcp)
            _ = Int(AppConfig.codexRelayHealthTimeout * 1000)
            let result: NWConnection.State = await withCheckedContinuation { continuation in
                let mgr = ContinuationManager(continuation: continuation)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled:
                        mgr.resumeOnce(state)
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .utility))
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(AppConfig.codexRelayHealthTimeout * 1_000_000_000))
                    mgr.resumeOnce(.cancelled)
                    conn.cancel()
                }
            }
            conn.cancel()
            if result == .ready {
                success = true; msg = nil
            } else {
                success = false; msg = "codex-relay not responding on port \(port)"
            }

            let prev = lock.withLock {
                let old = _codexRelayReachable
                if success {
                    _codexRelayReachable = true; _codexRelayError = nil
                } else {
                    _codexRelayReachable = false; _codexRelayError = msg
                }
                return old
            }

            Task { @MainActor in
                if success {
                    if prev != true {
                        NotificationCenter.default.post(name: .codexRelayStatusChanged, object: nil)
                    }
                } else {
                    if prev == true {
                        NotificationCenter.default.post(name: .codexRelayRestartNeeded, object: nil)
                    }
                }
            }
        }
    }

    /// 启动重试健康检测（仅在启动时调用，不广播 UI 通知，避免启动过程的短暂不可达导致 UI 闪烁）
    @discardableResult
    func checkCodexRelayHealthWithRetry(
        retries: Int = AppConfig.codexRelayHealthRetries,
        interval: TimeInterval = AppConfig.codexRelayHealthRetryInterval,
        port: UInt16 = AppConfig.codexRelayHealthPort
    ) -> Task<Void, Never> {
        Task {
            for attempt in 1...retries {
                // TCP 端口检查，不依赖 HTTP
                let host = NWEndpoint.Host("127.0.0.1")
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
                let conn = NWConnection(host: host, port: nwPort, using: .tcp)
                let result: NWConnection.State = await withCheckedContinuation { continuation in
                    let mgr = ContinuationManager(continuation: continuation)
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready, .failed, .cancelled:
                            mgr.resumeOnce(state)
                        default:
                            break
                        }
                    }
                    conn.start(queue: .global(qos: .utility))
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(AppConfig.codexRelayHealthRetryTimeout * 1_000_000_000))
                        mgr.resumeOnce(.cancelled)
                        conn.cancel()
                    }
                }
                conn.cancel()
                if result == .ready {
                    lock.withLock { _codexRelayReachable = true; _codexRelayError = nil }
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .codexRelayStatusChanged, object: nil)
                    }
                    print("[CodexRelay] TCP 端口检测通过 (attempt \(attempt))")
                    return
                }
                print("[CodexRelay] TCP 端口检测 attempt \(attempt)/\(retries): 连接失败")
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
            // 所有重试失败
            lock.withLock {
                _codexRelayReachable = false
                _codexRelayError = "codex-relay not listening on :\(port)"
            }
            Task { @MainActor in
                NotificationCenter.default.post(name: .codexRelayStatusChanged, object: nil)
            }
        }
    }
    func reportCodexRelayError(_ error: String?) {
        lock.withLock {
            _codexRelayError = error
            _codexRelayReachable = error == nil ? true : false
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .codexRelayStatusChanged, object: nil)
        }
    }
}

enum ProxyError: Error {
    case invalidPort
    case alreadyRunning
}
