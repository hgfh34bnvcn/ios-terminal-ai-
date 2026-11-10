import Foundation

public struct SlashCommand: Equatable, Sendable {
    public var name: String
    public var usage: String
    public var help: String
}

public enum ParsedInput: Equatable, Sendable {
    case empty
    case prompt(String)
    /// `!cmd`: run directly in the environment, bypassing the model.
    case shell(String)
    case command(name: String, args: String)
}

public enum Commands {
    public static let all: [SlashCommand] = [
        .init(name: "help", usage: "/help", help: "list commands"),
        .init(name: "new", usage: "/new", help: "start a new session"),
        .init(name: "clear", usage: "/clear", help: "same as /new"),
        .init(name: "resume", usage: "/resume", help: "open the session list"),
        .init(name: "model", usage: "/model [id]", help: "show or switch model"),
        .init(name: "effort", usage: "/effort [level]", help: "default, low, medium, high, xhigh, max"),
        .init(name: "mode", usage: "/mode [name]", help: "ask, accept-edits, plan, bypass"),
        .init(name: "env", usage: "/env [name|local]", help: "show or switch environment"),
        .init(name: "cd", usage: "/cd [path]", help: "show or change the working folder"),
        .init(name: "compact", usage: "/compact", help: "summarise the conversation to free context"),
        .init(name: "init", usage: "/init", help: "write a CLAUDE.md for this folder"),
        .init(name: "usage", usage: "/usage", help: "token use in this session"),
        .init(name: "retry", usage: "/retry", help: "resend the last prompt"),
        .init(name: "copy", usage: "/copy", help: "copy the last answer"),
        .init(name: "export", usage: "/export", help: "share the session as Markdown"),
        .init(name: "theme", usage: "/theme [id]", help: "show or switch theme"),
        .init(name: "config", usage: "/config", help: "open settings"),
    ]

    public static func parse(_ raw: String) -> ParsedInput {
        let text = raw.trimmed
        if text.isEmpty { return .empty }
        if text.hasPrefix("!") {
            let command = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? .empty : .shell(command)
        }
        if text.hasPrefix("/") {
            let body = text.dropFirst()
            let name = body.prefix { !$0.isWhitespace }.lowercased()
            // A leading slash that is not a known command (e.g. a file path) is an ordinary prompt.
            guard all.contains(where: { $0.name == name }) else { return .prompt(text) }
            let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return .command(name: name, args: args)
        }
        return .prompt(text)
    }

    /// Commands matching a partially typed `/name` (no arguments yet).
    public static func suggestions(for input: String) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(where: { $0.isWhitespace }) else { return [] }
        let partial = input.dropFirst().lowercased()
        return all.filter { $0.name.hasPrefix(partial) && $0.name != partial }
    }
}
