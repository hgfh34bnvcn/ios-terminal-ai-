import Foundation

extension KeyedDecodingContainer {
    /// Reads `key` when it is present and well-formed, so files written by older versions still load.
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }
}

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum APIFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `POST /v1/messages`, the format Claude Code and Claude Desktop gateways speak.
    case anthropic
    /// `POST /chat/completions`.
    case openAI = "openai"

    public var id: String { rawValue }
    public var title: String { self == .anthropic ? "Anthropic Messages" : "OpenAI-compatible" }
}

public enum AuthScheme: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `Authorization: Bearer <key>`
    case bearer
    /// `x-api-key: <key>`
    case xAPIKey = "x-api-key"

    public var id: String { rawValue }
}

public enum Effort: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Send nothing and let the model use its own default.
    case auto = "default"
    case low, medium, high, xhigh, max

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Default"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

public enum PermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask
    case acceptEdits = "accept-edits"
    case plan
    case bypass

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: return "Ask permissions"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan mode"
        case .bypass: return "Bypass permissions"
        }
    }
    public var detail: String {
        switch self {
        case .ask: return "Ask before commands, edits and web requests"
        case .acceptEdits: return "Edit files in the folder without asking"
        case .plan: return "Read and plan only; nothing is changed"
        case .bypass: return "Run everything without asking"
        }
    }
}

public struct HeaderField: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

public struct ModelInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }

    /// Compact label for narrow UI: "Opus 5.5" for "Claude Opus 5.5" or "claude-opus-5-5-20261001".
    public static func shortName(id: String, displayName: String? = nil) -> String {
        if let displayName, !displayName.isEmpty {
            return displayName.hasPrefix("Claude ") ? String(displayName.dropFirst(7)) : displayName
        }
        var name = id
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let date = name.range(of: "[-@]20\\d{6}$", options: .regularExpression) { name.removeSubrange(date) }
        guard name.hasPrefix("claude-") else { return name }
        // claude-opus-5-5 -> "Opus 5.5": words are capitalised, runs of numbers become a version.
        var words: [String] = []
        for token in name.dropFirst(7).split(separator: "-") {
            if token.allSatisfy(\.isNumber), let last = words.last, last.last?.isNumber == true {
                words[words.count - 1] = last + "." + token
            } else {
                words.append(token.allSatisfy(\.isNumber) ? String(token) : token.capitalized)
            }
        }
        return words.joined(separator: " ")
    }
}

