import Foundation

/// DeepSeek 高峰/低谷计费时段
///
/// 时段不再写死在代码里：由 `PeakRulesStore` 定期从官方定价页
/// （https://api-docs.deepseek.com/quick_start/pricing）抓取并解析；抓取或解析失败时保留
/// 上一次可用的规则，从未成功过则用内置兜底值（周一至周五 01:00–04:00 与 06:00–10:00 UTC，
/// 低谷价格约为高峰的一半）。判定本身仍是纯本地时钟计算（UTC 日历），不依赖网络。
enum DeepSeekPricing {
    /// 以 UTC 时区为基础的公历日历
    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 指定时间是否处于高峰时段（星期与 UTC 分钟数命中当前规则的任一区间）。
    static func isPeak(_ date: Date = Date()) -> Bool {
        let cal = utcCalendar
        let weekday = cal.component(.weekday, from: date)   // 1=周日 … 7=周六
        let minutesOfDay = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return PeakRulesStore.shared.rule.isPeak(weekday: weekday, minutesOfDay: minutesOfDay)
    }

    /// 下一个状态切换时刻（高峰→低谷 或 低谷→高峰）。
    ///
    /// 边界由当前规则给出（内置兜底为 01:00/04:00/06:00/10:00 UTC），因此取晚于 `date` 的
    /// 第一个使状态翻转的区间边界即可。
    static func nextTransition(after date: Date = Date()) -> Date {
        let cal = utcCalendar
        let rule = PeakRulesStore.shared.rule
        let currentPeak = isPeak(date)
        var day = cal.startOfDay(for: date)
        for _ in 0..<8 {   // 最多向后扫描 8 天（覆盖跨周末场景）
            let weekday = cal.component(.weekday, from: day)
            if rule.weekdays.contains(weekday) {   // 仅高峰日（工作日）存在区间边界
                for minute in rule.boundaryMinutes {
                    if let t = cal.date(byAdding: .minute, value: minute, to: day),
                       t > date, isPeak(t) != currentPeak {
                        return t
                    }
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return date.addingTimeInterval(3600)   // 兜底（正常不会走到）
    }

    /// 距下一次切换的剩余时间（如 "3h 12m"）。
    static func timeToTransitionText(from date: Date = Date()) -> String {
        let left = max(0, nextTransition(after: date).timeIntervalSince(date))
        let h = Int(left) / 3600
        let m = (Int(left) % 3600) / 60
        return String(format: "%dh %02dm", h, m)
    }
}
