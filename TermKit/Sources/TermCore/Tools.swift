import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ToolResult: Equatable, Sendable {
    /// What the model sees.
    public var text: String
    public var isError: Bool
    /// Display only: what a file edit changed.
    public var diff: String?
    public var todos: [TodoItem]?

    public init(text: String, isError: Bool = false, diff: String? = nil, todos: [TodoItem]? = nil) {
        self.text = text
        self.isError = isError
        self.diff = diff
        self.todos = todos
    }
}

public enum ToolKind: String, Equatable, Sendable {
    case read, edit, execute, network, meta
}

/// What the screen and the permission rules need to know about one tool call.
public struct ToolInfo: Equatable, Sendable {
    public var kind: ToolKind
    /// Short tool name, e.g. "Bash".
    public var title: String
    /// The command, path or URL the call is about.
    public var summary: String
    /// Longer text for the approval prompt.
    public var preview: String?
    public var previewIsDiff: Bool
    /// File tools: the absolute path.
    public var path: String?
    public var insideFolder: Bool
    public var command: String?
    public var domain: String?

    public init(kind: ToolKind, title: String, summary: String, preview: String? = nil, previewIsDiff: Bool = false,
                path: String? = nil, insideFolder: Bool = true, command: String? = nil, domain: String? = nil) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.preview = preview
        self.previewIsDiff = previewIsDiff
        self.path = path
        self.insideFolder = insideFolder
        self.command = command
        self.domain = domain
    }
}

public protocol ToolRunning: Sendable {
    var specs: [ToolSpec] { get }
    func info(_ call: ToolCall) -> ToolInfo
    func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult
}

public enum Truncate {
    /// Keeps the head and tail of long output so the model sees both the start and the final lines.
    public static func middle(_ text: String, limit: Int = 16_000) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        return String(text.prefix(half)) + "\n… [\(text.count - limit) characters omitted] …\n" + String(text.suffix(half))
    }
}

/// The agent's tools, working in one environment: shell, files, search, web fetch and a task list.
public struct ToolBox: ToolRunning {
    public let environment: WorkEnvironment
    /// Plan mode: only tools that cannot change anything are offered.
    public let readOnly: Bool

    public init(environment: WorkEnvironment, readOnly: Bool = false) {
        self.environment = environment
        self.readOnly = readOnly
    }

