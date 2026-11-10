import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema object for the arguments.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// Everything needed to reach a gateway.
public struct Connection: Equatable, Sendable {
    public var format: APIFormat
    public var baseURL: String
    public var apiKey: String
    public var authScheme: AuthScheme
    public var headers: [HeaderField]

    public init(format: APIFormat = .anthropic, baseURL: String, apiKey: String = "",
                authScheme: AuthScheme = .bearer, headers: [HeaderField] = []) {
        self.format = format
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.authScheme = authScheme
        self.headers = headers
    }

    func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        // Anthropic-style base URLs are normally given without the version segment; accept both.
        if format == .anthropic, !base.lowercased().hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw ClientError.invalidBaseURL(baseURL)
        }
        return url
    }

    func apply(to request: inout URLRequest) {
        if !apiKey.isEmpty {
            switch authScheme {
            case .bearer: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .xAPIKey: request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
        }
        if format == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        // Custom headers go last so they replace a built-in header of the same name.
        for header in headers where !header.name.trimmed.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name.trimmed)
        }
    }
}

public struct ChatRequest: Sendable {
    public var connection: Connection
    public var model: String
    public var system: String
    /// Conversation without system messages.
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var effort: Effort
    public var maxOutputTokens: Int
    public var promptCaching: Bool

    public init(connection: Connection, model: String, system: String = "", messages: [ChatMessage],
                tools: [ToolSpec] = [], effort: Effort = .auto, maxOutputTokens: Int = 16_000, promptCaching: Bool = true) {
        self.connection = connection
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.maxOutputTokens = maxOutputTokens
        self.promptCaching = promptCaching
    }
}

public enum StopReason: String, Equatable, Sendable {
    case endTurn, toolUse, maxTokens, refusal, other
}

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case thinking(String)
    /// A fragment of a tool call; fragments with the same index belong together.
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case usage(input: Int, output: Int)
    /// The finished assistant turn in the provider's own JSON, for replaying it unchanged.
    case providerContent(String)
    case stop(StopReason)
}

public protocol ChatStreaming: Sendable {
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public enum ClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value): return "invalid base URL: \(value)"
        }
    }
}

/// An error reported inside a response stream that started successfully.
public struct StreamError: LocalizedError, Equatable {
    public var type: String
    public var message: String

    public var errorDescription: String? { type.isEmpty ? message : "\(type): \(message)" }
}

/// Splits a server-sent-events byte stream into `data:` payloads.
public struct SSEParser {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var payloads: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") else { continue }
            var payload = text.dropFirst(5)
            if payload.first == " " { payload = payload.dropFirst() }
            payloads.append(String(payload))
        }
        return payloads
    }
}

enum JSON {
    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}

public enum History {
    /// Makes a message list safe to send: every tool call is followed by its result, results without a
    /// call are dropped, and empty turns are removed. A run that was killed part-way can leave such gaps.
    public static func sanitized(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            index += 1
            switch message.role {
            case .tool:
                continue
            case .assistant:
                let calls = message.toolCalls ?? []
                if calls.isEmpty, message.content.trimmed.isEmpty { continue }
                result.append(message)
                guard !calls.isEmpty else { continue }
                var results: [String: ChatMessage] = [:]
                while index < messages.count, messages[index].role == .tool {
                    if let id = messages[index].toolCallID { results[id] = messages[index] }
                    index += 1
                }
                for call in calls {
                    result.append(results[call.id] ?? ChatMessage(
                        role: .tool, content: "[interrupted before this tool call finished]",
                        toolCallID: call.id, isError: true))
                }
            case .user, .system:
                if !message.content.trimmed.isEmpty { result.append(message) }
            }
        }
        return result
    }
}

protocol StreamDecoding {
    mutating func decode(_ payload: String) throws -> [StreamEvent]
    /// Events still owed when the stream ends.
    mutating func finish() -> [StreamEvent]
}

// MARK: OpenAI-compatible chat completions

