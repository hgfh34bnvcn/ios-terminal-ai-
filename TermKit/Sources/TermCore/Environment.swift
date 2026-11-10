import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct EnvironmentError: LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum ErrorText {
    /// A readable message for any error; plain Swift errors would otherwise print as "operation couldn't be completed".
    public static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        if error is URLError || error is CocoaError { return error.localizedDescription }
        return String(describing: error)
    }
}

public struct GrepQuery: Sendable {
    public var pattern: String
    /// Absolute file or folder to search.
    public var path: String
    public var glob: String?
    public var ignoreCase: Bool
    public var limit: Int

    public init(pattern: String, path: String, glob: String? = nil, ignoreCase: Bool = false, limit: Int = 200) {
        self.pattern = pattern
        self.path = path
        self.glob = glob
        self.ignoreCase = ignoreCase
        self.limit = limit
    }
}

/// Where a session works: files, plus a shell when there is one. All paths are absolute POSIX paths.
public protocol WorkEnvironment: Sendable {
    var name: String { get }
    var detail: String { get }
    var cwd: String { get }
    var home: String { get }
    var platform: String { get }
    var hasShell: Bool { get }
    /// Every path the tools can reach is already confined, so reads never need approval.
    var isSandboxed: Bool { get }

    /// Runs a command in the working folder, streaming combined output, and returns the exit code.
    func exec(_ command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int
    func readFile(_ path: String, maxBytes: Int) async throws -> Data
    /// Creates missing parent folders.
    func writeFile(_ path: String, _ data: Data) async throws
    /// Files below `directory` as relative paths, skipping dependency and VCS folders.
    func listFiles(under directory: String, limit: Int) async throws -> [String]
    /// Names of the visible folders directly inside `directory`.
    func listDirectories(_ directory: String) async throws -> [String]
    /// Matching lines as `path:line:text`.
    func grep(_ query: GrepQuery) async throws -> String
}

enum WorkFolders {
    static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".venv", "__pycache__"]
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private let limit: Int

    init(limit: Int = 400_000) {
        self.limit = limit
    }

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        // Bounded so a runaway command cannot exhaust memory; the tail matters most.
        if text.utf8.count > limit { text = String(text.suffix(limit / 2)) }
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

// MARK: On-device files

/// The app's own folder, presented as a small file system rooted at `/`. There is no shell on iOS.
public struct LocalEnvironment: WorkEnvironment {
    public let root: URL
    public let name: String
    public let cwd: String

    public init(root: URL, folder: String = "", name: String = "This iPhone") {
        self.root = root
        self.name = name
        self.cwd = Paths.resolve(folder, cwd: "/", home: "/")
    }

    public var detail: String { "files on this device" }
    public var home: String { "/" }
    public var platform: String { "iOS app sandbox: files only, no shell" }
    public var hasShell: Bool { false }
    public var isSandboxed: Bool { true }

