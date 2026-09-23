import Foundation
import SwiftUI

// MARK: - Tailscale — 数据模型

/// `status --json` 的 BackendState。
enum TSBackendState: String, Sendable {
    case running = "Running"
    case starting = "Starting"
    case stopped = "Stopped"
    case needsLogin = "NeedsLogin"
    case noState = "NoState"

    var isConnected: Bool { self == .running }
}

/// `tailscale configure sysext status` 的结果（**纯文本**输出，不是 JSON）。
enum TSSysextState: Equatable, Sendable {
    case ok
    case notOk(String)
    case unknown
}

/// 本机节点（JSON 的 `Self`）。
struct TSSelfNode: Equatable, Sendable {
    let hostName: String
    let dnsName: String          // 已去掉结尾的点
    let os: String
    let tailscaleIPs: [String]
    let online: Bool
    let exitNode: Bool
    let exitNodeOption: Bool
    let relay: String
    let created: Date?
    let keyExpiry: Date?

    var displayName: String { hostName.isEmpty ? dnsName : hostName }
    var ipv4: String? { tailscaleIPs.first { !$0.contains(":") } }
}

/// tailnet 里的其他设备（JSON 的 `Peer`）。
struct TSPeer: Identifiable, Equatable, Sendable {
    let id: String
    let hostName: String
    let dnsName: String
    let os: String
    let online: Bool
    let active: Bool
    let tailscaleIPs: [String]
    let relay: String
    let curAddr: String
    let exitNode: Bool
    let exitNodeOption: Bool
    let lastSeen: Date?
    let userLogin: String?
    let rxBytes: Int64
    let txBytes: Int64

    var displayName: String { hostName.isEmpty ? dnsName : hostName }
    var ipv4: String? { tailscaleIPs.first { !$0.contains(":") } }
    /// 直连（有 CurAddr）还是走 DERP 中继。
    var isDirect: Bool { !curAddr.isEmpty }
}

/// serve / funnel 的一条映射。二者共用同一份配置，靠 `AllowFunnel` 标记区分。
struct TSServeMapping: Identifiable, Equatable, Sendable {
    let port: Int
    let scheme: String        // https / http / tcp
    let path: String          // 通常是 "/"
    let target: String        // http://localhost:18080
    let hostPort: String      // <node>.<tailnet>.ts.net:8443（纯 TCP 转发时为空）
    let isFunnel: Bool

    var id: String { "\(scheme):\(port):\(path)" }
    var url: String? {
        guard !hostPort.isEmpty else { return nil }
        let suffix = path == "/" ? "" : path
        return "\(scheme)://\(hostPort)\(suffix)"
    }
}

// MARK: - 采集快照（跨线程传递，全部 Sendable）

struct TSStatusSnapshot: Sendable {
    var backendState = ""
    var health: [String] = []
    var selfNode: TSSelfNode?
    var peers: [TSPeer] = []
    var tailnetName = ""
    var magicDNSSuffix = ""
    var magicDNSEnabled = false
    var error: String?
}

struct TSServeSnapshot: Sendable {
    var mappings: [TSServeMapping] = []
    /// tailnet 未启用 serve/funnel 时，CLI 给出的浏览器授权链接。
    var enableURL: String?
    var error: String?
}

struct TSVersionInfo: Sendable {
    var version: String?
    var variant: String?
}

// MARK: - 错误

enum TailscaleError: LocalizedError {
    case notInstalled
    case notConfigured
    case notEnabled(String)
    case commandFailed(String)
    case parseFailed

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .notInstalled:
            return isZH
                ? "未找到 tailscale 命令行（请安装 Tailscale macOS 客户端，或在其设置里安装 CLI integration）"
                : "tailscale CLI not found (install the Tailscale macOS client, or install CLI integration from its settings)"
        case .notConfigured:
            return isZH ? "尚未启用（设置 → 服务 → Tailscale）" : "Not enabled (Settings → Services → Tailscale)"
        case .notEnabled(let url):
            return isZH
                ? "该功能未在 tailnet 启用，需要在浏览器里授权：\(url)"
                : "Not enabled on your tailnet. Authorize in a browser: \(url)"
        case .commandFailed(let m):
            return isZH ? "命令失败: \(m)" : "Command failed: \(m)"
        case .parseFailed:
            return isZH ? "解析 tailscale 输出失败" : "Failed to parse tailscale output"
        }
    }

    /// `Strings.isZH` 是 private，各管理器自带一份。
    private static func checkZH() -> Bool {
        let saved = UserDefaults.standard.string(forKey: Strings.Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }
}

