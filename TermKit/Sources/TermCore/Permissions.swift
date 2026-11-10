import Foundation

/// A standing permission the user granted for the rest of a session.
public enum PermissionGrant: Equatable, Hashable, Sendable {
    /// Simple commands starting with these words, e.g. `git status`.
    case commandPrefix(String)
    /// File edits anywhere.
    case edits
    case domain(String)
    /// Reading and searching outside the working folder.
    case outsideReads

    public var label: String {
        switch self {
        case .commandPrefix(let prefix): return "Always allow \(prefix) commands"
        case .edits: return "Always allow edits"
        case .domain(let domain): return "Always allow \(domain)"
        case .outsideReads: return "Always allow reading outside the folder"
        }
    }
}

public struct PermissionRules: Equatable, Sendable {
    public var grants: Set<PermissionGrant> = []

    public init() {}

    public mutating func insert(_ grant: PermissionGrant) {
        grants.insert(grant)
    }
}

public enum PermissionDecision: Equatable, Sendable {
    case allow
    case ask
    /// Refused without asking; the text is sent to the model.
    case deny(String)
}

public enum Permissions {
    /// Programs for which a standing rule would be as good as no rule: they run other programs or are destructive.
    private static let neverStanding: Set<String> = [
        "sudo", "su", "doas", "env", "sh", "bash", "zsh", "fish", "eval", "exec", "xargs", "nohup", "time",
        "command", "rm", "dd", "mkfs", "shutdown", "reboot", "chmod", "chown", "kill", "pkill", "curl", "wget",
        "ssh", "scp", "python", "python3", "node", "perl", "ruby", "php",
    ]

    /// Programs whose first argument is a subcommand, so the rule covers `git status` rather than all of `git`.
    private static let subcommandTools: Set<String> = [
        "git", "npm", "pnpm", "yarn", "cargo", "go", "docker", "kubectl", "systemctl", "brew", "apt", "apt-get",
        "pip", "pip3", "swift", "gh", "make",
    ]

    /// The words a standing rule would cover, or nil when the command chains, redirects or substitutes,
    /// which a prefix cannot vouch for.
    public static func commandPrefix(_ command: String) -> String? {
        let command = command.trimmed
        for unsafe in ["\n", ";", "&", "|", "`", "$(", ">", "<", "(", ")"] where command.contains(unsafe) { return nil }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, !neverStanding.contains(first), !first.contains("=") else { return nil }
        if subcommandTools.contains(first), words.count > 1, !words[1].hasPrefix("-") {
            return first + " " + words[1]
        }
        return first
    }

    private static func commandAllowed(_ command: String, _ rules: PermissionRules) -> Bool {
        guard let prefix = commandPrefix(command) else { return false }
        return rules.grants.contains(.commandPrefix(prefix))
    }

    public static func decide(_ info: ToolInfo, mode: PermissionMode, rules: PermissionRules) -> PermissionDecision {
        if info.kind == .meta || mode == .bypass { return .allow }
        switch info.kind {
        case .read:
            return info.insideFolder || rules.grants.contains(.outsideReads) ? .allow : .ask
        case .edit:
            if mode == .plan { return .deny("Plan mode is on, so nothing can be changed. Present the plan instead.") }
            if rules.grants.contains(.edits) || (mode == .acceptEdits && info.insideFolder) { return .allow }
            return .ask
        case .execute:
            if mode == .plan { return .deny("Plan mode is on, so commands cannot be run. Present the plan instead.") }
            return commandAllowed(info.command ?? "", rules) ? .allow : .ask
        case .network:
            if let domain = info.domain, rules.grants.contains(.domain(domain)) { return .allow }
            return .ask
        case .meta:
            return .allow
        }
    }

    /// The standing permission that can be offered alongside a one-off approval, if a safe one exists.
    public static func grant(for info: ToolInfo) -> PermissionGrant? {
        switch info.kind {
        case .execute: return commandPrefix(info.command ?? "").map(PermissionGrant.commandPrefix)
        case .edit: return .edits
        case .network: return info.domain.map(PermissionGrant.domain)
        case .read: return info.insideFolder ? nil : .outsideReads
        case .meta: return nil
        }
    }
}
