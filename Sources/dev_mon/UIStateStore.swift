import Foundation
import SwiftUI

/// UI 状态持久化（页签选择 / 折叠状态 / 图表-列表视图模式）。
///
/// 存放于 `~/Library/Application Support/dev_mon/ui_state_prefs.json`（与 `usage.db` 同目录），
/// 因此**重启应用后仍然保持**；同一份内容也会随 Export Config / Import Config 迁移
/// （导出时扁平化为 `ui.<key>`，导入时按前缀还原）。
///
/// 实现与 `SyncManager` 同构：非隔离 + `NSLock` + `@unchecked Sendable`，
/// 这样视图的属性初始值可以直接写 `UIStateStore.shared`（Swift 6 下不会与 MainActor 冲突）。
/// 所有写入都发生在主线程（SwiftUI 事件回调），因此 `objectWillChange` 的发送线程是安全的。
final class UIStateStore: ObservableObject, @unchecked Sendable {
    static let shared = UIStateStore()

    /// 所有键集中在此，避免散落的字符串字面量。
    enum Key {
        // 页签
        static let selectedTab      = "tab.selected"
        static let usageSubTab      = "tab.usage"
        static let githubSubTab     = "tab.github"
        static let awsSubTab        = "tab.aws"
        static let cloudflareSubTab = "tab.cloudflare"
        static let dbSubTab         = "tab.db"
        static let settingsTab      = "tab.settings"

        // 视图模式：图表 ↔ 列表
        static let usageChart  = "chart.usage"
        static let sourceChart = "chart.source"

        // DeepSeek / Usage 页区段
        static let usageAccount = "section.usage.account"
        static let usageStats   = "section.usage.stats"
        static let usageList    = "section.usage.list"
        static let usageSource  = "section.usage.source"

        // GitHub 页
        static let ghRepoList = "section.gh.list"
        static func ghInfo(_ repoID: String) -> String { "section.gh.info.\(repoID)" }
        static func ghSection(_ kind: String, _ repoID: String) -> String { "section.gh.\(kind).\(repoID)" }

        // AWS 页
        static let awsInstanceList   = "section.aws.list"
        static let awsInstanceDetail = "section.aws.detail"

        // Cloudflare 页
        static let cfHostnameList = "section.cf.hostnames"

        // Netlify 页
        static let netlifySiteList = "section.netlify.list"
        static let netlifyBasic    = "section.netlify.basic"
        static let netlifyBuild    = "section.netlify.build"
        static let netlifyDeploys  = "section.netlify.deploys"

        // 数据库页
        static func localDB(_ id: String) -> String { "section.db.\(id)" }
        static func repoStore(_ id: String) -> String { "store.\(id)" }

        // 设置窗口
        static func service(_ key: String) -> String { "service.\(key)" }
        static func provider(_ id: String) -> String { "provider.\(id)" }

        /// Export Config 中 UI 状态键的前缀
        static let exportPrefix = "ui."
    }

    private struct Payload: Codable {
        var bools: [String: Bool]
        var ints: [String: Int]
    }

    private let lock = NSLock()
    private var bools: [String: Bool] = [:]
    private var ints: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("dev_mon")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ui_state_prefs.json")
    }()

    private init() {
        load()
    }

    // MARK: - 读取

    func bool(_ key: String, default def: Bool = true) -> Bool {
        lock.withLock { bools[key] ?? def }
    }

    func int(_ key: String, default def: Int = 0) -> Int {
        lock.withLock { ints[key] ?? def }
    }

    /// SwiftUI 绑定（`CollapsibleSection` / `SearchableSelector` / 复选框等）。
    func boolBinding(_ key: String, default def: Bool = true) -> Binding<Bool> {
        Binding(get: { self.bool(key, default: def) }, set: { self.setBool(key, $0) })
    }

    func intBinding(_ key: String, default def: Int = 0) -> Binding<Int> {
        Binding(get: { self.int(key, default: def) }, set: { self.setInt(key, newValue: $0) })
    }

    // MARK: - 写入

    func setBool(_ key: String, _ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            let old = bools[key]
            bools[key] = value
            return old != value
        }
        guard changed else { return }
        objectWillChange.send()
        scheduleSave()
    }

    func setInt(_ key: String, newValue: Int) {
        let changed = lock.withLock { () -> Bool in
            let old = ints[key]
            ints[key] = newValue
            return old != newValue
        }
        guard changed else { return }
        objectWillChange.send()
        scheduleSave()
    }

    func toggle(_ key: String, default def: Bool = true) {
        setBool(key, !bool(key, default: def))
    }

    /// 作用域内是否所有键都已展开（供单图标 toggle 决定图标与动作）。
    func allTrue(_ keys: [String]) -> Bool {
        let snapshot = lock.withLock { bools }
        return keys.allSatisfy { snapshot[$0] ?? true }
    }

    // MARK: - Export / Import Config

    /// 导出用快照（扁平化为 `ui.<key>`）。
    var exportedValues: [String: ConfigValue] {
        let (b, i) = lock.withLock { (bools, ints) }
        var out: [String: ConfigValue] = [:]
        for (k, v) in b { out[Key.exportPrefix + k] = .bool(v) }
        for (k, v) in i { out[Key.exportPrefix + k] = .number(Double(v)) }
        return out
    }

    /// 导入一个 `ui.<key>` 值；不是 UI 状态键时返回 false。
    @discardableResult
    func importValue(_ key: String, _ value: ConfigValue) -> Bool {
        guard key.hasPrefix(Key.exportPrefix) else { return false }
        let bare = String(key.dropFirst(Key.exportPrefix.count))
        switch value {
        case .bool(let v): setBool(bare, v)
        case .number(let n): setInt(bare, newValue: Int(n))
        default: break
        }
        return true
    }

    /// 把导入的键值直接写入（不触发逐键保存的抖动）。
    func importRaw(bools newBools: [String: Bool], ints newInts: [String: Int]) {
        lock.withLock {
            bools.merge(newBools) { _, new in new }
            ints.merge(newInts) { _, new in new }
        }
        objectWillChange.send()
        persist()
    }

    // MARK: - 持久化

    /// 立即落盘（退出应用前调用，避免丢失 300ms 防抖窗口内的改动）。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        lock.withLock {
            bools = payload.bools
            ints = payload.ints
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        let payload = lock.withLock { Payload(bools: bools, ints: ints) }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
