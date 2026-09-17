import Foundation
import AppKit
import Combine

/// DeepSeek 高峰/低谷计费时段规则。
///
/// 官方没有公布时段查询接口，只有定价页正文里的一句话
/// （<https://api-docs.deepseek.com/quick_start/pricing>），所以这里定期抓取该页面并解析成
/// 结构化规则。抓取或解析失败时**一律保留上一次可用的规则**，从未成功过则用 `fallback`
/// —— 也就是旧版写死在代码里的时段，因此任何失败都只会退化成旧行为。
struct PeakRule: Codable, Equatable, Sendable {
    /// 分钟区间（自 UTC 午夜起算的分钟数）
    struct Window: Codable, Equatable, Sendable {
        var startMinute: Int
        var endMinute: Int
    }

    /// 高峰时段适用的星期（1=周日 … 7=周六，Foundation 约定）
    var weekdays: [Int]
    /// 高峰时段区间（按 start 升序、互不重叠）
    var windows: [Window]
    /// 规则声明的时区标识（当前实现只接受 UTC）
    var timeZoneID: String
    var updatedAt: Date
    /// 规则来源（抓取 URL 或 "fallback"）
    var source: String

    /// 官方定价页（规则来源）
    static let docsURL = URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!

    /// 内置兜底 = 2026-09 官方公布值：周一至周五 01:00–04:00 与 06:00–10:00（UTC）
    static let fallback = PeakRule(
        weekdays: [2, 3, 4, 5, 6],
        windows: [Window(startMinute: 60, endMinute: 240),
                  Window(startMinute: 360, endMinute: 600)],
        timeZoneID: "UTC",
        updatedAt: .distantPast,
        source: "fallback"
    )

    var isFallback: Bool { source == "fallback" }

    /// 所有区间边界（升序去重）：状态只会在这些分钟内翻转。
    var boundaryMinutes: [Int] {
        Array(Set(windows.flatMap { [$0.startMinute, $0.endMinute] })).sorted()
    }

    func isPeak(weekday: Int, minutesOfDay: Int) -> Bool {
        guard weekdays.contains(weekday) else { return false }
        return windows.contains { minutesOfDay >= $0.startMinute && minutesOfDay < $0.endMinute }
    }

    /// 结构自检：解析结果只有通过这里才会被采用。
    var isValid: Bool {
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { return false }
        guard Set(weekdays).count == weekdays.count else { return false }
        guard (1...4).contains(windows.count) else { return false }
        var previousEnd = 0
        for w in windows.sorted(by: { $0.startMinute < $1.startMinute }) {
            guard w.startMinute >= 0, w.endMinute <= 1440, w.startMinute < w.endMinute else { return false }
            guard w.startMinute >= previousEnd else { return false }   // 不允许重叠
            previousEnd = w.endMinute
        }
        return true
    }
}

// MARK: - 解析官方页面

extension PeakRule {
    /// 正文锚点（英文页）；时区必须同句声明，避免匹配到价格表里的其它时间。
    private static let anchor = "peak hours"

