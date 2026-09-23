import Foundation

// MARK: - 操作日志（服务操作 / 通知的追加式记录）
//
// 与用量明细同库（`usage.db` 的 `action_log` 表），导出时按 `service` 分到
// `service_activity.<service>[]`。
//
// 记录点是各个管理器内的**真正执行点**（不是 popover 的确认弹窗）——确认弹窗只是其中一条
// 路径，另有若干操作直接从表单调用管理器（新增 hostname / 新增路由 / 新建站点 / 上传目录 /
// 规则编辑器保存），只挂弹窗会漏记。

/// 操作所属的服务 / 模块，同时也是导出时的分组键。
enum ActionService: String, Sendable, Codable, CaseIterable {
    case aws
    case cloudflare
    case netlify
    case databases      // 本地 MongoDB / MySQL / Neo4j（brew services）
    case repoStores     // 仓库自带的数据存储（备份等）
    case tailscale
    case notifications  // 全部通知
    case `internal`     // dev_mon 自身的模块：代理、同步、席位检查、提供商切换
}

/// 操作结果。`blocked` = 被护栏拦下（未触碰外部服务），`noop` = 无需操作（例如 RDP 规则已存在）。
enum ActionResult: String, Sendable, Codable {
    case success
    case failure
    case blocked
    case noop
}

/// 触发来源：用户点击 / 应用自动（轮询、隐式副作用）。
enum ActionSource: String, Sendable, Codable {
    case user
    case auto
}

/// 一条操作记录。`Codable` 直接用于导出（与 `records` 一样不另建 Export 结构）。
struct ActionEvent: Codable, Sendable, Hashable {
    /// 去重键（重复入库时靠唯一索引忽略，避免重试路径写重）
    let uuid: String
    /// 事件时间（在记录点取，导出时格式化为本地时间 + 时区后缀）
    let timestamp: Date
    let service: ActionService
    /// 动作 slug，形如 `<noun>.<verb>`（`instance.start` / `deploy.upload_folder`）
    let action: String
    /// 作用对象：实例 id、hostname、站点 id、仓库名、映射 id、provider id……
    let target: String
    let result: ActionResult
    let source: ActionSource
    /// 人类可读补充信息（沿用 UI 上已有的操作结果文案）
    let detail: String

    init(service: ActionService,
         action: String,
         target: String = "",
         result: ActionResult,
         source: ActionSource = .user,
         detail: String = "",
         timestamp: Date = Date()) {
        self.uuid = UUID().uuidString
        self.timestamp = timestamp
        self.service = service
        self.action = action
        self.target = target
        self.result = result
        self.source = source
        self.detail = detail
    }

    /// 从数据库读回（uuid / timestamp 按落库值还原）
    init(uuid: String,
         timestamp: Date,
         service: ActionService,
         action: String,
         target: String,
         result: ActionResult,
         source: ActionSource,
         detail: String) {
        self.uuid = uuid
        self.timestamp = timestamp
        self.service = service
        self.action = action
        self.target = target
        self.result = result
        self.source = source
        self.detail = detail
    }
}

// MARK: - 记录入口

/// 操作日志的统一入口。
///
/// 各管理器都是 `@MainActor`，而 `UsageStore` 是 actor，所以这里在主线程序存待写事件并
/// 合并成一次批量写入（避免每个动作各开一次事务）。记录本身**只能**是尽力而为：
/// 任何失败都不得影响被记录的操作。
@MainActor
enum ActionLog {

    /// 统一时间格式：`DD-MM-YYYY HH:MM:SS GMT±H[:MM]`（本地时间 + 时区）。
    /// 导出文件里的每个时间都用这个 —— `UsageExporter` 的 `dateEncodingStrategy` 是 `.custom`，
    /// 直接把 `format(_:)` 的结果当字符串写出去，所以「日期时间」与「时区」只有一份实现。
    ///
    /// 两个方法都是 `nonisolated`：那个编码闭包不是 MainActor 上下文，调 MainActor 隔离的方法
    /// 会跨隔离域（`#ActorIsolatedCall`）。也因此这里不持有共享的 `DateFormatter`（非 Sendable），
    /// 改为直接按公历字段拼字符串 —— 没有共享可变状态，任何隔离域都能同步调用。
    nonisolated static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%02d-%02d-%04d %02d:%02d:%02d",
                           c.day ?? 0, c.month ?? 0, c.year ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(stamp) \(gmtOffsetLabel(for: date))"
    }

    /// 时区后缀，形如 `GMT-5` / `GMT+5:30` / `GMT+0`，按**该时刻**的真实偏移计算（含夏令时）。
    /// 不用 `zzz` —— 那会随系统区域给出 `EST` / `JST` 这类缩写，同一个地方冬夏令时还可能换一种写法，
    /// 消费方得自己维护缩写表；带符号的数字偏移任何解析器都认得。
    nonisolated static func gmtOffsetLabel(for date: Date) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3600
        let minutes = (abs(offset) % 3600) / 60
        return minutes == 0
            ? "GMT\(sign)\(hours)"
            : "GMT\(sign)\(hours):\(String(format: "%02d", minutes))"
    }

    /// 待落盘的事件（按记录顺序）。合并写入，退出前由 `flushPending()` 兜底。
    private static var pending: [ActionEvent] = []
    private static var flushTask: Task<Void, Never>?

    /// 记录一条事件（结果由调用方明确给出）。
    static func record(_ service: ActionService,
                       action: String,
                       target: String = "",
                       result: ActionResult,
                       source: ActionSource = .user,
                       detail: String = "") {
        pending.append(ActionEvent(service: service,
                                   action: action,
                                   target: target,
                                   result: result,
                                   source: source,
                                   detail: detail))
        scheduleFlush()
    }

    /// 记录一条事件，结果由管理器上已有的 `actionSuccess` / `actionMessage` 推断。
    /// - Parameter blocked: 被护栏拦下（未真正执行），优先于 `success`。
    static func record(_ service: ActionService,
                       action: String,
                       target: String,
                       success: Bool,
                       message: String?,
                       source: ActionSource = .user,
                       blocked: Bool = false) {
        let result: ActionResult = blocked ? .blocked : (success ? .success : .failure)
        record(service, action: action, target: target,
               result: result, source: source, detail: message ?? "")
    }

    private static func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            await flushPending()
        }
    }

    /// 把待写事件落盘。应用退出前调用，确保不丢防抖窗口内的最后一批。
    static func flushPending() async {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        await UsageStore.shared.insertActions(batch)
    }
}
