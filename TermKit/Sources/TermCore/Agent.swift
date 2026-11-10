import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AgentEvent: Sendable {
    case assistantDelta(String)
    case thinkingDelta(String)
    /// A message to append to the conversation history (assistant turn or tool result).
    case message(ChatMessage)
    case toolStarted(ToolCall, info: ToolInfo)
    case toolOutput(id: String, chunk: String)
    case toolFinished(id: String, result: ToolResult, denied: Bool)
    case usage(input: Int, output: Int)
    /// Something the user should see that is not part of the conversation.
    case notice(String)
}

public enum ApprovalDecision: Equatable, Sendable {
    case allow
    /// The text, when given, is what the model is told.
    case deny(String?)
}

public enum AgentError: LocalizedError, Equatable {
    case tooManySteps(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let limit): return "Stopped after \(limit) tool rounds. Send another message to continue."
        }
    }
}

/// Runs the model, executes the tool calls it asks for, and repeats until it answers in plain text.
public struct Agent: Sendable {
    public var client: ChatStreaming
    public var tools: ToolRunning
    public var maxSteps: Int
    /// Seconds to wait before the first and second retry of a failed request.
    public var retryDelays: [Double]

    public init(client: ChatStreaming, tools: ToolRunning, maxSteps: Int = 60, retryDelays: [Double] = [2, 6]) {
        self.client = client
        self.tools = tools
        self.maxSteps = maxSteps
        self.retryDelays = retryDelays
    }

    /// Failures worth retrying: overload, rate limits, gateway hiccups and dropped connections.
    static func isTransient(_ error: Error) -> Bool {
        if let api = error as? APIError { return [408, 429, 500, 502, 503, 504, 529].contains(api.status) }
        if let stream = error as? StreamError { return ["overloaded_error", "rate_limit_error", "api_error"].contains(stream.type) }
        if let url = error as? URLError { return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(url.code) }
        return false
    }

    /// `request.messages` is the history including the new user message. Every message produced is
    /// reported through `emit(.message)` as soon as it is complete, so the caller's history stays valid
    /// even when the run is cancelled or fails part-way.
    public func run(
        request: ChatRequest,
        approve: @escaping @Sendable (ToolCall, ToolInfo) async -> ApprovalDecision,
        emit: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        var request = request
        request.tools = tools.specs

        for _ in 0..<maxSteps {
            var text = ""
            var calls: [Int: ToolCall] = [:]
            var provider: String?
            var stop: StopReason?
            var attempt = 0

            attempts: while true {
                var received = false
                do {
                    for try await event in client.streamChat(request) {
                        switch event {
                        case .text(let delta):
                            received = true
                            text += delta
                            await emit(.assistantDelta(delta))
                        case .thinking(let delta):
                            received = true
                            await emit(.thinkingDelta(delta))
                        case .toolCallDelta(let index, let id, let name, let arguments):
                            received = true
                            var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                            if let id, !id.isEmpty { call.id = id }
                            if let name, !name.isEmpty { call.name = name }
                            if let arguments { call.arguments += arguments }
                            calls[index] = call
                        case .usage(let input, let output):
                            await emit(.usage(input: input, output: output))
                        case .providerContent(let content):
                            provider = content
                        case .stop(let reason):
                            stop = reason
                        }
                    }
                    try Task.checkCancellation()
                    break attempts
                } catch {
                    if !Task.isCancelled, !received, attempt < retryDelays.count, Self.isTransient(error) {
                        let delay = retryDelays[attempt]
                        attempt += 1
                        await emit(.notice("\(ErrorText.describe(error)). Retrying in \(Int(delay))s…"))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue attempts
                    }
                    // Keep whatever text arrived; half-received tool calls are dropped so history stays well-formed.
                    if !text.trimmed.isEmpty {
                        await emit(.message(ChatMessage(role: .assistant, content: text, model: request.model)))
                    }
                    throw Task.isCancelled ? CancellationError() : error
                }
            }

            var toolCalls = calls.keys.sorted().compactMap { index -> ToolCall? in
                guard var call = calls[index], !call.name.isEmpty else { return nil }
                if call.id.isEmpty { call.id = "call_\(index)_\(UUID().uuidString.prefix(8))" }
                if call.arguments.trimmed.isEmpty { call.arguments = "{}" }
                return call
            }
            if stop == .maxTokens {
                // A call cut off by the output limit has incomplete arguments and must not run.
                let complete = toolCalls.filter { JSON.object($0.arguments) != nil }
                if complete.count != toolCalls.count {
                    toolCalls = complete
                    provider = nil
                }
            }

            if !text.trimmed.isEmpty || !toolCalls.isEmpty {
                let assistant = ChatMessage(role: .assistant, content: text, toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                                            providerContent: provider, model: request.model)
                request.messages.append(assistant)
                await emit(.message(assistant))
            }
            if stop == .maxTokens {
                await emit(.notice("The reply hit the output limit. Say \"continue\", or raise Max output tokens in the connection settings."))
            } else if stop == .refusal {
                await emit(.notice("The model declined to continue."))
            }
            if toolCalls.isEmpty { return }

            for call in toolCalls {
                let info = tools.info(call)
                await emit(.toolStarted(call, info: info))

                var result: ToolResult
                var denied = false
                let decision: ApprovalDecision = Task.isCancelled ? .deny("Cancelled by the user.") : await approve(call, info)
                switch decision {
                case .deny(let reason):
                    denied = true
                    result = ToolResult(text: reason ?? "The user declined this tool call.", isError: true)
                case .allow:
                    // Output is forwarded through a stream so chunks stay ordered and all arrive before the result.
                    let (output, continuation) = AsyncStream<String>.makeStream()
                    let forwarder = Task {
                        for await chunk in output { await emit(.toolOutput(id: call.id, chunk: chunk)) }
                    }
                    result = await tools.run(call) { continuation.yield($0) }
                    continuation.finish()
                    await forwarder.value
                }

                // Every tool call needs a result message, or the next request is rejected by the API.
                let message = ChatMessage(role: .tool, content: result.text, toolCallID: call.id, isError: result.isError)
                request.messages.append(message)
                await emit(.toolFinished(id: call.id, result: result, denied: denied))
                await emit(.message(message))
            }
            try Task.checkCancellation()
        }
        throw AgentError.tooManySteps(maxSteps)
    }
}

