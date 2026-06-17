import Foundation

struct UsageLogger: @unchecked Sendable {
    let store: UsageStore
    let onComplete: () -> Void

    func logChatUsage(requestBody: Data, responseBody: Data, latencyMs: Double, statusCode: Int, providerId: String = "", userAgent: String = "") {
        if let respJSON = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let usage = respJSON["usage"] as? [String: Any] {
            writeUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode, providerId: providerId, userAgent: userAgent)
            return
        }

        guard let sseText = String(data: responseBody, encoding: .utf8) else { return }
        let lines = sseText.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
            let jsonStr = String(line.dropFirst(6))
            if let chunkData = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
               let usage = json["usage"] as? [String: Any] {
                writeUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode, providerId: providerId, userAgent: userAgent)
                return
            }
        }
    }

    func logResponsesUsage(requestBody: Data, responseBody: Data, latencyMs: Double, providerId: String = "", userAgent: String = "") {
        guard let text = String(data: responseBody, encoding: .utf8) else { return }
        var usage: [String: Any]?

        let lines = text.components(separatedBy: "\n")
        var foundEvent = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "event: response.completed" { foundEvent = true; continue }
            if foundEvent, trimmed.hasPrefix("data: ") {
                let jsonStr = String(trimmed.dropFirst(6))
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let responseObj = json["response"] as? [String: Any] {
                    usage = responseObj["usage"] as? [String: Any]
                }
                break
            }
        }

        if usage == nil,
           let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] {
            usage = json["usage"] as? [String: Any]
        }

        if usage == nil {
            for line in lines.reversed() {
                guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let u = json["usage"] as? [String: Any] {
                    usage = u; break
                }
            }
        }

        guard let usage else { return }

        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }

        let cachedTokens: Int = {
            if let details = usage["input_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int { return cached }
            if let cached = usage["prompt_cache_hit_tokens"] as? Int { return cached }
            if let cached = usage["cached_tokens"] as? Int { return cached }
            return 0
        }()

        let details = usage["output_tokens_details"] as? [String: Any]
        saveLastModel(model, providerId: providerId)
        let record = UsageRecord(
            uuid: UUID().uuidString,
            timestamp: Date(),
            providerId: providerId,
            model: model,
            endpoint: "/v1/responses",
            promptTokens: usage["input_tokens"] as? Int ?? 0,
            completionTokens: usage["output_tokens"] as? Int ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0,
            cachedTokens: cachedTokens,
            reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
            latencyMs: latencyMs,
            statusCode: 200,
            userAgent: userAgent
        )
        insertAndNotify(record)
    }

    private func writeUsage(requestBody: Data, usage: [String: Any], latencyMs: Double, statusCode: Int, providerId: String = "", userAgent: String = "") {
        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }
        saveLastModel(model, providerId: providerId)
        let details = usage["completion_tokens_details"] as? [String: Any]
        let cachedTokens: Int = {
            if let details = usage["prompt_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int { return cached }
            if let cached = usage["prompt_cache_hit_tokens"] as? Int { return cached }
            if let cached = usage["cached_tokens"] as? Int { return cached }
            return 0
        }()
        let record = UsageRecord(
            uuid: UUID().uuidString,
            timestamp: Date(),
            providerId: providerId,
            model: model,
            endpoint: "/v1/chat/completions",
            promptTokens: usage["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage["completion_tokens"] as? Int ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0,
            cachedTokens: cachedTokens,
            reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
            latencyMs: latencyMs,
            statusCode: statusCode,
            userAgent: userAgent
        )
        insertAndNotify(record)
    }

    private func insertAndNotify(_ record: UsageRecord) {
        Task {
            await store.insert(record)
            onComplete()
            Task { @MainActor in
                NotificationCenter.default.post(name: .usageRecorded, object: nil)
            }
        }
    }

    private func saveLastModel(_ model: String, providerId: String) {
        guard !model.isEmpty, model != "unknown" else { return }
        UserDefaults.standard.set(model, forKey: Strings.Keys.lastModel(for: providerId))
    }
}