enum OpenAIFormat {
    static func encode(_ message: ChatMessage) -> [String: Any] {
        switch message.role {
        case .system, .user:
            return ["role": message.role.rawValue, "content": message.content]
        case .assistant:
            let calls = message.toolCalls ?? []
            var object: [String: Any] = ["role": "assistant"]
            object["content"] = message.content.isEmpty && !calls.isEmpty ? NSNull() : message.content
            if !calls.isEmpty {
                object["tool_calls"] = calls.map { call -> [String: Any] in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]]
                }
            }
            return object
        case .tool:
            return ["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.content]
        }
    }

    static func body(for request: ChatRequest) throws -> Data {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        messages += History.sanitized(request.messages).map(encode)
        var object: [String: Any] = [
            "model": request.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]
        if !request.tools.isEmpty {
            object["tools"] = request.tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": ["name": tool.name, "description": tool.description,
                              "parameters": JSON.object(tool.parametersJSON) ?? ["type": "object"]]]
            }
        }
        if request.effort != .auto {
            // The levels above "high" are not part of this format.
            object["reasoning_effort"] = [.xhigh, .max].contains(request.effort) ? "high" : request.effort.rawValue
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    struct Decoder: StreamDecoding {
        private var stop: StopReason?

        mutating func decode(_ payload: String) throws -> [StreamEvent] {
            guard let object = JSON.object(payload) else { return [] }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                throw StreamError(type: (error["type"] as? String) ?? "", message: message)
            }
            var events: [StreamEvent] = []
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                if let delta = choice["delta"] as? [String: Any] {
                    if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
                       !reasoning.isEmpty {
                        events.append(.thinking(reasoning))
                    }
                    if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
                    for (position, call) in ((delta["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                        let function = call["function"] as? [String: Any]
                        events.append(.toolCallDelta(
                            index: (call["index"] as? NSNumber)?.intValue ?? position,
                            id: call["id"] as? String,
                            name: function?["name"] as? String,
                            arguments: function?["arguments"] as? String))
                    }
                }
                switch choice["finish_reason"] as? String {
                case "stop": stop = .endTurn
                case "tool_calls", "function_call": stop = .toolUse
                case "length": stop = .maxTokens
                case "content_filter": stop = .refusal
                case .some: stop = .other
                case nil: break
                }
            }
            if let usage = object["usage"] as? [String: Any] {
                let input = JSON.int(usage["prompt_tokens"]), output = JSON.int(usage["completion_tokens"])
                if input > 0 || output > 0 { events.append(.usage(input: input, output: output)) }
            }
            return events
        }

        mutating func finish() -> [StreamEvent] {
            defer { stop = nil }
            return stop.map { [.stop($0)] } ?? []
        }
    }
}

// MARK: Anthropic Messages