    struct ToolError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    public var specs: [ToolSpec] {
        var specs: [ToolSpec] = []
        if environment.hasShell, !readOnly {
            specs.append(ToolSpec(
                name: "Bash",
                description: "Run a shell command in the working directory. Non-interactive: no TTY, no prompts, no pagers or editors. Each call starts a fresh shell, so chain dependent steps with &&. Returns combined stdout and stderr, then the exit code.",
                parametersJSON: #"{"type":"object","properties":{"command":{"type":"string","description":"The command to run"},"timeout_seconds":{"type":"number","description":"Default 120, maximum 900"}},"required":["command"]}"#))
        }
        specs.append(ToolSpec(
            name: "Read",
            description: "Read a text file. Each line is returned with its line number and a tab in front. Reads up to 2000 lines; use offset and limit for longer files.",
            parametersJSON: #"{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path, or relative to the working directory"},"offset":{"type":"integer","description":"First line to read, starting at 1"},"limit":{"type":"integer","description":"Number of lines to read"}},"required":["file_path"]}"#))
        if !readOnly {
            specs.append(ToolSpec(
                name: "Write",
                description: "Create a file or replace its whole content. Missing parent folders are created. Use Edit to change part of an existing file.",
                parametersJSON: #"{"type":"object","properties":{"file_path":{"type":"string"},"content":{"type":"string"}},"required":["file_path","content"]}"#))
            specs.append(ToolSpec(
                name: "Edit",
                description: "Replace an exact string in a file. old_string must match the file exactly, including whitespace and without the line-number prefix Read adds, and must be unique unless replace_all is true.",
                parametersJSON: #"{"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string","description":"Exact text to replace"},"new_string":{"type":"string","description":"Text to put in its place"},"replace_all":{"type":"boolean","description":"Replace every occurrence"}},"required":["file_path","old_string","new_string"]}"#))
        }
        specs.append(ToolSpec(
            name: "Glob",
            description: "Find files by glob pattern, for example **/*.swift or src/**/*.ts. Returns paths relative to the searched folder.",
            parametersJSON: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"Folder to search; defaults to the working directory"}},"required":["pattern"]}"#))
        specs.append(ToolSpec(
            name: "Grep",
            description: "Search file contents with a regular expression. Returns matching lines as path:line:text.",
            parametersJSON: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression"},"path":{"type":"string","description":"File or folder to search; defaults to the working directory"},"glob":{"type":"string","description":"Only search files whose name matches, e.g. *.swift"},"ignore_case":{"type":"boolean"}},"required":["pattern"]}"#))
        specs.append(ToolSpec(
            name: "WebFetch",
            description: "Fetch a web page or API response over HTTP(S) from the phone and return its text.",
            parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#))
        specs.append(ToolSpec(
            name: "TodoWrite",
            description: "Replace the task list shown to the user. Use it to plan and track work that takes several steps; keep one task in_progress at a time.",
            parametersJSON: #"{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["todos"]}"#))
        return specs
    }

    // MARK: Describing calls

    private func resolve(_ path: String) -> String {
        Paths.resolve(path, cwd: environment.cwd, home: environment.home)
    }

    private func isInside(_ path: String) -> Bool {
        environment.isSandboxed || Paths.isInside(path, environment.cwd)
    }

    private func rawPath(_ call: ToolCall) -> String {
        call.string("file_path") ?? call.string("path") ?? ""
    }

    static func head(_ text: String, lines limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.prefix(limit).joined(separator: "\n") + "\n… \(lines.count - limit) more lines"
    }

    public func info(_ call: ToolCall) -> ToolInfo {
        func file(_ kind: ToolKind, _ title: String, preview: String? = nil, isDiff: Bool = false) -> ToolInfo {
            let raw = rawPath(call)
            let path = resolve(raw)
            return ToolInfo(kind: kind, title: title,
                            summary: raw.isEmpty ? "(no path)" : Paths.display(path, cwd: environment.cwd, home: environment.home),
                            preview: preview, previewIsDiff: isDiff, path: path, insideFolder: isInside(path))
        }
        func search(_ title: String) -> ToolInfo {
            let base = resolve(call.string("path") ?? "")
            return ToolInfo(kind: .read, title: title, summary: call.string("pattern") ?? "", path: base, insideFolder: isInside(base))
        }

        switch call.name {
        case "Bash":
            let command = call.string("command") ?? ""
            return ToolInfo(kind: .execute, title: "Bash", summary: command, preview: command, command: command)
        case "Read":
            return file(.read, "Read")
        case "Write":
            return file(.edit, "Write", preview: Self.head(call.string("content") ?? "", lines: 40))
        case "Edit":
            let diff = Diff.unified(old: call.string("old_string") ?? "", new: call.string("new_string") ?? "",
                                    context: 0, maxLines: 60)
            return file(.edit, "Edit", preview: diff, isDiff: true)
        case "Glob":
            return search("Glob")
        case "Grep":
            return search("Grep")
        case "WebFetch":
            let url = call.string("url") ?? ""
            return ToolInfo(kind: .network, title: "Fetch", summary: url, preview: url, domain: URL(string: url)?.host?.lowercased())
        case "TodoWrite":
            let count = (call.argumentValues["todos"] as? [Any])?.count ?? 0
            return ToolInfo(kind: .meta, title: "Todos", summary: "\(count) item\(count == 1 ? "" : "s")")
        default:
            return ToolInfo(kind: .meta, title: call.name, summary: "")
        }
    }

    // MARK: Running calls

    public func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult {
        do {
            if readOnly, ["Bash", "Write", "Edit"].contains(call.name) {
                throw ToolError(message: "plan mode is on: \(call.name) is not available until the user leaves plan mode")
            }
            switch call.name {
            case "Bash": return try await bash(call, onOutput: onOutput)
            case "Read": return try await read(call)
            case "Write": return try await write(call)
            case "Edit": return try await edit(call)
            case "Glob": return try await glob(call)
            case "Grep": return try await grep(call)
            case "WebFetch": return try await fetch(call)
            case "TodoWrite": return try todos(call)
            default: return ToolResult(text: "unknown tool: \(call.name)", isError: true)
            }
        } catch is CancellationError {
            return ToolResult(text: "cancelled", isError: true)
        } catch {
            return ToolResult(text: "error: \(ErrorText.describe(error))", isError: true)
        }
    }

    private func require(_ call: ToolCall, _ key: String) throws -> String {
        guard let value = call.string(key) else { throw ToolError(message: "missing argument: \(key)") }
        return value
    }

    private func filePath(_ call: ToolCall) throws -> String {
        let raw = rawPath(call)
        guard !raw.trimmed.isEmpty else { throw ToolError(message: "missing argument: file_path") }
        return resolve(raw)
    }

    /// UTF-8 text, or nil for binary content.
    static func text(_ data: Data) -> String? {
        guard !data.prefix(8_000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func bash(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        guard environment.hasShell else {
            throw ToolError(message: "there is no shell in this environment; the user has to pick an SSH environment to run commands")
        }
        let command = try require(call, "command")
        let timeout = min(max(call.number("timeout_seconds") ?? 120, 1), 900)
        let collector = OutputCollector()
        let code = try await environment.exec(command, timeout: timeout) { chunk in
            collector.append(chunk)
            onOutput(chunk)
        }
        let output = Truncate.middle(collector.value)
        return ToolResult(text: (output.isEmpty ? "" : output + (output.hasSuffix("\n") ? "" : "\n")) + "[exit \(code)]",
                          isError: code != 0)
    }

    private func read(_ call: ToolCall) async throws -> ToolResult {
        let path = try filePath(call)
        let data = try await environment.readFile(path, maxBytes: 5_000_000)
        guard let text = Self.text(data) else {
            throw ToolError(message: "binary file (\(data.count) bytes); it cannot be shown as text")
        }
        let lines = Diff.lines(text)
        guard !lines.isEmpty else { return ToolResult(text: "(empty file)") }
        let offset = max(Int(call.number("offset") ?? 1), 1)
        let limit = min(max(Int(call.number("limit") ?? 2_000), 1), 2_000)
        guard offset <= lines.count else {
            throw ToolError(message: "offset \(offset) is past the end of the file (\(lines.count) lines)")
        }
        var output = ""
        var last = offset - 1
        for index in (offset - 1)..<min(offset - 1 + limit, lines.count) {
            let line = lines[index]
            let shown = line.count > 2_000 ? line.prefix(2_000) + "…" : line
            let next = String(format: "%6d\t", index + 1) + shown + "\n"
            if output.utf8.count + next.utf8.count > 80_000 { break }
            output += next
            last = index + 1
        }
        if last < lines.count {
            output += "[lines \(offset)-\(last) of \(lines.count); pass offset \(last + 1) to continue]"
        }
        return ToolResult(text: output)
    }

    private func write(_ call: ToolCall) async throws -> ToolResult {
        let path = try filePath(call)
        let content = try require(call, "content")
        let previous = (try? await environment.readFile(path, maxBytes: 2_000_000)).flatMap(Self.text)
        try await environment.writeFile(path, Data(content.utf8))
        let lines = Diff.lines(content).count
        return ToolResult(text: previous == nil ? "created \(path) (\(lines) lines)" : "wrote \(path) (\(lines) lines)",
                          diff: Diff.unified(old: previous ?? "", new: content))
    }

    private func edit(_ call: ToolCall) async throws -> ToolResult {
        let path = try filePath(call)
        let old = try require(call, "old_string"), new = try require(call, "new_string")
        guard !old.isEmpty else { throw ToolError(message: "old_string is empty; use Write to create a file") }
        guard old != new else { throw ToolError(message: "old_string and new_string are the same") }
        let data = try await environment.readFile(path, maxBytes: 5_000_000)
        guard let text = Self.text(data) else { throw ToolError(message: "binary file; it cannot be edited as text") }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else {
            throw ToolError(message: "old_string was not found in \(path). Read the file again: the text must match exactly, including whitespace.")
        }
        let all = call.bool("replace_all")
        guard count == 1 || all else {
            throw ToolError(message: "old_string appears \(count) times in \(path). Add surrounding lines to make it unique, or set replace_all.")
        }
        var updated = text
        if all {
            updated = text.replacingOccurrences(of: old, with: new)
        } else if let range = text.range(of: old) {
            updated.replaceSubrange(range, with: new)
        }
        try await environment.writeFile(path, Data(updated.utf8))
        return ToolResult(text: "edited \(path) (\(all ? count : 1) replacement\(all && count > 1 ? "s" : ""))",
                          diff: Diff.unified(old: text, new: updated))
    }

    private func glob(_ call: ToolCall) async throws -> ToolResult {
        let pattern = try require(call, "pattern")
        guard let matcher = Glob(pattern) else { throw ToolError(message: "invalid glob pattern: \(pattern)") }
        let files = try await environment.listFiles(under: resolve(call.string("path") ?? ""), limit: 20_000)
        let matches = files.filter(matcher.matches)
        guard !matches.isEmpty else { return ToolResult(text: "no files match \(pattern)") }
        var text = matches.prefix(300).joined(separator: "\n")
        if matches.count > 300 { text += "\n… \(matches.count - 300) more; narrow the pattern" }
        return ToolResult(text: text)
    }

    private func grep(_ call: ToolCall) async throws -> ToolResult {
        let query = GrepQuery(pattern: try require(call, "pattern"), path: resolve(call.string("path") ?? ""),
                              glob: call.string("glob"), ignoreCase: call.bool("ignore_case"))
        let output = try await environment.grep(query)
        return ToolResult(text: output.isEmpty ? "no matches" : Truncate.middle(output, limit: 30_000))
    }

    private func fetch(_ call: ToolCall) async throws -> ToolResult {
        let raw = try require(call, "url")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ToolError(message: "only http and https URLs are supported")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (status, body) = try await HTTP.collect(request, limit: 400_000)
        var text = String(decoding: body, as: UTF8.self)
        if text.range(of: "<html", options: .caseInsensitive) != nil { text = Self.stripHTML(text) }
        return ToolResult(text: "HTTP \(status)\n" + Truncate.middle(text), isError: !(200..<400).contains(status))
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return text.trimmed
    }

    private func todos(_ call: ToolCall) throws -> ToolResult {
        guard let entries = call.argumentValues["todos"] as? [[String: Any]] else {
            throw ToolError(message: "missing argument: todos")
        }
        let items = entries.compactMap { entry -> TodoItem? in
            guard let content = entry["content"] as? String else { return nil }
            return TodoItem(content: content, status: TodoItem.Status(rawValue: (entry["status"] as? String) ?? "") ?? .pending)
        }
        return ToolResult(text: "task list updated (\(items.filter { $0.status == .completed }.count)/\(items.count) done)", todos: items)
    }
}
