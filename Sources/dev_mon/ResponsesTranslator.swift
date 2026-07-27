import Foundation


// MARK: - Responses API → Chat Completions

/// 将 Responses API 请求转换为 Chat Completions 请求
func toChatRequest(
    req: ResponsesRequest,
    history: [ChatMessage],
    sessions: ResponsesSessionStore
) -> ChatRequest {
    var messages = history

    // 处理 system prompt (instructions 优先)
    let systemText = req.instructions ?? req.system
    if let system = systemText {
        if messages.isEmpty || messages[0].role != "system" {
            messages.insert(ChatMessage(
                role: "system",
                content: .string(system),
                reasoningContent: nil,
                toolCalls: nil,
                toolCallId: nil,
                name: nil
            ), at: 0)
        }
    }

    // 处理 input
    switch req.input {
    case .text(let text):
        messages.append(ChatMessage(
            role: "user",
            content: .string(text),
            reasoningContent: nil,
            toolCalls: nil,
            toolCallId: nil,
            name: nil
        ))

    case .items(let items):
        // 收集历史中已有的 call_id
        let existingCallIds: Set<String> = Set(messages.flatMap { msg in
            var ids: [String] = []
            if let tcs = msg.toolCalls {
                ids += tcs.compactMap { $0.objectValue?["id"]?.stringValue }
            }
            if let id = msg.toolCallId { ids.append(id) }
            return ids
        })

        let existingToolResponses: Set<String> = Set(
            messages.compactMap { $0.toolCallId }
        )

        var i = 0
        while i < items.count {
            let item = items[i]
            let itemType = item["type"]?.stringValue ?? ""

            if itemType == "function_call" {
                let callId = item["call_id"]?.stringValue ?? ""
                if existingCallIds.contains(callId) {
                    i += 1; continue
                }

                // 合并连续 function_call 为一个 assistant 消息
                var grouped: [JSONValue] = []
                var reasoningContent: String? = nil

                while i < items.count {
                    let cur = items[i]
                    if cur["type"]?.stringValue != "function_call" { break }
                    let cId = cur["call_id"]?.stringValue ?? ""
                    let name = responseFunctionNameForChat(cur)
                    let args = cur["arguments"]?.stringValue ?? "{}"
                    if reasoningContent == nil {
                        reasoningContent = sessions.getReasoning(callId: cId)
                    }
                    grouped.append(.object([
                        "id": .string(cId),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(name),
                            "arguments": .string(args)
                        ])
                    ]))
                    i += 1
                }

                var msg = ChatMessage(
                    role: "assistant",
                    content: nil,
                    reasoningContent: reasoningContent,
                    toolCalls: grouped.isEmpty ? nil : grouped,
                    toolCallId: nil,
                    name: nil
                )

                // Fallback: turn-level reasoning
                if msg.reasoningContent == nil {
                    msg.reasoningContent = sessions.getTurnReasoning(
                        messages: messages,
                        assistantMsg: msg
                    )
                }
                messages.append(msg)

            } else {
                switch itemType {
                case "function_call_output":
                    let callId = item["call_id"]?.stringValue ?? ""
                    if existingToolResponses.contains(callId) {
                        i += 1; continue
                    }
                    let output = item["output"]?.stringValue ?? ""
                    messages.append(ChatMessage(
                        role: "tool",
                        content: .string(output),
                        reasoningContent: nil,
                        toolCalls: nil,
                        toolCallId: callId,
                        name: nil
                    ))

                case "reasoning":
                    // Codex 历史中的 reasoning 项，跳过
                    break

                default:
                    // 普通 user/assistant/developer 消息
                    let role = item["role"]?.stringValue ?? "user"
                    let mappedRole = role == "developer" ? "system" : role
                    var msg = ChatMessage(
                        role: mappedRole,
                        content: valueToChatContent(item["content"]),
                        reasoningContent: nil,
                        toolCalls: nil,
                        toolCallId: nil,
                        name: nil
                    )
                    if msg.role == "assistant" {
                        msg.reasoningContent = sessions.getTurnReasoning(
                            messages: messages,
                            assistantMsg: msg
                        )
                    }
                    if msg.role == "system" {
                        if !messages.isEmpty && messages[0].role == "system" {
                            messages[0] = msg
                        } else {
                            messages.insert(msg, at: 0)
                        }
                    } else {
                        messages.append(msg)
                    }
                }
                i += 1
            }
        }
    }

    let convertedTools = convertTools(req.tools)
    return ChatRequest(
        model: req.model,
        messages: messages,
        tools: convertedTools.isEmpty ? nil : convertedTools,
        temperature: req.temperature,
        maxTokens: req.maxOutputTokens,
        streamOptions: nil,
        stream: req.stream ?? false
    )
}

