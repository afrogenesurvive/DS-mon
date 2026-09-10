import Foundation

// MARK: - 本地数据库服务（MongoDB / MySQL / Neo4j）

/// 本地数据库标识。三者均通过 Homebrew 安装（/opt/homebrew）。
enum LocalDBID: String, CaseIterable, Identifiable, Sendable {
    case mongodb
    case mysql
    case neo4j

    var id: String { rawValue }

    /// brew 服务名
    var formula: String {
        switch self {
        case .mongodb: return "mongodb-community"
        case .mysql: return "mysql"
        case .neo4j: return "neo4j"
        }
    }

    /// 默认客户端端口
    var port: Int {
        switch self {
        case .mongodb: return 27017
        case .mysql: return 3306
        case .neo4j: return 7687
        }
    }

    /// 本地 unix socket（存在即视为运行中；MySQL/Neo4j 也可能只有端口）
    var sockets: [String] {
        switch self {
        case .mongodb: return ["/tmp/mongodb-27017.sock"]
        case .mysql: return ["/tmp/mysql.sock", "/tmp/mysqlx.sock"]
        case .neo4j: return []
        }
    }

    /// 数据目录（服务器停止时，用于离线列出磁盘上已存在的库）
    var dataDirs: [String] {
        switch self {
        case .mongodb: return ["/opt/homebrew/var/mongodb"]
        case .mysql: return ["/opt/homebrew/var/mysql"]
        case .neo4j: return ["/opt/homebrew/var/neo4j/data/databases"]
        }
    }

    /// 用 brew 启动时是否注册登录自启（Mongo/Neo4j 已是登录服务；MySQL 保持 ad-hoc run）
    var startPersistsAtLogin: Bool {
        switch self {
        case .mongodb, .neo4j: return true
        case .mysql: return false
        }
    }

    /// 客户端命令行工具名（列表库用）
    var clientTool: String? {
        switch self {
        case .mongodb: return "mongosh"
        case .mysql: return "mysql"
        case .neo4j: return "cypher-shell"
        }
    }

    /// 客户端工具的候选绝对路径。GUI 应用的 PATH 不含 Homebrew 目录，
    /// 所以 `which` 不可靠 —— 已知路径优先，最后才回退到 `which`。
    var clientToolCandidates: [String] {
        switch self {
        case .mongodb:
            return ["/opt/homebrew/bin/mongosh",
                    "/usr/local/bin/mongosh",
                    "/opt/homebrew/opt/mongodb-community/bin/mongosh"]
        case .mysql:
            return ["/opt/homebrew/bin/mysql",
                    "/usr/local/bin/mysql",
                    "/opt/homebrew/opt/mysql-client/bin/mysql",
                    "/opt/homebrew/opt/mysql/bin/mysql"]
        case .neo4j:
            return ["/opt/homebrew/bin/cypher-shell",
                    "/usr/local/bin/cypher-shell",
                    "/opt/homebrew/opt/neo4j/bin/cypher-shell"]
        }
    }
}

/// 库列表来源（live = 服务器实时查询；disk = 停止时读数据目录）。
enum LocalDBDatabasesSource: Equatable {
    case none
    case live
    case disk
}

/// 命令失败的原因。可识别的情形附带可操作的修复动作（UI 据此显示按钮）。
enum LocalDBCommandFailure: Equatable, Sendable {
    /// Homebrew 4.6+ 拒绝加载第三方 tap 中的 formula（需要 `brew trust`）。
    case untrustedTap(tap: String, formula: String, command: String)
    /// 找不到该数据库的命令行客户端。
    case clientMissing(tool: String)
    /// 其它（保留完整 stderr/stdout 文本）。
    case other(String)
}

/// 单个数据库的运行期状态（@Observable，便于 SwiftUI 观察每一项）。
@MainActor
@Observable
final class LocalDBServiceState: Identifiable {
    let id: LocalDBID
    var running = false
    var pid: Int?
    var uptimeSeconds: Int?
    var databases: [String] = []
    var databasesSource = LocalDBDatabasesSource.none
    var databasesExpanded = false
    var databasesLoading = false
    var working = false       // start / stop 执行中
    var error: String?
    /// 结构化失败原因（可驱动“信任 Tap / 重试”等修复按钮）。
    var failure: LocalDBCommandFailure?
    /// 失败前正在执行的 brew 动作（start / run / stop），用于重试。
    var retryableAction: String?

