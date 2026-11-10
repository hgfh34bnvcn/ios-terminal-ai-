import Foundation
import Observation

public struct PendingApproval: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Short tool name, e.g. "Bash".
    public var tool: String
    public var summary: String
    public var preview: String?
    public var isDiff: Bool
    /// The standing permission offered next to a one-off approval.
    public var grant: PermissionGrant?

    public init(tool: String, summary: String, preview: String? = nil, isDiff: Bool = false, grant: PermissionGrant? = nil) {
        self.id = UUID()
        self.tool = tool
        self.summary = summary
        self.preview = preview
        self.isDiff = isDiff
        self.grant = grant
    }
}

public struct ShareItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(text: String) {
        self.id = UUID()
        self.text = text
    }
}

public struct Attachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.id = UUID()
        self.name = name
        self.text = text
    }
}

public struct SessionGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var sessions: [SessionSummary]
}

public struct FolderListing: Equatable, Sendable {
    public var path: String
    /// Short form for display, e.g. `~/app`.
    public var display: String
    public var parent: String?
    public var directories: [String]
}

/// Sample states for screenshots.
public enum DemoScreen: String, Sendable, CaseIterable {
    case chat, start, approval, sidebar, settings, connection, folder
}

public protocol RemoteConnecting: Sendable {
    func connect(to host: SSHHost, secret: String, passphrase: String?) async throws -> RemoteConnection
}

/// What the model needs from the platform; tests swap these for fakes.
public struct AppDependencies {
    public var storage: Storage
    public var secrets: SecretStore
    /// Folder behind the on-device environment.
    public var workspace: URL
    public var client: ChatStreaming
    public var listModels: @Sendable (Connection) async throws -> [ModelInfo]
    public var connector: RemoteConnecting?
    public var deviceName: String
    public var copy: (String) -> Void

    public init(storage: Storage, secrets: SecretStore, workspace: URL, client: ChatStreaming = GatewayClient(),
                listModels: (@Sendable (Connection) async throws -> [ModelInfo])? = nil,
                connector: RemoteConnecting? = nil, deviceName: String = "This iPhone",
                copy: @escaping (String) -> Void = { _ in }) {
        self.storage = storage
        self.secrets = secrets
        self.workspace = workspace
        self.client = client
        self.listModels = listModels ?? { try await GatewayClient().listModels($0) }
        self.connector = connector
        self.deviceName = deviceName
        self.copy = copy
    }
}

private struct Failure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Everything the screens show and do: connections, sessions, the running agent and its approvals.
@MainActor
@Observable
public final class AppModel {
    // MARK: Stored data

    public private(set) var profiles: [Profile] = []
    public private(set) var hosts: [SSHHost] = []
    public private(set) var settings = AppSettings()
    /// Saved sessions, most recent first.
    public private(set) var summaries: [SessionSummary] = []
    public private(set) var session = Session()

    // MARK: Screen state

    public var input = ""
    /// The composer sends its text straight to the environment's shell.
    public var shellMode = false
    public var showSidebar = false
    public var showSettings = false
    public var showFolderPicker = false
    public var shareItem: ShareItem?
    public private(set) var attachments: [Attachment] = []
    public private(set) var isRunning = false
    /// What a run is waiting on, e.g. "Connecting to web1…".
    public private(set) var activity: String?
    public private(set) var pendingApproval: PendingApproval?
    /// The working folder as the environment reports it, once known.
    public private(set) var workingFolder: String?
    public private(set) var recentPrompts: [String] = []
    /// Bumped when the transcript should jump to the bottom.
    public private(set) var scrollTick = 0
    public let demo: DemoScreen?

    private let dependencies: AppDependencies
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored private var rules = PermissionRules()
    @ObservationIgnored private var connections: [UUID: RemoteConnection] = [:]
    @ObservationIgnored private var environments: [String: WorkEnvironment] = [:]
    @ObservationIgnored private var assistantItem: UUID?
    @ObservationIgnored private var thinkingItem: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var warnedInsecure: Set<UUID> = []

    public init(dependencies: AppDependencies, demo: DemoScreen? = nil, theme: String? = nil) {
        self.dependencies = dependencies
        self.demo = demo
        profiles = dependencies.storage.loadProfiles()
        hosts = dependencies.storage.loadHosts()
        settings = dependencies.storage.loadSettings()
        summaries = dependencies.storage.sessionSummaries()
        session = makeSession()
        if let demo {
            loadDemo(demo, theme: theme)
        } else if let profile = activeProfile, profile.modelDiscovery {
            let id = profile.id
            Task { await refreshModels(id) }
        }
    }

    // MARK: Derived state

    public var theme: Theme { Theme.named(settings.themeID) }
    public var deviceName: String { dependencies.deviceName }
    public var needsSetup: Bool { profiles.isEmpty }

    public var activeProfile: Profile? {
        profiles.first { $0.id == settings.activeProfileID } ?? profiles.first
    }

    public var currentHost: SSHHost? {
        hosts.first { $0.id == session.hostID }
    }

    public var hasShell: Bool { session.hostID != nil }

