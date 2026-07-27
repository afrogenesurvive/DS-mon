import Foundation

struct DeepSeekProvider: Provider {
    let id = "deepseek"
    let name = "DeepSeek"
    let baseURL = "https://api.deepseek.com"
    let balanceURL: String? = "/user/balance"
    let preferredDefaultModel: String? = "deepseek-v4-flash"
    let rpmLimit: Int? = 200
    let developerPlatformURL = "https://platform.deepseek.com/usage"

    let fallbackModels: [String: ModelPricing] = [
        "deepseek-v4-flash": ModelPricing(label: "V4 Flash", hitPrice: 0.02, missPrice: 1.0, outPrice: 2.0),
        "deepseek-v4-pro":   ModelPricing(label: "V4 Pro",   hitPrice: 0.026, missPrice: 3.13, outPrice: 6.26),
        "deepseek-chat":     ModelPricing(label: "Chat",     hitPrice: 0.02, missPrice: 1.0, outPrice: 2.0),
        "deepseek-reasoner": ModelPricing(label: "Reasoner", hitPrice: 0.02, missPrice: 1.0, outPrice: 2.0),
    ]

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? {
        guard let available = json["is_available"] as? Bool, available,
              let infos = json["balance_infos"] as? [[String: Any]] else { return nil }
        var total = 0.0, granted = 0.0, toppedUp = 0.0
        for info in infos {
            if let v = Double(info["total_balance"] as? String ?? "") { total += v }
            if let v = Double(info["granted_balance"] as? String ?? "") ?? info["granted_balance"] as? Double { granted += v }
            if let v = Double(info["topped_up_balance"] as? String ?? "") ?? info["topped_up_balance"] as? Double { toppedUp += v }
        }
        return (total, granted, toppedUp)
    }
}
