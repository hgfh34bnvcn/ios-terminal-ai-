import XCTest
@testable import TermCore

final class GatewayTests: XCTestCase {
    func testSSEParserHandlesSplitChunksCRLFAndMultibyteCharacters() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: {\"a\"".utf8)), [])
        XCTAssertEqual(parser.feed(Data(":1}\r\n\r\ndata:[DONE]\n: comment\nevent: x\n".utf8)), ["{\"a\":1}", "[DONE]"])

        let bytes = Array("data: héllo ✓\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<8])), [])
        XCTAssertEqual(parser.feed(Data(bytes[8...])), ["héllo ✓"])
    }

    func testEndpoints() throws {
        func url(_ format: APIFormat, _ base: String, _ path: String) throws -> String {
            try Connection(format: format, baseURL: base).endpoint(path).absoluteString
        }
        // Anthropic-style bases work with or without the version segment.
        XCTAssertEqual(try url(.anthropic, "https://gw.example.com", "/messages"), "https://gw.example.com/v1/messages")
        XCTAssertEqual(try url(.anthropic, " https://gw.example.com/v1/ ", "/messages"), "https://gw.example.com/v1/messages")
        XCTAssertEqual(try url(.anthropic, "https://gw.example.com/proxy", "/models?limit=1000"),
                       "https://gw.example.com/proxy/v1/models?limit=1000")
        XCTAssertEqual(try url(.openAI, "https://api.example.com/v1/", "/chat/completions"),
                       "https://api.example.com/v1/chat/completions")
        XCTAssertThrowsError(try url(.openAI, "ftp://x", "/models"))
        XCTAssertThrowsError(try url(.anthropic, "not a url", "/models"))
    }

    func testOpenAIDecoding() throws {
        var decoder = OpenAIFormat.Decoder()
        XCTAssertEqual(try decoder.decode(#"{"choices":[{"delta":{"content":"hi"}}]}"#), [.text("hi")])
        XCTAssertEqual(try decoder.decode(#"{"choices":[{"delta":{"reasoning_content":"hm"}}]}"#), [.thinking("hm")])
        XCTAssertEqual(
            try decoder.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"Bash","arguments":"{\"co"}}]},"finish_reason":"tool_calls"}]}"#),
            [.toolCallDelta(index: 1, id: "c1", name: "Bash", arguments: "{\"co")])
        XCTAssertEqual(try decoder.decode(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#),
                       [.usage(input: 12, output: 3)])
        XCTAssertEqual(try decoder.decode("not json"), [])
        XCTAssertEqual(decoder.finish(), [.stop(.toolUse)])
        XCTAssertThrowsError(try decoder.decode(#"{"error":{"message":"boom","type":"server_error"}}"#)) { error in
            XCTAssertEqual(error as? StreamError, StreamError(type: "server_error", message: "boom"))
        }
    }

    func testAnthropicDecoding() throws {
        var decoder = AnthropicFormat.Decoder()
        var events: [StreamEvent] = []
        for payload in [
            #"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me check."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"123"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"it"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"and\":\"echo hi\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"some_future_event","value":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}"#,
            #"{"type":"message_stop"}"#,
        ] {
            events += try decoder.decode(payload)
        }

        XCTAssertEqual(Array(events.prefix(7)), [
            .thinking("Let me check."),
            .text("Checking "),
            .text("it"),
            .toolCallDelta(index: 2, id: "toolu_1", name: "Bash", arguments: nil),
            .toolCallDelta(index: 2, id: nil, name: nil, arguments: "{\"comm"),
            .toolCallDelta(index: 2, id: nil, name: nil, arguments: "and\":\"echo hi\"}"),
            // Cached tokens count towards the prompt size.
            .usage(input: 125, output: 30),
        ])
        XCTAssertEqual(events.count, 9)
        XCTAssertEqual(events[8], .stop(.toolUse))
        guard case .providerContent(let raw) = events[7] else { return XCTFail("expected the finished turn") }
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(blocks[0]["thinking"] as? String, "Let me check.")
        XCTAssertEqual(blocks[0]["signature"] as? String, "sig-123")
        XCTAssertEqual(blocks[1]["text"] as? String, "Checking it")
        XCTAssertEqual((blocks[2]["input"] as? [String: Any])?["command"] as? String, "echo hi")
        XCTAssertEqual(decoder.finish(), [], "nothing is owed twice")
    }

    func testAnthropicStreamErrorsAndCutOffStreams() throws {
        var decoder = AnthropicFormat.Decoder()
        XCTAssertThrowsError(try decoder.decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)) { error in
            XCTAssertEqual(error as? StreamError, StreamError(type: "overloaded_error", message: "Overloaded"))
        }

        // A stream that ends without message_stop still hands over what arrived; empty text blocks are left out.
        var cut = AnthropicFormat.Decoder()
        _ = try cut.decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        _ = try cut.decode(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)
        _ = try cut.decode(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"partial"}}"#)
        XCTAssertEqual(cut.finish(), [.providerContent(#"[{"text":"partial","type":"text"}]"#)])

        // Some gateways send a tool's input whole instead of as deltas.
        var whole = AnthropicFormat.Decoder()
        let events = try whole.decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a"}}}"#)
        XCTAssertEqual(events, [.toolCallDelta(index: 0, id: "t1", name: "Read", arguments: #"{"file_path":"a"}"#)])
    }

    func testAnthropicRequest() throws {
        let raw = #"[{"signature":"sig","thinking":"t","type":"thinking"},{"text":"Checking","type":"text"},{"id":"toolu_1","input":{"command":"ls"},"name":"Bash","type":"tool_use"}]"#
        let history = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "Checking",
                        toolCalls: [ToolCall(id: "toolu_1", name: "Bash", arguments: #"{"command":"ls"}"#)],
                        providerContent: raw, model: "m1"),
            ChatMessage(role: .tool, content: "a.txt", toolCallID: "toolu_1", isError: true),
            ChatMessage(role: .user, content: "and now?"),
        ]
        var request = ChatRequest(
            connection: Connection(format: .anthropic, baseURL: "https://gw.example.com/", apiKey: "k", authScheme: .xAPIKey,
                                   headers: [HeaderField(name: "X-Tenant", value: "t1"), HeaderField(name: " ", value: "ignored")]),
            model: "m1", system: "sys", messages: history,
            tools: [ToolSpec(name: "Bash", description: "d", parametersJSON: #"{"type":"object"}"#)],
            effort: .high, maxOutputTokens: 1_234)

        let urlRequest = try GatewayClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://gw.example.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Tenant"), "t1")

        let body = try jsonObject(urlRequest.httpBody)
        XCTAssertEqual(body["model"] as? String, "m1")
        XCTAssertEqual(body["max_tokens"] as? Int, 1_234)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "high")
        let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first)
        XCTAssertEqual(system["text"] as? String, "sys")
        XCTAssertNotNil(system["cache_control"])
        XCTAssertNotNil((body["tools"] as? [[String: Any]])?.first?["input_schema"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        // Same model: the turn goes back block for block, reasoning and signature included.
        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(assistant[0]["signature"] as? String, "sig")
        // The tool result and the next prompt share one user turn, result first, breakpoint on the newest block.
        let last = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(last.map { $0["type"] as? String }, ["tool_result", "text"])
        XCTAssertEqual(last[0]["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(last[0]["is_error"] as? Bool, true)
        XCTAssertNil(last[0]["cache_control"])
        XCTAssertNotNil(last[1]["cache_control"])

        // Another model: the turn is rebuilt from text and tool calls, and optional fields are left out.
        request.model = "m2"
        request.effort = .auto
        request.promptCaching = false
        request.connection.authScheme = .bearer
        let other = try GatewayClient.urlRequest(for: request)
        XCTAssertEqual(other.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertNil(other.value(forHTTPHeaderField: "x-api-key"))
        let otherBody = try jsonObject(other.httpBody)
        let rebuilt = try XCTUnwrap((otherBody["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        XCTAssertEqual(rebuilt.map { $0["type"] as? String }, ["text", "tool_use"])
        XCTAssertEqual((rebuilt[1]["input"] as? [String: Any])?["command"] as? String, "ls")
        XCTAssertNil(otherBody["output_config"])
        XCTAssertNil((otherBody["system"] as? [[String: Any]])?.first?["cache_control"])
    }

    func testOpenAIRequest() throws {
        let history = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "Bash", arguments: "")]),
            ChatMessage(role: .tool, content: "out", toolCallID: "c1"),
        ]
        let request = ChatRequest(
            connection: Connection(format: .openAI, baseURL: "https://api.example.com/v1/", apiKey: "k"),
            model: "m", system: "sys", messages: history,
            tools: [ToolSpec(name: "Bash", description: "d", parametersJSON: #"{"type":"object"}"#)], effort: .max)
        let urlRequest = try GatewayClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-version"))

        let body = try jsonObject(urlRequest.httpBody)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high", "levels above high are capped for this format")
        XCTAssertNil(body["max_tokens"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertTrue(messages[2]["content"] is NSNull)
        let call = try XCTUnwrap((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{}")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "c1")
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        XCTAssertEqual((tool["parameters"] as? [String: Any])?["type"] as? String, "object")
    }

    func testHistoryIsRepairedBeforeSending() {
        let call1 = ToolCall(id: "a", name: "Bash", arguments: "{}"), call2 = ToolCall(id: "b", name: "Read", arguments: "{}")
        let repaired = History.sanitized([
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .tool, content: "orphan", toolCallID: "zzz"),
            ChatMessage(role: .assistant, content: "  "),
            ChatMessage(role: .assistant, content: "", toolCalls: [call1, call2]),
            ChatMessage(role: .tool, content: "second", toolCallID: "b"),
            ChatMessage(role: .user, content: " \n"),
            ChatMessage(role: .user, content: "next"),
        ])
        XCTAssertEqual(repaired.map(\.role), [.user, .assistant, .tool, .tool, .user])
        XCTAssertEqual(repaired[2].toolCallID, "a")
        XCTAssertTrue(repaired[2].content.contains("interrupted"))
        XCTAssertEqual(repaired[2].isError, true)
        XCTAssertEqual(repaired[3].content, "second")
        XCTAssertEqual(repaired[4].content, "next")
    }

    // MARK: Live HTTP (needs Tests/mock_server.py)

    private func liveBase() throws -> String {
        guard let base = ProcessInfo.processInfo.environment["TERMAI_TEST_BASEURL"] else {
            throw XCTSkip("set TERMAI_TEST_BASEURL to run")
        }
        return base
    }

    func testLiveAnthropicGateway() async throws {
        let base = try liveBase()
        let connection = Connection(format: .anthropic, baseURL: base, apiKey: "test-key", authScheme: .xAPIKey)
        let client = GatewayClient()
        let models = try await client.listModels(connection)
        XCTAssertEqual(models, [ModelInfo(id: "claude-mock-1", displayName: "Claude Mock 1"), ModelInfo(id: "claude-mock-2")])

        let home = try scratchDirectory("live-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = try await RemoteEnvironment.open(connection: LocalShellConnection(home: home), name: "box", detail: "test", folder: "")
        let user = ChatMessage(role: .user, content: "go")
        let recorder = Recorder()
        // The mock rejects the second round unless reasoning, effort and cache breakpoints are sent correctly.
        try await Agent(client: client, tools: ToolBox(environment: environment)).run(
            request: ChatRequest(connection: connection, model: "claude-mock-1", system: "sys", messages: [user], effort: .high),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].content, "Checking héllo ✓")
        XCTAssertEqual(messages[1].content, "hi\n[exit 0]")
        XCTAssertEqual(messages[2].content, "done")
        let thinking = await recorder.thinking
        XCTAssertEqual(thinking, "Let me check.")

        do {
            let wrong = Connection(format: .anthropic, baseURL: base, apiKey: "wrong")
            for try await _ in client.streamChat(ChatRequest(connection: wrong, model: "m", messages: [user])) {}
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? APIError, APIError(status: 401, message: "bad key"))
        }

        // An overloaded gateway is retried, then reported.
        let retries = Recorder()
        do {
            try await Agent(client: client, tools: ToolBox(environment: environment), retryDelays: [0.01, 0.01]).run(
                request: ChatRequest(connection: connection, model: "overloaded", messages: [user]),
                approve: { _, _ in .allow }, emit: { await retries.record($0) })
            XCTFail("expected 529")
        } catch {
            XCTAssertEqual(error as? APIError, APIError(status: 529, message: "Overloaded"))
        }
        let notices = await retries.notices
        XCTAssertEqual(notices.count, 2)
    }

    func testLiveOpenAIGateway() async throws {
        let base = try liveBase() + "/v1"
        let connection = Connection(format: .openAI, baseURL: base, apiKey: "test-key")
        let client = GatewayClient()
        let models = try await client.listModels(connection)
        XCTAssertEqual(models.map(\.id), ["mock-b", "mock-a"])

        let home = try scratchDirectory("live-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = try await RemoteEnvironment.open(connection: LocalShellConnection(home: home), name: "box", detail: "test", folder: "")
        let recorder = Recorder()
        try await Agent(client: client, tools: ToolBox(environment: environment)).run(
            request: ChatRequest(connection: connection, model: "mock-a", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[1].content, "hi\n[exit 0]")
        XCTAssertEqual(messages[2].content, "héllo ✓ done")
    }
}