    public var environmentLabel: String {
        if session.hostID == nil { return dependencies.deviceName }
        return currentHost?.name ?? "Missing host"
    }

    public var folderLabel: String {
        if let workingFolder { return workingFolder }
        if !session.folder.isEmpty { return session.folder }
        return session.hostID == nil ? "/" : "~"
    }

    /// The session's own choice, else the last one used on this connection, else its default.
    public var currentModel: String? {
        guard let profile = activeProfile else { return nil }
        let available = profile.pickerModels
        if let chosen = session.model, available.contains(chosen) { return chosen }
        if !profile.alwaysStartWithDefault, let last = profile.lastModel, available.contains(last) { return last }
        return profile.defaultModel
    }

    public var currentEffort: Effort {
        guard let profile = activeProfile else { return .auto }
        if let chosen = session.effort { return chosen }
        if !profile.alwaysStartWithDefault, let last = profile.lastEffort { return last }
        return profile.defaultEffort
    }

    public var modelLabel: String {
        guard let profile = activeProfile else { return "No connection" }
        guard let model = currentModel else { return "No model" }
        return profile.shortName(for: model)
    }

    public var contextLabel: String? {
        session.contextTokens > 0 ? Self.compact(session.contextTokens) : nil
    }

    public var suggestions: [SlashCommand] {
        shellMode || isRunning ? [] : Commands.suggestions(for: input)
    }

    public var canSend: Bool {
        !isRunning && pendingApproval == nil && (!input.trimmed.isEmpty || !attachments.isEmpty)
    }

    public var placeholder: String {
        if pendingApproval != nil { return "Waiting for your answer above" }
        if shellMode { return "Run a command on \(environmentLabel)" }
        return "Describe a task or ask a question"
    }

    public var recentFolders: [String] {
        settings.recentFolders[AppSettings.folderKey(session.hostID)] ?? []
    }

    /// The most recent saved session other than the one on screen.
    public var lastSession: SessionSummary? {
        summaries.first { $0.id != session.id }
    }

