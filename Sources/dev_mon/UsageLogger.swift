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
            userAgent: userAgent,
            sourceIP: ""
        )
        insertAndNotify(record)
    }

    /// 记录 Anthropic Messages API（/v1/messages）用量
    func logMessagesUsage(requestBody: Data, responseBody: Data, latencyMs: Double, statusCode: Int, providerId: String = "", userAgent: String = "") {
        var usage: [String: Any]?

        // 1) 非流式：顶层 usage 对象
        if let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let u = json["usage"] as? [String: Any] {
            usage = u
        } else if let text = String(data: responseBody, encoding: .utf8) {
            // 2) 流式：聚合 message_start（输入）+ message_delta（输出）
            var input = 0, output = 0, cacheCreation = 0, cacheRead = 0
            var found = false
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data: ") else { continue }
                let jsonStr = String(trimmed.dropFirst(6))
                guard let chunkData = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else { continue }
                switch json["type"] as? String ?? "" {
                case "message_start":
                    found = true
                    if let message = json["message"] as? [String: Any],
                       let u = message["usage"] as? [String: Any] {
                        input = u["input_tokens"] as? Int ?? 0
                        cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
                    }
                case "message_delta":
                    found = true
                    if let u = json["usage"] as? [String: Any] {
                        output = u["output_tokens"] as? Int ?? 0
                        cacheCreation = u["cache_creation_input_tokens"] as? Int ?? 0
                    }
                default:
                    break
                }
            }
            guard found else { return }
            usage = [
                "input_tokens": input,
                "output_tokens": output,
                "total_tokens": input + output,
                "cache_creation_input_tokens": cacheCreation,
                "cache_read_input_tokens": cacheRead,
            ]
        }

        guard let usage else { return }
        writeMessagesUsage(requestBody: requestBody, usage: usage, latencyMs: latencyMs, statusCode: statusCode, providerId: providerId, userAgent: userAgent)
    }

    private func writeMessagesUsage(requestBody: Data, usage: [String: Any], latencyMs: Double, statusCode: Int, providerId: String = "", userAgent: String = "") {
        var model = "unknown"
        if let reqJSON = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            model = reqJSON["model"] as? String ?? "unknown"
        }
        saveLastModel(model, providerId: providerId)
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let record = UsageRecord(
            uuid: UUID().uuidString,
            timestamp: Date(),
            providerId: providerId,
            model: model,
            endpoint: "/v1/messages",
            promptTokens: input,
            completionTokens: output,
            totalTokens: usage["total_tokens"] as? Int ?? (input + output),
            cachedTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            reasoningTokens: 0,
            latencyMs: latencyMs,
            statusCode: statusCode,
            userAgent: userAgent,
            sourceIP: ""
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
            userAgent: userAgent,
            sourceIP: ""
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