// MARK: - Tailscale Manager

/// 管理本机 Tailscale（macOS **Standalone / macsys** 变体）的连接状态 + serve/funnel 映射。
///
/// 取值全部走 `tailscale` 命令行（`status --json` / `serve status --json` / `funnel status --json`），
/// 不使用 admin API，因此**不需要任何令牌**。
///
/// 两个实机验证过的坑（改动这里之前务必阅读）：
/// 1. 该二进制**同时是 GUI 与 CLI**：它检查 `SHLVL`/`TERM`/`TERM_PROGRAM`/`PS1` 来决定行为，
///    从 GUI 进程 fork 出来时这些变量都不存在，于是会**弹出 GUI 窗口而不是执行命令**。
///    所以一律通过 `ProcessRunner.runTailscale`（自动注入 `TAILSCALE_BE_CLI=1`）。
/// 2. tailnet 未启用 Serve/Funnel 时，**添加命令会一直挂着**等浏览器授权（不会自己退出），
///    所以变更命令必须带 timeout，并把输出里的启用链接提取出来交给 UI。
@MainActor
@Observable
final class TailscaleManager {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 健康探测间隔（远快于 10 分钟的完整刷新，用于及时发现断连）。
    private static let healthProbeInterval: TimeInterval = 60
    private static let alertCooldown: TimeInterval = 180
    /// 变更命令超时：未启用时 tailscale 会一直挂着，必须自己收手。
    private static let mutationTimeout: TimeInterval = 20

    private var refreshTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var wasConnected: Bool?
    private var lastDownFiredAt: Date?
    private var lastRestoredFiredAt: Date?
    /// 用户主动操作后短暂抑制告警，避免把自己的操作误报成「掉线」。
    private var suppressAlertUntil: Date?

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"
    private(set) var binaryPath: String?
    private(set) var cliVersion: String?
    private(set) var osVariant: String?
    private(set) var sysextState: TSSysextState = .unknown
    private(set) var backendStateRaw = ""
    private(set) var health: [String] = []
    private(set) var selfNode: TSSelfNode?
    private(set) var peers: [TSPeer] = []
    private(set) var tailnetName = ""
    private(set) var magicDNSSuffix = ""
    private(set) var magicDNSEnabled = false
    private(set) var serves: [TSServeMapping] = []
    private(set) var funnels: [TSServeMapping] = []

    private(set) var isWorking = false
    private(set) var actionMessage: String?
    private(set) var actionSuccess = true

    /// tailnet 未启用 serve/funnel 时的授权链接（UI 提供一键打开）。
    /// 注意：`serve status --json` 在「未启用」和「已启用但没配置」两种情况下都返回 `{}`，
    /// 所以这个标记只能通过**实际发一次命令**发现，并且在成功后清掉。
    private(set) var serveEnableURL: String?
    private(set) var funnelEnableURL: String?