enum AnthropicFormat {
    static func messages(for request: ChatRequest) -> [[String: Any]] {
        var turns: [(role: String, blocks: [[String: Any]])] = []
        // The API wants alternating turns, so adjacent messages of one role are merged. Tool results are
        // user-role blocks and end up at the start of the user turn that follows the tool calls.
        func add(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.indices.last, turns[last].role == role {
                turns[last].blocks += blocks
            } else {
                turns.append((role, blocks))
            }
        }

        for message in History.sanitized(request.messages) {
            switch message.role {
            case .system:
                continue
            case .user:
                add("user", [["type": "text", "text": message.content]])
            case .assistant:
                // Blocks from the same model go back untouched: reasoning blocks carry signatures that
                // must not change. For another model the turn is rebuilt from text and tool calls.
                if message.model == request.model, let raw = message.providerContent,
                   let blocks = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
                   !blocks.isEmpty {
                    add("assistant", blocks)
                } else {
                    var blocks: [[String: Any]] = []
                    if !message.content.trimmed.isEmpty { blocks.append(["type": "text", "text": message.content]) }
                    for call in message.toolCalls ?? [] {
                        blocks.append(["type": "tool_use", "id": call.id, "name": call.name,
                                       "input": JSON.object(call.arguments) ?? [String: Any]()])
                    }
                    add("assistant", blocks)
                }
            case .tool:
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.content.isEmpty ? "(no output)" : message.content,
                ]
                if message.isError == true { block["is_error"] = true }
                add("user", [block])
            }
        }
        // A breakpoint on the newest block lets the next tool round reuse the whole conversation so far.
        if request.promptCaching, let last = turns.indices.last, turns[last].role == "user",
           let block = turns[last].blocks.indices.last {
            turns[last].blocks[block]["cache_control"] = ["type": "ephemeral"]
        }
        return turns.map { ["role": $0.role, "content": $0.blocks] }
    }

    static func body(for request: ChatRequest) throws -> Data {
        var object: [String: Any] = [
            "model": request.model,
            "max_tokens": max(request.maxOutputTokens, 1),
            "stream": true,
            "messages": messages(for: request),
        ]
        if !request.system.isEmpty {
            var block: [String: Any] = ["type": "text", "text": request.system]
            if request.promptCaching { block["cache_control"] = ["type": "ephemeral"] }
            object["system"] = [block]
        }
        if !request.tools.isEmpty {
            object["tools"] = request.tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description,
                 "input_schema": JSON.object(tool.parametersJSON) ?? ["type": "object"]]
            }
        }
        if request.effort != .auto { object["output_config"] = ["effort": request.effort.rawValue] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    struct Decoder: StreamDecoding {
        private var blocks: [Int: [String: Any]] = [:]
        private var order: [Int] = []
        private var partialInput: [Int: String] = [:]
        private var input = 0
        private var output = 0
        private var stop: StopReason?
        private var finished = false

        private mutating func read(_ usage: [String: Any]) {
            // Cached tokens are reported separately; together with the rest they are the prompt size.
            if usage["input_tokens"] != nil {
                input = JSON.int(usage["input_tokens"]) + JSON.int(usage["cache_creation_input_tokens"])
                    + JSON.int(usage["cache_read_input_tokens"])
            }
            if usage["output_tokens"] != nil { output = JSON.int(usage["output_tokens"]) }
        }

        /// Appends streamed text to a string field of the block being built.
        private mutating func extend(_ key: String, at index: Int, with value: String) {
            guard var block = blocks[index] else { return }
            block[key] = ((block[key] as? String) ?? "") + value
            blocks[index] = block
        }

        mutating func decode(_ payload: String) throws -> [StreamEvent] {
            guard let object = JSON.object(payload), let type = object["type"] as? String else { return [] }
            let index = JSON.int(object["index"])
            switch type {
            case "message_start":
                if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] { read(usage) }
                return []

            case "content_block_start":
                guard let block = object["content_block"] as? [String: Any] else { return [] }
                blocks[index] = block
                order.append(index)
                switch block["type"] as? String {
                case "tool_use":
                    var arguments: String?
                    // Some gateways send the whole input up front instead of as deltas.
                    if let whole = block["input"] as? [String: Any], !whole.isEmpty,
                       let data = try? JSONSerialization.data(withJSONObject: whole) {
                        arguments = String(decoding: data, as: UTF8.self)
                        partialInput[index] = arguments
                    }
                    return [.toolCallDelta(index: index, id: block["id"] as? String, name: block["name"] as? String,
                                           arguments: arguments)]
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { return [.text(text)] }
                case "thinking":
                    if let text = block["thinking"] as? String, !text.isEmpty { return [.thinking(text)] }
                default:
                    break
                }
                return []

            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "text_delta":
                    guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                    extend("text", at: index, with: text)
                    return [.text(text)]
                case "input_json_delta":
                    guard let partial = delta["partial_json"] as? String, !partial.isEmpty else { return [] }
                    partialInput[index, default: ""] += partial
                    return [.toolCallDelta(index: index, id: nil, name: nil, arguments: partial)]
                case "thinking_delta":
                    guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                    extend("thinking", at: index, with: text)
                    return [.thinking(text)]
                case "signature_delta":
                    if let signature = delta["signature"] as? String { extend("signature", at: index, with: signature) }
                    return []
                default:
                    return []
                }

            case "content_block_stop":
                return []

            case "message_delta":
                if let usage = object["usage"] as? [String: Any] { read(usage) }
                switch (object["delta"] as? [String: Any])?["stop_reason"] as? String {
                case "end_turn", "stop_sequence": stop = .endTurn
                case "tool_use": stop = .toolUse
                case "max_tokens", "model_context_window_exceeded": stop = .maxTokens
                case "refusal": stop = .refusal
                case .some: stop = .other
                case nil: break
                }
                return input > 0 || output > 0 ? [.usage(input: input, output: output)] : []

            case "message_stop":
                return finish()

            case "error":
                let error = object["error"] as? [String: Any]
                throw StreamError(type: (error?["type"] as? String) ?? "",
                                  message: (error?["message"] as? String) ?? "the gateway reported an error")

            default:
                // ping and event types added later
                return []
            }
        }

        mutating func finish() -> [StreamEvent] {
            guard !finished else { return [] }
            finished = true
            var events: [StreamEvent] = []
            var content: [[String: Any]] = []
            for index in order {
                guard var block = blocks[index] else { continue }
                if block["type"] as? String == "tool_use", let partial = partialInput[index] {
                    block["input"] = JSON.object(partial) ?? [String: Any]()
                }
                // An empty text block is rejected when sent back.
                if block["type"] as? String == "text", ((block["text"] as? String) ?? "").trimmed.isEmpty { continue }
                content.append(block)
            }
            if !content.isEmpty, let data = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) {
                events.append(.providerContent(String(decoding: data, as: UTF8.self)))
            }
            if let stop { events.append(.stop(stop)) }
            return events
        }
    }
}

