import Foundation
import SwiftUI

// MARK: - Cloudflare Tunnel — Data Models

/// cloudflared launchd 守护进程状态（本机 /Library/LaunchDaemons）。
enum CFDaemonState: Equatable, Sendable {
    case notInstalled      // 未找到 plist / 二进制
    case installed         // 已安装但未运行
    case running(pid: Int32)
}

struct CloudflareTunnel: Identifiable, Equatable, Sendable {
    let id: String        // tunnel UUID
    let name: String
    let status: String    // API 返回的 status：inactive / healthy / degraded / down
    let connectorCount: Int

    var isHealthy: Bool { status == "healthy" || (status != "inactive" && status != "down" && connectorCount > 0) }
}

/// 远程托管隧道 ingress 规则里的一个公开主机名条目（无 hostname 的 catch-all 不展示）。
struct CFIngressRule: Identifiable, Equatable, Sendable {
    let hostname: String
    let path: String?
    let service: String
    var id: String { hostname + (path ?? "") }
}

/// 私有网络 IP/CIDR 路由（WARP / 私有路由）。
struct CFIPRoute: Identifiable, Equatable, Sendable {
    let network: String    // e.g. 10.0.0.0/24
    let comment: String?
    var id: String { network }
}

struct CFAccount: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}
struct CFZone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

// MARK: - Cloudflare Error

enum CloudflareError: LocalizedError {
    case notConfigured
    case invalidToken
    case accessDenied
    case notFound(String)
    case networkError(String)
    case parseFailed
    case noAccount
    case noZone
    case noTunnel
    case adminFailed(String)

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .notConfigured:
            return isZH ? "尚未配置（Settings → Services → Cloudflare）" : "Not configured (Settings → Services → Cloudflare)"
        case .invalidToken:
            return isZH ? "Cloudflare API 令牌无效或已过期" : "Invalid or expired Cloudflare API token"
        case .accessDenied:
            return isZH ? "权限不足（令牌需要 Zone:Read+DNS:Edit 与 Account:Tunnel:Edit）" : "Insufficient permissions (token needs Zone:Read+DNS:Edit and Account:Tunnel:Edit)"
        case .notFound(let s):
            return isZH ? "未找到: \(s)" : "Not found: \(s)"
        case .networkError(let m):
            return isZH ? "网络错误: \(m)" : "Network error: \(m)"
        case .parseFailed:
            return isZH ? "解析响应失败" : "Failed to parse response"
        case .noAccount:
            return isZH ? "令牌无权读取任何账户" : "Token can't read any account"
        case .noZone:
            return isZH ? "未找到可用的 Zone" : "No zone available"
        case .noTunnel:
            return isZH ? "该账户没有隧道" : "No tunnel in this account"
        case .adminFailed(let m):
            return isZH ? "操作失败: \(m)" : "Action failed: \(m)"
        }
    }

    private static func checkZH() -> Bool {
        let saved = UserDefaults.standard.string(forKey: Strings.Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }
}

// MARK: - Cloudflare Tunnel Manager

/// 管理本机 cloudflared launchd 守护进程 + Cloudflare API（隧道/路由）。
///
/// 背景：本机服务是 `sudo cloudflared service install` 装的 **system LaunchDaemon**，
/// 且是 `--token-file` 的 **远程托管隧道**（无本地 config.yml ingress），
/// 所以公开主机名 / 私有 IP 路由都通过 Cloudflare REST API 管理；
/// 只有 Start/Stop/Restart 需要管理员权限（osascript）。
@MainActor
@Observable
final class CloudflareTunnelManager {
    static let serviceLabel = "com.cloudflare.cloudflared"
    nonisolated static let daemonPlistPath = "/Library/LaunchDaemons/com.cloudflare.cloudflared.plist"
    private static let apiBase = "https://api.cloudflare.com/client/v4"
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var refreshTask: Task<Void, Never>?
    /// 本地 cloudflared 进程健康监控（更快感知隧道断开，独立于 10 分钟的 API 刷新）。
    private var healthTask: Task<Void, Never>?
    private var wasDaemonUp: Bool?
    private var wasRemoteHealthy: Bool?
    private var lastDownFiredAt: Date?
    private var lastRestoredFiredAt: Date?
    /// 用户主动 start/stop/restart 后短暂抑制告警，避免把用户操作误报为“隧道断开”。
    private var suppressAlertUntil: Date?

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"
    private(set) var daemonState = CFDaemonState.notInstalled
    private(set) var binaryPath: String?