// MARK: - Chat Completions → Responses API (非流式)

func fromChatResponse(
    responseId: String,
    model: String,
    chatResp: ChatResponse,
    namespaceTools: [String: (namespace: String, name: String)]
) -> ([String: JSONValue], ChatUsage?) {
    fromChatResponseWithToolMap(
        responseId: responseId,
        model: model,
        chatResp: chatResp,
        namespaceTools: namespaceTools
    )
}

func fromChatResponseWithToolMap(
    responseId: String,
    model: String,
    chatResp: ChatResponse,
    namespaceTools: [String: (namespace: String, name: String)]
) -> ([String: JSONValue], ChatUsage?) {
    guard let choice = chatResp.choices.first else {
        return ([:], chatResp.usage)
    }

    let msg = choice.message
    var output: [JSONValue] = []

    // 文本输出
    if let content = msg.content, case .string(let text) = content, !text.isEmpty {
        output.append(.object([
            "type": .string("message"),
            "id": .string("msg_\(UUID().uuidString.prefix(8))"),
            "role": .string("assistant"),
            "status": .string("completed"),
            "content": .array([
                .object(["type": .string("output_text"), "text": .string(text)])
            ])
        ]))
    }

    // 工具调用输出
    if let tcs = msg.toolCalls {
        for (idx, tc) in tcs.enumerated() {
            if let tcObj = tc.objectValue {
                let rawName = tcObj["function"]?.objectValue?["name"]?.stringValue ?? ""
                let args = tcObj["function"]?.objectValue?["arguments"]?.stringValue ?? "{}"
                let callId = tcObj["id"]?.stringValue ?? "call_\(idx)"
                let (ns, mappedName) = responseFunctionNameForResponses(rawName, namespaceTools: namespaceTools)
                var item: [String: JSONValue] = [
                    "type": .string("function_call"),
                    "id": .string("fc_\(UUID().uuidString.prefix(8))"),
                    "call_id": .string(callId),
                    "name": .string(mappedName),
                    "arguments": .string(args),
                    "status": .string("completed")
                ]
                if let ns { item["namespace"] = .string(ns) }
                output.append(.object(item))
            }
        }
    }

    let response: [String: JSONValue] = [
        "id": .string(responseId),
        "object": .string("response"),
        "model": .string(model),
        "status": .string("completed"),
        "output": .array(output),
        "usage": .object(buildUsageJSON(chatResp.usage))
    ]

    return (response, chatResp.usage)
}

// MARK: - 辅助函数

private func responseFunctionNameForChat(_ item: [String: JSONValue]) -> String {
    guard let name = item["name"]?.stringValue else { return "unknown" }
    if let namespace = item["namespace"]?.stringValue, !namespace.isEmpty {
        return chatFunctionNameForNamespace(namespace: namespace, name: name)
    }
    return name
}

private func valueToChatContent(_ value: JSONValue?) -> JSONValue? {
    guard let value else { return nil }
    switch value {
    case .string(let s):
        return .string(s)
    case .array(let parts):
        let hasNonText = parts.contains { part in
            guard let obj = part.objectValue else { return true }
            let kind = obj["type"]?.stringValue ?? ""
            return !(kind == "input_text" || kind == "text" || kind == "output_text")
        }
        if !hasNonText {
            let text = parts.compactMap { part -> String? in
                part.objectValue?["text"]?.stringValue
            }.joined()
            return .string(text)
        }
        let mapped: [JSONValue] = parts.map { mapContentPart($0) }
        return .array(mapped)
    default:
        return value
    }
}

