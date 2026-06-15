import Foundation
extension ProxyConnectionHandler {
    // MARK: - Responses API 直接处理

    /// 直接处理 /v1/responses 请求：翻译 → URLSession 发送 → 返回响应
    func handleResponsesDirectly(
        method: String, path: String, headers: [String: String], body: Data,
        providerInfo: (baseURL: String, authHeader: String?, providerId: String, apiPath: String, defaultModel: String?)?,
        requestModel: String
    ) async {
        // 解析 Responses API 请求
        guard let reqJSON = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reqData = try? JSONSerialization.data(withJSONObject: reqJSON),
              let responsesReq = try? JSONDecoder().decode(ResponsesRequest.self, from: reqData)
        else {
            //appendLog("[Responses] 无法解析请求: \(requestModel)")
            sendError(code: 400, body: "Invalid request body")
            onRequestCompleted()
            onFinished?()
            return
        }

        let isStreaming = responsesReq.stream ?? false
        let sessions = ResponsesSessionStore.shared

        // 获取历史消息
        let history = responsesReq.previousResponseId.flatMap {
            sessions.getHistory(responseId: $0)
        } ?? []

        // 转换为 Chat Completions 请求
        let chatReq = toChatRequest(req: responsesReq, history: history, sessions: sessions)

        guard let info = providerInfo else {
            sendError(code: 502, body: "No active provider")
            onRequestCompleted()
            onFinished?()
            return
        }

        // 构建上游 URL: baseURL + apiPath + "/chat/completions"
        let baseWithoutSlash = info.baseURL.hasSuffix("/")
            ? String(info.baseURL.dropLast())
            : info.baseURL
        let apiWithSlash: String
        if info.apiPath.isEmpty {
            apiWithSlash = ""
        } else if info.apiPath.hasPrefix("/") {
            apiWithSlash = info.apiPath
        } else {
            apiWithSlash = "/" + info.apiPath
        }
        guard let url = URL(string: "\(baseWithoutSlash)\(apiWithSlash)/chat/completions") else {
            sendError(code: 502, body: "Invalid upstream URL")
            onRequestCompleted()
            onFinished?()
            return
        }

        //appendLog("[Responses] URL: \(url.absoluteString)")
        //appendLog("[Responses] 翻译: \(chatReq.model) stream=\(isStreaming) tools=\(chatReq.tools?.count ?? 0) msgs=\(chatReq.messages.count)")

        // 编码 Chat Completions 请求
        if let chatBodyDebug = try? JSONEncoder().encode(chatReq),
           let bodyStr = String(data: chatBodyDebug, encoding: .utf8) {
            //appendLog("[Responses] 请求body: \(bodyStr.prefix(2000))")
        }
        guard let chatBody = try? JSONEncoder().encode(chatReq) else {
            sendError(code: 502, body: "Failed to encode chat request")
            onRequestCompleted()
            onFinished?()
            return
        }

        // 发起请求到 upstream
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.httpBody = chatBody
        urlReq.timeoutInterval = AppConfig.proxyRequestTimeout
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = info.authHeader {
            urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let start = Date()

        if isStreaming {
            await handleResponsesStreaming(
                urlReq: urlReq, responseId: sessions.newId(),
                model: chatReq.model, chatReq: chatReq,
                sessions: sessions, start: start
            )
        } else {
            await handleResponsesBlocking(
                urlReq: urlReq, responseId: sessions.newId(),
                model: chatReq.model, start: start
            )
        }
    }

    /// 处理流式 Responses API 请求
    func handleResponsesStreaming(
        urlReq: URLRequest, responseId: String, model: String,
        chatReq: ChatRequest, sessions: ResponsesSessionStore, start: Date
    ) async {
        var state = StreamTranslationState()
        var headersSent = false
        var accumulatedBody = Data()

        do {
            let (bytes, resp) = try await AppConfig.directURLSession.bytes(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502
            _ = (httpResp?.allHeaderFields as? [String: String]) ?? [:]

            if statusCode != 200 {
                //appendLog("[Responses] 上游错误 status=\(statusCode)")
                sendError(code: 502, body: "Upstream error: \(statusCode)")
                onRequestCompleted()
                onFinished?()
                return
            }

            // 发送 SSE 响应头
            var headerStr = "HTTP/1.1 200 OK\r\n"
            headerStr += "Content-Type: text/event-stream; charset=utf-8\r\n"
            headerStr += "Connection: close\r\n"
            headerStr += "Cache-Control: no-cache\r\n\r\n"
            guard let headerData = headerStr.data(using: .utf8) else {
                sendError(code: 502, body: "Header encoding error")
                onRequestCompleted()
                onFinished?()
                return
            }
            conn.send(content: headerData, completion: .contentProcessed { _ in })
            headersSent = true

            // 逐行读取 SSE 流（使用 Data 缓冲区避免 UTF-8 多字节字符乱码）
            var lineBuf = Data()
            for try await byte in bytes {
                accumulatedBody.append(byte)
                if byte == UInt8(ascii: "\n") {
                    if let line = String(data: lineBuf, encoding: .utf8),
                       line.hasPrefix("data: ") {
                        let dataContent = String(line.dropFirst(6))
                        if dataContent.trimmingCharacters(in: .whitespacesAndNewlines) != "[DONE]" {
                            let events = translateSSEToResponsesEvent(
                                sseData: dataContent,
                                responseId: responseId,
                                model: model,
                                state: &state
                            )
                            for event in events {
                                if let eventData = (event + "\n").data(using: .utf8) {
                                    conn.send(content: eventData, completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    lineBuf.removeAll(keepingCapacity: true)
                } else {
                    lineBuf.append(byte)
                }
            }

            // 流结束，确保 response.completed 或 tool call items 已关闭
            if !state.streamDone {
                if state.didEmitMessageItem {
                    let doneEvent = "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"\(state.messageItemId)\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(state.accumulatedText.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"}]}}\n\n"
                    if let d = doneEvent.data(using: .utf8) { conn.send(content: d, completion: .contentProcessed { _ in }) }
                }
                for (idx, accum) in state.toolCallAccums.sorted(by: { $0.key < $1.key }) {
                    let fcItemId = state.toolCallItemIds[idx] ?? ""
                    let args = accum.arguments.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let doneEvent = "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":\(idx+1),\"item\":{\"type\":\"function_call\",\"id\":\"\(fcItemId)\",\"call_id\":\"\(accum.id)\",\"name\":\"\(accum.name)\",\"arguments\":\"\(args)\",\"status\":\"completed\"}}\n\n"
                    if let d = doneEvent.data(using: .utf8) { conn.send(content: d, completion: .contentProcessed { _ in }) }
                }
                let completedEvent = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"\(responseId)\",\"status\":\"completed\",\"model\":\"\(model)\",\"output\":[],\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n"
                if let d = completedEvent.data(using: .utf8) { conn.send(content: d, completion: .contentProcessed { _ in }) }
            }

            conn.send(content: Data(), completion: .contentProcessed { [weak conn] _ in
                conn?.cancel()
            })

            // 保存会话
            let assistantToolCalls: [JSONValue]? = {
                if state.toolCallAccums.isEmpty { return nil }
                return state.toolCallAccums.sorted(by: { $0.key < $1.key }).map { (_, accum) in
                    .object([
                        "id": .string(accum.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(accum.name),
                            "arguments": .string(accum.arguments)
                        ])
                    ])
                }
            }()
            let assistantMsg = ChatMessage(
                role: "assistant",
                content: state.accumulatedText.isEmpty ? nil : .string(state.accumulatedText),
                reasoningContent: state.accumulatedReasoning.isEmpty ? nil : state.accumulatedReasoning,
                toolCalls: assistantToolCalls,
                toolCallId: nil, name: nil
            )
            var fullHistory = chatReq.messages
            fullHistory.append(assistantMsg)
            if !state.accumulatedReasoning.isEmpty {
                sessions.storeTurnReasoning(messages: chatReq.messages, assistantMsg: assistantMsg, reasoning: state.accumulatedReasoning)
            }
            sessions.saveWithId(id: responseId, messages: fullHistory)

        } catch {
            //appendLog("[Responses] 流错误: \(error.localizedDescription)")
            if !headersSent {
                sendError(code: 502, body: "Upstream error: \(error.localizedDescription)")
            } else {
                conn.cancel()
            }
        }
        onRequestCompleted()
        onFinished?()
    }

    /// 处理非流式 Responses API 请求
    func handleResponsesBlocking(
        urlReq: URLRequest, responseId: String, model: String, start: Date
    ) async {
        do {
            let (data, resp) =             try await AppConfig.directURLSession.data(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            guard statusCode == 200 else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                //appendLog("[Responses] 上游错误 \(statusCode): \(bodyText.prefix(200))")
                sendError(code: 502, body: "Upstream error: \(statusCode)")
                onRequestCompleted()
                onFinished?()
                return
            }

            guard let chatResp = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
                //appendLog("[Responses] 解析上游响应失败")
                sendError(code: 502, body: "Failed to parse upstream response")
                onRequestCompleted()
                onFinished?()
                return
            }

            let (respJSON, _) = fromChatResponse(
                responseId: responseId, model: model,
                chatResp: chatResp, namespaceTools: [:]
            )

            let responseData = try JSONSerialization.data(withJSONObject: respJSON)

            // 发送响应
            var headerStr = "HTTP/1.1 200 OK\r\n"
            headerStr += "Content-Type: application/json; charset=utf-8\r\n"
            headerStr += "Connection: close\r\n"
            headerStr += "Content-Length: \(responseData.count)\r\n\r\n"
            guard let headerData = headerStr.data(using: .utf8) else {
                sendError(code: 502, body: "Header encoding error")
                onRequestCompleted()
                onFinished?()
                return
            }
            conn.send(content: headerData, completion: .contentProcessed { _ in })
            conn.send(content: responseData, completion: .contentProcessed { [weak conn] _ in
                conn?.cancel()
            })

        } catch {
            //appendLog("[Responses] 阻塞请求错误: \(error.localizedDescription)")
            sendError(code: 502, body: "Upstream error: \(error.localizedDescription)")
        }
        onRequestCompleted()
        onFinished?()
    }

}