    // API 数据
    private(set) var accounts: [CFAccount] = []
    private(set) var zones: [CFZone] = []
    private(set) var tunnels: [CloudflareTunnel] = []
    private(set) var ingress: [CFIngressRule] = []
    private(set) var ipRoutes: [CFIPRoute] = []

    /// 是否有操作正在执行（禁用按钮）
    private(set) var isWorking = false
    /// 最近一次用户操作的结果（Overview 底部横幅）
    private(set) var actionMessage: String?
    private(set) var actionSuccess = true

    // MARK: Settings (persisted)

    var isEnabled: Bool {
        enabled && !apiToken.isEmpty
    }
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Strings.Keys.cloudflareEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareEnabled) }
    }
    var apiToken: String {
        SecureStore.retrieve(key: Strings.Keys.cloudflareApiToken) ?? ""
    }
    var accountID: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.cloudflareAccountId) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareAccountId) }
    }
    var accountName: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.cloudflareAccountName) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareAccountName) }
    }
    var zoneID: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.cloudflareZoneId) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareZoneId) }
    }
    var zoneName: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.cloudflareZoneName) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareZoneName) }
    }
    var tunnelID: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.cloudflareTunnelId) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareTunnelId) }
    }
    var tunnelName: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.cloudflareTunnelName) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.cloudflareTunnelName) }
    }

    var selectedTunnel: CloudflareTunnel? {
        guard let id = tunnelID else { return nil }
        return tunnels.first { $0.id == id }
    }

    var daemonRunning: Bool {
        if case .running = daemonState { return true }
        return false
    }

    init() {
        if isEnabled {
            startAutoRefresh()
            refresh()
        }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.refreshTask?.cancel()
            self?.healthTask?.cancel()
        }
    }

    // MARK: - Refresh loop

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.cloudRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled { self.refresh() }
            }
        }
        startHealthMonitor()
    }

    // MARK: - Health monitoring（本地进程探测，及时感知「隧道断开」）

    private static let healthProbeInterval: TimeInterval = 60
    private static let alertCooldown: TimeInterval = 180

    func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthProbeInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled { await self.probeDaemonHealth() }
            }
        }
    }

    /// 探测本地 daemon，仅在其运行↔停止状态切换时发送通知（避免周期性刷屏）。
    private func probeDaemonHealth() async {
        let state = await Task.detached(priority: .utility) { Self.probeDaemonSync() }.value
        guard isEnabled else { return }
        daemonState = state
        let up = daemonRunning
        defer { wasDaemonUp = up }
        guard let prev = wasDaemonUp, prev != up else { return }
        if up {
            fireRestoredIfAllowed()
        } else {
            fireDownIfAllowed(body: Strings.tunnelDownBody)
        }
    }

    /// API 刷新后发现「进程在跑但隧道失联/不健康」（远程托管隧道的 token/配置问题）。
    private func evaluateRemoteHealth() {
        guard isEnabled, errorMessage == nil, daemonRunning, let tunnel = selectedTunnel else { return }
        let healthy = tunnel.isHealthy
        if let prev = wasRemoteHealthy, prev != healthy {
            wasRemoteHealthy = healthy
            if healthy {
                fireRestoredIfAllowed()
            } else {
                fireDownIfAllowed(body: Strings.tunnelDownRemoteBody)
            }
        } else {
            wasRemoteHealthy = healthy
        }
    }

    private var tunnelAlertEnabled: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.tunnelDownNotificationEnabled) as? Bool) ?? true
    }

    private func fireDownIfAllowed(body: String) {
        guard tunnelAlertEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastDownFiredAt, Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastDownFiredAt = Date()
        AppAlertCenter.fire(.tunnelDown, title: Strings.tunnelDownTitle, body: body)
    }

    private func fireRestoredIfAllowed() {
        guard tunnelAlertEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastRestoredFiredAt, Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastRestoredFiredAt = Date()
        AppAlertCenter.fire(.tunnelRestored, title: Strings.tunnelRestoredTitle, body: Strings.tunnelRestoredBody)
    }

    /// 本地守护进程探测（pgrep；后台执行，无需权限）。
    nonisolated static func probeDaemonSync() -> CFDaemonState {
        if !FileManager.default.fileExists(atPath: daemonPlistPath) {
            return .notInstalled
        }
        let r = ProcessRunner.run(launchPath: "/usr/bin/pgrep", args: ["-x", "cloudflared"], timeout: 5)
        if r.status == 0,
           let line = r.stdout.split(separator: "\n").first,
           let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
            return .running(pid: pid)
        }
        return .installed
    }

    /// 主入口：探测守护进程并拉取 API 状态。被 Settings toggle / 定时器 / 手动刷新调用。
    func refresh() {
        guard isEnabled else {
            errorMessage = CloudflareError.notConfigured.localizedDescription
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        binaryPath = ProcessRunner.cloudflaredPath()

        Task {
            daemonState = await Task.detached(priority: .userInitiated) {
                Self.probeDaemonSync()
            }.value

            // 账户/Zone 缓存为空时先发现
            if accounts.isEmpty { await discoverAccounts() }
            guard errorMessage == nil else { finishRefresh(); return }
            if let acct = accountID {
                await fetchTunnels(account: acct)
                if errorMessage == nil, zones.isEmpty { await discoverZones() }
            }
            guard errorMessage == nil else { finishRefresh(); return }
            if let acct = accountID, let tid = tunnelID {
                await fetchConfigAndRoutes(account: acct, tunnelID: tid)
            }
            finishRefresh()
        }
    }

    private func finishRefresh() {
        isLoading = false
        if errorMessage == nil {
            lastUpdate = Self.timeFormatter.string(from: Date())
        }
        evaluateRemoteHealth()
    }

    /// 设置里「验证并发现」：校验令牌 → 账户/Zone/隧道列表 + 自动选择。
    func verifyAndDiscover() async {
        guard !apiToken.isEmpty else {
            errorMessage = CloudflareError.invalidToken.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        await discoverAccounts()
        guard errorMessage == nil, let acct = accountID else { finishRefresh(); return }
        await discoverZones()
        await fetchTunnels(account: acct)
        finishRefresh()
    }

    // MARK: - Discover (accounts / zones / tunnels)

    private func discoverAccounts() async {
        accounts = []
        do {
            let json = try await api("GET", "/accounts", query: [URLQueryItem(name: "per_page", value: "50")])
            guard let arr = (json["result"] as? [[String: Any]]) else {
                throw CloudflareError.parseFailed
            }
            accounts = arr.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                return CFAccount(id: id, name: (dict["name"] as? String) ?? id)
            }
            if accounts.isEmpty {
                throw CloudflareError.noAccount
            }
            // 保持之前选择；否则选第一个。
            if accountID == nil || !accounts.contains(where: { $0.id == accountID }) {
                accountID = accounts[0].id
                accountName = accounts[0].name
            } else if accountName == nil {
                accountName = accounts.first { $0.id == accountID }?.name
            }
        } catch let e as CloudflareError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func discoverZones() async {
        zones = []
        do {
            let json = try await api("GET", "/zones", query: [URLQueryItem(name: "per_page", value: "50")])
            guard let arr = (json["result"] as? [[String: Any]]) else {
                throw CloudflareError.parseFailed
            }
            zones = arr.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                return CFZone(id: id, name: (dict["name"] as? String) ?? id)
            }
            if zoneID == nil || !zones.contains(where: { $0.id == zoneID }) {
                zoneID = zones.first?.id
                zoneName = zones.first?.name
            } else if zoneName == nil {
                zoneName = zones.first { $0.id == zoneID }?.name
            }
        } catch let e as CloudflareError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func fetchTunnels(account: String) async {
        do {
            let json = try await api("GET", "/accounts/\(account)/cfd_tunnel",
                                     query: [URLQueryItem(name: "is_deleted", value: "false")])
            guard let arr = (json["result"] as? [[String: Any]]) else {
                throw CloudflareError.parseFailed
            }
            tunnels = arr.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let conns = (dict["connections"] as? [[String: Any]]) ?? []
                return CloudflareTunnel(
                    id: id,
                    name: (dict["name"] as? String) ?? id,
                    status: (dict["status"] as? String) ?? "inactive",
                    connectorCount: conns.count
                )
            }
            if tunnelID == nil || !tunnels.contains(where: { $0.id == tunnelID }) {
                tunnelID = tunnels.first?.id
                tunnelName = tunnels.first?.name
            } else if tunnelName == nil {
                tunnelName = tunnels.first { $0.id == tunnelID }?.name
            }
        } catch let e as CloudflareError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func fetchConfigAndRoutes(account: String, tunnelID: String) async {
        // 公开主机名 ingress（注意：缺失/为空时不能 return —— 否则下面的私有路由永远不会拉取）
        do {
            let json = try await api("GET", "/accounts/\(account)/cfd_tunnel/\(tunnelID)/configurations")
            if let result = json["result"] as? [String: Any],
               let config = result["config"] as? [String: Any],
               let raw = config["ingress"] as? [[String: Any]] {
                ingress = raw.compactMap { dict in
                    guard let hostname = dict["hostname"] as? String else { return nil } // catch-all 无 hostname
                    return CFIngressRule(
                        hostname: hostname,
                        path: dict["path"] as? String,
                        service: (dict["service"] as? String) ?? ""
                    )
                }
            } else {
                // 部分隧道可能没有公开主机名配置 —— 视为空，并继续拉取下面的私有路由
                ingress = []
            }
        } catch let e as CloudflareError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }

        // 私有网络 IP 路由
        do {
            let json = try await api("GET", "/accounts/\(account)/cfd_tunnel/\(tunnelID)/routes/network",
                                     query: [URLQueryItem(name: "per_page", value: "100")])
            let arr = (json["result"] as? [[String: Any]]) ?? []
            ipRoutes = arr.compactMap { dict in
                guard let network = dict["network"] as? String else { return nil }
                return CFIPRoute(network: network, comment: dict["comment"] as? String)
            }
        } catch let e as CloudflareError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    /// 仅探测本机守护进程（设置页 onAppear 用）。
    func probeDaemon() async {
        daemonState = await Task.detached(priority: .userInitiated) { Self.probeDaemonSync() }.value
    }

    // MARK: - Selection changes

    func changeAccount(_ id: String) async {
        accountID = id
        accountName = accounts.first { $0.id == id }?.name
        tunnelID = nil
        tunnelName = nil
        ingress = []
        ipRoutes = []
        await discoverZones()
        await fetchTunnels(account: id)
    }

    func changeZone(_ id: String) {
        zoneID = id
        zoneName = zones.first { $0.id == id }?.name
    }

    func changeTunnel(_ id: String) async {
        tunnelID = id
        tunnelName = tunnels.first { $0.id == id }?.name
        ingress = []
        ipRoutes = []
        if let acct = accountID {
            await fetchConfigAndRoutes(account: acct, tunnelID: id)
        }
    }

    // MARK: - Daemon actions (admin)

    /// 启动 cloudflared 隧道服务。
    /// 优先用 `launchctl kickstart system/<label>`（比 legacy `launchctl start` 更可靠、域更明确）；
    /// 若本启动会话尚未 bootstrap 该 plist，则先 `launchctl bootstrap system <plist>` 再启动，
    /// 最后轮询等待进程真正起来（launchd 异步 spawn）。
    /// 启动 cloudflared 隧道服务。
    /// 流程：kickstart 一次 → 轮询等进程起来；仅当数秒后仍未运行（例如本启动会话
    /// 尚未 bootstrap 该 plist）才用 bootstrap 补一次 —— 避免每次都弹多次管理员密码。
    func startTunnel() async {
        isWorking = true
        suppressAlertUntil = Date().addingTimeInterval(30)
        let plist = Self.daemonPlistPath
        guard FileManager.default.fileExists(atPath: plist) else {
            await finishAdmin(ok: false,
                              message: CloudflareError.adminFailed(Strings.cloudflareDaemonNotInstalled).localizedDescription)
            return
        }
        let daemon = "system/\(Self.serviceLabel)"
        // 已加载但停止的服务：kickstart 即可拉起（launchd 异步 spawn，需轮询等待）。
        await runAdminCommand("launchctl kickstart \(daemon)")
        var running = await waitForDaemon(running: true, attempts: 8)   // ~4s
        if !running {
            // 极少见：本启动会话尚未加载该 plist → bootstrap 一次（RunAtLoad 会自动运行）。
            await runAdminCommand("launchctl bootstrap system \(plist)")
            running = await waitForDaemon(running: true, attempts: 24)  // ~12s
        }
        await finishAdmin(ok: running,
                          message: running ? Strings.cloudflareDaemonOk : Strings.cloudflareDaemonNotRunning)
        if running {
            // 拉取 API 状态，刷新 Overview 的隧道健康/连接数。
            refresh()
        }
    }

    func stopTunnel() async {
        isWorking = true
        suppressAlertUntil = Date().addingTimeInterval(30)
        await runAdminCommand("launchctl stop \(Self.serviceLabel)")
        let stopped = await waitForDaemon(running: false, attempts: 6)
        await finishAdmin(ok: stopped,
                          message: stopped ? Strings.cloudflareDaemonOk : Strings.cloudflareDaemonStillRunning)
    }

    func restartTunnel() async {
        isWorking = true
        suppressAlertUntil = Date().addingTimeInterval(30)
        let daemon = "system/\(Self.serviceLabel)"
        await runAdminCommand("launchctl kickstart -k \(daemon)")
        let running = await waitForDaemon(running: true, attempts: 20)
        await finishAdmin(ok: running,
                          message: running ? Strings.cloudflareDaemonOk : Strings.cloudflareDaemonNotRunning)
        if running {
            refresh()
        }
    }

    /// 轮询本机 cloudflared 进程直至达到期望状态；每 0.5s 一次，最多 attempts 次。
    private func waitForDaemon(running wantRunning: Bool, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            let state = await Task.detached(priority: .userInitiated) { Self.probeDaemonSync() }.value
            daemonState = state
            let isRunning: Bool
            if case .running = state { isRunning = true } else { isRunning = false }
            if isRunning == wantRunning { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// 以管理员权限执行一条 shell 命令；失败时把错误写入 actionMessage（不中断后续动作）。
    private func runAdminCommand(_ command: String) async {
        let res = await Task.detached(priority: .userInitiated) {
            ProcessRunner.runAdmin(command: command)
        }.value
        if !res.ok {
            actionSuccess = false
            actionMessage = res.message
        }
    }

    /// 收尾：成功则写入成功消息；失败时若还没有更具体的错误（如用户取消授权），再写入提示。
    private func finishAdmin(ok: Bool, message: String) async {
        isWorking = false
        actionSuccess = ok
        if ok {
            actionMessage = message
        } else if actionMessage == nil || actionMessage?.isEmpty == true {
            actionMessage = message
        }
    }

    // MARK: - Hostname routes (ingress + DNS CNAME)

    func addPublicHostname(hostname: String, service: String) async {
        await mutateIngress { rules in
            rules + [["hostname": hostname, "service": service]]
        }
        if actionSuccess {
            await ensureDNS(hostname: hostname)
        }
        refresh()
    }

    func removePublicHostname(hostname: String) async {
        await mutateIngress { rules in
            rules.filter { ($0["hostname"] as? String) != hostname }
        }
        if actionSuccess {
            await removeDNS(hostname: hostname)
        }
        refresh()
    }

    /// 读取当前 configurations → 修改 ingress → PUT 回去。
    private func mutateIngress(_ transform: ([[String: Any]]) -> [[String: Any]]) async {
        guard let acct = accountID, let tid = tunnelID else {
            actionMessage = CloudflareError.noTunnel.localizedDescription
            actionSuccess = false
            return
        }
        isWorking = true
        actionMessage = nil
        defer { isWorking = false }
        do {
            let json = try await api("GET", "/accounts/\(acct)/cfd_tunnel/\(tid)/configurations")
            guard let result = json["result"] as? [String: Any] else { throw CloudflareError.parseFailed }
            var config = (result["config"] as? [String: Any]) ?? [:]
            var rules = (config["ingress"] as? [[String: Any]]) ?? []
            rules = transform(rules)
            config["ingress"] = rules
            let body: [String: Any] = ["config": config]
            let put = try await api("PUT", "/accounts/\(acct)/cfd_tunnel/\(tid)/configurations", jsonBody: body)
            if (put["success"] as? Bool) == true {
                actionSuccess = true
                actionMessage = Strings.cloudflareRouteChanged
            } else {
                actionSuccess = false
                actionMessage = (put["errors"] as? [[String: Any]])?.first?["message"] as? String
                    ?? CloudflareError.parseFailed.localizedDescription
            }
            // 更新 UI 的 ingress 快照
            if actionSuccess {
                ingress = rules.compactMap { dict in
                    guard let h = dict["hostname"] as? String else { return nil }
                    return CFIngressRule(hostname: h, path: dict["path"] as? String,
                                         service: (dict["service"] as? String) ?? "")
                }
            }
        } catch let e as CloudflareError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    /// 确保 zone 里存在 `hostname → <tunnelID>.cfargotunnel.com` 的 CNAME（远程托管隧道的公开主机名需要 DNS 记录）。
    private func ensureDNS(hostname: String) async {
        guard let zid = zoneID, let tid = tunnelID else {
            actionSuccess = false
            actionMessage = CloudflareError.noZone.localizedDescription
            return
        }
        let content = "\(tid).cfargotunnel.com"
        do {
            let list = try await api("GET", "/zones/\(zid)/dns_records",
                                     query: [URLQueryItem(name: "type", value: "CNAME"),
                                             URLQueryItem(name: "name", value: hostname)])
            let records = (list["result"] as? [[String: Any]]) ?? []
            let exists = records.contains { dict in
                ((dict["content"] as? String) ?? "").lowercased() == content.lowercased()
            }
            if exists { return }
            let body: [String: Any] = [
                "type": "CNAME", "name": hostname, "content": content,
                "proxied": true, "ttl": 1,
            ]
            _ = try await api("POST", "/zones/\(zid)/dns_records", jsonBody: body)
        } catch let e as CloudflareError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func removeDNS(hostname: String) async {
        guard let zid = zoneID else { return }
        do {
            let list = try await api("GET", "/zones/\(zid)/dns_records",
                                     query: [URLQueryItem(name: "type", value: "CNAME"),
                                             URLQueryItem(name: "name", value: hostname)])
            let records = (list["result"] as? [[String: Any]]) ?? []
            for rec in records {
                guard let rid = rec["id"] as? String else { continue }
                let content = (rec["content"] as? String) ?? ""
                if content.lowercased().hasSuffix("cfargotunnel.com") {
                    _ = try? await api("DELETE", "/zones/\(zid)/dns_records/\(rid)")
                }
            }
        } catch {
            // DNS 清理失败不阻塞（ingress 已删）；保留记录也安全。
        }
    }

    // MARK: - Private IP routes

    func addIPRoute(network: String, comment: String) async {
        guard let acct = accountID, let tid = tunnelID else {
            actionMessage = CloudflareError.noTunnel.localizedDescription
            actionSuccess = false
            return
        }
        isWorking = true
        actionMessage = nil
        defer { isWorking = false }
        do {
            var body: [String: Any] = ["network": network]
            if !comment.isEmpty { body["comment"] = comment }
            let json = try await api("POST", "/accounts/\(acct)/cfd_tunnel/\(tid)/routes/network", jsonBody: body)
            if (json["success"] as? Bool) == true {
                actionSuccess = true
                actionMessage = Strings.cloudflareRouteChanged
                if !ipRoutes.contains(where: { $0.network == network }) {
                    ipRoutes.append(CFIPRoute(network: network, comment: comment.isEmpty ? nil : comment))
                }
            } else {
                actionSuccess = false
                actionMessage = (json["errors"] as? [[String: Any]])?.first?["message"] as? String
                    ?? CloudflareError.parseFailed.localizedDescription
            }
        } catch let e as CloudflareError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    func removeIPRoute(network: String) async {
        guard let acct = accountID, let tid = tunnelID else { return }
        isWorking = true
        actionMessage = nil
        defer { isWorking = false }
        let encoded = network.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")) ?? network
        do {
            let json = try await api("DELETE", "/accounts/\(acct)/cfd_tunnel/\(tid)/routes/network/\(encoded)")
            if (json["success"] as? Bool) == true {
                actionSuccess = true
                actionMessage = Strings.cloudflareRouteChanged
                ipRoutes.removeAll { $0.network == network }
            } else {
                actionSuccess = false
                actionMessage = (json["errors"] as? [[String: Any]])?.first?["message"] as? String
                    ?? CloudflareError.parseFailed.localizedDescription
            }
        } catch let e as CloudflareError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = CloudflareError.networkError(error.localizedDescription).localizedDescription
        }
    }

    // MARK: - Cloudflare API plumbing

    /// 执行一次 Cloudflare API 调用，返回顶层 JSON 字典。失败抛 CloudflareError。
    private func api(_ method: String, _ path: String,
                     query: [URLQueryItem] = [], jsonBody: Any? = nil) async throws -> [String: Any] {
        guard let token = apiToken.isEmpty ? nil : apiToken else {
            throw CloudflareError.invalidToken
        }
        var comps = URLComponents(string: Self.apiBase + path)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw CloudflareError.parseFailed }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = AppConfig.cloudRequestTimeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await AppConfig.directURLSession.data(for: req)
        } catch {
            throw CloudflareError.networkError(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 { throw CloudflareError.invalidToken }
            if http.statusCode == 403 { throw CloudflareError.accessDenied }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudflareError.parseFailed
        }
        return obj
    }
}