private func mapContentPart(_ part: JSONValue) -> JSONValue {
    guard let obj = part.objectValue,
          let kind = obj["type"]?.stringValue else { return part }
    switch kind {
    case "input_text", "text", "output_text":
        let text = obj["text"]?.stringValue ?? ""
        return .object(["type": .string("text"), "text": .string(text)])
    case "input_image":
        let url = obj["image_url"]?.stringValue ?? ""
        return .object([
            "type": .string("image_url"),
            "image_url": .object(["url": .string(url)])
        ])
    case "image_url":
        let inner: JSONValue
        if let objVal = obj["image_url"]?.objectValue {
            inner = .object(objVal)
        } else if let strVal = obj["image_url"]?.stringValue {
            inner = .object(["url": .string(strVal)])
        } else {
            inner = .object(["url": .string("")])
        }
        return .object(["type": .string("image_url"), "image_url": inner])
    default:
        return part
    }
}

private func buildUsageJSON(_ usage: ChatUsage?) -> [String: JSONValue] {
    guard let usage else {
        return [
            "input_tokens": .integer(0),
            "output_tokens": .integer(0),
            "total_tokens": .integer(0)
        ]
    }
    var result: [String: JSONValue] = [
        "input_tokens": .integer(usage.promptTokens),
        "output_tokens": .integer(usage.completionTokens),
        "total_tokens": .integer(usage.totalTokens)
    ]
    if usage.cachedTokens > 0 {
        result["input_tokens_details"] = .object([
            "cached_tokens": .integer(usage.cachedTokens)
        ])
    }
    return result
}

// MARK: - SSE 翻译 (流式)

/// 将 upstream Chat Completions SSE 行翻译为 Responses API 事件行
func translateSSEToResponsesEvent(
    sseData: String,
    responseId: String,
    model: String,
    state: inout StreamTranslationState
) -> [String] {
    var events: [String] = []

    // 跳过 [DONE]
    let trimmed = sseData.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != "[DONE]", !trimmed.isEmpty else { return events }

    // 首次调用时发送 response.created
    if !state.didEmitCreated {
        events.append(buildSSEEvent(event: "response.created", data: [
            "type": "response.created",
            "response": [
                "id": responseId,
                "status": "in_progress",
                "model": model
            ] as [String: Any]
        ]))
        state.didEmitCreated = true
    }

    guard let chunkData = trimmed.data(using: .utf8),
          let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: chunkData)
    else { return events }

    // 记录 usage
    if let usage = chunk.usage {
        state.streamUsage = usage
    }

    guard let choice = chunk.choices.first else { return events }

    // 累积 content
    if let content = choice.delta.content {
        state.accumulatedText += content
        if !state.didEmitMessageItem {
            events.append(buildSSEEvent(event: "response.output_item.added", data: [
                "type": "response.output_item.added",
                "item": [
                    "type": "message",
                    "id": state.messageItemId,
                    "role": "assistant",
                    "status": "in_progress",
                    "content": []
                ] as [String: Any]
            ]))
            state.didEmitMessageItem = true
        }
        events.append(buildSSEEvent(event: "response.output_text.delta", data: [
            "type": "response.output_text.delta",
            "item_id": state.messageItemId,
            "output_index": 0,
            "delta": content
        ]))
    }

    // 累积 reasoning
    if let reasoning = choice.delta.reasoningContent {
        state.accumulatedReasoning += reasoning
    }

    // 累积 tool_calls
    if let tcs = choice.delta.toolCalls {
        for tc in tcs {
            let index = tc.index
            if state.toolCallAccums[index] == nil {
                state.toolCallAccums[index] = ToolCallAccum(
                    id: tc.id ?? "call_\(index)",
                    name: tc.function?.name ?? "",
                    arguments: ""
                )
                let fcItemId = "fc_\(UUID().uuidString.prefix(8))"
                state.toolCallItemIds[index] = fcItemId

                let outputIndex = (state.didEmitMessageItem ? 1 : 0) + index
                events.append(buildSSEEvent(event: "response.output_item.added", data: [
                    "type": "response.output_item.added",
                    "output_index": outputIndex,
                    "item": [
                        "type": "function_call",
                        "id": fcItemId,
                        "call_id": state.toolCallAccums[index]!.id,
                        "name": state.toolCallAccums[index]!.name,
                        "arguments": "",
                        "status": "in_progress"
                    ] as [String: Any]
                ]))
            }
            if let args = tc.function?.arguments {
                state.toolCallAccums[index]!.arguments += args
                let fcItemId = state.toolCallItemIds[index] ?? ""
                let outputIndex = (state.didEmitMessageItem ? 1 : 0) + index
                events.append(buildSSEEvent(event: "response.function_call_arguments.delta", data: [
                    "type": "response.function_call_arguments.delta",
                    "item_id": fcItemId,
                    "output_index": outputIndex,
                    "delta": args
                ]))
            }
            if let name = tc.function?.name {
                state.toolCallAccums[index]!.name = name
            }
            if let id = tc.id {
                state.toolCallAccums[index]!.id = id
            }
        }
    }

    // finish_reason → close message/tool items + response.completed
    if let reason = choice.finishReason, !reason.isEmpty {
        // 关闭 message item
        if state.didEmitMessageItem {
            events.append(buildSSEEvent(event: "response.output_item.done", data: [
                "type": "response.output_item.done",
                "output_index": 0,
                "item": [
                    "type": "message",
                    "id": state.messageItemId,
                    "role": "assistant",
                    "status": "completed",
                    "content": [
                        ["type": "output_text", "text": state.accumulatedText]
                    ]
                ] as [String: Any]
            ]))
        }

        // 关闭 tool call items
        for (idx, accum) in state.toolCallAccums.sorted(by: { $0.key < $1.key }) {
            let fcItemId = state.toolCallItemIds[idx] ?? ""
            let outputIndex = (state.didEmitMessageItem ? 1 : 0) + idx
            events.append(buildSSEEvent(event: "response.output_item.done", data: [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": [
                    "type": "function_call",
                    "id": fcItemId,
                    "call_id": accum.id,
                    "name": accum.name,
                    "arguments": accum.arguments,
                    "status": "completed"
                ] as [String: Any]
            ]))
        }

        // response.completed
        let usage = state.streamUsage ?? ChatUsage(
            promptTokens: 0, completionTokens: 0, totalTokens: 0,
            promptCacheHitTokens: nil, promptTokensDetails: nil
        )
        events.append(buildSSEEvent(event: "response.completed", data: [
            "type": "response.completed",
            "response": [
                "id": responseId,
                "status": "completed",
                "model": model,
                "output": buildStreamOutputArray(state: state),
                "usage": [
                    "input_tokens": usage.promptTokens,
                    "output_tokens": usage.completionTokens,
                    "total_tokens": usage.totalTokens,
                    "input_tokens_details": [
                        "cached_tokens": usage.cachedTokens
                    ]
                ]
            ] as [String: Any]
        ]))

        state.streamDone = true
    }

    return events
}