    /// Maps a path onto the real folder, refusing anything that leaves it, including through symlinks.
    func url(for path: String) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalized = Paths.normalize(path)
        guard normalized != "/" else { return base }
        // Resolve links on the part that exists, so a link cannot carry a new file outside.
        var existing = base.appendingPathComponent(String(normalized.dropFirst())).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var target = existing.resolvingSymlinksInPath()
        for component in missing { target.appendPathComponent(component) }
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw EnvironmentError("path is outside the workspace: \(path)")
        }
        return target
    }

    private func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    public func exec(_ command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        throw EnvironmentError("there is no shell on this device; an SSH environment is needed to run commands")
    }

    public func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        let url = try url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EnvironmentError("no such file: \(path)") }
        guard !isDirectory(url.path) else { throw EnvironmentError("\(path) is a folder") }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw EnvironmentError("file is too large (\(size) bytes)") }
        return try Data(contentsOf: url)
    }

    public func writeFile(_ path: String, _ data: Data) async throws {
        let url = try url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func listFiles(under directory: String, limit: Int) async throws -> [String] {
        let base = try url(for: directory)
        guard isDirectory(base.path), let enumerator = FileManager.default.enumerator(atPath: base.path) else {
            throw EnvironmentError("no such folder: \(directory)")
        }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if isDirectory(base.path + "/" + relative) {
                let name = relative.split(separator: "/").last.map(String.init) ?? relative
                if WorkFolders.skipped.contains(name) { enumerator.skipDescendants() }
                continue
            }
            files.append(relative)
            if files.count >= limit { break }
        }
        return files.sorted()
    }

    public func listDirectories(_ directory: String) async throws -> [String] {
        let base = try url(for: directory)
        guard isDirectory(base.path) else { throw EnvironmentError("no such folder: \(directory)") }
        return try FileManager.default.contentsOfDirectory(atPath: base.path)
            .filter { !$0.hasPrefix(".") && isDirectory(base.path + "/" + $0) }
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    public func grep(_ query: GrepQuery) async throws -> String {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: query.pattern, options: query.ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw EnvironmentError("invalid regular expression: \(query.pattern)")
        }
        let base = try url(for: query.path)
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw EnvironmentError("no such file or folder: \(query.path)")
        }
        var targets: [(display: String, url: URL)] = []
        if isDirectory(base.path) {
            // Like ripgrep, a glob without a slash applies to file names at any depth.
            let filter = query.glob.flatMap { Glob($0.contains("/") ? $0 : "**/" + $0) }
            for relative in try await listFiles(under: query.path, limit: 20_000) where filter?.matches(relative) ?? true {
                targets.append((Paths.normalize(query.path + "/" + relative), base.appendingPathComponent(relative)))
            }
        } else {
            targets = [(Paths.normalize(query.path), base)]
        }
        var lines: [String] = []
        for target in targets {
            guard let data = try? Data(contentsOf: target.url), data.count <= 1_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                lines.append("\(target.display):\(number + 1):\(line.prefix(300))")
                if lines.count >= query.limit { return lines.joined(separator: "\n") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Remote hosts

/// A connected machine: a non-interactive shell plus file transfer.
public protocol RemoteConnection: Sendable {
    /// The server's host key in OpenSSH format.
    var hostKey: String { get }
    var hostKeyFingerprint: String { get }
    var isConnected: Bool { get }
    func exec(_ command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int
    func readFile(_ path: String, maxBytes: Int) async throws -> Data
    func writeFile(_ path: String, _ data: Data) async throws
    func close() async
}

/// A working folder on a remote host. Listing and searching go through the host's own tools.
public struct RemoteEnvironment: WorkEnvironment {
    public let connection: RemoteConnection
    public let name: String
    public let detail: String
    public let cwd: String
    public let home: String
    public let platform: String

    public var hasShell: Bool { true }
    public var isSandboxed: Bool { false }

    private static let marker = "__termai__"

    static func capture(_ connection: RemoteConnection, _ command: String, timeout: TimeInterval = 30,
                        limit: Int = 400_000) async throws -> (code: Int, output: String) {
        let collector = OutputCollector(limit: limit)
        let code = try await connection.exec(command, timeout: timeout) { collector.append($0) }
        return (code, collector.value)
    }

    /// Lines the probe printed itself, ignoring anything a login script wrote.
    private static func marked(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { $0.hasPrefix(marker) ? String($0.dropFirst(marker.count)) : nil }
    }

    /// Looks up the home folder and platform, and checks that `folder` exists.
    public static func open(connection: RemoteConnection, name: String, detail: String, folder: String) async throws -> RemoteEnvironment {
        let probe = try await capture(connection, "printf '\(marker)%s\\n' \"$HOME\" \"$(uname -sm 2>/dev/null)\"")
        let values = marked(probe.output)
        let home = values.first.flatMap { $0.hasPrefix("/") ? Paths.normalize($0) : nil } ?? "/"
        let platform = values.count > 1 && !values[1].isEmpty ? values[1] : "unknown"
        let target = Paths.resolve(folder, cwd: home, home: home)
        let check = try await capture(connection, "cd -- \(Paths.shellQuote(target)) && printf '\(marker)%s\\n' \"$PWD\"")
        guard check.code == 0, let cwd = marked(check.output).last, cwd.hasPrefix("/") else {
            throw EnvironmentError("folder not found on \(name): \(target)")
        }
        return RemoteEnvironment(connection: connection, name: name, detail: detail, cwd: Paths.normalize(cwd),
                                 home: home, platform: platform)
    }

    public func exec(_ command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        try await connection.exec("cd -- \(Paths.shellQuote(cwd)) || exit 126\n\(command)", timeout: timeout, onOutput: onOutput)
    }

    public func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await connection.readFile(path, maxBytes: maxBytes)
    }

    public func writeFile(_ path: String, _ data: Data) async throws {
        do {
            try await connection.writeFile(path, data)
        } catch {
            // Most often the parent folder is missing: create it and try once more.
            let made = try await Self.capture(connection, "mkdir -p -- \(Paths.shellQuote(Paths.parent(path)))")
            guard made.code == 0 else { throw error }
            try await connection.writeFile(path, data)
        }
    }

    public func listFiles(under directory: String, limit: Int) async throws -> [String] {
        let prune = WorkFolders.skipped.sorted().map { "-name \(Paths.shellQuote($0))" }.joined(separator: " -o ")
        let command = "cd -- \(Paths.shellQuote(directory)) || exit 3\n"
            + "find . \\( \(prune) \\) -prune -o -type f -print 2>/dev/null | head -n \(limit)"
        let result = try await Self.capture(connection, command, timeout: 60, limit: 4_000_000)
        guard result.code != 3 else { throw EnvironmentError("no such folder: \(directory)") }
        return result.output.split(separator: "\n")
            .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
            .sorted()
    }

    public func listDirectories(_ directory: String) async throws -> [String] {
        let command = "cd -- \(Paths.shellQuote(directory)) || exit 3\nls -1p 2>/dev/null | grep '/$'\nexit 0"
        let result = try await Self.capture(connection, command)
        guard result.code != 3 else { throw EnvironmentError("no such folder: \(directory)") }
        return result.output.split(separator: "\n")
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    public func grep(_ query: GrepQuery) async throws -> String {
        let pattern = Paths.shellQuote(query.pattern), path = Paths.shellQuote(query.path)
        let flag = query.ignoreCase ? " -i" : ""
        var ripgrep = "rg -n --no-heading --color never\(flag)"
        var plain = "grep -rnIE\(flag) --exclude-dir=.git --exclude-dir=node_modules"
        if let glob = query.glob, !glob.isEmpty {
            ripgrep += " -g \(Paths.shellQuote(glob))"
            plain += " --include=\(Paths.shellQuote(glob))"
        }
        // ripgrep when the host has it, otherwise grep.
        let command = "if command -v rg >/dev/null 2>&1; then \(ripgrep) -e \(pattern) -- \(path); "
            + "else \(plain) -e \(pattern) -- \(path); fi 2>&1 | head -n \(query.limit)"
        let result = try await Self.capture(connection, command, timeout: 60)
        return result.output.trimmingCharacters(in: .newlines)
    }
}