    /// 抓取到的 HTML → 便于正则匹配的纯文本（去标签 / 解实体 / 折叠空白）。
    static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?s)<script.*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)<style.*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&lt;": "<", "&gt;": ">", "&#160;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s
    }

    /// 从官方定价页正文解析高峰时段。任何不确定都返回 nil（调用方保留旧规则）。
    static func parse(_ plainText: String) -> PeakRule? {
        let lower = plainText.lowercased()
        guard let anchorRange = lower.range(of: anchor) else { return nil }
        let segment = sentenceSegment(plainText, from: anchorRange.lowerBound)
        let segLower = segment.lowercased()
        guard segLower.contains("utc") || segLower.contains("gmt") else { return nil }

        let windows = parseWindows(segment)
        guard !windows.isEmpty else { return nil }
        guard let weekdays = parseWeekdays(segment) else { return nil }

        let rule = PeakRule(weekdays: weekdays,
                            windows: windows,
                            timeZoneID: "UTC",
                            updatedAt: Date(),
                            source: docsURL.absoluteString)
        return rule.isValid ? rule : nil
    }

    /// 取锚点开始的**一整句**（折叠过空白后是一行，故以首个 ". " 收尾，最长 320 字符）。
    private static func sentenceSegment(_ text: String, from start: String.Index) -> String {
        let hardEnd = text.index(start, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
        let slice = text[start..<hardEnd]
        if let dot = slice.range(of: ". "),
           slice.distance(from: slice.startIndex, to: dot.lowerBound) > 20 {
            return String(slice[slice.startIndex..<dot.lowerBound])
        }
        return String(slice)
    }

    /// "01:00 - 04:00 and 06:00 - 10:00" → 两个区间。接受 `-` / `–` / `—`。
    private static func parseWindows(_ segment: String) -> [Window] {
        let pattern = #"(\d{1,2}):(\d{2})\s*[-–—]\s*(\d{1,2}):(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = segment as NSString
        let matches = re.matches(in: segment, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            func group(_ i: Int) -> Int? { Int(ns.substring(with: m.range(at: i))) }
            guard let h1 = group(1), let m1 = group(2), let h2 = group(3), let m2 = group(4),
                  h1 < 24, h2 < 24, m1 < 60, m2 < 60 else { return nil }
            return Window(startMinute: h1 * 60 + m1, endMinute: h2 * 60 + m2)
        }
    }

    /// 星期名 → Foundation weekday 值（1=周日 … 7=周六）
    private static let weekdayTokens: [(String, Int)] = [
        ("sunday", 1), ("sun", 1),
        ("monday", 2), ("mon", 2),
        ("tuesday", 3), ("tue", 3), ("tues", 3),
        ("wednesday", 4), ("wed", 4),
        ("thursday", 5), ("thu", 5), ("thur", 5), ("thurs", 5),
        ("friday", 6), ("fri", 6),
        ("saturday", 7), ("sat", 7),
    ]

    /// "Monday through Friday" → [2,3,4,5,6]；也接受 "Mon–Fri" / "Monday to Friday"。
    private static func parseWeekdays(_ segment: String) -> [Int]? {
        let lower = segment.lowercased()
        var hits: [(offset: Int, value: Int)] = []
        for (token, value) in weekdayTokens {
            var search = lower.startIndex
            while let r = lower.range(of: token, range: search..<lower.endIndex) {
                let before = r.lowerBound == lower.startIndex
                    ? nil : lower[lower.index(before: r.lowerBound)]
                let after = r.upperBound == lower.endIndex ? nil : lower[r.upperBound]
                if !(before.map(isWordChar) ?? false), !(after.map(isWordChar) ?? false) {
                    hits.append((lower.distance(from: lower.startIndex, to: r.lowerBound), value))
                }
                search = r.upperBound
            }
        }
        guard !hits.isEmpty else { return nil }
        hits.sort { $0.offset < $1.offset }

        var result: [Int] = []
        var consumed = Set<Int>()
        for (index, hit) in hits.enumerated() {
            if consumed.contains(index) { continue }
            if index + 1 < hits.count,
               isRangeConnector(between(lower, hit.offset, hits[index + 1].offset)) {
                // 展开 range（含两端；数值回绕时按跨周处理）
                var day = hit.value
                var steps = 0
                while steps < 7 {
                    result.append(day)
                    if day == hits[index + 1].value { break }
                    day = day == 7 ? 1 : day + 1
                    steps += 1
                }
                consumed.insert(index + 1)
                continue
            }
            result.append(hit.value)
        }
        let unique = Array(Set(result)).sorted()
        return unique.isEmpty ? nil : unique
    }

    private static func between(_ lower: String, _ a: Int, _ b: Int) -> String {
        let s = lower.index(lower.startIndex, offsetBy: a)
        let e = lower.index(lower.startIndex, offsetBy: b)
        return String(lower[s..<e])
    }

    /// 两个星期名之间是否是区间连接词（"through" / "to" / 纯短横线）。
    private static func isRangeConnector(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.contains("through") || t.contains("thru") || t == "to" { return true }
        return t.allSatisfy { " –—-~".contains($0) }
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}

// MARK: - 规则存储 / 定期抓取

enum PeakRulesError: LocalizedError {
    case http(Int)
    case parse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):    return String(format: Strings.peakRulesErrorHTTP, "\(code)")
        case .parse:             return Strings.peakRulesErrorParse
        case .transport(let m):  return String(format: Strings.peakRulesErrorNetwork, m)
        }
    }
}

/// 规则缓存 + 定期抓取。
///
/// 与 `UIStateStore` / `SyncManager` 同构：**非隔离** + `NSLock` + `@unchecked Sendable`，
/// 这样视图的属性初始值可以直接写 `PeakRulesStore.shared`，而 `DeepSeekPricing`（非隔离）
/// 也能在任意线程读取规则。所有会修改状态的方法都是 `@MainActor`，因此
/// `objectWillChange` 与通知一定在主线程发出。
final class PeakRulesStore: ObservableObject, @unchecked Sendable {
    static let shared = PeakRulesStore()

    /// 缓存上一次成功解析的规则（JSON）
    static let storageKey = "peak_rules_v1"
    /// 上次成功抓取时间
    static let checkedAtKey = "peak_rules_checked_at"
    /// 抓取间隔（小时）—— 用户可配置，随 Export Config 迁移
    static let intervalKey = "peak_rules_check_interval_hours"

