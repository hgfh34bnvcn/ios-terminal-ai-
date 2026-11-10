import XCTest
@testable import TermCore

final class AgentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try scratchDirectory("agent")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var tools: ToolBox { ToolBox(environment: LocalEnvironment(root: root)) }

    func testRunsToolCallsAndFeedsResultsBack() async throws {
        let client = ScriptedClient([
            [.thinking("hm"), .text("Writing."), toolCall("Write", "{\"file_path\":"),
             .toolCallDelta(index: 0, id: nil, name: nil, arguments: "\"a.txt\",\"content\":\"x\\n\"}"),
             .providerContent("[RAW]"), .usage(input: 10, output: 2), .stop(.toolUse)],
            [.text("Done."), .stop(.endTurn)],
        ])
        let recorder = Recorder()
        try await Agent(client: client, tools: tools).run(
            request: chatRequest(),
            approve: { call, info in
                XCTAssertEqual(call.name, "Write")
                XCTAssertEqual(info.summary, "a.txt")
                return .allow
            },
            emit: { await recorder.record($0) })

        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].toolCalls, [ToolCall(id: "c1", name: "Write", arguments: "{\"file_path\":\"a.txt\",\"content\":\"x\\n\"}")])
        XCTAssertEqual(messages[0].providerContent, "[RAW]")
        XCTAssertEqual(messages[0].model, "m1")
        XCTAssertEqual(messages[1].toolCallID, "c1")
        XCTAssertEqual(messages[1].content, "created /a.txt (1 lines)")
        XCTAssertEqual(messages[1].isError, false)
        XCTAssertEqual(messages[2].content, "Done.")
        let thinking = await recorder.thinking, text = await recorder.text
        XCTAssertEqual(thinking, "hm")
        XCTAssertEqual(text, "Writing.Done.")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "x\n")

        // The second model call sees the call and its result; every call is offered the tools.
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(client.requests[0].tools.map(\.name), tools.specs.map(\.name))
    }

    func testDeclinedCallIsReportedToTheModelAndNotRun() async throws {
        let client = ScriptedClient([
            // No id and no arguments: both are filled in so the result can be matched.
            [.toolCallDelta(index: 0, id: "", name: "Write", arguments: #"{"file_path":"a.txt","content":"x"}"#),
             .toolCallDelta(index: 1, id: nil, name: "TodoWrite", arguments: nil)],
            [.text("ok, skipped")],
        ])
        let recorder = Recorder()
        try await Agent(client: client, tools: tools).run(
            request: chatRequest(),
            approve: { call, _ in call.name == "Write" ? .deny("Plan mode is on.") : .allow },
            emit: { await recorder.record($0) })

        let finished = await recorder.finished
        XCTAssertEqual(finished.map(\.denied), [true, false])
        XCTAssertEqual(finished[0].result, ToolResult(text: "Plan mode is on.", isError: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        let messages = await recorder.messages
        let calls = try XCTUnwrap(messages[0].toolCalls)
        XCTAssertFalse(calls[0].id.isEmpty)
        XCTAssertEqual(calls[1].arguments, "{}")
        XCTAssertEqual(messages[1].toolCallID, calls[0].id)
        XCTAssertEqual(messages[1].isError, true)
        XCTAssertEqual(messages[2].toolCallID, calls[1].id)
    }

    func testTransientFailuresAreRetriedBeforeAnyOutput() async throws {
        let client = ScriptedClient(scripts: [
            .failure(APIError(status: 529, message: "Overloaded")),
            .failure(StreamError(type: "overloaded_error", message: "Overloaded")),
            .events([.text("ok")]),
        ])
        let recorder = Recorder()
        try await Agent(client: client, tools: tools, retryDelays: [0.01, 0.01]).run(
            request: chatRequest(), approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let notices = await recorder.notices, messages = await recorder.messages
        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(notices[0].contains("HTTP 529"), notices[0])
        XCTAssertEqual(messages.map(\.content), ["ok"])
        XCTAssertEqual(client.requests.count, 3)
    }

    func testOtherFailuresAreNotRetried() async {
        for failure in [APIError(status: 401, message: "bad key"), APIError(status: 400, message: "bad request")] {
            let client = ScriptedClient(scripts: [.failure(failure), .events([.text("never")])])
            do {
                try await Agent(client: client, tools: tools, retryDelays: [0.01]).run(
                    request: chatRequest(), approve: { _, _ in .allow }, emit: { _ in })
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? APIError, failure)
            }
            XCTAssertEqual(client.requests.count, 1)
        }
    }

    func testCallCutOffByTheOutputLimitDoesNotRun() async throws {
        let client = ScriptedClient([
            [.text("partial"), toolCall("Write", "{\"file_path\":\"a.txt\",\"cont"), .providerContent("[RAW]"), .stop(.maxTokens)],
        ])
        let recorder = Recorder()
        try await Agent(client: client, tools: tools).run(
            request: chatRequest(), approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages, notices = await recorder.notices, started = await recorder.started
        XCTAssertEqual(messages, [ChatMessage(role: .assistant, content: "partial", model: "m1")])
        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("output limit"), notices[0])
        XCTAssertEqual(client.requests.count, 1)
    }

    func testEmptyTurnAddsNothingToTheHistory() async throws {
        let recorder = Recorder()
        try await Agent(client: ScriptedClient([[.usage(input: 5, output: 0), .stop(.refusal)]]), tools: tools).run(
            request: chatRequest(), approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages, notices = await recorder.notices
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(notices, ["The model declined to continue."])
    }

    func testToolOutputArrivesInOrderBeforeTheResult() async throws {
        struct Chatty: ToolRunning {
            var specs: [ToolSpec] { [] }
            func info(_ call: ToolCall) -> ToolInfo { ToolInfo(kind: .execute, title: "Bash", summary: "x") }
            func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult {
                for number in 0..<200 { onOutput("\(number),") }
                return ToolResult(text: "done")
            }
        }
        let recorder = Recorder()
        try await Agent(client: ScriptedClient([[toolCall("Bash", "{}")], [.text("ok")]]), tools: Chatty()).run(
            request: chatRequest(), approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let order = await recorder.order
        XCTAssertEqual(order, (0..<200).map { "\($0)," } + ["END"])
    }

    func testStopsAfterMaxSteps() async {
        let loop: [StreamEvent] = [toolCall("Glob", #"{"pattern":"*"}"#)]
        do {
            try await Agent(client: ScriptedClient([loop, loop, loop]), tools: tools, maxSteps: 2).run(
                request: chatRequest(), approve: { _, _ in .allow }, emit: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .tooManySteps(2))
        }
    }

    func testCancellingWhileWaitingForApprovalLeavesAValidHistory() async throws {
        let recorder = Recorder()
        let client = ScriptedClient([[.text("About to write."), toolCall("Write", #"{"file_path":"a.txt","content":"x"}"#)]])
        let tools = self.tools
        let run = Task {
            try await Agent(client: client, tools: tools).run(
                request: chatRequest(),
                approve: { _, _ in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return .deny(nil)
                },
                emit: { await recorder.record($0) })
        }
        for _ in 0..<300 {
            if await !recorder.started.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        run.cancel()
        do {
            try await run.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The call still has a result, so the conversation can continue later.
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool])
        XCTAssertEqual(History.sanitized(messages), messages)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testSystemPrompt() {
        let local = SystemPrompt.build(environment: LocalEnvironment(root: root, folder: "proj"), mode: .plan,
                                       date: Date(timeIntervalSince1970: 1_800_000_000),
                                       projectInstructions: "Use tabs.", userInstructions: " Be brief. ")
        XCTAssertTrue(local.contains("Working directory: /proj"))
        XCTAssertTrue(local.contains("There is no shell here"))
        XCTAssertFalse(local.contains("Bash is non-interactive"))
        XCTAssertTrue(local.contains("# Plan mode"))
        XCTAssertTrue(local.contains("Date: 2027-01-15"))
        XCTAssertTrue(local.contains("# Project instructions\nUse tabs."))
        XCTAssertTrue(local.hasSuffix("# User instructions\nBe brief."))

        let remote = RemoteEnvironment(connection: LocalShellConnection(home: root), name: "web1", detail: "deploy@10.0.0.12",
                                       cwd: "/srv/app", home: "/home/deploy", platform: "Linux x86_64")
        let prompt = SystemPrompt.build(environment: remote, mode: .ask)
        XCTAssertTrue(prompt.contains("Environment: web1 (deploy@10.0.0.12)"))
        XCTAssertTrue(prompt.contains("Platform: Linux x86_64"))
        XCTAssertTrue(prompt.contains("Bash is non-interactive"))
        XCTAssertFalse(prompt.contains("# Plan mode"))
        XCTAssertFalse(prompt.contains("# User instructions"))
    }
}