// MARK: - SSE 辅助

private func buildSSEEvent(event: String, data: [String: Any]) -> String {
    let jsonData = (try? JSONSerialization.data(withJSONObject: data)) ?? Data()
    let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
    return "event: \(event)\ndata: \(jsonStr)\n\n"
}

private func buildStreamOutputArray(state: StreamTranslationState) -> [[String: Any]] {
    var output: [[String: Any]] = []
    if state.didEmitMessageItem {
        output.append([
            "type": "message",
            "id": state.messageItemId,
            "role": "assistant",
            "status": "completed",
            "content": [
                ["type": "output_text", "text": state.accumulatedText]
            ]
        ])
    }
    for (idx, accum) in state.toolCallAccums.sorted(by: { $0.key < $1.key }) {
        let fcItemId = state.toolCallItemIds[idx] ?? ""
        output.append([
            "type": "function_call",
            "id": fcItemId,
            "call_id": accum.id,
            "name": accum.name,
            "arguments": accum.arguments,
            "status": "completed"
        ])
    }
    return output
}

// MARK: - 流式翻译状态

struct StreamTranslationState {
    var didEmitCreated = false
    var didEmitMessageItem = false
    var accumulatedText = ""
    var accumulatedReasoning = ""
    var messageItemId = "msg_\(UUID().uuidString.prefix(8))"
    var toolCallAccums: [Int: ToolCallAccum] = [:]
    var toolCallItemIds: [Int: String] = [:]
    var streamUsage: ChatUsage? = nil
    var streamDone = false
}

struct ToolCallAccum {
    var id: String
    var name: String
    var arguments: String
}