    public static func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    /// Saved sessions for the sidebar: pinned first, the rest grouped by environment and folder.
    public func groups(matching search: String = "") -> [SessionGroup] {
        let query = search.trimmed.lowercased()
        let visible = summaries.filter { query.isEmpty || $0.title.lowercased().contains(query) }
        var groups: [SessionGroup] = []
        let pinned = visible.filter(\.pinned)
        if !pinned.isEmpty { groups.append(SessionGroup(id: "pinned", title: "Pinned", sessions: pinned)) }
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]
        for summary in visible where !summary.pinned {
            let title = groupTitle(summary)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(summary)
        }
        return groups + order.map { SessionGroup(id: "group." + $0, title: $0, sessions: buckets[$0] ?? []) }
    }

    private func groupTitle(_ summary: SessionSummary) -> String {
        var environment = dependencies.deviceName
        if let id = summary.hostID { environment = hosts.first { $0.id == id }?.name ?? "Removed host" }
        return summary.folder.isEmpty ? environment : "\(environment) · \(summary.folder)"
    }

    // MARK: Transcript

    @discardableResult
    private func append(_ kind: TranscriptItem.Kind, _ text: String, title: String? = nil,
                        status: TranscriptItem.Status? = nil, tool: String? = nil, attachments: [String]? = nil) -> UUID {
        let item = TranscriptItem(kind: kind, text: text, title: title, status: status, tool: tool, attachments: attachments)
        session.transcript.append(item)
        return item.id
    }

    private func info(_ text: String) {
        append(.info, text)
        scrollTick += 1
    }

    private func fail(_ text: String) {
        append(.error, text)
        scrollTick += 1
    }

    private func busy() {
        info("Stop the current run first.")
    }

    private func mutate(_ id: UUID?, _ change: (inout TranscriptItem) -> Void) {
        guard let id, let index = session.transcript.lastIndex(where: { $0.id == id }) else { return }
        change(&session.transcript[index])
    }

    private func appendOutput(_ id: UUID?, _ chunk: String) {
        mutate(id) { item in
            item.text += chunk
            // Only the tail is shown; keep the stored text bounded for long-running commands.
            if item.text.utf8.count > 24_000 { item.text = String(item.text.suffix(16_000)) }
        }
    }

    // MARK: Input

    public func submit() {
        let raw = input
        let text = raw.trimmed
        guard !isRunning, pendingApproval == nil, !text.isEmpty || !attachments.isEmpty else { return }
        input = ""
        scrollTick += 1
        if !text.isEmpty {
            recentPrompts.removeAll { $0 == text }
            recentPrompts.insert(text, at: 0)
            if recentPrompts.count > 12 { recentPrompts.removeLast() }
        }
        if shellMode, !text.isEmpty { return runShell(text) }
        switch Commands.parse(raw) {
        case .empty: send("")
        case .prompt(let prompt): send(prompt)
        case .shell(let command): runShell(command)
        case .command(let name, let args): runCommand(name, args)
        }
    }

    /// Adds a text file to the next message.
    public func attach(name: String, data: Data) {
        guard data.count <= 200_000 else { return fail("\(name) is too large to attach (limit 200 KB).") }
        guard let text = ToolBox.text(data) else { return fail("\(name) is not a text file.") }
        attachments.append(Attachment(name: name, text: text))
    }

    public func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: Agent runs

    private func send(_ text: String) {
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let profile = activeProfile else {
            input = text
            return fail("No connection yet. Add your gateway in Settings.")
        }
        guard let model = currentModel else {
            input = text
            return fail("No model selected. Pick one from the model menu, or add a model ID in Settings › Connection.")
        }
        var content = text
        for attachment in attachments {
            content += (content.isEmpty ? "" : "\n\n") + "<file name=\"\(attachment.name)\">\n\(attachment.text)\n</file>"
        }
        append(.user, text, attachments: attachments.isEmpty ? nil : attachments.map(\.name))
        attachments = []
        if session.messages.isEmpty { session.title = Session.title(from: text.isEmpty ? "Attached files" : text) }
        session.messages.append(ChatMessage(role: .user, content: content))
        startRun(profile: profile, model: model)
    }

    /// Connects to the session's environment and builds the request a turn starts from.
    private func prepare(profile: Profile, model: String, effort: Effort, hostID: UUID?, folder: String,
                         messages: [ChatMessage]) async throws -> (request: ChatRequest, tools: ToolBox) {
        let environment = try await environment(hostID: hostID, folder: folder)
        try Task.checkCancellation()
        workingFolder = Paths.abbreviate(environment.cwd, home: environment.home)
        let project = await projectInstructions(in: environment)
        let mode = session.mode
        let tools = ToolBox(environment: environment, readOnly: mode == .plan)
        let system = SystemPrompt.build(environment: environment, mode: mode, projectInstructions: project,
                                        userInstructions: settings.instructions)
        let request = ChatRequest(connection: connection(for: profile), model: model, system: system, messages: messages,
                                  tools: tools.specs, effort: effort, maxOutputTokens: profile.maxOutputTokens,
                                  promptCaching: profile.promptCaching)
        return (request, tools)
    }

    private func startRun(profile: Profile, model: String) {
        isRunning = true
        assistantItem = nil
        thinkingItem = nil
        if profile.baseURL.lowercased().hasPrefix("http://"), !apiKey(for: profile).isEmpty,
           warnedInsecure.insert(profile.id).inserted {
            info("Note: \(profile.name) uses plain http, so the API key is sent unencrypted.")
        }
        let effort = currentEffort
        let hostID = session.hostID, folder = session.folder
        let history = session.messages
        let client = dependencies.client

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.prepare(profile: profile, model: model, effort: effort, hostID: hostID,
                                                      folder: folder, messages: history)
                try await Agent(client: client, tools: prepared.tools).run(
                    request: prepared.request,
                    approve: { [weak self] _, info in await self?.authorize(info) ?? .deny(nil) },
                    emit: { [weak self] event in await self?.handle(event) })
            } catch {
                self.report(error)
            }
            self.finishRun()
        }
    }

    private func finishRun() {
        for index in session.transcript.indices where session.transcript[index].status == .running {
            session.transcript[index].status = .failed
        }
        isRunning = false
        activity = nil
        runTask = nil
        assistantItem = nil
        thinkingItem = nil
        toolItems = [:]
        persist()
        scrollTick += 1
    }

    private func report(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return info("Interrupted") }
        var message = ErrorText.describe(error)
        if let api = error as? APIError {
            if [404, 405].contains(api.status) {
                message += "\nCheck the base URL and API format in Settings › Connection."
            } else if [401, 403].contains(api.status) {
                message += "\nCheck the API key and auth scheme in Settings › Connection."
            }
        }
        let lowered = message.lowercased()
        if lowered.contains("prompt is too long") || lowered.contains("context length") || lowered.contains("context window") {
            message += "\nUse /compact to shrink the conversation."
        }
        fail(message)
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .thinkingDelta(let delta):
            if thinkingItem == nil { thinkingItem = append(.thinking, "") }
            mutate(thinkingItem) { $0.text += delta }
        case .assistantDelta(let delta):
            thinkingItem = nil
            if assistantItem == nil { assistantItem = append(.assistant, "") }
            mutate(assistantItem) { $0.text += delta }
        case .message(let message):
            session.messages.append(message)
            if message.role == .assistant {
                assistantItem = nil
                thinkingItem = nil
            } else if message.role == .tool {
                // Saved after every tool round, so a killed app loses little.
                persist()
            }
        case .toolStarted(let call, let info):
            thinkingItem = nil
            toolItems[call.id] = append(.tool, "", title: info.summary, status: .running, tool: info.title)
        case .toolOutput(let id, let chunk):
            appendOutput(toolItems[id], chunk)
        case .toolFinished(let id, let result, let denied):
            mutate(toolItems[id]) { item in
                item.status = denied ? .denied : (result.isError ? .failed : .ok)
                item.diff = result.diff
                item.todos = result.todos
                if denied || item.text.isEmpty {
                    item.text = String(result.text.prefix(4_000))
                } else if result.isError, let last = result.text.split(separator: "\n").last {
                    // Streamed output is already shown; add the closing status line.
                    if !item.text.hasSuffix("\n") { item.text += "\n" }
                    item.text += last
                }
            }
        case .usage(let input, let output):
            session.contextTokens = input + output
            session.tokensIn += input
            session.tokensOut += output
        case .notice(let text):
            info(text)
        }
    }

    public func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if pendingApproval != nil { resolveApproval(allow: false) }
    }

    // MARK: Approval

    private func authorize(_ info: ToolInfo) async -> ApprovalDecision {
        switch Permissions.decide(info, mode: session.mode, rules: rules) {
        case .allow:
            return .allow
        case .deny(let reason):
            return .deny(reason)
        case .ask:
            if Task.isCancelled { return .deny(nil) }
            pendingApproval = PendingApproval(tool: info.title, summary: info.summary, preview: info.preview,
                                              isDiff: info.previewIsDiff, grant: Permissions.grant(for: info))
            scrollTick += 1
            return await withCheckedContinuation { approvalContinuation = $0 }
        }
    }

    public func resolveApproval(allow: Bool) {
        guard pendingApproval != nil else { return }
        pendingApproval = nil
        approvalContinuation?.resume(returning: allow ? .allow : .deny(nil))
        approvalContinuation = nil
    }

    /// Approves this call and stops asking for calls like it for the rest of the session.
    public func allowAlways() {
        if let grant = pendingApproval?.grant { rules.insert(grant) }
        resolveApproval(allow: true)
    }

    // MARK: Environments

    private func environment(hostID: UUID?, folder: String) async throws -> WorkEnvironment {
        guard let hostID else {
            return LocalEnvironment(root: dependencies.workspace, folder: folder, name: dependencies.deviceName)
        }
        guard let host = hosts.first(where: { $0.id == hostID }) else {
            throw Failure("This session's SSH host was removed. Choose another environment.")
        }
        let key = "\(hostID.uuidString)|\(folder)"
        if let cached = environments[key], connections[hostID]?.isConnected == true { return cached }
        let connection = try await connect(to: host)
        let environment = try await RemoteEnvironment.open(connection: connection, name: host.name, detail: host.address, folder: folder)
        environments[key] = environment
        return environment
    }

    private func connect(to host: SSHHost) async throws -> RemoteConnection {
        if let existing = connections[host.id], existing.isConnected { return existing }
        await dropConnection(host.id)
        guard let connector = dependencies.connector else { throw Failure("SSH is not available in this build.") }
        guard let secret = dependencies.secrets.secret(for: host.secretKey), !secret.isEmpty else {
            throw Failure("No password or key is stored for \(host.name). Add one in Settings › Environments.")
        }
        activity = "Connecting to \(host.name)…"
        defer { activity = nil }
        let connection = try await connector.connect(to: host, secret: secret,
                                                     passphrase: dependencies.secrets.secret(for: host.passphraseKey))
        if host.trustedHostKey == nil, !connection.hostKey.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].trustedHostKey = connection.hostKey
            dependencies.storage.saveHosts(hosts)
            info("First connection to \(host.name). Trusting its host key:\n\(connection.hostKeyFingerprint)")
        }
        connections[host.id] = connection
        return connection
    }

    private func dropConnection(_ id: UUID) async {
        environments = environments.filter { !$0.key.hasPrefix(id.uuidString) }
        if let old = connections.removeValue(forKey: id) { await old.close() }
    }

    /// The folder's own instructions for agents, when it has any.
    private func projectInstructions(in environment: WorkEnvironment) async -> String? {
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let path = Paths.resolve(name, cwd: environment.cwd, home: environment.home)
            if let data = try? await environment.readFile(path, maxBytes: 100_000), let text = ToolBox.text(data),
               !text.trimmed.isEmpty {
                return "From \(name) in the working directory:\n" + String(text.prefix(20_000))
            }
        }
        return nil
    }

    public func selectEnvironment(_ hostID: UUID?) {
        guard !isRunning else { return busy() }
        guard hostID != session.hostID else { return }
        session.hostID = hostID
        session.folder = settings.lastFolders[AppSettings.folderKey(hostID)] ?? ""
        workingFolder = nil
        if hostID == nil { shellMode = false }
        update { $0.lastHostID = hostID }
        persist()
    }

    public func setFolder(_ path: String) {
        guard !isRunning else { return busy() }
        let path = path.trimmed
        session.folder = path
        workingFolder = nil
        let key = AppSettings.folderKey(session.hostID)
        update { settings in
            settings.lastFolders[key] = path
            guard !path.isEmpty else { return }
            var recent = settings.recentFolders[key] ?? []
            recent.removeAll { $0 == path }
            recent.insert(path, at: 0)
            settings.recentFolders[key] = Array(recent.prefix(8))
        }
        persist()
    }

    /// Folders inside `path` in the session's environment, for the folder picker.
    public func browse(_ path: String) async throws -> FolderListing {
        let environment = try await environment(hostID: session.hostID, folder: "")
        let resolved = Paths.resolve(path, cwd: environment.home, home: environment.home)
        let directories = try await environment.listDirectories(resolved)
        return FolderListing(path: resolved, display: Paths.abbreviate(resolved, home: environment.home),
                             parent: resolved == "/" ? nil : Paths.parent(resolved), directories: directories)
    }

    /// `!command` or shell mode: run it directly and tell the model what happened.
    private func runShell(_ command: String) {
        guard session.hostID != nil else {
            return fail("There is no shell on this device. Choose an SSH environment to run commands.")
        }
        isRunning = true
        let hostID = session.hostID, folder = session.folder
        runTask = Task { [weak self] in
            guard let self else { return }
            var item: UUID?
            do {
                let environment = try await self.environment(hostID: hostID, folder: folder)
                self.workingFolder = Paths.abbreviate(environment.cwd, home: environment.home)
                let id = self.append(.tool, "", title: command, status: .running, tool: "Bash")
                item = id
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] in
                    for await chunk in output { self?.appendOutput(id, chunk) }
                }
                let code: Int
                do {
                    code = try await environment.exec(command, timeout: 300) { continuation.yield($0) }
                } catch {
                    continuation.finish()
                    await forwarder.value
                    throw error
                }
                continuation.finish()
                await forwarder.value
                self.mutate(id) { $0.status = code == 0 ? .ok : .failed }
                if code != 0 { self.appendOutput(id, "[exit \(code)]") }
                let shown = self.session.transcript.first { $0.id == id }?.text ?? ""
                if self.session.messages.isEmpty { self.session.title = Session.title(from: "! " + command) }
                self.session.messages.append(ChatMessage(
                    role: .user,
                    content: "[I ran this myself on \(environment.name)]\n$ \(command)\n\(Truncate.middle(shown, limit: 4_000))\n[exit \(code)]"))
            } catch {
                self.mutate(item) { $0.status = .failed }
                self.report(error)
            }
            self.finishRun()
        }
    }

    // MARK: Model, effort and mode

    public func selectModel(_ id: String) {
        let id = id.trimmed
        guard !id.isEmpty, var profile = activeProfile else { return }
        // An ID typed by hand is kept, so it is in the picker next time.
        if !profile.pickerModels.contains(id) { profile.models.append(id) }
        profile.lastModel = id
        store(profile)
        session.model = id
        persist()
    }

    public func selectEffort(_ effort: Effort) {
        guard var profile = activeProfile else { return }
        profile.lastEffort = effort
        store(profile)
        session.effort = effort
        persist()
    }

    public func selectMode(_ mode: PermissionMode) {
        session.mode = mode
        persist()
    }

    private func store(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        dependencies.storage.saveProfiles(profiles)
    }

    // MARK: Sessions

    private func makeSession() -> Session {
        let hostID = settings.lastHostID.flatMap { id in hosts.contains { $0.id == id } ? id : nil }
        return Session(hostID: hostID, folder: settings.lastFolders[AppSettings.folderKey(hostID)] ?? "",
                       mode: settings.defaultMode)
    }

    private func persist() {
        guard !session.isEmpty else { return }
        session.updatedAt = Date()
        dependencies.storage.saveSession(session)
        summaries.removeAll { $0.id == session.id }
        summaries.insert(session.summary, at: 0)
    }

    private func show(_ next: Session) {
        session = next
        rules = PermissionRules()
        workingFolder = nil
        attachments = []
        if next.hostID == nil { shellMode = false }
        showSidebar = false
        scrollTick += 1
    }

    public func newSession() {
        guard !isRunning else { return busy() }
        persist()
        show(makeSession())
    }

    public func openSession(_ id: UUID) {
        guard id != session.id else {
            showSidebar = false
            return
        }
        guard !isRunning else { return busy() }
        guard let loaded = dependencies.storage.loadSession(id: id) else {
            summaries.removeAll { $0.id == id }
            return
        }
        persist()
        show(loaded)
    }

    public func deleteSession(_ id: UUID) {
        if id == session.id {
            guard !isRunning else { return busy() }
            show(makeSession())
        }
        dependencies.storage.deleteSession(id: id)
        summaries.removeAll { $0.id == id }
    }

    /// Changes a saved session that is not on screen, without moving it up the list.
    private func edit(_ id: UUID, _ change: (inout Session) -> Void) {
        if id == session.id {
            change(&session)
            persist()
        } else if var stored = dependencies.storage.loadSession(id: id) {
            change(&stored)
            dependencies.storage.saveSession(stored)
            if let index = summaries.firstIndex(where: { $0.id == id }) { summaries[index] = stored.summary }
        }
    }

    public func togglePin(_ id: UUID) {
        edit(id) { $0.pinned.toggle() }
    }

    public func renameSession(_ id: UUID, to title: String) {
        let title = title.trimmed
        guard !title.isEmpty else { return }
        edit(id) { $0.title = String(title.prefix(80)) }
    }

    // MARK: Commands

    private func runCommand(_ name: String, _ args: String) {
        // Commands that leave the transcript are not echoed into it.
        if !["new", "clear", "resume", "config", "init"].contains(name) {
            append(.user, "/" + name + (args.isEmpty ? "" : " " + args))
        }
        switch name {
        case "help":
            let width = (Commands.all.map(\.usage.count).max() ?? 0) + 2
            var lines = Commands.all.map { $0.usage.padding(toLength: width, withPad: " ", startingAt: 0) + $0.help }
            lines.append("!command".padding(toLength: width, withPad: " ", startingAt: 0) + "run it yourself in an SSH environment")
            info(lines.joined(separator: "\n"))
        case "new", "clear":
            newSession()
        case "resume":
            showSidebar = true
        case "config":
            showSettings = true
        case "model":
            modelCommand(args)
        case "effort":
            if args.isEmpty { return info("Effort: \(currentEffort.title)") }
            let wanted = args.lowercased() == "auto" ? "default" : args.lowercased()
            guard let effort = Effort(rawValue: wanted) else {
                return fail("Unknown effort. Options: " + Effort.allCases.map(\.rawValue).joined(separator: ", "))
            }
            selectEffort(effort)
            info("Effort: \(effort.title)")
        case "mode":
            if args.isEmpty { return info("\(session.mode.title): \(session.mode.detail.lowercased())") }
            let wanted = args.lowercased()
            guard let mode = PermissionMode.allCases.first(where: { $0.rawValue == wanted || $0.rawValue.hasPrefix(wanted) }) else {
                return fail("Unknown mode. Options: " + PermissionMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            selectMode(mode)
            info("\(mode.title): \(mode.detail.lowercased())")
        case "env":
            environmentCommand(args)
        case "cd":
            if args.isEmpty { return info("Working folder: \(folderLabel)") }
            setFolder(args)
            info("Working folder: \(args). It is checked when the next task starts.")
        case "compact":
            compact()
        case "init":
            send("Look around this folder and write a concise CLAUDE.md for it: what the project is, how to build, test and run it, and the conventions an agent should follow here. If a CLAUDE.md already exists, improve it instead of replacing it.")
        case "usage":
            info("Context in the last request: \(Self.compact(session.contextTokens)) tokens\nSession total: \(Self.compact(session.tokensIn)) in, \(Self.compact(session.tokensOut)) out")
        case "retry":
            guard !isRunning else { return busy() }
            guard let index = session.messages.lastIndex(where: { $0.role == .user }) else { return fail("Nothing to retry.") }
            guard let profile = activeProfile, let model = currentModel else { return fail("No connection or model selected.") }
            session.messages.removeSubrange((index + 1)...)
            startRun(profile: profile, model: model)
        case "copy":
            guard let last = session.transcript.last(where: { $0.kind == .assistant }) else { return fail("No answer to copy yet.") }
            dependencies.copy(last.text)
            info("Copied \(last.text.count) characters.")
        case "export":
            guard !session.isEmpty else { return fail("Nothing to export yet.") }
            shareItem = ShareItem(text: Markdown.export(session))
        case "theme":
            if args.isEmpty {
                return info(Theme.all.map { ($0.id == theme.id ? "● " : "  ") + $0.id.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.name }
                    .joined(separator: "\n"))
            }
            let wanted = args.lowercased()
            guard let match = Theme.all.first(where: { $0.id == wanted || $0.name.lowercased().hasPrefix(wanted) }) else {
                return fail("Unknown theme. Options: " + Theme.all.map(\.id).joined(separator: ", "))
            }
            update { $0.themeID = match.id }
            info("Theme: \(match.name)")
        default:
            fail("Unknown command: /\(name)")
        }
    }

    private func modelCommand(_ args: String) {
        guard let profile = activeProfile else { return fail("No connection yet. Add your gateway in Settings.") }
        let available = profile.pickerModels
        if args.isEmpty {
            let current = currentModel
            let lines = available.map { ($0 == current ? "● " : "  ") + $0 }
            return info(lines.isEmpty
                ? "No models yet. /model <id> uses one directly; Settings › Connection can fetch the gateway's list."
                : lines.joined(separator: "\n"))
        }
        // An exact ID, a unique part of a known ID, or a new ID.
        let matches = available.filter { $0.localizedCaseInsensitiveContains(args) }
        let chosen = available.first { $0 == args } ?? (matches.count == 1 ? matches[0] : args)
        selectModel(chosen)
        info("Model: \(chosen)")
    }

    private func environmentCommand(_ args: String) {
        if args.isEmpty {
            var lines = [(session.hostID == nil ? "● " : "  ") + dependencies.deviceName + "  (files only)"]
            lines += hosts.map { ($0.id == session.hostID ? "● " : "  ") + $0.name + "  " + $0.address }
            return info(lines.joined(separator: "\n"))
        }
        let wanted = args.lowercased()
        if ["local", "phone", "device", "off"].contains(wanted) {
            selectEnvironment(nil)
            return info("Environment: \(dependencies.deviceName)")
        }
        guard let host = hosts.first(where: { $0.name.lowercased().hasPrefix(wanted) }) else {
            return fail("No SSH host named \(args). Add one in Settings › Environments.")
        }
        selectEnvironment(host.id)
        info("Environment: \(host.name) (\(host.address))")
    }

    private static let compactPrompt = """
        Write a summary of this conversation that can replace it. Include the user's goals and constraints, \
        what was found and decided, the files and commands that matter with their paths, the current state of \
        the work, and what remains to be done. Be specific and do not call any tools.
        """

    /// Replaces the conversation with a summary written by the model, to free up context.
    private func compact() {
        guard !isRunning else { return busy() }
        guard session.messages.count > 2 else { return info("Nothing to compact yet.") }
        guard let profile = activeProfile, let model = currentModel else { return fail("No connection or model selected.") }
        isRunning = true
        activity = "Compacting…"
        let effort = currentEffort
        let hostID = session.hostID, folder = session.folder
        let history = session.messages + [ChatMessage(role: .user, content: Self.compactPrompt)]
        let client = dependencies.client

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The same system prompt and tools as a normal turn, so the provider's cached prefix is reused.
                let prepared = try await self.prepare(profile: profile, model: model, effort: effort, hostID: hostID,
                                                      folder: folder, messages: history)
                self.activity = "Compacting…"
                var summary = ""
                for try await event in client.streamChat(prepared.request) {
                    if case .text(let delta) = event { summary += delta }
                }
                try Task.checkCancellation()
                guard !summary.trimmed.isEmpty else {
                    throw Failure("The model returned an empty summary, so nothing was changed.")
                }
                let before = self.session.messages.count
                self.session.messages = [ChatMessage(
                    role: .user,
                    content: "This conversation was compacted. Summary of everything so far:\n\n" + summary.trimmed)]
                self.session.contextTokens = 0
                self.info("Compacted \(before) messages into a summary.")
            } catch {
                self.report(error)
            }
            self.finishRun()
        }
    }

    // MARK: Settings

    public func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        dependencies.storage.saveSettings(settings)
    }

    public func apiKey(for profile: Profile) -> String {
        dependencies.secrets.secret(for: profile.secretKey) ?? ""
    }

    /// Stored with the secrets: header values are often tokens.
    public func headers(for profile: Profile) -> [HeaderField] {
        guard let raw = dependencies.secrets.secret(for: profile.headersKey),
              let list = try? JSONDecoder().decode([HeaderField].self, from: Data(raw.utf8)) else { return [] }
        return list
    }

    public func connection(for profile: Profile, apiKey: String? = nil, headers: [HeaderField]? = nil) -> Connection {
        Connection(format: profile.format, baseURL: profile.baseURL, apiKey: apiKey ?? self.apiKey(for: profile),
                   authScheme: profile.authScheme, headers: headers ?? self.headers(for: profile))
    }

    public func saveProfile(_ profile: Profile, apiKey: String, headers: [HeaderField]) {
        var profile = profile
        profile.name = profile.name.trimmed
        profile.baseURL = profile.baseURL.trimmed
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        dependencies.storage.saveProfiles(profiles)
        dependencies.secrets.setSecret(apiKey.trimmed, for: profile.secretKey)
        let kept = headers.filter { !$0.name.trimmed.isEmpty }
        let encoded = (try? JSONEncoder().encode(kept)).map { String(decoding: $0, as: UTF8.self) }
        dependencies.secrets.setSecret(kept.isEmpty ? nil : encoded, for: profile.headersKey)
        if !profiles.contains(where: { $0.id == settings.activeProfileID }) {
            update { $0.activeProfileID = profile.id }
        }
        if profile.modelDiscovery {
            let id = profile.id
            Task { await refreshModels(id) }
        }
    }

    public func deleteProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        dependencies.storage.saveProfiles(profiles)
        dependencies.secrets.setSecret(nil, for: profile.secretKey)
        dependencies.secrets.setSecret(nil, for: profile.headersKey)
        if settings.activeProfileID == id { update { $0.activeProfileID = profiles.first?.id } }
    }

    public func activateProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }), settings.activeProfileID != id else { return }
        update { $0.activeProfileID = id }
        // Model IDs belong to a connection; fall back to the new one's default.
        session.model = nil
        session.effort = nil
        if let profile = activeProfile, profile.modelDiscovery {
            Task { await refreshModels(id) }
        }
    }

    /// Asks the gateway for its models and remembers them. Returns what went wrong, if anything.
    @discardableResult
    public func refreshModels(_ id: UUID) async -> String? {
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        do {
            let models = try await dependencies.listModels(connection(for: profile))
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
            if profiles[index].discovered != models {
                profiles[index].discovered = models
                dependencies.storage.saveProfiles(profiles)
            }
            return nil
        } catch {
            return ErrorText.describe(error)
        }
    }

    /// Lists models with settings that are still being edited.
    public func fetchModels(for profile: Profile, apiKey: String, headers: [HeaderField]) async throws -> [ModelInfo] {
        try await dependencies.listModels(connection(for: profile, apiKey: apiKey.trimmed, headers: headers))
    }

    public func hostSecret(for host: SSHHost) -> String {
        dependencies.secrets.secret(for: host.secretKey) ?? ""
    }

    public func hostPassphrase(for host: SSHHost) -> String {
        dependencies.secrets.secret(for: host.passphraseKey) ?? ""
    }

    public func saveHost(_ host: SSHHost, secret: String, passphrase: String) {
        var host = host
        host.name = host.name.trimmed
        host.host = host.host.trimmed
        host.username = host.username.trimmed
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        dependencies.storage.saveHosts(hosts)
        dependencies.secrets.setSecret(secret, for: host.secretKey)
        dependencies.secrets.setSecret(passphrase.isEmpty ? nil : passphrase, for: host.passphraseKey)
        // Reconnect with the new details on next use.
        let id = host.id
        Task { await dropConnection(id) }
    }

    public func deleteHost(_ id: UUID) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        hosts.removeAll { $0.id == id }
        dependencies.storage.saveHosts(hosts)
        dependencies.secrets.setSecret(nil, for: host.secretKey)
        dependencies.secrets.setSecret(nil, for: host.passphraseKey)
        if session.hostID == id, session.isEmpty {
            session.hostID = nil
            session.folder = ""
            workingFolder = nil
            shellMode = false
        }
        if settings.lastHostID == id { update { $0.lastHostID = nil } }
        Task { await dropConnection(id) }
    }

    // MARK: Demo content

    private func loadDemo(_ screen: DemoScreen, theme: String?) {
        var profile = Profile(name: "Gateway", baseURL: "https://llm-gateway.example.com")
        profile.discovered = [
            ModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
            ModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"),
            ModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5"),
        ]
        profile.lastEffort = .high
        let host = SSHHost(name: "web1", host: "10.0.0.12", username: "deploy",
                           trustedHostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo")
        profiles = [profile]
        hosts = [host]
        settings = AppSettings(activeProfileID: profile.id, themeID: theme ?? Theme.dark.id, lastHostID: host.id)
        settings.recentFolders[AppSettings.folderKey(host.id)] = ["~/app", "/etc/nginx"]
        dependencies.secrets.setSecret("sk-demo-0000000000000000", for: profile.secretKey)

        let now = Date()
        summaries = [
            SessionSummary(id: UUID(), title: "Rotate the TLS certificates", updatedAt: now.addingTimeInterval(-3_600), pinned: true, hostID: host.id, folder: "~/app"),
            SessionSummary(id: UUID(), title: "Why is the health check failing?", updatedAt: now.addingTimeInterval(-7_200), hostID: host.id, folder: "~/app"),
            SessionSummary(id: UUID(), title: "Add a /version endpoint", updatedAt: now.addingTimeInterval(-90_000), hostID: host.id, folder: "~/app"),
            SessionSummary(id: UUID(), title: "Tidy up the nginx config", updatedAt: now.addingTimeInterval(-180_000), hostID: host.id, folder: "/etc/nginx"),
            SessionSummary(id: UUID(), title: "Draft release notes", updatedAt: now.addingTimeInterval(-260_000)),
        ]
        session = Session(hostID: host.id, folder: "~/app")
        workingFolder = "~/app"

        switch screen {
        case .start:
            break
        case .sidebar:
            showSidebar = true
        case .settings, .connection:
            showSettings = true
        case .folder:
            session = Session()
            workingFolder = nil
            for folder in ["notes", "projects/api", "projects/site", "scripts"] {
                try? FileManager.default.createDirectory(at: dependencies.workspace.appendingPathComponent(folder),
                                                         withIntermediateDirectories: true)
            }
            showFolderPicker = true
        case .chat, .approval:
            session.title = "Why is the health check failing?"
            session.messages = [ChatMessage(role: .user, content: "demo")]
            session.contextTokens = 18_400
            append(.user, "Why is the health check failing on web1?")
            append(.assistant, "I'll look at the service first, then its config.")
            append(.tool, "× app.service - API server\n     Active: failed (Result: exit-code)\nError: listen EADDRINUSE: address already in use :::8080\n[exit 3]",
                   title: "systemctl status app --no-pager", status: .failed, tool: "Bash")
            append(.tool, "", title: "config/app.yml", status: .ok, tool: "Read")
            append(.assistant, "Port **8080** is already taken by the metrics exporter, so the app exits at startup. The health check expects `8081`, which is free:")
            let diff = "@@ -3 +3 @@\n server:\n-  port: 8080\n+  port: 8081\n   workers: 4"
            let restart = "sudo systemctl restart app && curl -sf localhost:8081/health"
            if screen == .approval {
                append(.tool, "", title: "config/app.yml", status: .running, tool: "Edit")
                isRunning = true
                pendingApproval = PendingApproval(tool: "Edit", summary: "config/app.yml",
                                                  preview: "@@ -1 +1 @@\n-  port: 8080\n+  port: 8081", isDiff: true, grant: .edits)
            } else {
                let edit = append(.tool, "edited /home/deploy/app/config/app.yml (1 replacement)", title: "config/app.yml", status: .ok, tool: "Edit")
                mutate(edit) { $0.diff = diff }
                append(.tool, "{\"status\":\"ok\"}", title: restart, status: .ok, tool: "Bash")
                append(.assistant, "Fixed. The app now listens on 8081 and the health check passes.\n\n- `config/app.yml`: port 8080 → 8081\n- restarted `app.service`")
            }
        }
    }
}