public enum SystemPrompt {
    public static func build(environment: WorkEnvironment, mode: PermissionMode, date: Date = Date(),
                             projectInstructions: String? = nil, userInstructions: String = "") -> String {
        var lines = [
            "You are TermAI, a coding agent in a mobile app. You work in the environment described below through the provided tools, for a user who is typing on a phone.",
            "",
            "# How to work",
            "- Keep replies short: the screen is small. Lead with the result. Use fenced code blocks for code and commands, and other Markdown sparingly.",
            "- Look before you change: use Read, Glob and Grep instead of guessing, and read a file before editing it.",
            "- Use Edit to change existing files and Write for new ones. Paths may be absolute or relative to the working directory.",
        ]
        if environment.hasShell {
            lines.append("- Bash is non-interactive (no TTY, prompts, pagers or editors) and each call starts fresh in the working directory, so chain steps with && and pass flags such as -y.")
        } else {
            lines.append("- There is no shell here: only the file tools and WebFetch work. If a command has to run, tell the user to choose an SSH environment.")
        }
        lines += [
            "- Tool calls may wait for the user's approval. Prefer a few purposeful calls, and say what a destructive command will do before running it.",
            "- For work with several steps, keep a task list with TodoWrite.",
            "- Do what was asked and stop. Do not refactor or add things nobody requested.",
        ]
        if mode == .plan {
            lines += [
                "",
                "# Plan mode",
                "Plan mode is on. Investigate with the read-only tools and answer with a concrete plan. Do not change files or run commands; the user switches modes when they want the plan carried out.",
            ]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        lines += [
            "",
            "# Environment",
            "Environment: \(environment.name) (\(environment.detail))",
            "Working directory: \(environment.cwd)",
            "Platform: \(environment.platform)",
            "Date: \(formatter.string(from: date))",
        ]
        if let projectInstructions, !projectInstructions.trimmed.isEmpty {
            lines += ["", "# Project instructions", projectInstructions.trimmed]
        }
        if !userInstructions.trimmed.isEmpty {
            lines += ["", "# User instructions", userInstructions.trimmed]
        }
        return lines.joined(separator: "\n")
    }
}
