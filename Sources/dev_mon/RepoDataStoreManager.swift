import Foundation
import AppKit
import SQLite3

// MARK: - 类型

/// 仓库数据存储的种类。刻意不局限于 SQL 服务器 —— 这些仓库里大量的“数据库”
/// 其实是 SQLite 文件、向量库、JSONL 队列或外部系统（Trello）。
enum RepoStoreKind: String, Codable, CaseIterable, Sendable {
    case sqlite
    case chroma
    case jsonl
    case jsonState
    case remote
}

/// 描述符的来源，用于在 UI 上标注“为什么它出现在这里”。
enum RepoStoreSource: String, Codable, Sendable {
    case manifest      // 仓库根目录的 devmon.json
    case dotenv        // .env 里声明的路径
    case glob          // 按文件名模式扫描到
    case knownDir      // 已知目录（storage/、logs/…）
}

/// 一个仓库数据存储的描述（可缓存、可 Codable）。
struct RepoStoreDescriptor: Identifiable, Sendable, Equatable, Codable {
    var id: String
    var repoPath: String
    var repoName: String
    var relPath: String          // 相对仓库根；remote 为空
    var label: String
    var kind: RepoStoreKind
    var source: RepoStoreSource
    var port: Int?
    var pidFile: String?
    var triggerFile: String?
    var capBytes: Int64?
    /// 敏感存储（如语音指纹库）：只显示总量，绝不显示表名/行内容。
    var sensitive: Bool
    /// manifest 声明的表名（用于计数）。
    var tables: [String]

    var fullPath: String {
        relPath.isEmpty ? repoPath : (repoPath as NSString).appendingPathComponent(relPath)
    }
}

/// 计数行（UI 里一行 `label  value`）。
struct RepoStoreCount: Identifiable, Sendable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    var isWarning = false
}

/// 仓库自带服务的健康信息（manifest 的 `service` 块）。
struct RepoServiceInfo: Sendable, Equatable, Codable {
    var port: Int?
    var pidFile: String?
    var triggerFile: String?
}

/// 扫描结果：一个仓库 + 它的存储 + 它的服务。
struct RepoDiscovery: Sendable {
    var path: String
    var name: String
    var stores: [RepoStoreDescriptor]
    var service: RepoServiceInfo?
}

// MARK: - 可观察状态

/// 单个仓库分组的运行期状态。
@MainActor
@Observable
final class RepoStoreGroup: Identifiable {
    let id: String
    let repoName: String
    let repoPath: String
    let service: RepoServiceInfo?

    var stores: [RepoStoreState] = []
    var expanded = true
    /// 仓库自带服务（如 5001 的 FastAPI 后端、3199 的 webhook）是否在监听。
    var serviceUp = false
    var serviceUptimeSeconds: Int?

    init(path: String, name: String, service: RepoServiceInfo?) {
        self.id = path
        self.repoPath = path
        self.repoName = name
        self.service = service
    }
}

/// 单个存储的运行期状态。
@MainActor
@Observable
final class RepoStoreState: Identifiable {
    let descriptor: RepoStoreDescriptor
    let id: String

    var exists = false
    var sizeBytes: Int64?
    var modifiedAt: Date?
    /// SQLite 的 `-wal`/`-shm` 存在 → 说明当前有进程在写。
    var inUse = false

    var counts: [RepoStoreCount] = []
    var countsLoaded = false
    var countsExpanded = false
    var countsLoading = false

    var working = false
    var error: String?

    init(descriptor: RepoStoreDescriptor) {
        self.descriptor = descriptor
        self.id = descriptor.id
    }
}

// MARK: - Manager

/// 仓库数据存储（Repo Data Stores）。
///
/// 与 `LocalDBManager` 同构：`@Observable` + `@MainActor`、自己的定时刷新 +
/// 健康探测（切换时发通知）、UserDefaults 持久化、命令走 `ProcessRunner`。
///
/// 发现顺序：仓库根目录的 `devmon.json`（精确）→ `.env` 声明的路径 → 已知目录 /
/// 文件名模式（尽力而为）。**只读**：只做 stat / 只读 SQLite 查询，绝不写入仓库，
/// 也绝不读取 `config.json`、`.env` 的值、`safe/` 下的密钥文件内容。
@MainActor
@Observable
final class RepoDataStoreManager {

