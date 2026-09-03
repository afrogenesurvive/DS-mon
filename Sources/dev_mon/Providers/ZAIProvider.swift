import Foundation

/// Z.AI (Zhipu GLM) — OpenAI-compatible 国际端点。
///
/// z.ai 没有公开的余额 / 用量 / 账单 REST API（仅推理端点），因此这是一个
/// *按用量计费*（spend-based）提供商：`balanceURL` / `tokenUsageURL` /
/// `spendLimitURL` 均为 nil。“剩余额度”由 设置 → 提供商 中手填的月度预算减去
/// 本地代理记录的本月费用推导。
///
/// 默认走 GLM Coding Plan 专用端点（Z.AI for Copilot 使用
/// `/api/coding/paas/v4`），可在 设置 → 提供商 切换到标准按量付费端点
/// （`/api/paas/v4`）。
///
/// Coding Plan 的真实用量配额只能通过 z.ai 的内部（非官方、UI 使用的）接口读取，
/// 这些接口可能随时变更，查询失败时 UI 应静默降级：
/// - `GET /api/monitor/usage/quota/limit` → data.limits[]（5h 会话 / 7 天 / 月度搜索）
/// - `GET /api/biz/subscription/list` → data[]（套餐名、续费日期）
enum ZAIEndpoint: String, CaseIterable {
    case coding = "coding"
    case standard = "standard"

    var apiPath: String {
        switch self {
        case .coding:   return "/api/coding/paas/v4"   // GLM Coding Plan 专用
        case .standard: return "/api/paas/v4"          // 标准按量付费
        }
    }

    static var current: ZAIEndpoint {
        let raw = UserDefaults.standard.string(forKey: Strings.Keys.zaiEndpoint)
        return ZAIEndpoint(rawValue: raw ?? "") ?? .coding
    }

    static func set(_ endpoint: ZAIEndpoint) {
        UserDefaults.standard.set(endpoint.rawValue, forKey: Strings.Keys.zaiEndpoint)
    }
}

struct ZAIProvider: Provider {
    let id = "zai"
    let name = "Z.ai"
    let baseURL = "https://api.z.ai"
    /// 由用户选择的上游端点（Coding Plan 专用 or 标准按量付费）。
    var apiPath: String { ZAIEndpoint.current.apiPath }
    // No public balance/usage API on z.ai.
    let balanceURL: String? = nil
    let isSpendBased = true
    let preferredDefaultModel: String? = "glm-5.3-flash"
    let developerPlatformURL = "https://z.ai/model-api"
    let opencodeProviderId = "zai"
    let currency = "USD"
    // No bundled brand asset yet — fall back to an SF Symbol.
    let iconName = "sparkles"

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? { nil }

    // 定价与 ModelPricing.zaiDefault 保持一致（USD / 1M tokens）。
    // fallbackModels keys 同时驱动本地代理的模型→提供商路由。
    let fallbackModels: [String: ModelPricing] = ModelPricing.zaiDefault

    // MARK: - 内部配额/套餐接口（非官方；失败时上层静默降级）

    let quotaURL: String? = "https://api.z.ai/api/monitor/usage/quota/limit"
    let planURL: String? = "https://api.z.ai/api/biz/subscription/list"

    func parseQuota(_ json: [String: Any]) -> ProviderQuotaUsage? {
        guard let data = json["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]],
              !limits.isEmpty else { return nil }
        var usage = ProviderQuotaUsage()
        for item in limits {
            let type = item["type"] as? String ?? ""
            let unit = (item["unit"] as? NSNumber)?.intValue ?? 0
            let number = (item["number"] as? NSNumber)?.intValue ?? 0
            let limit = Self.number(item["usage"])
            let used = Self.number(item["currentValue"])
            let remaining = Self.number(item["remaining"])
            let rawPercent = Self.number(item["percentage"])
            let percent = limit > 0
                ? min(100, max(0, rawPercent > 0 ? rawPercent : used / limit * 100))
                : 0
            let kind: ProviderQuotaWindowKind
            if type == "TIME_LIMIT" {
                kind = .searchMonthly
            } else if number == 7 && unit == 6 {
                kind = .weekly7d
            } else if number == 5 && unit == 3 {
                kind = .session5h
            } else {
                continue // 其余窗口暂不展示
            }
            let details: [ProviderQuotaDetail] = (item["usageDetails"] as? [[String: Any]])?
                .compactMap { entry in
                    guard let model = entry["modelCode"] as? String else { return nil }
                    return ProviderQuotaDetail(model: model, used: Self.number(entry["usage"]))
                } ?? []
            usage.windows.append(ProviderQuotaWindow(
                kind: kind,
                limit: limit,
                used: used,
                remaining: remaining,
                percent: percent,
                resetDate: Self.epochMilliseconds(item["nextResetTime"]),
                details: details
            ))
        }
        return usage.windows.isEmpty ? nil : usage
    }

    func parsePlan(_ json: [String: Any]) -> (name: String?, renewalDate: Date?)? {
        guard let data = json["data"] as? [[String: Any]], let first = data.first else { return nil }
        let name = first["productName"] as? String
        var renewal: Date?
        if let raw = first["nextRenewTime"] as? String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            renewal = fmt.date(from: raw)
        }
        if name == nil && renewal == nil { return nil }
        return (name, renewal)
    }

    // MARK: - 内部钱包余额（非官方；失败时上层静默降级）

    /// 账户信息接口 → data.customerNumber（accountBalance 需要 customerId）。
    let walletInfoURL = "https://api.z.ai/api/biz/customerService/zaiUserInfo"
    /// 钱包余额接口（POST {customerId}）→ data.totalBalance。
    let walletBalanceURL = "https://api.z.ai/api/platform-charge-zai/business/accountBalance"

    /// 从 zaiUserInfo 提取账户号（customerNumber）。
    func parseCustomerNumber(_ json: [String: Any]) -> String? {
        guard let data = json["data"] as? [String: Any] else { return nil }
        guard let num = data["customerNumber"] as? String, !num.isEmpty else { return nil }
        return num
    }

    /// 从 accountBalance 提取总钱包余额（优先 totalBalance，回退首个 account）。
    func parseWalletBalance(_ json: [String: Any]) -> Double? {
        guard let data = json["data"] as? [String: Any] else { return nil }
        if data["totalBalance"] != nil {
            return Self.number(data["totalBalance"])
        }
        if let first = (data["accountList"] as? [[String: Any]])?.first {
            return Self.number(first["balance"])
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func epochMilliseconds(_ value: Any?) -> Date? {
        guard let n = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}
