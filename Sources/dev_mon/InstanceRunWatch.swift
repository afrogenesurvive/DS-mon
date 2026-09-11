import Foundation

/// EC2 实例「持续运行」看门狗。
///
/// 目标：实例被遗忘在运行状态时别把免费额度（或钱包）烧完 —— 连续运行超过
/// `interval` 就发一次通知，之后每 `interval` 重复一次，实例停止后重新计时。
///
/// 计时起点（`firstSeen`）：
/// - 首次看到某实例处于 running 时，用 `launchTime`（AWS 的本次启动时间）作为起点；
///   若拿不到就用当前时间。
/// - 起点**只会向后持久化一次**，之后刷新不覆盖 —— 所以不会因为偶然的时钟/接口
///   抖动而把「已运行多久」算短。
/// - 实例一旦不在 running，条目被清除 → 下次启动重新计时（并重新武装提醒）。
///
/// 状态存在 UserDefaults，应用重启后仍能继续计时。
@MainActor
final class InstanceRunWatch {

    static let shared = InstanceRunWatch()

    /// 首次提醒的阈值，同时是重复提醒的间隔（30 分钟）。
    static let interval: TimeInterval = 30 * 60

    /// `[instanceId: firstSeenEpoch]`
    private static let firstSeenKey = "aws_instance_run_first_seen"

    private var firstSeen: [String: Date]
    /// 仅内存：每个实例上次发通知的时间（重启后允许立刻再提醒一次）。
    private var lastAlerted: [String: Date] = [:]

    init() {
        firstSeen = Self.loadFirstSeen()
    }

    /// 设置开关（Settings → Notifications，默认开）。
    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.awsRunNotifyEnabled) as? Bool) ?? true
    }

    /// 每次 EC2 刷新后调用（@MainActor）。
    func evaluate(_ instances: [AWSInstance], now: Date = Date()) {
        pruneStopped(instances, now: now)
        recordFirstSeen(instances, now: now)
        guard isEnabled else { return }

        for instance in instances where instance.isRunning {
            guard let start = firstSeen[instance.instanceId] else { continue }
            let elapsed = now.timeIntervalSince(start)
            guard elapsed >= Self.interval else { continue }
            if let last = lastAlerted[instance.instanceId],
               now.timeIntervalSince(last) < Self.interval {
                continue
            }
            lastAlerted[instance.instanceId] = now
            AppAlertCenter.fire(
                .awsInstanceLongRunning,
                title: Strings.awsRunningTitle,
                body: Strings.awsRunningBody(instance.name ?? instance.instanceId,
                                             instance.instanceId,
                                             Strings.dbUptime(Int(elapsed))))
        }
    }

    /// 当前连续运行时长（供 UI 显示；未在运行或未记录时返回 nil）。
    func runningFor(_ instanceId: String, now: Date = Date()) -> TimeInterval? {
        guard let start = firstSeen[instanceId] else { return nil }
        return now.timeIntervalSince(start)
    }

    // MARK: - 内部

    /// 清除已停止实例的计时 —— 下次运行重新开始，提醒也重新武装。
    private func pruneStopped(_ instances: [AWSInstance], now: Date) {
        let running = Set(instances.filter { $0.isRunning }.map { $0.instanceId })
        guard !running.isEmpty || !firstSeen.isEmpty else { return }
        let stale = firstSeen.keys.filter { !running.contains($0) }
        for id in stale {
            firstSeen[id] = nil
            lastAlerted[id] = nil
        }
        if !stale.isEmpty { save() }
    }

    /// 首次见到运行中实例时记录起点（已记录的不覆盖）。
    private func recordFirstSeen(_ instances: [AWSInstance], now: Date) {
        var changed = false
        for instance in instances where instance.isRunning {
            guard firstSeen[instance.instanceId] == nil else { continue }
            // launchTime 是 AWS 记录的本次启动时间；缺失时退化为「现在」。
            let start = instance.launchTime.map { min($0, now) } ?? now
            firstSeen[instance.instanceId] = start
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        let raw = firstSeen.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: Self.firstSeenKey)
    }

    private static func loadFirstSeen() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: firstSeenKey) else { return [:] }
        var out: [String: Date] = [:]
        for (id, value) in raw {
            if let epoch = value as? Double {
                out[id] = Date(timeIntervalSince1970: epoch)
            } else if let epoch = value as? Int {
                out[id] = Date(timeIntervalSince1970: TimeInterval(epoch))
            }
        }
        return out
    }
}