    // MARK: 常量（nonisolated：后台扫描/查询需在非主线程访问）

    private nonisolated static let commandTimeout: TimeInterval = 90
    private nonisolated static let healthProbeInterval: UInt64 = 30_000_000_000   // 30s
    private nonisolated static let defaultRescanInterval: TimeInterval = 300      // 5min
    private nonisolated static let alertCooldown: TimeInterval = 180
    /// 解析 JSONL 行数的体积上限（超过只报大小，避免读入巨大文件）。
    private nonisolated static let maxJSONLParseBytes: Int64 = 32 * 1024 * 1024

    /// 扫描时跳过的目录名（构建产物 / 依赖 / 缓存）。
    nonisolated static let skipDirectoryNames: Set<String> = [
        "node_modules", ".venv", "venv", "env", "dist", "build", "target", "vendor",
        ".next", ".git", "Pods", "DerivedData", "__pycache__", "dist-resources",
        ".build", "out", "obj", "bin", "coverage", ".turbo", ".cache",
    ]

    /// 永不读取内容的本文件名（密钥/机密）。
    nonisolated static let neverReadFileNames: Set<String> = ["config.json", ".env", ".env.local"]

    // MARK: 任务 / 探测状态

    private var healthTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var suppressAlertUntil: Date?
    private var lastScanAt = Date.distantPast
    private var wasUp: [String: Bool] = [:]
    private var lastDownFiredAt: [String: Date] = [:]
    private var lastRestoredFiredAt: [String: Date] = [:]

    // MARK: 可观察状态

