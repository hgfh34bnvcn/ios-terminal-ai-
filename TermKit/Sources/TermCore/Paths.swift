import Foundation

/// POSIX path helpers that work on strings, so they behave the same for local and remote files.
public enum Paths {
    /// Absolute path with `.`, `..` and repeated slashes removed.
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Turns a path typed by the user or the model into an absolute one.
    public static func resolve(_ path: String, cwd: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." { return normalize(cwd) }
        if trimmed == "~" { return normalize(home) }
        if trimmed.hasPrefix("~/") { return normalize(home + "/" + trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("/") { return normalize(trimmed) }
        return normalize(cwd + "/" + trimmed)
    }

    public static func isInside(_ path: String, _ directory: String) -> Bool {
        let directory = normalize(directory), path = normalize(path)
        return directory == "/" || path == directory || path.hasPrefix(directory + "/")
    }

    /// `/home/me/app` -> `~/app`
    public static func abbreviate(_ path: String, home: String) -> String {
        let home = normalize(home)
        guard home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Path relative to `directory` when it is inside it, otherwise the path shortened with `~`.
    public static func display(_ path: String, cwd: String, home: String) -> String {
        let cwd = normalize(cwd)
        if path == cwd { return "." }
        if cwd != "/", path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        if cwd == "/", path.hasPrefix("/") { return String(path.dropFirst()) }
        return abbreviate(path, home: home)
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        guard let slash = normalized.lastIndex(of: "/"), slash != normalized.startIndex else { return "/" }
        return String(normalized[..<slash])
    }

    public static func name(_ path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? "/"
    }

    /// Single-quotes a value for a POSIX shell.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Glob patterns with `**`, `*`, `?`, `[abc]` and `{a,b}`, matched against slash-separated relative paths.
public struct Glob {
    private let regex: NSRegularExpression

    public init?(_ pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: Glob.regexSource(pattern)) else { return nil }
        self.regex = regex
    }

    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    public static func matches(_ pattern: String, _ path: String) -> Bool {
        Glob(pattern)?.matches(path) ?? false
    }

    static func regexSource(_ pattern: String) -> String {
        let characters = Array(pattern)
        var source = "^"
        var depth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    // `**/` spans any number of folders, including none.
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        source += "(?:.*/)?"
                        index += 3
                    } else {
                        source += ".*"
                        index += 2
                    }
                    continue
                }
                source += "[^/]*"
            case "?":
                source += "[^/]"
            case "{":
                depth += 1
                source += "(?:"
            case "}":
                if depth > 0 {
                    depth -= 1
                    source += ")"
                } else {
                    source += "\\}"
                }
            case ",":
                source += depth > 0 ? "|" : ","
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]") {
                    var set = String(characters[index...close])
                    if set.hasPrefix("[!") { set = "[^" + set.dropFirst(2) }
                    source += set
                    index = close + 1
                    continue
                }
                source += "\\["
            default:
                if "\\.+()|^$]".contains(character) { source += "\\" }
                source.append(character)
            }
            index += 1
        }
        return source + String(repeating: ")", count: depth) + "$"
    }
}
