import Foundation

struct KimiProvider: Provider {
    let id = "kimi"
    let name = "Moonshot"
    let baseURL = "https://api.moonshot.cn"
    let balanceURL: String? = "/v1/users/me/balance"
    let rpmLimit: Int? = 200
    let developerPlatformURL = "https://platform.kimi.com/console/account"

    let fallbackModels: [String: ModelPricing] = [
        "kimi-k2.6":                  ModelPricing(label: "K2.6",     hitPrice: 2.0, missPrice: 4.0, outPrice: 12.0),
        "moonshot-v1-8k":             ModelPricing(label: "V1 8K",   hitPrice: 0.06, missPrice: 0.12, outPrice: 0.12),
        "moonshot-v1-32k":            ModelPricing(label: "V1 32K",  hitPrice: 0.24, missPrice: 0.48, outPrice: 0.48),
        "moonshot-v1-128k":           ModelPricing(label: "V1 128K", hitPrice: 0.96, missPrice: 1.92, outPrice: 1.92),
        "moonshot-v1-32k-vision-preview": ModelPricing(label: "V1 Vision", hitPrice: 0.24, missPrice: 0.48, outPrice: 0.48),
    ]

    func parseBalance(_ json: [String: Any]) -> (total: Double, granted: Double, toppedUp: Double)? {
        guard let code = json["code"] as? Int, code == 0,
              let data = json["data"] as? [String: Any] else { return nil }
        let total = (data["available_balance"] as? Double) ?? 0
        let cash = (data["cash_balance"] as? Double) ?? 0
        let voucher = (data["voucher_balance"] as? Double) ?? (data["granted_balance"] as? Double) ?? 0
        return (total, voucher, cash)
    }
}