    // MARK: Settings

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Strings.Keys.tailscaleEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.tailscaleEnabled) }
    }

    var notifyEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Strings.Keys.tailscaleNotifyEnabled) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.tailscaleNotifyEnabled) }
    }

    var isEnabled: Bool { enabled && ProcessRunner.tailscalePath() != nil }
    var isInstalled: Bool { binaryPath != nil || ProcessRunner.tailscalePath() != nil }
    var backendState: TSBackendState? { TSBackendState(rawValue: backendStateRaw) }
    var isConnected: Bool { backendState?.isConnected ?? false }
    var onlinePeerCount: Int { peers.filter(\.online).count }
    var selfIPv4: String? { selfNode?.ipv4 }
    var hasServeConfig: Bool { !serves.isEmpty }
    var hasFunnelConfig: Bool { !funnels.isEmpty }

    var sysextText: String? {
        switch sysextState {
        case .ok: return Strings.tailscaleSysextOk
        case .notOk(let t): return t
        case .unknown: return nil
        }
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

    func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthProbeInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled { await self.probeHealth() }
            }
        }
    }

    /// 轻量探测（`status --json` 约 3 KB），只在连接状态翻转时发通知。
    private func probeHealth() async {
        let snap = await Task.detached(priority: .utility) { Self.fetchStatusSync() }.value
        guard isEnabled, snap.error == nil else { return }
        applyStatus(snap)
        evaluateConnection()
    }

    /// 连接状态翻转 → 通知（带冷却 + 用户操作后抑制）。
    private func evaluateConnection() {
        guard isEnabled, errorMessage == nil else { return }
        let connected = isConnected
        defer { wasConnected = connected }
        guard let prev = wasConnected, prev != connected else { return }
        if connected { fireRestoredIfAllowed() } else { fireDownIfAllowed() }
    }

    private func fireDownIfAllowed() {
        guard notifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastDownFiredAt, Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastDownFiredAt = Date()
        AppAlertCenter.fire(.tailscaleDown, title: Strings.tailscaleDownTitle,
                            body: Strings.tailscaleDownBody, subject: tailnetName)
    }

    private func fireRestoredIfAllowed() {
        guard notifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastRestoredFiredAt, Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastRestoredFiredAt = Date()
        AppAlertCenter.fire(.tailscaleRestored, title: Strings.tailscaleRestoredTitle,
                            body: Strings.tailscaleRestoredBody, subject: tailnetName)
    }

    // MARK: - 完整刷新

    /// 主入口：版本 / 系统扩展 / 节点与对端 / serve+funnel 配置。被设置开关、定时器、手动刷新调用。
    func refresh() {
        guard enabled else {
            errorMessage = TailscaleError.notConfigured.localizedDescription
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        binaryPath = ProcessRunner.tailscalePath()
        guard binaryPath != nil else {
            errorMessage = TailscaleError.notInstalled.localizedDescription
            isLoading = false
            return
        }

        Task {
            let info = await Task.detached(priority: .userInitiated) { Self.fetchVersionSync() }.value
            cliVersion = info.version
            osVariant = info.variant
            sysextState = await Task.detached(priority: .userInitiated) { Self.fetchSysextSync() }.value

            let status = await Task.detached(priority: .userInitiated) { Self.fetchStatusSync() }.value
            applyStatus(status)

            let serve = await Task.detached(priority: .userInitiated) { Self.fetchServeSync() }.value
            let funnel = await Task.detached(priority: .userInitiated) { Self.fetchFunnelSync() }.value
            applyServe(serve: serve, funnel: funnel)

            finishRefresh()
        }
    }

    private func finishRefresh() {
        isLoading = false
        if errorMessage == nil { lastUpdate = Self.timeFormatter.string(from: Date()) }
        evaluateConnection()
    }

    private func applyStatus(_ snap: TSStatusSnapshot) {
        if let err = snap.error { errorMessage = err; return }
        backendStateRaw = snap.backendState
        health = snap.health
        selfNode = snap.selfNode
        peers = snap.peers
        tailnetName = snap.tailnetName
        magicDNSSuffix = snap.magicDNSSuffix
        magicDNSEnabled = snap.magicDNSEnabled
    }

    /// serve 配置是唯一来源；funnel 只是其中被 `AllowFunnel` 标记为公开的那部分。
    /// `funnel status --json` 若返回了内容就优先用它（防版本差异）。
    private func applyServe(serve: TSServeSnapshot, funnel: TSServeSnapshot) {
        if let err = serve.error, errorMessage == nil { errorMessage = err }
        let all = serve.mappings
        serves = all.filter { !$0.isFunnel }
        funnels = funnel.mappings.isEmpty ? all.filter(\.isFunnel) : funnel.mappings
    }

    func clearServeEnableHint() { serveEnableURL = nil }
    func clearFunnelEnableHint() { funnelEnableURL = nil }

    // MARK: - 变更动作（serve / funnel）

    /// 添加一条 serve（仅 tailnet 内可见）。
    func addServe(port: Int, target: String, useHTTPS: Bool) async {
        let flag = useHTTPS ? "--https=\(port)" : "--http=\(port)"
        await runMutation(["serve", "--bg", "--yes", flag, target],
                          success: Strings.tailscaleServeAdded, isFunnelCommand: false)
    }

    /// 添加一条 funnel（公开到互联网；端口仅限 443 / 8443 / 10000）。
    func addFunnel(port: Int, target: String) async {
        // 发布前护栏：funnel 是完全公开的，本应用自己的端口必须先配好令牌
        if let appPort = AppConfig.appOwnedServicePort(in: target),
           !AppConfig.appOwnedPortIsAuthenticated(appPort) {
            actionSuccess = false
            actionMessage = String(format: Strings.publishBlockedNoToken, "\(appPort)")
            ActionLog.record(.tailscale, action: "funnel.add", target: target, success: false,
                             message: actionMessage, blocked: true)
            return
        }
        await runMutation(["funnel", "--bg", "--yes", "--https=\(port)", target],
                          success: Strings.tailscaleFunnelAdded, isFunnelCommand: true)
    }

    /// 关闭一条映射。`off` 形式必须带上原来的全部 flag，否则关不掉。
    func removeMapping(_ mapping: TSServeMapping, funnel: Bool) async {
        let verb = funnel ? "funnel" : "serve"
        var args = [verb, "--yes"]
        switch mapping.scheme {
        case "https": args.append("--https=\(mapping.port)")
        case "http": args.append("--http=\(mapping.port)")
        default: args.append("--tcp=\(mapping.port)")
        }
        if mapping.path != "/" { args.append("--set-path=\(mapping.path)") }
        args.append("off")
        await runMutation(args, success: Strings.tailscaleMappingRemoved, isFunnelCommand: funnel)
    }

    /// 清空 funnel 配置。
    func resetFunnel() async {
        await runMutation(["funnel", "reset"], success: Strings.tailscaleFunnelReset, isFunnelCommand: true)
    }

    private func runMutation(_ args: [String], success: String, isFunnelCommand: Bool) async {
        isWorking = true
        actionMessage = nil
        // 函数退出时统一记录。三种结局：待授权（blocked）/ 成功 / 失败。
        // 待授权时 CLI 会打印授权链接，链接**不进日志**，只记 tailscaleEnableRequired。
        var outcome: ActionResult = .failure
        defer {
            ActionLog.record(.tailscale, action: Self.mutationAction(args),
                             target: Self.mutationTarget(args),
                             result: outcome, detail: actionMessage ?? "")
        }
        let timeout = Self.mutationTimeout
        let result = await Task.detached(priority: .userInitiated) {
            ProcessRunner.runTailscale(args, timeout: timeout)
        }.value
        isWorking = false

        let output = (result.stdout + "\n" + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // tailnet 未启用 → CLI 打印授权链接后一直挂着（我们超时收手）。这不是错误，是待授权状态。
        if let url = Self.parseEnableURL(output) {
            if isFunnelCommand { funnelEnableURL = url } else { serveEnableURL = url }
            actionSuccess = false
            actionMessage = Strings.tailscaleEnableRequired
            outcome = .blocked
            return
        }
        if result.status == 0 {
            if isFunnelCommand { funnelEnableURL = nil } else { serveEnableURL = nil }
            actionSuccess = true
            actionMessage = success
            outcome = .success
            suppressAlertUntil = Date().addingTimeInterval(30)
            refresh()
            return
        }
        actionSuccess = false
        actionMessage = output.isEmpty ? Strings.tailscaleCommandTimedOut : output
    }

    /// 从 CLI 参数推断动作名（runMutation 是 serve / funnel 的唯一出口）。
    private static func mutationAction(_ args: [String]) -> String {
        let isFunnel = args.first == "funnel"
        if args.contains("off") { return isFunnel ? "funnel.remove" : "serve.remove" }
        if args.contains("reset") { return "funnel.reset" }
        return isFunnel ? "funnel.add" : "serve.add"
    }

    /// 从 CLI 参数提取作用对象：新增时是目标地址，删除/重置时是端口 / 路径。
    private static func mutationTarget(_ args: [String]) -> String {
        if let last = args.last, !last.hasPrefix("--"), last != "off", last != "reset" {
            return last
        }
        let flags = args.filter {
            $0.hasPrefix("--https=") || $0.hasPrefix("--http=")
                || $0.hasPrefix("--tcp=") || $0.hasPrefix("--set-path=")
        }
        return flags.isEmpty ? (args.first ?? "") : flags.joined(separator: " ")
    }

    // MARK: - CLI 采集（nonisolated：在后台线程执行阻塞的 Process）

    nonisolated static func fetchVersionSync() -> TSVersionInfo {
        let r = ProcessRunner.runTailscale(["version", "--json"], timeout: 10)
        guard r.status == 0,
              let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TSVersionInfo(version: nil, variant: nil)
        }
        return TSVersionInfo(version: (obj["short"] as? String) ?? (obj["majorMinorPatch"] as? String),
                             variant: obj["osVariant"] as? String)
    }

    nonisolated static func fetchSysextSync() -> TSSysextState {
        let r = ProcessRunner.runTailscale(["configure", "sysext", "status"], timeout: 10)
        let text = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }
        // 实机输出：`System extension state: OK. For more detailed information, …`
        return text.contains("OK") ? .ok : .notOk(text)
    }

    nonisolated static func fetchStatusSync() -> TSStatusSnapshot {
        var snap = TSStatusSnapshot()
        let r = ProcessRunner.runTailscale(["status", "--json"], timeout: 12)
        guard r.status == 0 else {
            let msg = (r.stderr + "\n" + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            snap.error = msg.isEmpty ? "tailscale status exit \(r.status)" : msg
            return snap
        }
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            snap.error = TailscaleError.parseFailed.localizedDescription
            return snap
        }

        snap.backendState = obj["BackendState"] as? String ?? ""
        snap.health = stringArray(obj["Health"])
        snap.magicDNSSuffix = obj["MagicDNSSuffix"] as? String ?? ""
        if let tailnet = obj["CurrentTailnet"] as? [String: Any] {
            snap.tailnetName = tailnet["Name"] as? String ?? ""
            if let suffix = tailnet["MagicDNSSuffix"] as? String, !suffix.isEmpty {
                snap.magicDNSSuffix = suffix
            }
            snap.magicDNSEnabled = tailnet["MagicDNSEnabled"] as? Bool ?? false
        }

        if let selfDict = obj["Self"] as? [String: Any] {
            snap.selfNode = TSSelfNode(
                hostName: selfDict["HostName"] as? String ?? "",
                dnsName: trimDNS(selfDict["DNSName"] as? String ?? ""),
                os: selfDict["OS"] as? String ?? "",
                tailscaleIPs: stringArray(selfDict["TailscaleIPs"]),
                online: selfDict["Online"] as? Bool ?? false,
                exitNode: selfDict["ExitNode"] as? Bool ?? false,
                exitNodeOption: selfDict["ExitNodeOption"] as? Bool ?? false,
                relay: selfDict["Relay"] as? String ?? "",
                created: parseTSDate(selfDict["Created"] as? String ?? ""),
                keyExpiry: parseTSDate(selfDict["KeyExpiry"] as? String ?? ""))
        }

        // Peer 只带 UserID，登录名要从 User 表查。
        var logins: [Int64: String] = [:]
        if let users = obj["User"] as? [String: Any] {
            for value in users.values {
                guard let user = value as? [String: Any],
                      let id = (user["ID"] as? NSNumber)?.int64Value else { continue }
                logins[id] = user["LoginName"] as? String ?? ""
            }
        }

        // ⚠️ 单机 tailnet 时这里是 null；`as?` 会安全地变成空列表。
        if let peerMap = obj["Peer"] as? [String: Any] {
            for value in peerMap.values {
                guard let peer = value as? [String: Any] else { continue }
                let uid = (peer["UserID"] as? NSNumber)?.int64Value
                snap.peers.append(TSPeer(
                    id: peer["ID"] as? String ?? UUID().uuidString,
                    hostName: peer["HostName"] as? String ?? "",
                    dnsName: trimDNS(peer["DNSName"] as? String ?? ""),
                    os: peer["OS"] as? String ?? "",
                    online: peer["Online"] as? Bool ?? false,
                    active: peer["Active"] as? Bool ?? false,
                    tailscaleIPs: stringArray(peer["TailscaleIPs"]),
                    relay: peer["Relay"] as? String ?? "",
                    curAddr: peer["CurAddr"] as? String ?? "",
                    exitNode: peer["ExitNode"] as? Bool ?? false,
                    exitNodeOption: peer["ExitNodeOption"] as? Bool ?? false,
                    lastSeen: parseTSDate(peer["LastSeen"] as? String ?? ""),
                    userLogin: uid.flatMap { logins[$0] },
                    rxBytes: (peer["RxBytes"] as? NSNumber)?.int64Value ?? 0,
                    txBytes: (peer["TxBytes"] as? NSNumber)?.int64Value ?? 0))
            }
        }
        snap.peers.sort { a, b in
            if a.online != b.online { return a.online }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        return snap
    }

    /// 全部 serve 配置（含 funnel —— funnel 只是其中被标记为公开的部分）。
    nonisolated static func fetchServeSync() -> TSServeSnapshot {
        var snap = TSServeSnapshot()
        let r = ProcessRunner.runTailscale(["serve", "status", "--json"], timeout: 12)
        guard r.status == 0 else {
            let text = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = parseEnableURL(text) {
                snap.enableURL = url
            } else {
                snap.error = text.isEmpty ? "tailscale serve status exit \(r.status)" : text
            }
            return snap
        }
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return snap }
        snap.mappings = parseServeConfig(obj)
        return snap
    }

    /// 只返回公开的 funnel 映射；未配置/未启用时返回空（会把结果让给 serve 的解析）。
    nonisolated static func fetchFunnelSync() -> TSServeSnapshot {
        var snap = TSServeSnapshot()
        let r = ProcessRunner.runTailscale(["funnel", "status", "--json"], timeout: 12)
        guard r.status == 0,
              let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !obj.isEmpty else { return snap }
        snap.mappings = parseServeConfig(obj)
        return snap
    }

    /// 解析实机验证过的结构：
    /// ```json
    /// { "TCP": { "8443": { "HTTPS": true } },
    ///   "Web": { "<dns>:8443": { "Handlers": { "/": { "Proxy": "http://localhost:18080" } } } },
    ///   "AllowFunnel": { "<dns>:8443": true } }
    /// ```
    nonisolated static func parseServeConfig(_ obj: [String: Any]) -> [TSServeMapping] {
        let tcp = obj["TCP"] as? [String: Any] ?? [:]
        let web = obj["Web"] as? [String: Any] ?? [:]
        let allowFunnel = obj["AllowFunnel"] as? [String: Any] ?? [:]
        var out: [TSServeMapping] = []
        var seenPorts = Set<Int>()

        for (hostPort, value) in web {
            guard let webDict = value as? [String: Any],
                  let port = portFrom(hostPort) else { continue }
            seenPorts.insert(port)
            let tcpEntry = tcp["\(port)"] as? [String: Any]
            let scheme = (tcpEntry?["HTTPS"] as? Bool ?? false) ? "https" : "http"
            let isFunnel = allowFunnel[hostPort] != nil
            let handlers = webDict["Handlers"] as? [String: Any] ?? [:]
            for (path, handlerValue) in handlers {
                let handler = handlerValue as? [String: Any] ?? [:]
                let target = (handler["Proxy"] as? String)
                    ?? (handler["Text"] as? String)
                    ?? (handler["Path"] as? String)
                    ?? ""
                out.append(TSServeMapping(port: port, scheme: scheme, path: path, target: target,
                                          hostPort: hostPort, isFunnel: isFunnel))
            }
        }

        // 纯 TCP 转发没有 Web handler，单独补齐。
        for (portKey, value) in tcp {
            guard let port = Int(portKey), !seenPorts.contains(port),
                  let tcpDict = value as? [String: Any] else { continue }
            let forward = tcpDict["TCPForward"] as? String ?? ""
            guard !forward.isEmpty else { continue }
            out.append(TSServeMapping(port: port, scheme: "tcp", path: "/", target: forward,
                                      hostPort: "", isFunnel: false))
        }

        return out.sorted { a, b in
            if a.port != b.port { return a.port < b.port }
            return a.path < b.path
        }
    }

    nonisolated private static func stringArray(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// `Web` 的键形如 `host.tailnet.ts.net:8443`，取最后一段做端口。
    nonisolated static func portFrom(_ hostPort: String) -> Int? {
        guard let last = hostPort.split(separator: ":").last else { return nil }
        return Int(last)
    }

    nonisolated private static func trimDNS(_ s: String) -> String {
        s.hasSuffix(".") ? String(s.dropLast()) : s
    }

    /// Tailscale 的时间戳带 9 位小数（`2026-09-13T04:04:08.294454054Z`），
    /// ISO8601DateFormatter 不一定吃得下 —— 先裁掉小数部分。
    /// 全零时间（`0001-01-01T00:00:00Z`）表示「从未」，返回 nil。
    nonisolated static func parseTSDate(_ s: String) -> Date? {
        guard !s.isEmpty, !s.hasPrefix("0001-01-01") else { return nil }
        var core = s
        if let dot = core.firstIndex(of: ".") { core = String(core[..<dot]) + "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: core)
    }

    /// 从 CLI 输出里提取启用链接，例如
    /// `https://login.tailscale.com/f/serve?node=nYh7GZxSMq11CNTRL`
    nonisolated static func parseEnableURL(_ text: String) -> String? {
        let pattern = #"https://[A-Za-z0-9.\-]+/f/(serve|funnel)\?node=[A-Za-z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, options: [],
                                           range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}
