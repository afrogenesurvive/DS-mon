import Foundation

// MARK: - Responses API (inbound from Codex CLI)

struct ResponsesRequest: Codable {
    let model: String
    let input: ResponsesInput
    var previousResponseId: String?
    var tools: [JSONValue]?
    var stream: Bool?
    var temperature: Double?
    var maxOutputTokens: Int?
    var system: String?
    var instructions: String?

    enum CodingKeys: String, CodingKey {
        case model, input, tools, stream, temperature, system, instructions
        case previousResponseId = "previous_response_id"
        case maxOutputTokens = "max_output_tokens"
    }
}

enum ResponsesInput: Codable {
    case text(String)
    case items([[String: JSONValue]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let items = try? container.decode([[String: JSONValue]].self) {
            self = .items(items)
        } else {
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .items(let items):
            try container.encode(items)
        }
    }
}

// MARK: - Chat Completions (outbound to provider)

struct ChatRequest: Codable {
    let model: String
    var messages: [ChatMessage]
    var tools: [JSONValue]?
    var temperature: Double?
    var maxTokens: Int?
    var streamOptions: ChatStreamOptions?
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature, stream
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
    }
}

struct ChatStreamOptions: Codable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct ChatMessage: Codable {
    var role: String
    var content: JSONValue?
    var reasoningContent: String?
    var toolCalls: [JSONValue]?
    var toolCallId: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

struct ChatResponse: Codable {
    let choices: [ChatChoice]
    let usage: ChatUsage?
}

struct ChatChoice: Codable {
    let message: ChatMessage
}

struct ChatUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let promptCacheHitTokens: Int?
    let promptTokensDetails: PromptTokensDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    var cachedTokens: Int {
        promptCacheHitTokens ?? promptTokensDetails?.cachedTokens ?? 0
    }
}

struct PromptTokensDetails: Codable {
    let cachedTokens: Int

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

// MARK: - SSE streaming types

struct ChatStreamChunk: Codable {
    let choices: [ChatStreamChoice]
    let usage: ChatUsage?
}

struct ChatStreamChoice: Codable {
    let delta: ChatDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

struct ChatDelta: Codable {
    let role: String?
    let content: String?
    let reasoningContent: String?
    let toolCalls: [DeltaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

struct DeltaToolCall: Codable {
    let index: Int
    let id: String?
    let function: DeltaFunction?
}

struct DeltaFunction: Codable {
    let name: String?
    let arguments: String?
}

// MARK: - Responses API output types

struct ResponsesOutputMessage: Codable {
    let type: String
    let id: String
    let role: String
    let status: String
    let content: [ResponsesContentPart]
}

struct ResponsesContentPart: Codable {
    let type: String
    let text: String?
}

struct ResponsesOutputFunctionCall: Codable {
    let type: String
    let id: String
    let callId: String
    let name: String
    let arguments: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case type, id, name, arguments, status
        case callId = "call_id"
    }
}

// MARK: - Flexible JSON value for untyped fields

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let int = try? container.decode(Int.self) {
            self = .integer(int)
        } else if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .integer(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .integer(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}

// MARK: - Helper extensions

extension ChatMessage {
    var textContent: String {
        guard let content else { return "" }
        if case .string(let s) = content { return s }
        return ""
    }
}