    private(set) var groups: [RepoStoreGroup] = []
    private(set) var isScanning = false
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
        if isEnabled {
            startAutoRefresh()
            refresh()
        }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.healthTask?.cancel()
            self?.scanTask?.cancel()
        }
    }

    // MARK: Settings (persisted)

    var isEnabled: Bool { enabled }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Strings.Keys.repoStoresEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.repoStoresEnabled) }
    }

    var notifyEnabled: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.repoStoresNotifyEnabled) as? Bool) ?? true
    }

    /// 详情开关：关闭时只显示数量/大小，不显示表名。
    var showDetails: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.repoStoresShowDetails) as? Bool) ?? false
    }

    /// 是否包含“外部系统”行（如 Trello 这个 system of record）。
    var includeRemote: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.repoStoresIncludeRemote) as? Bool) ?? true
    }

    /// 扫描根目录（逗号或换行分隔）。
    var rootsRaw: String {
        UserDefaults.standard.string(forKey: Strings.Keys.repoStoresRoots) ?? Self.defaultRootValue
    }
    func setRootsRaw(_ value: String) {
        UserDefaults.standard.set(value, forKey: Strings.Keys.repoStoresRoots)
    }

    var roots: [String] {
        rootsRaw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated static var defaultRootValue: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/GitHub")
    }

    var maxDepth: Int {
        let v = UserDefaults.standard.integer(forKey: Strings.Keys.repoStoresDepth)
        return v >= 1 ? min(v, 6) : 3
    }
    func setMaxDepth(_ value: Int) {
        UserDefaults.standard.set(max(1, min(value, 6)), forKey: Strings.Keys.repoStoresDepth)
    }

    // MARK: 辅助

    func group(_ id: String) -> RepoStoreGroup? {
        groups.first { $0.id == id }
    }

    func store(_ id: String) -> RepoStoreState? {
        for g in groups {
            if let s = g.stores.first(where: { $0.id == id }) { return s }
        }
        return nil
    }

    // MARK: - 刷新 / 扫描

    func startAutoRefresh() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Self.healthProbeInterval))
                guard !Task.isCancelled, let self else { return }
                guard self.isEnabled else { continue }
                await self.probeAll(alert: true)
                if Date().timeIntervalSince(self.lastScanAt) > Self.defaultRescanInterval {
                    self.refresh()
                }
            }
        }
    }

    /// 重新扫描仓库（结构可能变化）。健康探测由定时器负责。
    func refresh() {
        guard isEnabled else {
            errorMessage = "not configured"
            isLoading = false
            return
        }
        guard !isScanning else { return }
        isScanning = true
        isLoading = true
        errorMessage = nil
        let roots = self.roots
        let depth = self.maxDepth
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .utility) {
                RepoDataStoreManager.scan(roots: roots, maxDepth: depth)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(discovered)
            self.isScanning = false
            self.isLoading = false
            self.lastUpdate = Self.timeFormatter.string(from: Date())
            self.lastScanAt = Date()
            await self.probeAll(alert: false)
        }
    }

    /// 设置里的「立即扫描」（等待完成）。
    func scanNow() async {
        guard isEnabled else { return }
        let roots = self.roots
        let depth = self.maxDepth
        isScanning = true
        isLoading = true
        errorMessage = nil
        let discovered = await Task.detached(priority: .utility) {
            RepoDataStoreManager.scan(roots: roots, maxDepth: depth)
        }.value
        apply(discovered)
        isScanning = false
        isLoading = false
        lastUpdate = Self.timeFormatter.string(from: Date())
        lastScanAt = Date()
        await probeAll(alert: false)
    }

    /// 把扫描结果并回现有状态（保留已展开的计数，避免每次刷新都闪）。
    private func apply(_ discovered: [RepoDiscovery]) {
        let previous = Dictionary(uniqueKeysWithValues: groups.flatMap { g in
            g.stores.map { ($0.id, $0) }
        })
        var result: [RepoStoreGroup] = []
        for repo in discovered {
            let stores = repo.stores.filter { includeRemote || $0.kind != .remote }
            guard !stores.isEmpty else { continue }
            let group = RepoStoreGroup(path: repo.path, name: repo.name, service: repo.service)
            group.stores = stores.map { d -> RepoStoreState in
                if let old = previous[d.id], old.descriptor == d {
                    // 复用旧对象以保留展开状态与已加载的计数。
                    return old
                }
                return RepoStoreState(descriptor: d)
            }
            result.append(group)
        }
        groups = result.sorted { $0.repoName.localizedCaseInsensitiveCompare($1.repoName) == .orderedAscending }
    }

    // MARK: - 健康探测（文件存在性 + 大小 + 服务端口）

    private func probeAll(alert: Bool) async {
        let groups = self.groups
        let expandedIDs = Set(groups.flatMap { $0.stores.filter { $0.countsExpanded }.map { $0.id } })
        // stat 全部存储（轻量），计数只刷新已展开的行。
        // 注意：@MainActor 的组/行不能跨进 detached 任务 —— 先快照成 Sendable 值。
        let targets: [ProbeTarget] = groups.flatMap { group in
            group.stores.map { ProbeTarget(id: $0.id, descriptor: $0.descriptor) }
        }
        let probes = await Task.detached(priority: .userInitiated) { () -> [String: RepoDataStoreManager.StatResult] in
            var out: [String: RepoDataStoreManager.StatResult] = [:]
            for target in targets {
                out[target.id] = RepoDataStoreManager.stat(target.descriptor)
            }
            return out
        }.value

        for group in groups {
            for state in group.stores {
                guard let stat = probes[state.id] else { continue }
                state.exists = stat.exists
                state.sizeBytes = stat.sizeBytes
                state.modifiedAt = stat.modifiedAt
                state.inUse = stat.inUse
            }
        }

        // 服务探测（每个仓库一次）。
        for group in groups {
            guard let service = group.service else {
                group.serviceUp = false
                group.serviceUptimeSeconds = nil
                continue
            }
            let repoPath = group.repoPath
            let probe = await Task.detached(priority: .userInitiated) {
                RepoDataStoreManager.probeService(service, repoPath: repoPath)
            }.value
            let wasUpBefore = group.serviceUp
            group.serviceUp = probe.up
            group.serviceUptimeSeconds = probe.uptimeSeconds
            if alert, wasUpBefore != probe.up {
                detectServiceTransition(group, nowUp: probe.up)
            }
        }

        // 已展开的行：刷新计数。
        for group in groups {
            for state in group.stores where state.countsExpanded && expandedIDs.contains(state.id) {
                await loadCounts(state)
            }
        }
    }

    private func detectServiceTransition(_ group: RepoStoreGroup, nowUp: Bool) {
        guard let prev = wasUp[group.id] else {
            wasUp[group.id] = nowUp
            return
        }
        wasUp[group.id] = nowUp
        guard prev != nowUp else { return }
        if nowUp {
            fireRestoredIfAllowed(group)
        } else {
            fireDownIfAllowed(group)
        }
    }

    private func fireDownIfAllowed(_ group: RepoStoreGroup) {
        guard notifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastDownFiredAt[group.id], Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastDownFiredAt[group.id] = Date()
        AppAlertCenter.fire(.storeDegraded,
                            title: String(format: Strings.storeDownTitle, group.repoName),
                            body: String(format: Strings.storeDownBody, group.repoName))
    }

    private func fireRestoredIfAllowed(_ group: RepoStoreGroup) {
        guard notifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastRestoredFiredAt[group.id], Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastRestoredFiredAt[group.id] = Date()
        AppAlertCenter.fire(.storeRestored,
                            title: String(format: Strings.storeRestoredTitle, group.repoName),
                            body: String(format: Strings.storeRestoredBody, group.repoName))
    }

    // MARK: - 计数

    /// 展开/收起某个存储的计数（展开即拉取）。
    func toggleCounts(_ store: RepoStoreState) {
        store.countsExpanded.toggle()
        if store.countsExpanded {
            Task { await loadCounts(store) }
        } else {
            store.counts = []
            store.countsLoaded = false
            store.error = nil
        }
    }

    func loadCounts(_ store: RepoStoreState) async {
        guard isEnabled, !store.countsLoading else { return }
        store.countsLoading = true
        store.error = nil
        let descriptor = store.descriptor
        let details = showDetails
        let result = await Task.detached(priority: .userInitiated) {
            RepoDataStoreManager.counts(for: descriptor, showDetails: details)
        }.value
        store.counts = result.counts
        store.error = result.error
        store.countsLoaded = true
        store.countsLoading = false
    }

    // MARK: - 只读动作

    /// 备份到 `~/Backups/dev_mon/<repo>/`（绝不写入仓库）。
    func backup(_ store: RepoStoreState) {
        guard isEnabled, !store.working else { return }
        store.working = true
        let descriptor = store.descriptor
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RepoDataStoreManager.performBackup(descriptor)
            }.value
            store.working = false
            switch result {
            case .success(let url):
                actionMessage = String(format: Strings.storeBackupDone, url.path)
                actionSuccess = true
            case .failure(let message):
                actionMessage = message
                actionSuccess = false
            }
        }
    }

    func reveal(_ store: RepoStoreState) {
        let path = store.descriptor.fullPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 在终端里用 sqlite3 打开（仅 SQLite/Chroma）。
    func openInTerminal(_ store: RepoStoreState) {
        let path = store.descriptor.fullPath
        guard let sqlite3 = ProcessRunner.firstExecutable(
            ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"], fallbackName: "sqlite3") else {
            actionMessage = Strings.localDBClientMissing("sqlite3")
            actionSuccess = false
            return
        }
        let script = "tell application \"Terminal\" to do script \"\(sqlite3) \(shellQuoted(path))\""
        _ = ProcessRunner.run(launchPath: "/usr/bin/osascript", args: ["-e", script], timeout: 10)
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 扫描（nonisolated：后台线程）

    nonisolated static func scan(roots: [String], maxDepth: Int) -> [RepoDiscovery] {
        let fm = FileManager.default
        var out: [RepoDiscovery] = []
        for root in roots {
            let rootPath = (root as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: rootPath) else { continue }
            var queue: [(String, Int)] = [(rootPath, 0)]
            while let (dir, depth) = queue.popLast() {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                if entries.contains(".git"), let repo = describeRepo(at: dir) {
                    out.append(repo)
                    continue   // 不再深入仓库内部
                }
                guard depth < maxDepth else { continue }
                for name in entries where !name.hasPrefix(".") {
                    guard !skipDirectoryNames.contains(name) else { continue }
                    var isDir: ObjCBool = false
                    let child = (dir as NSString).appendingPathComponent(name)
                    if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                        queue.append((child, depth + 1))
                    }
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 仓库 → 存储描述符（manifest 优先，缺失时走启发式）。
    nonisolated static func describeRepo(at path: String) -> RepoDiscovery? {
        let name = (path as NSString).lastPathComponent
        var descriptors: [RepoStoreDescriptor] = []
        var service: RepoServiceInfo?

        if let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).appendingPathComponent("devmon.json"))),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            if let s = manifest.service {
                service = RepoServiceInfo(port: s.port, pidFile: s.pidFile, triggerFile: s.triggerFile)
            }
            for entry in manifest.stores ?? [] {
                guard let kindRaw = entry.kind,
                      let kind = RepoStoreKind(rawValue: kindRaw) else { continue }
                let rel = entry.path ?? ""
                if kind != .remote && rel.isEmpty { continue }
                descriptors.append(RepoStoreDescriptor(
                    id: "\(path)|\(kind.rawValue)|\(rel)",
                    repoPath: path,
                    repoName: name,
                    relPath: rel,
                    label: entry.label ?? defaultLabel(kind: kind, relPath: rel),
                    kind: kind,
                    source: .manifest,
                    port: entry.port,
                    pidFile: entry.pidFile,
                    triggerFile: entry.triggerFile,
                    capBytes: entry.capBytes,
                    sensitive: entry.sensitive ?? false,
                    tables: entry.tables ?? []))
            }
        }

        if descriptors.filter({ $0.kind != .remote }).isEmpty {
            descriptors.append(contentsOf: heuristicStores(repoPath: path, repoName: name))
        }
        guard !descriptors.isEmpty else { return nil }
        return RepoDiscovery(path: path, name: name, stores: descriptors, service: service)
    }

    /// 启发式发现：只处理明确的模式，避免误报。
    nonisolated static func heuristicStores(repoPath: String, repoName: String) -> [RepoStoreDescriptor] {
        let fm = FileManager.default
        var out: [RepoStoreDescriptor] = []
        var seen = Set<String>()

        func add(_ kind: RepoStoreKind, _ rel: String, _ label: String,
                 source: RepoStoreSource, sensitive: Bool = false, capBytes: Int64? = nil) {
            let trimmed = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, seen.insert("\(kind.rawValue)|\(trimmed)").inserted else { return }
            let abs = trimmed.hasPrefix("/") ? trimmed : (repoPath as NSString).appendingPathComponent(trimmed)
            guard fm.fileExists(atPath: abs) else { return }
            if neverReadFileNames.contains((trimmed as NSString).lastPathComponent) { return }
            out.append(RepoStoreDescriptor(
                id: "\(repoPath)|\(kind.rawValue)|\(trimmed)",
                repoPath: repoPath, repoName: repoName, relPath: trimmed, label: label,
                kind: kind, source: source, port: nil, pidFile: nil, triggerFile: nil,
                capBytes: capBytes, sensitive: sensitive, tables: []))
        }

        // .env 里声明的存储路径（只读我们关心的键，值不展示）。
        let env = readStorageEnv(repoPath: repoPath)
        if let storage = env["TRANSCRIPTION_STORAGE"] {
            for name in sqliteFilesIn(directory: storage) {
                add(.sqlite, (storage as NSString).appendingPathComponent(name),
                    (name as NSString).deletingPathExtension, source: .dotenv)
            }
        }
        if let voice = env["VOICEPRINT_DB_PATH"] {
            add(.sqlite, voice, "Voiceprints", source: .dotenv, sensitive: true)
        }
        if let logDir = env["LOG_DIR"] {
            for name in jsonlFilesIn(directory: (repoPath as NSString).appendingPathComponent(logDir)) {
                add(.jsonl, (logDir as NSString).appendingPathComponent(name),
                    (name as NSString).deletingPathExtension, source: .dotenv,
                    capBytes: name == "dsmon_buffer.jsonl" ? 5 * 1024 * 1024 : nil)
            }
        }

        // storage/ 下的 SQLite（目录名即来源）
        for name in sqliteFilesIn(directory: (repoPath as NSString).appendingPathComponent("storage")) {
            let sensitive = name.lowercased().contains("voiceprint")
            add(.sqlite, "storage/\(name)", (name as NSString).deletingPathExtension,
                source: .knownDir, sensitive: sensitive)
        }
        // Chroma 向量库
        add(.chroma, "storage/chroma/chroma.sqlite3", "Chroma", source: .knownDir)
        // 事件 / 通知队列
        for name in jsonlFilesIn(directory: (repoPath as NSString).appendingPathComponent("logs/pending-tool-calls")) {
            add(.jsonl, "logs/pending-tool-calls/\(name)",
                (name as NSString).deletingPathExtension, source: .knownDir)
        }
        add(.jsonl, "logs/dsmon_buffer.jsonl", "DS-mon usage buffer",
            source: .knownDir, capBytes: 5 * 1024 * 1024)
        for name in jsonlFilesIn(directory: (repoPath as NSString).appendingPathComponent("queue")) {
            add(.jsonl, "queue/\(name)", (name as NSString).deletingPathExtension, source: .knownDir)
        }
        // safe/ 下的状态文件：只 stat，不解析（可能含密钥）。
        let safeDir = (repoPath as NSString).appendingPathComponent("safe")
        if let entries = try? fm.contentsOfDirectory(atPath: safeDir).sorted() {
            for name in entries where name.hasSuffix(".json") {
                add(.jsonState, "safe/\(name)", (name as NSString).deletingPathExtension,
                    source: .knownDir, sensitive: true)
            }
        }
        return out
    }

    /// 目录下的 SQLite 文件（不存在则空）。
    nonisolated static func sqliteFilesIn(directory: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.sorted().filter { name in
            let lower = name.lowercased()
            guard lower.hasSuffix(".db") || lower.hasSuffix(".sqlite") || lower.hasSuffix(".sqlite3") else {
                return false
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return !isDir.boolValue
        }
    }

    nonisolated static func jsonlFilesIn(directory: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.sorted().filter { $0.hasSuffix(".jsonl") }
    }

    /// 只读取我们关心的键（绝不展示/透出值）。
    nonisolated static func readStorageEnv(repoPath: String) -> [String: String] {
        let wanted: Set<String> = ["TRANSCRIPTION_STORAGE", "VOICEPRINT_DB_PATH", "LOG_DIR"]
        var result: [String: String] = [:]
        for file in [".env", ".env.local"] {
            guard let text = try? String(contentsOfFile: (repoPath as NSString).appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                guard wanted.contains(key) else { continue }
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
                    value = String(value.dropFirst().dropLast())
                }
                guard !value.isEmpty else { continue }
                // 相对路径按仓库根解析。
                if !value.hasPrefix("/") && !value.hasPrefix("~") {
                    value = (repoPath as NSString).appendingPathComponent(value)
                }
                result[key] = (value as NSString).expandingTildeInPath
            }
        }
        return result
    }

    // MARK: - stat / 服务探测

    struct StatResult: Sendable {
        var exists = false
        var sizeBytes: Int64?
        var modifiedAt: Date?
        var inUse = false
    }

    /// 供后台探测使用的 Sendable 快照（@MainActor 的行对象不能跨线程）。
    private struct ProbeTarget: Sendable {
        var id: String
        var descriptor: RepoStoreDescriptor
    }

    nonisolated static func stat(_ descriptor: RepoStoreDescriptor) -> StatResult {
        var result = StatResult()
        guard descriptor.kind != .remote else { return result }
        let path = descriptor.fullPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return result }
        result.exists = true
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            result.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value
            result.modifiedAt = attrs[.modificationDate] as? Date
        }
        // SQLite WAL 伴随文件 = 有进程在写。
        if descriptor.kind == .sqlite || descriptor.kind == .chroma {
            result.inUse = fm.fileExists(atPath: path + "-wal") || fm.fileExists(atPath: path + "-shm")
        }
        return result
    }

    struct ServiceProbe: Sendable {
        var up = false
        var uptimeSeconds: Int?
    }

    nonisolated static func probeService(_ service: RepoServiceInfo, repoPath: String) -> ServiceProbe {
        var out = ServiceProbe()
        if let pidFile = service.pidFile {
            let path = (repoPath as NSString).appendingPathComponent(pidFile)
            if let pid = PortProbe.pid(fromFile: path) {
                out.uptimeSeconds = PortProbe.uptime(pid: pid)
                out.up = out.uptimeSeconds != nil
            }
        }
        if !out.up, let port = service.port {
            let probe = PortProbe.probe(port: port)
            out.up = probe.running
            if out.uptimeSeconds == nil, let pid = probe.pid {
                out.uptimeSeconds = PortProbe.uptime(pid: pid)
            }
        }
        if !out.up, let trigger = service.triggerFile {
            out.up = FileManager.default.fileExists(
                atPath: (repoPath as NSString).appendingPathComponent(trigger))
        }
        return out
    }

    // MARK: - 计数（只读）

    struct CountResult: Sendable {
        var counts: [RepoStoreCount] = []
        var error: String?
    }

    nonisolated static func counts(for descriptor: RepoStoreDescriptor, showDetails: Bool) -> CountResult {
        switch descriptor.kind {
        case .remote:
            return CountResult(counts: [])
        case .sqlite, .chroma:
            return sqliteCounts(path: descriptor.fullPath,
                                tables: descriptor.tables,
                                sensitive: descriptor.sensitive,
                                showDetails: showDetails)
        case .jsonl:
            return jsonlCounts(path: descriptor.fullPath, capBytes: descriptor.capBytes)
        case .jsonState:
            return jsonCounts(path: descriptor.fullPath, sensitive: descriptor.sensitive)
        }
    }

    nonisolated static func sqliteCounts(path: String, tables: [String], sensitive: Bool,
                                         showDetails: Bool) -> CountResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            return CountResult(counts: [], error: "sqlite: cannot open (read-only)")
        }
        defer { sqlite3_close(db) }

        var counts: [RepoStoreCount] = []

        // 完整性（quick_check 比 integrity_check 快得多）
        if let check = scalarText(db, "PRAGMA quick_check;") {
            let ok = check.lowercased() == "ok"
            counts.append(RepoStoreCount(label: "integrity", value: ok ? "ok" : check, isWarning: !ok))
        }

        // 表清单
        var tableNames: [String] = []
        if let stmt = prepare(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { tableNames.append(String(cString: c)) }
            }
            sqlite3_finalize(stmt)
        }
        counts.append(RepoStoreCount(label: "tables", value: "\(tableNames.count)"))

        // 敏感库：只给总量，不给表名。
        if sensitive {
            if let first = tableNames.first,
               let total = scalarInt(db, "SELECT COUNT(*) FROM \"\(first)\";") {
                counts.append(RepoStoreCount(label: "rows", value: formatCount(total)))
            }
            return CountResult(counts: counts)
        }

        // 明示的表优先，否则看前几张大表。
        let targets = tables.isEmpty ? Array(tableNames.prefix(8)) : tables
        for name in targets where tableNames.contains(name) {
            guard let rows = scalarInt(db, "SELECT COUNT(*) FROM \"\(name)\";") else { continue }
            counts.append(RepoStoreCount(label: name, value: formatCount(rows)))
            // 事件队列表：按 status 分组（failed / dlq 需要显眼）。
            if showDetails || name == "events", let buckets = statusBuckets(db, table: name) {
                for bucket in buckets {
                    let status = bucket.0.lowercased()
                    counts.append(RepoStoreCount(label: "\(name) · \(bucket.0)",
                                                 value: formatCount(bucket.1),
                                                 isWarning: (status == "failed" || status == "dlq" || status == "error") && bucket.1 > 0))
                }
            }
        }
        return CountResult(counts: counts)
    }

    private nonisolated static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private nonisolated static func scalarText(_ db: OpaquePointer, _ sql: String) -> String? {
        guard let stmt = prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private nonisolated static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
        guard let stmt = prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private nonisolated static func hasStatusColumn(_ db: OpaquePointer, table: String) -> Bool {
        guard let stmt = prepare(db, "PRAGMA table_info(\"\(table)\");") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == "status" { return true }
        }
        return false
    }

    private nonisolated static func statusBuckets(_ db: OpaquePointer, table: String) -> [(String, Int)]? {
        guard hasStatusColumn(db, table: table) else { return nil }
        guard let stmt = prepare(db, "SELECT COALESCE(status,'?'), COUNT(*) FROM \"\(table)\" GROUP BY 1 ORDER BY 2 DESC;") else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "?"
            out.append((status, Int(sqlite3_column_int64(stmt, 1))))
        }
        return out.isEmpty ? nil : out
    }

    nonisolated static func jsonlCounts(path: String, capBytes: Int64?) -> CountResult {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return CountResult(counts: [], error: nil)
        }
        var counts = [RepoStoreCount(label: "size", value: formatBytes(size))]
        if let cap = capBytes, cap > 0 {
            let pct = Int((Double(size) / Double(cap)) * 100)
            counts.append(RepoStoreCount(label: "buffer cap", value: "\(pct)%",
                                         isWarning: pct >= 80))
        }
        guard size <= maxJSONLParseBytes, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return CountResult(counts: counts)
        }
        var lines = 0
        var pending = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines += 1
            if !line.contains("\"cleared\":true") && !line.contains("\"status\":\"cleared\"") {
                pending += 1
            }
        }
        counts.append(RepoStoreCount(label: "entries", value: "\(lines)"))
        // 只有优先队列的 pending 才值得标红；misc_notifications 天生会积压原始 webhook。
        let warnsOnPending = path.lowercased().contains("priority")
        counts.append(RepoStoreCount(label: "pending", value: "\(pending)",
                                     isWarning: warnsOnPending && pending > 0))
        return CountResult(counts: counts)
    }

    nonisolated static func jsonCounts(path: String, sensitive: Bool) -> CountResult {
        // 敏感文件（safe/ 下的密钥/状态）只报大小，不解析。
        if sensitive {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                return CountResult(counts: [RepoStoreCount(label: "size", value: formatBytes(size))])
            }
            return CountResult(counts: [])
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return CountResult(counts: [], error: nil)
        }
        if let array = obj as? [Any] {
            return CountResult(counts: [RepoStoreCount(label: "items", value: "\(array.count)")])
        }
        if let dict = obj as? [String: Any] {
            return CountResult(counts: [RepoStoreCount(label: "keys", value: "\(dict.count)")])
        }
        return CountResult(counts: [])
    }

    // MARK: - 备份

    enum BackupOutcome: Sendable {
        case success(URL)
        case failure(String)
    }

    nonisolated static func performBackup(_ descriptor: RepoStoreDescriptor) -> BackupOutcome {
        guard descriptor.kind != .remote else { return .failure("remote store") }
        let source = descriptor.fullPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { return .failure(Strings.storeMissing) }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        let safeStamp = stamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let ext = (source as NSString).pathExtension
        let fileName = "\(descriptor.label.replacingOccurrences(of: " ", with: "-"))-\(safeStamp).\(ext.isEmpty ? "db" : ext)"
        let dir = ((NSHomeDirectory() as NSString)
            .appendingPathComponent("Backups/dev_mon"))
            .appending("/\(descriptor.repoName)")
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(error.localizedDescription)
        }
        let dest = (dir as NSString).appendingPathComponent(fileName)

        // SQLite：VACUUM INTO 生成一致性快照（包含未 checkpoint 的 WAL）。
        if descriptor.kind == .sqlite || descriptor.kind == .chroma {
            var db: OpaquePointer?
            if sqlite3_open_v2(source, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
               let db {
                let escaped = dest.replacingOccurrences(of: "'", with: "''")
                let rc = sqlite3_exec(db, "VACUUM INTO '\(escaped)';", nil, nil, nil)
                sqlite3_close(db)
                if rc == SQLITE_OK { return .success(URL(fileURLWithPath: dest)) }
            }
        }
        do {
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: source, toPath: dest)
            return .success(URL(fileURLWithPath: dest))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - 格式化

    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[index])
    }

    nonisolated static func formatCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    nonisolated static func defaultLabel(kind: RepoStoreKind, relPath: String) -> String {
        if kind == .remote { return relPath.isEmpty ? "remote" : relPath }
        let name = (relPath as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? (relPath as NSString).lastPathComponent : base
    }

    // MARK: - devmon.json 解码

    private struct Manifest: Decodable {
        struct Store: Decodable {
            var kind: String?
            var path: String?
            var label: String?
            var sensitive: Bool?
            var tables: [String]?
            var port: Int?
            var pidFile: String?
            var triggerFile: String?
            var capBytes: Int64?
        }
        struct Service: Decodable {
            var port: Int?
            var pidFile: String?
            var triggerFile: String?
        }
        var stores: [Store]?
        var service: Service?
    }
}
