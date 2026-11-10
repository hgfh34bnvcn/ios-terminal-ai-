import Foundation
import XCTest
@testable import TermCore

enum Script {
    case events([StreamEvent])
    case failure(Error)
}

/// Replays scripted streams, one per model call, and records the requests it received.
final class ScriptedClient: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [Script]
    private var received: [ChatRequest] = []

    init(_ scripts: [[StreamEvent]]) {
        self.scripts = scripts.map(Script.events)
    }

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        received.append(request)
        let script = scripts.isEmpty ? Script.events([]) : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch script {
            case .events(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

func toolCall(_ name: String, _ arguments: String, id: String = "c1", index: Int = 0) -> StreamEvent {
    .toolCallDelta(index: index, id: id, name: name, arguments: arguments)
}

actor Recorder {
    var messages: [ChatMessage] = []
    var started: [ToolInfo] = []
    var finished: [(id: String, result: ToolResult, denied: Bool)] = []
    var notices: [String] = []
    var order: [String] = []
    var text = ""
    var thinking = ""

    func record(_ event: AgentEvent) {
        switch event {
        case .message(let message): messages.append(message)
        case .toolStarted(_, let info): started.append(info)
        case .toolOutput(_, let chunk): order.append(chunk)
        case .toolFinished(let id, let result, let denied):
            finished.append((id, result, denied))
            order.append("END")
        case .assistantDelta(let delta): text += delta
        case .thinkingDelta(let delta): thinking += delta
        case .notice(let notice): notices.append(notice)
        case .usage: break
        }
    }
}

/// Stands in for an SSH host: commands run in a local shell whose home is a scratch folder.
final class LocalShellConnection: RemoteConnection, @unchecked Sendable {
    let home: URL

    init(home: URL) {
        self.home = home
    }

    var hostKey: String { "ssh-ed25519 AAAAtest" }
    var hostKeyFingerprint: String { "SHA256:test" }
    var isConnected: Bool { true }

    func exec(_ command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        process.currentDirectoryURL = home
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !data.isEmpty { onOutput(String(decoding: data, as: UTF8.self)) }
        return Int(process.terminationStatus)
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else { throw EnvironmentError("\(path): No such file") }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func writeFile(_ path: String, _ data: Data) async throws {
        // Like SFTP, writing does not create folders.
        guard FileManager.default.fileExists(atPath: Paths.parent(path)) else { throw EnvironmentError("\(path): No such file") }
        try data.write(to: URL(fileURLWithPath: path))
    }

    func close() async {}
}

struct FakeConnector: RemoteConnecting {
    let connection: LocalShellConnection

    func connect(to host: SSHHost, secret: String, passphrase: String?) async throws -> RemoteConnection {
        connection
    }
}

func scratchDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("termai-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func jsonObject(_ data: Data?) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
}

func chatRequest(_ messages: [ChatMessage] = [ChatMessage(role: .user, content: "go")], format: APIFormat = .anthropic) -> ChatRequest {
    ChatRequest(connection: Connection(format: format, baseURL: "http://gateway.test"), model: "m1", messages: messages)
}
