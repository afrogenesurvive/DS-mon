import Foundation

// MARK: - 会话管理（简化内存版）

/// 管理 `previous_response_id` 对应的历史消息和 reasoning 缓存
final class ResponsesSessionStore: @unchecked Sendable {
    static let shared = ResponsesSessionStore()

    private let lock = NSLock()
    private var sessions: [String: SessionEntry] = [:]
    private var reasoningByCallId: [String: String] = [:]
    private var turnReasoning: [String: String] = [:] // fingerprint → reasoning

    private struct SessionEntry {
        let messages: [ChatMessage]
        let createdAt: Date
    }

    private init() {}

    // MARK: - History

    func getHistory(responseId: String) -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sessions[responseId]?.messages ?? []
    }

    @discardableResult
    func save(messages: [ChatMessage]) -> String {
        let id = UUID().uuidString
        lock.lock()
        sessions[id] = SessionEntry(messages: messages, createdAt: Date())
        lock.unlock()
        return id
    }

    func saveWithId(id: String, messages: [ChatMessage]) {
        lock.lock()
        sessions[id] = SessionEntry(messages: messages, createdAt: Date())
        lock.unlock()
    }

    func newId() -> String {
        UUID().uuidString
    }

    // MARK: - Reasoning (按 call_id)

    func storeReasoning(callId: String, reasoning: String) {
        lock.lock()
        reasoningByCallId[callId] = reasoning
        lock.unlock()
    }

    func getReasoning(callId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reasoningByCallId[callId]
    }

    // MARK: - Turn-level reasoning (按指纹)

    func storeTurnReasoning(messages: [ChatMessage], assistantMsg: ChatMessage, reasoning: String) {
        let fingerprint = turnFingerprint(messages: messages, assistantMsg: assistantMsg)
        lock.lock()
        turnReasoning[fingerprint] = reasoning
        lock.unlock()
    }

    func getTurnReasoning(messages: [ChatMessage], assistantMsg: ChatMessage) -> String? {
        let fingerprint = turnFingerprint(messages: messages, assistantMsg: assistantMsg)
        lock.lock()
        defer { lock.unlock() }
        return turnReasoning[fingerprint]
    }

    // MARK: - Cleanup

    func cleanup() {
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour TTL
        lock.lock()
        sessions = sessions.filter { $0.value.createdAt > cutoff }
        // 保留 reasoning 不过期（通常很小）
        lock.unlock()
    }

    // MARK: - Private

    private func turnFingerprint(messages: [ChatMessage], assistantMsg: ChatMessage) -> String {
        // 用最后几条消息的 content hash 做指纹
        let lastMsgs = messages.suffix(3).map { $0.textContent }.joined()
        let assistantText = assistantMsg.textContent
        let hash = "\(lastMsgs)|\(assistantText)".hashValue
        return String(hash)
    }
}