    init(id: LocalDBID) {
        self.id = id
    }
}

// MARK: - Local DB Manager

/// 本地数据库（MongoDB / MySQL / Neo4j）状态与开关控制。
///
/// 与 CloudflareTunnelManager 同构：@Observable、@MainActor、自己的定时刷新 +
/// 健康探测（运行↔停止切换时发通知）、SecureStore 凭据、UserDefaults 持久化。
/// 命令均通过 `brew services`（用户级，无需管理员密码）与各数据库客户端执行。
@MainActor
@Observable
final class LocalDBManager {

    // MARK: 常量（nonisolated：后台探测/命令需在非主线程访问）

    private nonisolated static let commandTimeout: TimeInterval = 90
    private nonisolated static let healthProbeInterval: UInt64 = 30_000_000_000   // 30s
    private nonisolated static let alertCooldown: TimeInterval = 180

    private static var brewPathCache: String?

    // MARK: 任务 / 探测状态

    private var refreshTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var suppressAlertUntil: Date?
    private var wasUp: [LocalDBID: Bool] = [:]
    private var lastDownFiredAt: [LocalDBID: Date] = [:]
    private var lastRestoredFiredAt: [LocalDBID: Date] = [:]
    /// 每个服务最后一次失败的 brew 动作（start / run / stop），用于“重试”。
    private var lastFailedAction: [LocalDBID: String] = [:]

    // MARK: 可观察状态

    private(set) var services: [LocalDBServiceState]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"
    private(set) var actionMessage: String?
    private(set) var actionSuccess = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        services = LocalDBID.allCases.map { LocalDBServiceState(id: $0) }
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

    // MARK: Settings (persisted)

