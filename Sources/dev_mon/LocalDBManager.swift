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
}

/// 库列表来源（live = 服务器实时查询；disk = 停止时读数据目录）。
enum LocalDBDatabasesSource: Equatable {
    case none
    case live
    case disk
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

    private nonisolated static let probeTimeout: TimeInterval = 5
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

    private struct ProbeResult: Sendable {
        var running = false
        var pid: Int?
    }

    /// 后台同步探测：lsof 端口监听优先，其次 unix socket。
    private nonisolated static func probeSync(_ id: LocalDBID) -> ProbeResult {
        let lsof = ProcessRunner.run(launchPath: "/usr/sbin/lsof",
                                     args: ["-nP", "-iTCP:\(id.port)", "-sTCP:LISTEN", "-t"],
                                     timeout: probeTimeout)
        if lsof.status == 0 {
            if let line = lsof.stdout.split(separator: "\n").first,
               let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                return ProbeResult(running: true, pid: pid)
            }
        }
        let anySocket = id.sockets.contains { FileManager.default.fileExists(atPath: $0) }
        return ProbeResult(running: anySocket, pid: nil)
    }

    private nonisolated static func uptimeSecondsSync(pid: Int) -> Int? {
        let ps = ProcessRunner.run(launchPath: "/bin/ps", args: ["-p", "\(pid)", "-o", "etime="],
                                   timeout: probeTimeout)
        guard ps.status == 0 else { return nil }
        return parseEtime(ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 解析 ps etime：`[[dd-]hh:]mm:ss`。
    nonisolated static func parseEtime(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        var days = 0
        var rest = s
        if let dash = s.firstIndex(of: "-"), let d = Int(s[..<dash]) {
            days = d
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        switch parts.count {
        case 1: seconds = parts[0]
        case 2: seconds = parts[0] * 60 + parts[1]
        default: seconds = parts[parts.count - 3] * 3600 + parts[parts.count - 2] * 60 + parts[parts.count - 1]
        }
        return days * 86400 + seconds
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
                    LocalDBManager.uptimeSecondsSync(pid: pid)
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
            let action = id.startPersistsAtLogin ? "start" : "run"
            let r = await Task.detached(priority: .userInitiated) {
                ProcessRunner.run(launchPath: brew, args: ["services", action, id.formula],
                                  timeout: LocalDBManager.commandTimeout)
            }.value
            guard r.status == 0 else {
                state.working = false
                state.error = Self.shellMessage(r)
                return
            }
            // 等待监听端口起来（MySQL/Neo4j 启动需要数秒）。
            for _ in 0..<13 {
                try? await Task.sleep(for: .milliseconds(2000))
                let probe = await Task.detached(priority: .userInitiated) {
                    LocalDBManager.probeSync(id)
                }.value
                if probe.running {
                    state.running = true
                    state.pid = probe.pid
                    if let pid = probe.pid {
                        let secs = await Task.detached(priority: .utility) {
                            LocalDBManager.uptimeSecondsSync(pid: pid)
                        }.value
                        state.uptimeSeconds = secs
                    }
                    wasUp[id] = true
                    suppressAlertUntil = Date().addingTimeInterval(30)
                    break
                }
            }
            state.working = false
            if state.running {
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
            let r = await Task.detached(priority: .userInitiated) {
                ProcessRunner.run(launchPath: brew, args: ["services", "stop", id.formula],
                                  timeout: LocalDBManager.commandTimeout)
            }.value
            if r.status != 0 {
                state.working = false
                state.error = Self.shellMessage(r)
                return
            }
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(1000))
                let probe = await Task.detached(priority: .userInitiated) {
                    LocalDBManager.probeSync(id)
                }.value
                if !probe.running { break }
            }
            state.running = false
            state.pid = nil
            state.uptimeSeconds = nil
            state.databases = []
            state.databasesSource = .none
            wasUp[id] = false
            suppressAlertUntil = Date().addingTimeInterval(30)
            state.working = false
            actionMessage = String(format: Strings.localDBStopped, Strings.localDBName(id.rawValue))
            actionSuccess = true
        }
    }

    private static func brewPath() -> String? {
        if let cached = brewPathCache { return cached }
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? ProcessRunner.which("brew")
        brewPathCache = found
        return found
    }

    private nonisolated static func shellMessage(_ r: (status: Int32, stdout: String, stderr: String)) -> String {
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty { return String(msg.prefix(240)) }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return String(out.prefix(240)) }
        return "brew exit \(r.status)"
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
              let bin = ProcessRunner.which(tool) else {
            return ([], Strings.localDBClientMissing(id.clientTool ?? "-"))
        }
        let r: (status: Int32, stdout: String, stderr: String)
        switch id {
        case .mongodb:
            let eval = "db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name)"
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
                // mongosh JSON 输出：尝试整体解析。
                if names.isEmpty,
                   let data = stdout.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dbs = obj["databases"] as? [[String: Any]] {
                    names = dbs.compactMap { $0["name"] as? String }
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

    /// 磁盘上已存在的库（目录即库；跳过系统/临时目录与隐藏项）。
    private nonisolated static func listOnDisk(_ id: LocalDBID) -> [String] {
        var result: [String] = []
        for dir in id.dataDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                atPath: dir).sorted() else { continue }
            for name in entries {
                guard !name.hasPrefix("."), !name.hasPrefix("#") else { continue }
                var isDir: ObjCBool = false
                let path = (dir as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                result.append(name)
            }
        }
        return Array(Set(result)).sorted()
    }
}
