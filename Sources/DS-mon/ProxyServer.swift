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

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Strings.Keys.proxyPort)
        if saved >= AppConfig.minProxyPort, saved <= AppConfig.maxProxyPort {
            _port = UInt16(saved)
        }
    }

    func recordRequest() {
        lock.withLock {
            _requestCount += 1
            let newLevel = min(1.0, _vuLevel + 0.5)
            _vuLevel = newLevel
            _vuLevelHistory.append(newLevel)
            if _vuLevelHistory.count > 5 { _vuLevelHistory.removeFirst() }
            _vuAvgLevel = _vuLevelHistory.reduce(0, +) / Double(_vuLevelHistory.count)
        }
    }

    func decayVU() {
        lock.withLock {
            _vuLevel = max(0, _vuLevel - 0.01)
            if !_vuLevelHistory.isEmpty {
                _vuLevelHistory = _vuLevelHistory.map { max(0, $0 - 0.005) }
                _vuLevelHistory.removeAll { $0 <= 0 }
                _vuAvgLevel = _vuLevelHistory.isEmpty ? 0 : _vuLevelHistory.reduce(0, +) / Double(_vuLevelHistory.count)
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
                        }
                    default: break
                    }
                },
                onRequestStarted: { _ in }
            ) { [weak self] in
                self?.recordRequest()
                Task { @MainActor in
                    StatusBarController.shared.refreshCacheHitRate()
                }
            }
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
        UserDefaults.standard.set(true, forKey: Strings.Keys.proxyEnabled)
        print("[ProxyServer] Started on :\(currentPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock {
            _isRunning = false; _listenerError = nil
            connectionHandlers.removeAll()
            connectionTasks.removeAll()
        }
        UserDefaults.standard.set(false, forKey: Strings.Keys.proxyEnabled)
        print("[ProxyServer] Stopped")
    }
}

enum ProxyError: Error {
    case invalidPort
    case alreadyRunning
}