    var isEnabled: Bool { enabled }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Strings.Keys.localDBsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.localDBsEnabled) }
    }

    var notifyEnabled: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.localDBsNotifyEnabled) as? Bool) ?? true
    }

    var mysqlUser: String {
        UserDefaults.standard.string(forKey: Strings.Keys.localDBsMySQLUser) ?? ""
    }
    func setMySQLUser(_ value: String) {
        UserDefaults.standard.set(value, forKey: Strings.Keys.localDBsMySQLUser)
    }
    var mysqlPassword: String {
        SecureStore.retrieve(key: Strings.Keys.localDBsMySQLPassword) ?? ""
    }
    func setMySQLPassword(_ value: String) {
        SecureStore.save(key: Strings.Keys.localDBsMySQLPassword, value: value)
    }

    var neo4jUser: String {
        UserDefaults.standard.string(forKey: Strings.Keys.localDBsNeo4jUser) ?? ""
    }
    func setNeo4jUser(_ value: String) {
        UserDefaults.standard.set(value, forKey: Strings.Keys.localDBsNeo4jUser)
    }
    var neo4jPassword: String {
        SecureStore.retrieve(key: Strings.Keys.localDBsNeo4jPassword) ?? ""
    }
    func setNeo4jPassword(_ value: String) {
        SecureStore.save(key: Strings.Keys.localDBsNeo4jPassword, value: value)
    }

    // MARK: 辅助

    func service(_ id: LocalDBID) -> LocalDBServiceState {
        services.first { $0.id == id } ?? LocalDBServiceState(id: id)
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

    /// 健康探测：仅做状态更新 + 切换告警（比整表刷新更频繁、更快）。
    func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Self.healthProbeInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled { await self.probeAll(alert: true) }
            }
        }
    }

    /// 主入口：探测全部服务的运行状态 + uptime。被 Settings toggle / 定时器 / 手动刷新调用。
    func refresh() {
        guard isEnabled else {
            errorMessage = "not configured"
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            await performRefresh()
        }
    }

    /// 设置里「检查状态」（等待完成）。
    func checkNow() async {
        guard isEnabled else { return }
        isLoading = true
        errorMessage = nil
        await performRefresh()
    }

    private func performRefresh() async {
        await probeAll(alert: false)
        isLoading = false
        lastUpdate = Self.timeFormatter.string(from: Date())
    }

    // MARK: - 探测

    /// 后台同步探测（端口 + socket）—— 实现见 `PortProbe`。
    private nonisolated static func probeSync(_ id: LocalDBID) -> PortProbe.Result {
        PortProbe.probe(port: id.port, sockets: id.sockets)
    }

    private func probeAll(alert: Bool) async {
        for state in services {
            let id = state.id
            let probe = await Task.detached(priority: .userInitiated) {
                LocalDBManager.probeSync(id)
            }.value
            state.running = probe.running
            state.pid = probe.pid
            if probe.running, let pid = probe.pid {
                let secs = await Task.detached(priority: .utility) {
                    PortProbe.uptime(pid: pid)
                }.value
                state.uptimeSeconds = secs
            } else {
                state.uptimeSeconds = nil
            }
            if alert { detectTransition(id, nowUp: state.running) }
        }
    }

    /// 仅在「已知状态」发生切换时发告警，避免周期性刷屏；用户 Start/Stop 后由
    /// `wasUp` 与 `suppressAlertUntil` 双重抑制。
    private func detectTransition(_ id: LocalDBID, nowUp: Bool) {
        guard let prev = wasUp[id] else {
            wasUp[id] = nowUp
            return
        }
        wasUp[id] = nowUp
        guard prev != nowUp else { return }
        let name = Strings.localDBName(id.rawValue)
        if nowUp {
            fireRestoredIfAllowed(id, name: name)
        } else {
            fireDownIfAllowed(id, name: name)
        }
    }

    private func fireDownIfAllowed(_ id: LocalDBID, name: String) {
        guard notifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastDownFiredAt[id], Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastDownFiredAt[id] = Date()
        AppAlertCenter.fire(.dbDown,
                            title: String(format: Strings.dbDownTitle, name),
                            body: String(format: Strings.dbDownBody, name))
    }

    private func fireRestoredIfAllowed(_ id: LocalDBID, name: String) {
        guard notifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastRestoredFiredAt[id], Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastRestoredFiredAt[id] = Date()
        AppAlertCenter.fire(.dbRestored,
                            title: String(format: Strings.dbRestoredTitle, name),
                            body: String(format: Strings.dbRestoredBody, name))
    }

    // MARK: - Start / Stop（brew services）

    /// 执行一次 `brew services <verb> <formula>`；失败时分类记录并返回 false。
    private func runBrewServiceAction(_ verb: String, _ id: LocalDBID, brew: String) async -> Bool {
        let r = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(launchPath: brew, args: ["services", verb, id.formula],
                              timeout: LocalDBManager.commandTimeout)
        }.value
        guard r.status == 0 else {
            let failure = Self.classify(r, id: id)
            let text = Self.failureText(failure)
            let state = service(id)
            state.failure = failure
            state.error = text
            state.retryableAction = verb
            lastFailedAction[id] = verb
            state.working = false
            actionMessage = text
            actionSuccess = false
            return false
        }
        return true
    }

    /// 成功路径：清掉失败 / 重试标记。
    private func clearFailure(_ id: LocalDBID) {
        let state = service(id)
        state.failure = nil
        state.error = nil
        state.retryableAction = nil
        lastFailedAction[id] = nil
    }

    /// 重试上一次失败的 brew 动作（由「重试」按钮调用）。
    func retryLastAction(_ id: LocalDBID) {
        let state = service(id)
        guard isEnabled, !state.working else { return }
        guard let verb = lastFailedAction[id] ?? state.retryableAction else { return }
        switch verb {
        case "start", "run": start(id)
        case "stop": stop(id)
        default: break
        }
    }

    /// 运行 `brew trust`（先按 formula，失败则信任整个 tap），完成后重试失败的动作。
    /// 仅在用户点击「信任 Tap」时调用 —— dev_mon 不会自行改动 Homebrew 的信任状态。
    func trustTap(_ id: LocalDBID) {
        let state = service(id)
        guard isEnabled, !state.working,
              case .untrustedTap(let tap, let formula, _)? = state.failure else { return }
        guard let brew = Self.brewPath() else {
            state.error = Strings.localDBBrewMissing
            return
        }
        state.working = true
        state.error = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                let direct = ProcessRunner.run(launchPath: brew,
                                               args: ["trust", "--formula", formula],
                                               timeout: LocalDBManager.commandTimeout)
                if direct.status == 0 { return direct }
                // 回退：信任整个 tap（覆盖该 tap 下的其它 formula）。
                return ProcessRunner.run(launchPath: brew,
                                         args: ["trust", "--tap", tap],
                                         timeout: LocalDBManager.commandTimeout)
            }.value
            state.working = false
            guard r.status == 0 else {
                let text = Strings.dbTrustFailed + "：" + Self.shellMessage(r)
                state.failure = .other(text)
                state.error = text
                actionMessage = text
                actionSuccess = false
                return
            }
            // 清掉失败状态但保留待重试动作，然后重跑它。
            state.failure = nil
            state.error = nil
            actionMessage = nil
            retryLastAction(id)
        }
    }

    func start(_ id: LocalDBID) {
        let state = service(id)
        guard isEnabled, !state.working else { return }
        state.working = true
        state.error = nil
        guard let brew = Self.brewPath() else {
            state.working = false
            state.error = Strings.localDBBrewMissing
            return
        }
        Task {
            let verb = id.startPersistsAtLogin ? "start" : "run"
            guard await runBrewServiceAction(verb, id, brew: brew) else { return }
            clearFailure(id)
            // 等待监听端口起来（MySQL/Neo4j 启动需要数秒）。
            var up = false
            for _ in 0..<13 {
                try? await Task.sleep(for: .milliseconds(2000))
                let probe = await Task.detached(priority: .userInitiated) {
                    LocalDBManager.probeSync(id)
                }.value
                if probe.running {
                    up = true
                    state.running = true
                    state.pid = probe.pid
                    if let pid = probe.pid {
                        let secs = await Task.detached(priority: .utility) {
                            PortProbe.uptime(pid: pid)
                        }.value
                        state.uptimeSeconds = secs
                    }
                    wasUp[id] = true
                    suppressAlertUntil = Date().addingTimeInterval(30)
                    break
                }
            }
            state.working = false
            if up {
                actionMessage = String(format: Strings.localDBStarted, Strings.localDBName(id.rawValue))
                actionSuccess = true
            } else {
                actionMessage = String(format: Strings.localDBStartFailed, Strings.localDBName(id.rawValue))
                actionSuccess = false
            }
        }
    }

    func stop(_ id: LocalDBID) {
        let state = service(id)
        guard isEnabled, !state.working else { return }
        state.working = true
        state.error = nil
        guard let brew = Self.brewPath() else {
            state.working = false
            state.error = Strings.localDBBrewMissing
            return
        }
        Task {
            guard await runBrewServiceAction("stop", id, brew: brew) else { return }
            clearFailure(id)
            var stillRunning = true
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(1000))
                let probe = await Task.detached(priority: .userInitiated) {
                    LocalDBManager.probeSync(id)
                }.value
                if !probe.running {
                    stillRunning = false
                    break
                }
            }
            // 以最后一次探测为准 —— 不无条件当作已停止。
            state.running = stillRunning
            state.pid = nil
            state.uptimeSeconds = nil
            wasUp[id] = stillRunning
            suppressAlertUntil = Date().addingTimeInterval(30)
            state.working = false
            if stillRunning {
                state.databases = []
                state.databasesSource = .none
                let text = String(format: Strings.dbStopIncomplete, Strings.localDBName(id.rawValue))
                state.failure = .other(text)
                state.error = text
                state.retryableAction = "stop"
                lastFailedAction[id] = "stop"
                actionMessage = text
                actionSuccess = false
            } else {
                state.databases = []
                state.databasesSource = .none
                actionMessage = String(format: Strings.localDBStopped, Strings.localDBName(id.rawValue))
                actionSuccess = true
            }
        }
    }

    private static func brewPath() -> String? {
        if let cached = brewPathCache { return cached }
        // 已知路径优先：GUI 应用的 PATH 里没有 /opt/homebrew/bin。
        let found = ProcessRunner.firstExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                                                  fallbackName: "brew")
        brewPathCache = found
        return found
    }

    /// 命令失败原文（保留完整可操作信息，仅压缩空行 + 宽松上限）。
    private nonisolated static func shellMessage(_ r: (status: Int32, stdout: String, stderr: String)) -> String {
        let msg = normalize(r.stderr.isEmpty ? r.stdout : r.stderr)
        if !msg.isEmpty {
            return msg.count > 600 ? String(msg.prefix(600)) + "…" : msg
        }
        return "brew exit \(r.status)"
    }

    // MARK: - 失败分类（驱动可操作的修复 UI）

    /// 把 stderr/stdout 归类为可处理的失败原因。
    private nonisolated static func classify(_ r: (status: Int32, stdout: String, stderr: String),
                                             id: LocalDBID) -> LocalDBCommandFailure {
        let text = normalize(r.stderr.isEmpty ? r.stdout : r.stderr)
        // Homebrew 4.6+：`Refusing to load formula <formula> from untrusted tap <tap>.`
        if let formula = firstCapture(#"Refusing to load formula\s+(\S+)"#, in: text) {
            let tap = firstCapture(#"from untrusted tap\s+([^\s.]+)"#, in: text)
                ?? formula.split(separator: "/").prefix(2).joined(separator: "/")
            return .untrustedTap(tap: tap,
                                 formula: formula,
                                 command: "brew trust --formula \(formula)")
        }
        return .other(text.isEmpty ? "brew exit \(r.status)" : text)
    }

    /// 失败原因的展示文本。
    private nonisolated static func failureText(_ failure: LocalDBCommandFailure) -> String {
        switch failure {
        case .untrustedTap(_, let formula, let command):
            return Strings.dbUntrustedTapError(formula, command)
        case .clientMissing(let tool):
            return Strings.localDBClientMissing(tool)
        case .other(let text):
            return text
        }
    }

    /// 压掉空行、去掉行首尾空白（保留行结构，便于阅读命令）。
    private nonisolated static func normalize(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return collapsed.isEmpty ? s.trimmingCharacters(in: .whitespacesAndNewlines) : collapsed
    }

    private nonisolated static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - 数据库列表

    private struct DBCredential: Sendable {
        var user: String = ""
        var password: String = ""
    }

    private func credential(for id: LocalDBID) -> DBCredential {
        switch id {
        case .mongodb:
            return DBCredential()
        case .mysql:
            let u = mysqlUser.isEmpty ? "root" : mysqlUser
            return DBCredential(user: u, password: mysqlPassword)
        case .neo4j:
            return DBCredential(user: neo4jUser, password: neo4jPassword)
        }
    }

    /// 展开/收起某个服务的库列表。展开即拉取（运行中→实时查询；停止→磁盘目录）。
    func toggleDatabases(_ id: LocalDBID) {
        let state = service(id)
        state.databasesExpanded.toggle()
        if state.databasesExpanded {
            refreshDatabases(id)
        } else {
            state.databases = []
            state.databasesSource = .none
            state.error = nil
        }
    }

    func refreshDatabases(_ id: LocalDBID) {
        let state = service(id)
        guard isEnabled, !state.databasesLoading else { return }
        state.databasesLoading = true
        state.error = nil
        Task {
            let running = state.running
            let cred = credential(for: id)
            let result = await Task.detached(priority: .userInitiated) {
                LocalDBManager.listDatabasesSync(id, running: running, cred: cred)
            }.value
            let dbs = result.0
            let message = result.1
            if let message {
                // 运行中查询失败（如凭据错误）时回退到磁盘目录并保留错误提示。
                state.databases = LocalDBManager.listOnDisk(id)
                state.databasesSource = .disk
                state.error = message
            } else {
                state.databases = dbs
                state.databasesSource = running ? .live : .disk
            }
            state.databasesLoading = false
        }
    }

    private nonisolated static func listDatabasesSync(_ id: LocalDBID, running: Bool,
                                          cred: DBCredential) -> ([String], String?) {
        if !running { return (listOnDisk(id), nil) }
        guard let tool = id.clientTool,
              let bin = ProcessRunner.firstExecutable(id.clientToolCandidates, fallbackName: tool) else {
            return ([], Strings.localDBClientMissing(id.clientTool ?? "-"))
        }
        let r: (status: Int32, stdout: String, stderr: String)
        switch id {
        case .mongodb:
            // JSON.stringify：mongosh 默认打印 JS 风格数组，直接解析会失败。
            let eval = "JSON.stringify(db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name))"
            r = ProcessRunner.run(launchPath: bin, args: ["--quiet", "--eval", eval],
                                  timeout: commandTimeout)
        case .mysql:
            var args = ["--batch", "--skip-column-names", "-h", "127.0.0.1", "-P", "3306"]
            args += ["-u", cred.user]
            if !cred.password.isEmpty { args += ["-p\(cred.password)"] }
            args += ["-e", "SHOW DATABASES"]
            r = ProcessRunner.run(launchPath: bin, args: args, timeout: commandTimeout)
        case .neo4j:
            var args = ["-a", "bolt://localhost:7687"]
            if !cred.user.isEmpty { args += ["-u", cred.user] }
            if !cred.password.isEmpty { args += ["-p", cred.password] }
            args += ["SHOW DATABASES"]
            r = ProcessRunner.run(launchPath: bin, args: args, timeout: commandTimeout)
        }
        guard r.status == 0 else { return ([], shellMessage(r)) }
        return (parseDBOutput(id, stdout: r.stdout), nil)
    }

    private nonisolated static func parseDBOutput(_ id: LocalDBID, stdout: String) -> [String] {
        let lines = stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var names: [String] = []
        for line in lines {
            guard !line.isEmpty else { continue }
            switch id {
            case .mongodb:
                // mongosh JSON.stringify 输出：`["admin","config","local"]`。
                if names.isEmpty {
                    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let data = trimmed.data(using: .utf8)
                    if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                        names = arr
                    } else if let data,
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let dbs = obj["databases"] as? [[String: Any]] {
                        names = dbs.compactMap { $0["name"] as? String }
                    } else {
                        // 回退：旧版/未 stringify 的 `[ 'admin', 'config' ]` 输出。
                        names = parseJSStyleArray(trimmed)
                    }
                }
            case .mysql:
                names.append(line)
            case .neo4j:
                // cypher-shell 的表格输出：跳过列名与分隔线。
                let lower = line.lowercased()
                if lower == "name" { continue }
                if line.allSatisfy({ $0 == "-" || $0 == "=" || $0 == " " }) { continue }
                names.append(line)
            }
        }
        return Array(Set(names)).sorted()
    }

    /// 解析 mongosh 默认打印的 JS 风格数组：`[ 'admin', 'config', 'local' ]`。
    private nonisolated static func parseJSStyleArray(_ s: String) -> [String] {
        guard s.hasPrefix("["), s.hasSuffix("]") else { return [] }
        return s.dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"\t\n")) }
            .filter { !$0.isEmpty }
    }

    /// 磁盘上已存在的库（目录即库；跳过系统/临时目录与隐藏项）。
    ///
    /// MongoDB 需要额外过滤：数据目录里绝大多数条目是 WiredTiger 引擎内部
    /// （`diagnostic.data`、`journal`、`WiredTiger*`、`_mdb_catalog.wt`、
    /// `collection-N.wt`、`index-N.wt`），真正的库是 `<name>/` 目录或 `<name>.wt`。
    private nonisolated static func listOnDisk(_ id: LocalDBID) -> [String] {
        var result: [String] = []
        for dir in id.dataDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                atPath: dir).sorted() else { continue }
            for name in entries {
                var isDir: ObjCBool = false
                let path = (dir as NSString).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if let db = onDiskDatabaseName(name, id: id, isDirectory: true) {
                        result.append(db)
                    }
                } else if id == .mongodb, name.hasSuffix(".wt") {
                    if let db = onDiskDatabaseName(name, id: id, isDirectory: false) {
                        result.append(db)
                    }
                }
            }
        }
        return Array(Set(result)).sorted()
    }

    /// 目录项 → 库名；返回 nil 表示这是引擎内部文件/目录，不是数据库。
    private nonisolated static func onDiskDatabaseName(_ name: String, id: LocalDBID,
                                                      isDirectory: Bool) -> String? {
        guard !name.hasPrefix("."), !name.hasPrefix("#") else { return nil }
        switch id {
        case .mongodb:
            let internals: Set<String> = [
                "diagnostic.data", "journal", "mongod.lock", "storage.bson",
                "WiredTiger.lock", "WiredTiger.turtle", "WiredTiger.wt",
                "WiredTigerHS.wt", "_mdb_catalog.wt", "sizeStorer.wt", "lost+found",
            ]
            if internals.contains(name) { return nil }
            if name.hasPrefix("_") || name.hasPrefix("collection-")
                || name.hasPrefix("index-") || name.hasPrefix("WiredTiger") {
                return nil
            }
            if name.hasSuffix(".wt") {
                let base = String(name.dropLast(3))
                return base.isEmpty ? nil : base
            }
            return isDirectory ? name : nil
        case .mysql, .neo4j:
            guard isDirectory else { return nil }
            return name
        }
    }
}