// MARK: Client

/// Streams chat turns from a gateway in either wire format and lists its models.
public struct GatewayClient: ChatStreaming {
    public init() {}

    static func urlRequest(for request: ChatRequest) throws -> URLRequest {
        let anthropic = request.connection.format == .anthropic
        var urlRequest = URLRequest(url: try request.connection.endpoint(anthropic ? "/messages" : "/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.connection.apply(to: &urlRequest)
        urlRequest.httpBody = anthropic ? try AnthropicFormat.body(for: request) : try OpenAIFormat.body(for: request)
        return urlRequest
    }

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.urlRequest(for: request)
                    var decoder: StreamDecoding = request.connection.format == .anthropic
                        ? AnthropicFormat.Decoder() : OpenAIFormat.Decoder()
                    var parser = SSEParser()
                    var status = 0
                    var errorBody = Data()
                    for try await chunk in HTTP.stream(urlRequest) {
                        switch chunk {
                        case .status(let code):
                            status = code
                        case .data(let data):
                            guard (200..<300).contains(status) else {
                                errorBody.append(data)
                                continue
                            }
                            for payload in parser.feed(data) where payload != "[DONE]" {
                                for event in try decoder.decode(payload) { continuation.yield(event) }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard (200..<300).contains(status) else { throw APIError.from(status: status, body: errorBody) }
                    for event in decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Models the gateway advertises, in the gateway's own order.
    public func listModels(_ connection: Connection) async throws -> [ModelInfo] {
        var request = URLRequest(url: try connection.endpoint(connection.format == .anthropic ? "/models?limit=1000" : "/models"))
        request.timeoutInterval = 20
        connection.apply(to: &request)
        let (status, body) = try await HTTP.collect(request)
        guard (200..<300).contains(status) else { throw APIError.from(status: status, body: body) }
        let object = try? JSONSerialization.jsonObject(with: body)
        let dictionary = object as? [String: Any]
        let entries = (dictionary?["data"] as? [[String: Any]]) ?? (dictionary?["models"] as? [[String: Any]])
            ?? (object as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return entries.compactMap { entry -> ModelInfo? in
            guard let id = (entry["id"] as? String) ?? (entry["name"] as? String), seen.insert(id).inserted else { return nil }
            return ModelInfo(id: id, displayName: entry["display_name"] as? String)
        }
    }
}