    private let lock = NSLock()
    private var _rule: PeakRule = .fallback
    private var _lastChecked: Date?
    private var _lastError: String?
    private var _isRefreshing = false

    /// 当前生效的规则（任意线程可读）
    var rule: PeakRule { lock.withLock { _rule } }
    /// 上次成功抓取时间（失败不推进，避免"看起来查过了"）
    var lastChecked: Date? { lock.withLock { _lastChecked } }
    /// 最近一次失败原因（成功后清空）
    var lastError: String? { lock.withLock { _lastError } }
    var isRefreshing: Bool { lock.withLock { _isRefreshing } }

    /// 抓取间隔（小时），默认 24，范围 1…168
    var intervalHours: Double {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        guard stored >= 1 else { return AppConfig.peakRulesCheckIntervalDefaultHours }
        return min(stored, 168)
    }

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        loadCached()
    }

    // MARK: - 缓存读写

    private func loadCached() {
        let defaults = UserDefaults.standard
        var loaded: PeakRule?
        if let data = defaults.data(forKey: Self.storageKey),
           let rule = try? JSONDecoder().decode(PeakRule.self, from: data),
           rule.isValid {
            loaded = rule
        }
        let checked = defaults.object(forKey: Self.checkedAtKey) as? Date
        lock.withLock {
            _rule = loaded ?? .fallback
            _lastChecked = checked
        }
    }

    // MARK: - 调度

    /// 启动定期抓取（应用启动时调用）。
    ///
    /// 与 `SeatRegistry.startAutoCheck()` 同构：先立刻检查一次（Timer 首次触发要等整整一个间隔），
    /// 再按间隔重复；`tolerance` 留 10% 让系统合并唤醒。另外监听系统唤醒 —— 定时器在睡眠期间
    /// 不会触发，24 小时的间隔一旦跨过睡眠就会长期不更新。
    @MainActor
    func startAutoRefresh() {
        stopAutoRefresh()
        Task { await refreshIfStale() }

        let interval = intervalHours * 3600
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshIfStale() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshIfStale() }
        }
    }

    @MainActor
    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// 设置间隔并重启定时器（设置页调用）
    @MainActor
    func setInterval(hours: Double) {
        UserDefaults.standard.set(max(1, min(hours, 168)), forKey: Self.intervalKey)
        objectWillChange.send()
        startAutoRefresh()
    }

    // MARK: - 抓取

    /// 距上次成功抓取已超过间隔时抓取一次。
    @MainActor
    func refreshIfStale() async {
        if let checked = lastChecked,
           Date().timeIntervalSince(checked) < intervalHours * 3600 { return }
        await refresh()
    }

    /// 抓取并解析；失败保留旧规则。
    @MainActor
    func refresh() async {
        guard !isRefreshing else { return }
        setRefreshing(true)
        defer { setRefreshing(false) }

        do {
            var req = URLRequest(url: PeakRule.docsURL,
                                 timeoutInterval: AppConfig.modelsRequestTimeout)
            req.setValue("dev_mon", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await AppConfig.directURLSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw PeakRulesError.http(status) }
            guard let html = String(data: data, encoding: .utf8),
                  let parsed = PeakRule.parse(PeakRule.plainText(fromHTML: html)) else {
                throw PeakRulesError.parse
            }
            apply(parsed)
            AppConfig.appendLog(to: AppConfig.proxyLogURL,
                                "[PeakRules] updated: weekdays=\(parsed.weekdays) windows=\(parsed.windows)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure(message)
            AppConfig.appendLog(to: AppConfig.proxyLogURL, "[PeakRules] refresh failed: \(message)")
        }
    }

    /// 采用新规则：切换时刻可能变化，因此必须重排系统通知。
    private func apply(_ newRule: PeakRule) {
        lock.withLock {
            _rule = newRule
            _lastChecked = Date()
            _lastError = nil
            UserDefaults.standard.set(try? JSONEncoder().encode(newRule), forKey: Self.storageKey)
            UserDefaults.standard.set(Date(), forKey: Self.checkedAtKey)
        }
        PeakNotifier.scheduleNextTransition()
        // 状态栏立即按新规则重算（点/文字芯片/倒计时）
        NotificationCenter.default.post(name: .peakSettingsDidChange, object: nil)
        objectWillChange.send()
    }

    private func registerFailure(_ message: String) {
        lock.withLock { _lastError = message }
        objectWillChange.send()
    }

    private func setRefreshing(_ value: Bool) {
        lock.withLock { _isRefreshing = value }
        objectWillChange.send()
    }
}
