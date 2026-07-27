import Foundation

final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()
    private var buckets: [String: [Date]] = [:]
    private let lock = NSLock()

    func check(providerId: String, rpmLimit: Int?) -> Bool {
        guard let limit = rpmLimit, limit > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let window = now.addingTimeInterval(-60)
        var timestamps = buckets[providerId] ?? []
        timestamps.removeAll { $0 < window }
        guard timestamps.count < limit else { return false }
        timestamps.append(now)
        buckets[providerId] = timestamps
        return true
    }
}
