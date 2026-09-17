import Foundation
import Network

/// 本地 HTTP 代理服务器。
/// 使用 @unchecked Sendable + NSLock（NWListener 回调在后台队列，无法 actor-isolate）。
/// 所有状态通过 lock.withLock 同步访问。
final class ProxyServer: @unchecked Sendable {
    static let shared = ProxyServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _isRunning = false
    private var _port: UInt16 = AppConfig.defaultProxyPort
    private var _requestCount = 0
    private var _vuLevel: Double = 0.0
    private var _vuAvgLevel: Double = 0.0
    private var _vuLevelHistory: [Double] = []
    private var _activeConnectionCount = 0
    private var _listenerError: String?
    private var connectionHandlers: [ObjectIdentifier: ProxyConnectionHandler] = [:]
    /// 活跃连接 task 追踪（防止 ARC 提前释放，任务取消时清理）
    private var connectionTasks: Set<Task<Void, Never>> = []

    var isRunning: Bool { lock.withLock { _isRunning } }
    var port: UInt16 { lock.withLock { _port } }
    var requestCount: Int { lock.withLock { _requestCount } }
    var vuLevel: Double { lock.withLock { _vuLevel } }
    var vuAvgLevel: Double { lock.withLock { _vuAvgLevel } }
    var hasActiveConnection: Bool { lock.withLock { _activeConnectionCount > 0 } }
    var listenerError: String? { lock.withLock { _listenerError } }

    /// 客户端令牌：为空时**拒绝所有请求**。代理会用本机的 API Key 覆盖上游认证头，
    /// 所以没令牌就转发等于把账号借给任何能连上端口的人。
    var clientToken: String? {
        guard let stored = SecureStore.retrieve(key: Strings.Keys.proxyClientToken),
              !stored.isEmpty else { return nil }
        return stored
    }

    /// 确保存在客户端令牌；返回 nil 表示签发失败（调用方应拒绝启动）。
    @discardableResult
    func ensureClientToken() -> String? {
        if let token = clientToken { return token }
        let generated = SyncManager.makeToken()
        guard !generated.isEmpty else {
            print("[ProxyServer] Cannot generate a client token")
            return nil
        }
        SecureStore.save(key: Strings.Keys.proxyClientToken, value: generated)
        print("[ProxyServer] Generated a new client token")
        return generated
    }

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Strings.Keys.proxyPort)
        if saved >= AppConfig.minProxyPort, saved <= AppConfig.maxProxyPort {
            _port = UInt16(saved)
        }
    }

    func recordRequest(bodySize: Int = 0) {
        lock.withLock {
            _requestCount += 1
            let scaled: Double = if bodySize > 0 {
                min(1.0, Double(bodySize) / 100_000.0)
            } else {
                0.5
            }
            _vuLevel = min(1.0, _vuLevel + scaled)
            _vuAvgLevel = 0.3 * _vuLevel + 0.7 * _vuAvgLevel
            _vuLevelHistory.append(_vuLevel)
            if _vuLevelHistory.count > 5 { _vuLevelHistory.removeFirst() }
        }
    }

    func decayVU() {
        lock.withLock {
            _vuLevel = max(0, _vuLevel - 0.01)
            _vuAvgLevel = max(0, _vuAvgLevel - 0.003)
        }
    }

    func start(port: UInt16? = nil) throws {
        guard !lock.withLock({ _isRunning }) else { return }
        if let port { lock.withLock { _port = port } }
        // fail-closed：没有客户端令牌就不把代理暴露出去
        guard ensureClientToken() != nil else { throw ProxyError.missingClientToken }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let currentPort = lock.withLock { _port }
        guard let nwPort = NWEndpoint.Port(rawValue: currentPort) else {
            throw ProxyError.invalidPort
        }
        // 只监听回环：cloudflared / tailscale 都从本机发起连接，公网入口交给隧道。
        // 这样同一 Wi-Fi 上的其它设备就无法直接使用未认证的代理。
        // 注意：端口随 requiredLocalEndpoint 给出，不能再传给 `on:`（两者同时传会抛 EINVAL）。
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let peerPort: UInt16? = {
                guard case .hostPort(_, let port) = conn.endpoint else { return nil }
                return port.rawValue
            }()
            let handler = ProxyConnectionHandler(
                connection: conn,
                store: UsageStore.shared,
                peerPort: peerPort,
                onConnectionStateChanged: { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lock.withLock { self._activeConnectionCount += 1 }
                    case .cancelled, .failed:
                        self.lock.withLock {
                            self._activeConnectionCount = max(0, self._activeConnectionCount - 1)
                        }
                    default: break
                    }
                },
                onRequestStarted: { _ in },
                onRequestCompleted: {
                    Task { @MainActor in
                        StatusBarController.shared.refreshCacheHitRate()
                    }
                }
            )
            let handlerId = ObjectIdentifier(handler)
            lock.withLock { connectionHandlers[handlerId] = handler }
            handler.onFinished = { [weak self] in
                guard let self else { return }
                let _ = self.lock.withLock {
                    self.connectionHandlers.removeValue(forKey: handlerId)
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
        print("[ProxyServer] Started on 127.0.0.1:\(currentPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock {
            _isRunning = false; _listenerError = nil
            connectionHandlers.removeAll()
            connectionTasks.removeAll()
        }
        // 不再写 proxyEnabled：退出应用时写 false 会让「客户端是否开启代理」这个
        // 用户意图被系统事件覆盖（下次启动就不再生效）。意图只由设置里的开关写入。
        print("[ProxyServer] Stopped")
    }
}

enum ProxyError: Error {
    case invalidPort
    case alreadyRunning
    /// 未能签发客户端令牌：宁可不启动，也不开一个无认证的转发口
    case missingClientToken
}