/// A gateway connection: where requests go and which models it offers. Secrets live in the secret store.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var format: APIFormat
    public var authScheme: AuthScheme
    /// Fill the model picker from the gateway's model list.
    public var modelDiscovery: Bool
    /// Models added by hand. They come first in the picker; the first entry is the default.
    public var models: [String]
    /// Result of the last successful discovery.
    public var discovered: [ModelInfo]
    public var defaultEffort: Effort
    /// New sessions start on the default model and effort instead of the last choice.
    public var alwaysStartWithDefault: Bool
    public var lastModel: String?
    public var lastEffort: Effort?
    /// Anthropic format only, where the field is required.
    public var maxOutputTokens: Int
    /// Anthropic format only: mark the prompt prefix as cacheable so tool rounds are cheaper.
    public var promptCaching: Bool

    public init(id: UUID = UUID(), name: String, baseURL: String, format: APIFormat = .anthropic,
                authScheme: AuthScheme = .bearer, modelDiscovery: Bool = true, models: [String] = [],
                discovered: [ModelInfo] = [], defaultEffort: Effort = .auto, alwaysStartWithDefault: Bool = false,
                maxOutputTokens: Int = 16_000, promptCaching: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.format = format
        self.authScheme = authScheme
        self.modelDiscovery = modelDiscovery
        self.models = models
        self.discovered = discovered
        self.defaultEffort = defaultEffort
        self.alwaysStartWithDefault = alwaysStartWithDefault
        self.maxOutputTokens = maxOutputTokens
        self.promptCaching = promptCaching
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, format, authScheme, modelDiscovery, models, discovered, defaultEffort
        case alwaysStartWithDefault, lastModel, lastEffort, maxOutputTokens, promptCaching
    }

    private enum LegacyKeys: String, CodingKey {
        case defaultModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.value(.name, default: "")
        baseURL = container.value(.baseURL, default: "")
        // Profiles saved before the format field existed were OpenAI-compatible.
        format = container.value(.format, default: .openAI)
        authScheme = container.value(.authScheme, default: .bearer)
        modelDiscovery = container.value(.modelDiscovery, default: true)
        discovered = container.value(.discovered, default: [])
        defaultEffort = container.value(.defaultEffort, default: .auto)
        alwaysStartWithDefault = container.value(.alwaysStartWithDefault, default: false)
        lastModel = try? container.decodeIfPresent(String.self, forKey: .lastModel)
        lastEffort = try? container.decodeIfPresent(Effort.self, forKey: .lastEffort)
        maxOutputTokens = container.value(.maxOutputTokens, default: 16_000)
        promptCaching = container.value(.promptCaching, default: true)
        var list: [String] = container.value(.models, default: [])
        // Older files stored the default separately; the list order now carries it.
        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .defaultModel),
           let index = list.firstIndex(of: legacy), index > 0 {
            list.remove(at: index)
            list.insert(legacy, at: 0)
        }
        models = list
    }

    public var secretKey: String { "profile.\(id.uuidString).apikey" }
    public var headersKey: String { "profile.\(id.uuidString).headers" }

    /// What the model picker offers: hand-added models first, then discovered ones while discovery is on.
    public var pickerModels: [String] {
        guard modelDiscovery else { return models }
        return models + discovered.map(\.id).filter { !models.contains($0) }
    }

    public var defaultModel: String? { pickerModels.first }

    public func shortName(for model: String) -> String {
        ModelInfo.shortName(id: model, displayName: discovered.first { $0.id == model }?.displayName)
    }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// OpenSSH-format host key recorded on first connect; later connects must match it.
    public var trustedHostKey: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                auth: Auth = .password, trustedHostKey: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.trustedHostKey = trustedHostKey
    }

    public var secretKey: String { "host.\(id.uuidString).secret" }
    public var passphraseKey: String { "host.\(id.uuidString).passphrase" }
    public var address: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Raw JSON object string as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentValues: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public func string(_ key: String) -> String? { argumentValues[key] as? String }

    public func number(_ key: String) -> Double? {
        let value = argumentValues[key]
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    public func bool(_ key: String) -> Bool {
        let value = argumentValues[key]
        if let flag = value as? Bool { return flag }
        if let string = value as? String { return string.lowercased() == "true" }
        return false
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?
    /// Tool results only.
    public var isError: Bool?
    /// The assistant turn exactly as the provider returned it (JSON content blocks). Replayed to the same
    /// model so reasoning blocks and their signatures survive tool rounds.
    public var providerContent: String?
    /// Model that produced an assistant message.
    public var model: String?

    public init(role: Role, content: String, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil,
                isError: Bool? = nil, providerContent: String? = nil, model: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.isError = isError
        self.providerContent = providerContent
        self.model = model
    }
}

public struct TodoItem: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    public var status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// One block in the on-screen transcript.
public struct TranscriptItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, thinking, tool, info, error
    }

    public enum Status: String, Codable, Sendable {
        case running, ok, failed, denied
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// Tool blocks: what the call does, e.g. the command or the file path.
    public var title: String?
    public var status: Status?
    /// Tool blocks: display name of the tool, e.g. "Bash".
    public var tool: String?
    public var diff: String?
    public var todos: [TodoItem]?
    /// User blocks: names of attached files.
    public var attachments: [String]?

    public init(id: UUID = UUID(), kind: Kind, text: String, title: String? = nil, status: Status? = nil,
                tool: String? = nil, diff: String? = nil, todos: [TodoItem]? = nil, attachments: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.status = status
        self.tool = tool
        self.diff = diff
        self.todos = todos
        self.attachments = attachments
    }
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var transcript: [TranscriptItem]
    /// SSH host the session works on; nil is the on-device workspace.
    public var hostID: UUID?
    /// Working folder as chosen by the user; empty is the environment's home.
    public var folder: String
    /// Nil follows the connection's default or last choice.
    public var model: String?
    public var effort: Effort?
    public var mode: PermissionMode
    public var pinned: Bool
    public var tokensIn: Int
    public var tokensOut: Int
    /// Size of the context sent with the most recent request.
    public var contextTokens: Int

    public static let untitled = "New session"

    public init(id: UUID = UUID(), title: String = Session.untitled, createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], transcript: [TranscriptItem] = [], hostID: UUID? = nil,
                folder: String = "", mode: PermissionMode = .ask, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
        self.hostID = hostID
        self.folder = folder
        self.mode = mode
        self.pinned = pinned
        self.tokensIn = 0
        self.tokensOut = 0
        self.contextTokens = 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = container.value(.title, default: Session.untitled)
        createdAt = container.value(.createdAt, default: Date())
        updatedAt = container.value(.updatedAt, default: Date())
        messages = container.value(.messages, default: [])
        transcript = container.value(.transcript, default: [])
        hostID = try? container.decodeIfPresent(UUID.self, forKey: .hostID)
        folder = container.value(.folder, default: "")
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        effort = try? container.decodeIfPresent(Effort.self, forKey: .effort)
        mode = container.value(.mode, default: .ask)
        pinned = container.value(.pinned, default: false)
        tokensIn = container.value(.tokensIn, default: 0)
        tokensOut = container.value(.tokensOut, default: 0)
        contextTokens = container.value(.contextTokens, default: 0)
    }

    public var isEmpty: Bool { messages.isEmpty }

    public var summary: SessionSummary {
        SessionSummary(id: id, title: title, updatedAt: updatedAt, pinned: pinned, hostID: hostID, folder: folder)
    }

    public static func title(from prompt: String) -> String {
        let line = prompt.trimmed.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? Session.untitled : String(line.prefix(60))
    }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    public var pinned: Bool
    public var hostID: UUID?
    public var folder: String

    public init(id: UUID, title: String, updatedAt: Date, pinned: Bool = false, hostID: UUID? = nil, folder: String = "") {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.hostID = hostID
        self.folder = folder
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var themeID: String
    public var fontSize: Double
    /// Permission mode new sessions start in.
    public var defaultMode: PermissionMode
    /// Added to the system prompt of every session.
    public var instructions: String
    public var lastHostID: UUID?
    /// Last working folder per environment, keyed by host ID or "local".
    public var lastFolders: [String: String]
    public var recentFolders: [String: [String]]

    public init(activeProfileID: UUID? = nil, themeID: String = Theme.dark.id, fontSize: Double = 15,
                defaultMode: PermissionMode = .ask, instructions: String = "", lastHostID: UUID? = nil) {
        self.activeProfileID = activeProfileID
        self.themeID = themeID
        self.fontSize = fontSize
        self.defaultMode = defaultMode
        self.instructions = instructions
        self.lastHostID = lastHostID
        self.lastFolders = [:]
        self.recentFolders = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case activeProfileID, themeID, fontSize, defaultMode, instructions, lastHostID, lastFolders, recentFolders
    }

    private enum LegacyKeys: String, CodingKey {
        case systemPrompt, approvalMode, activeHostID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        activeProfileID = try? container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        themeID = container.value(.themeID, default: Theme.dark.id)
        fontSize = container.value(.fontSize, default: 15)
        let oldMode = (try? legacy?.decodeIfPresent(String.self, forKey: .approvalMode)) ?? nil
        defaultMode = container.value(.defaultMode, default: oldMode == "auto" ? .bypass : .ask)
        let oldPrompt = (try? legacy?.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? nil
        instructions = container.value(.instructions, default: oldPrompt ?? "")
        let oldHost = (try? legacy?.decodeIfPresent(UUID.self, forKey: .activeHostID)) ?? nil
        lastHostID = (try? container.decodeIfPresent(UUID.self, forKey: .lastHostID)) ?? oldHost
        lastFolders = container.value(.lastFolders, default: [:])
        recentFolders = container.value(.recentFolders, default: [:])
    }

    public static func folderKey(_ hostID: UUID?) -> String { hostID?.uuidString ?? "local" }
}
