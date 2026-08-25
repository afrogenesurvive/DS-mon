import Foundation

/// DeepSeek 高峰/低谷计费时段
///
/// 官方说明（https://api-docs.deepseek.com/quick_start/pricing）：
/// 高峰时段为周一至周五 01:00–04:00 与 06:00–10:00（UTC），其余时间为低谷时段
/// （低谷价格约为高峰的一半）。纯本地时钟计算，无需网络请求。
enum DeepSeekPricing {
    /// 以 UTC 时区为基础的公历日历
    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 指定时间是否处于高峰时段（周一至周五 01:00–04:00 与 06:00–10:00 UTC）。
    static func isPeak(_ date: Date = Date()) -> Bool {
        let cal = utcCalendar
        let weekday = cal.component(.weekday, from: date)   // 1=周日 … 7=周六
        guard weekday >= 2 && weekday <= 6 else { return false }  // 周一(2)–周五(6)
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let t = Double(hour) + Double(minute) / 60.0
        return (t >= 1.0 && t < 4.0) || (t >= 6.0 && t < 10.0)
    }

    /// 下一个状态切换时刻（高峰→低谷 或 低谷→高峰）。
    ///
    /// 每次边界（01:00/04:00/06:00/10:00 UTC）都会翻转状态，因此取晚于 `date` 的
    /// 第一个工作日边界即可。
    static func nextTransition(after date: Date = Date()) -> Date {
        let cal = utcCalendar
        let currentPeak = isPeak(date)
        var day = cal.startOfDay(for: date)
        for _ in 0..<8 {   // 最多向后扫描 8 天（覆盖跨周末场景）
            let weekday = cal.component(.weekday, from: day)
            if weekday >= 2 && weekday <= 6 {   // 仅工作日存在高峰边界
                for hour in [1, 4, 6, 10] {
                    if let t = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day),
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
