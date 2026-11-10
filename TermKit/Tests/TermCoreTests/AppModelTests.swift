import XCTest
@testable import TermCore

final class AppModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try scratchDirectory("app")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var workspace: URL { directory.appendingPathComponent("workspace") }

    private final class Clipboard: @unchecked Sendable {
        var values: [String] = []
    }

    private struct Fixture {
        var model: AppModel
        var client: ScriptedClient
        var secrets: InMemorySecretStore
        var storage: Storage
        var clipboard: Clipboard
    }

    @MainActor
    private func makeModel(_ scripts: [[StreamEvent]] = [],
                           profile: Profile? = Profile(name: "gw", baseURL: "https://gw.example.com", models: ["m1", "m2"]),
                           hosts: [SSHHost] = [], shell: LocalShellConnection? = nil) -> Fixture {
        let storage = Storage(directory: directory.appendingPathComponent("support"))
        let secrets = InMemorySecretStore()
        if let profile {
            storage.saveProfiles([profile])
            secrets.setSecret("key", for: profile.secretKey)
        }
        storage.saveHosts(hosts)
        hosts.forEach { secrets.setSecret("pw", for: $0.secretKey) }
        let client = ScriptedClient(scripts)
        let clipboard = Clipboard()
        let dependencies = AppDependencies(
            storage: storage, secrets: secrets, workspace: workspace, client: client,
            listModels: { _ in [ModelInfo(id: "d1", displayName: "Claude Disco 1")] },
            connector: shell.map(FakeConnector.init), copy: { clipboard.values.append($0) })
        return Fixture(model: AppModel(dependencies: dependencies), client: client, secrets: secrets, storage: storage, clipboard: clipboard)
    }

    @MainActor
    private func wait(for what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    @MainActor
    private func send(_ model: AppModel, _ text: String) async throws {
        model.input = text
        model.submit()
        try await wait(for: "the run to finish or ask") { !model.isRunning || model.pendingApproval != nil }
    }

    @MainActor
    func testATaskRunsToolsAndIsSaved() async throws {
        let fixture = makeModel([
            [.text("Writing."), toolCall("Write", #"{"file_path":"a.txt","content":"x\n"}"#), .usage(input: 100, output: 20)],
            [.text("Done.")],
        ])
        let model = fixture.model
        XCTAssertFalse(model.canSend)
        try await send(model, "make a file\nplease")

        let pending = try XCTUnwrap(model.pendingApproval)
        XCTAssertEqual(pending.tool, "Write")
        XCTAssertEqual(pending.summary, "a.txt")
        XCTAssertEqual(pending.preview, "x\n")
        XCTAssertEqual(pending.grant, .edits)
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))

        model.resolveApproval(allow: true)
        try await wait(for: "the run to finish") { !model.isRunning }
        XCTAssertEqual(model.session.transcript.map(\.kind), [.user, .assistant, .tool, .assistant])
        let tool = model.session.transcript[2]
        XCTAssertEqual(tool.tool, "Write")
        XCTAssertEqual(tool.title, "a.txt")
        XCTAssertEqual(tool.status, .ok)
        XCTAssertEqual(tool.diff, "@@ -1 +1 @@\n+x")
        XCTAssertEqual(model.session.messages.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("a.txt"), encoding: .utf8), "x\n")
        XCTAssertEqual(model.session.title, "make a file")
        XCTAssertEqual(model.session.contextTokens, 120)
        XCTAssertEqual(model.contextLabel, "120")
        XCTAssertEqual(model.folderLabel, "/")
        XCTAssertEqual(model.recentPrompts, ["make a file\nplease"])

        XCTAssertEqual(model.summaries.map(\.id), [model.session.id])
        XCTAssertEqual(fixture.storage.loadSession(id: model.session.id)?.messages.count, 4)

        let first = fixture.client.requests[0]
        XCTAssertEqual(first.model, "m1")
        XCTAssertEqual(first.connection, Connection(format: .anthropic, baseURL: "https://gw.example.com", apiKey: "key"))
        XCTAssertTrue(first.system.contains("Working directory: /\n"), first.system)
        XCTAssertFalse(first.tools.contains { $0.name == "Bash" }, "there is no shell on the device")
        XCTAssertEqual(first.messages.map(\.content), ["make a file\nplease"])
        XCTAssertEqual(fixture.client.requests[1].messages.count, 3)
    }

    @MainActor
    func testDecliningAndAlwaysAllowing() async throws {
        func write(_ name: String, _ id: String) -> [StreamEvent] {
            [toolCall("Write", "{\"file_path\":\"\(name)\",\"content\":\"x\"}", id: id)]
        }
        let fixture = makeModel([write("a.txt", "c1"), write("b.txt", "c2"), write("c.txt", "c3"), [.text("ok")]])
        let model = fixture.model
        try await send(model, "write three files")
        model.resolveApproval(allow: false)
        try await wait(for: "the second question") { model.pendingApproval?.summary == "b.txt" }
        model.allowAlways()
        try await wait(for: "the run to finish") { !model.isRunning }

        // The third call was covered by the standing permission and never asked.
        let tools = model.session.transcript.filter { $0.kind == .tool }
        XCTAssertEqual(tools.map(\.status), [.denied, .ok, .ok])
        XCTAssertEqual(tools[0].text, "The user declined this tool call.")
        let files = try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted()
        XCTAssertEqual(files, ["b.txt", "c.txt"])
        XCTAssertEqual(fixture.client.requests[1].messages.last?.content, "The user declined this tool call.")

        // Standing permissions end with the session.
        fixture.client.requests.isEmpty ? XCTFail("no requests") : ()
        model.newSession()
        XCTAssertTrue(model.session.isEmpty)
    }

    @MainActor
    func testPlanModeChangesNothing() async throws {
        let fixture = makeModel([[toolCall("Write", #"{"file_path":"a.txt","content":"x"}"#)], [.text("Here is the plan.")]])
        let model = fixture.model
        model.selectMode(.plan)
        try await send(model, "refactor it")

        XCTAssertNil(model.pendingApproval)
        XCTAssertFalse(model.isRunning)
        let tool = try XCTUnwrap(model.session.transcript.first { $0.kind == .tool })
        XCTAssertEqual(tool.status, .denied)
        XCTAssertTrue(tool.text.contains("Plan mode is on"), tool.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        let request = fixture.client.requests[0]
        XCTAssertEqual(request.tools.map(\.name), ["Read", "Glob", "Grep", "WebFetch", "TodoWrite"])
        XCTAssertTrue(request.system.contains("# Plan mode"))
    }

    @MainActor
    func testModelAndEffortChoices() async throws {
        let fixture = makeModel([[.text("hi")]])
        let model = fixture.model
        try await wait(for: "model discovery") { model.activeProfile?.discovered.isEmpty == false }
        XCTAssertEqual(model.activeProfile?.pickerModels, ["m1", "m2", "d1"])
        XCTAssertEqual(model.currentModel, "m1")
        XCTAssertEqual(model.modelLabel, "m1")
        XCTAssertEqual(model.currentEffort, .auto)

        model.selectModel("d1")
        model.selectEffort(.high)
        XCTAssertEqual(model.modelLabel, "Disco 1")
        try await send(model, "hello")
        XCTAssertEqual(fixture.client.requests[0].model, "d1")
        XCTAssertEqual(fixture.client.requests[0].effort, .high)

        // A new session keeps the last choice until the connection says to start from its default.
        model.newSession()
        XCTAssertEqual(model.currentModel, "d1")
        XCTAssertEqual(model.currentEffort, .high)
        var profile = try XCTUnwrap(model.activeProfile)
        XCTAssertEqual(profile.lastModel, "d1")
        profile.alwaysStartWithDefault = true
        profile.defaultEffort = .low
        model.saveProfile(profile, apiKey: "key", headers: [])
        XCTAssertEqual(model.currentModel, "m1")
        XCTAssertEqual(model.currentEffort, .low)

        // An ID typed by hand is used and kept in the picker.
        model.input = "/model custom-x"
        model.submit()
        XCTAssertEqual(model.currentModel, "custom-x")
        XCTAssertEqual(model.activeProfile?.models, ["m1", "m2", "custom-x"])
        model.input = "/model m2"
        model.submit()
        XCTAssertEqual(model.currentModel, "m2")
        XCTAssertEqual(fixture.storage.loadProfiles().first?.lastModel, "m2")
    }

    @MainActor
    func testSessionList() async throws {
        let host = SSHHost(name: "web1", host: "h", username: "u")
        let fixture = makeModel([[.text("one")], [.text("two")], [.text("three")]], hosts: [host])
        let model = fixture.model
        try await send(model, "first task")
        let first = model.session.id

        model.newSession()
        model.setFolder("/notes")
        try await send(model, "second task")
        let second = model.session.id
        XCTAssertEqual(model.groups().map(\.title), ["This iPhone · /notes", "This iPhone"])
        XCTAssertEqual(model.lastSession?.id, first)

        model.togglePin(first)
        model.renameSession(first, to: "  Renamed  ")
        XCTAssertEqual(model.groups().map(\.title), ["Pinned", "This iPhone · /notes"])
        XCTAssertEqual(model.groups().first?.sessions.map(\.title), ["Renamed"])
        XCTAssertEqual(model.groups(matching: "SECOND").flatMap(\.sessions).map(\.id), [second])
        XCTAssertEqual(model.summaries.map(\.id), [second, first], "editing a saved session does not reorder the list")
        XCTAssertEqual(fixture.storage.loadSession(id: first)?.pinned, true)

        model.openSession(first)
        XCTAssertEqual(model.session.title, "Renamed")
        XCTAssertEqual(model.session.transcript.map(\.kind), [.user, .assistant])
        XCTAssertEqual(model.folderLabel, "/")
        try await send(model, "more")
        XCTAssertEqual(model.summaries.map(\.id), [first, second], "the session just used moves to the top")

        model.deleteSession(first)
        XCTAssertTrue(model.session.isEmpty)
        XCTAssertEqual(model.session.folder, "/notes", "a new session starts in the last folder")
        XCTAssertEqual(model.summaries.map(\.id), [second])
        XCTAssertNil(fixture.storage.loadSession(id: first))

        // A fresh launch lists what was saved.
        let relaunched = makeModel(profile: nil, hosts: [host]).model
        XCTAssertEqual(relaunched.summaries.map(\.title), ["second task"])
        XCTAssertTrue(relaunched.session.isEmpty)
    }

    @MainActor
    func testCommands() async throws {
        let fixture = makeModel()
        let model = fixture.model
        func command(_ text: String) -> TranscriptItem? {
            model.input = text
            model.submit()
            return model.session.transcript.last
        }

        XCTAssertTrue(command("/help")?.text.contains("/compact") == true)
        XCTAssertEqual(command("/mode plan")?.text, "Plan mode: read and plan only; nothing is changed")
        XCTAssertEqual(model.session.mode, .plan)
        XCTAssertEqual(command("/mode accept")?.kind, .info)
        XCTAssertEqual(model.session.mode, .acceptEdits)
        XCTAssertEqual(command("/mode nonsense")?.kind, .error)
        XCTAssertEqual(command("/effort max")?.text, "Effort: Max")
        XCTAssertEqual(model.currentEffort, .max)
        XCTAssertEqual(command("/effort auto")?.text, "Effort: Default")
        XCTAssertEqual(command("/effort silly")?.kind, .error)
        _ = command("/cd /notes")
        XCTAssertEqual(model.session.folder, "/notes")
        XCTAssertEqual(model.recentFolders, ["/notes"])
        XCTAssertEqual(command("/cd")?.text, "Working folder: /notes")
        XCTAssertEqual(command("/theme light")?.text, "Theme: Light")
        XCTAssertEqual(fixture.storage.loadSettings().themeID, "light")
        XCTAssertEqual(command("/theme neon")?.kind, .error)
        XCTAssertEqual(command("/usage")?.kind, .info)
        XCTAssertEqual(command("/copy")?.kind, .error)
        XCTAssertEqual(command("/retry")?.kind, .error)
        XCTAssertEqual(command("/env web")?.kind, .error)
        XCTAssertEqual(command("/env")?.text, "● This iPhone  (files only)")
        XCTAssertEqual(command("!ls")?.kind, .error, "there is no shell on the device")

        // Commands that only open something leave the transcript alone.
        let count = model.session.transcript.count
        _ = command("/config")
        _ = command("/resume")
        XCTAssertTrue(model.showSettings)
        XCTAssertTrue(model.showSidebar)
        XCTAssertEqual(model.session.transcript.count, count)
        XCTAssertTrue(model.session.isEmpty, "commands alone do not make a session worth saving")
        XCTAssertTrue(model.summaries.isEmpty)

        model.input = "/co"
        XCTAssertEqual(model.suggestions.map(\.name), ["compact", "copy", "config"])
    }

    @MainActor
    func testWorkingOnAHostOverAShell() async throws {
        let home = try scratchDirectory("host-home")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("app"), withIntermediateDirectories: true)
        try Data("Always run the tests.\n".utf8).write(to: home.appendingPathComponent("app/CLAUDE.md"))
        let host = SSHHost(name: "box", host: "10.0.0.5", username: "me")
        let fixture = makeModel([[.text("Listing."), toolCall("Bash", #"{"command":"echo out; ls"}"#)], [.text("fin")]],
                                hosts: [host], shell: LocalShellConnection(home: home))
        let model = fixture.model
        XCTAssertFalse(model.hasShell)
        model.selectEnvironment(host.id)
        model.setFolder("~/app")
        XCTAssertTrue(model.hasShell)
        XCTAssertEqual(model.environmentLabel, "box")
        XCTAssertEqual(model.folderLabel, "~/app")

        // Running a command yourself.
        try await send(model, "!echo hi; exit 2")
        let own = try XCTUnwrap(model.session.transcript.last { $0.kind == .tool })
        XCTAssertEqual(own.tool, "Bash")
        XCTAssertEqual(own.title, "echo hi; exit 2")
        XCTAssertEqual(own.text, "hi\n[exit 2]")
        XCTAssertEqual(own.status, .failed)
        XCTAssertEqual(model.session.messages.last?.content, "[I ran this myself on box]\n$ echo hi; exit 2\nhi\n[exit 2]\n[exit 2]")
        XCTAssertTrue(model.session.transcript.contains { $0.kind == .info && $0.text.contains("SHA256:test") })
        XCTAssertEqual(model.hosts.first?.trustedHostKey, "ssh-ed25519 AAAAtest")
        XCTAssertEqual(fixture.storage.loadHosts().first?.trustedHostKey, "ssh-ed25519 AAAAtest")
        XCTAssertEqual(model.folderLabel, "~/app")

        // The agent working in the same folder.
        try await send(model, "list the folder")
        let pending = try XCTUnwrap(model.pendingApproval)
        XCTAssertEqual(pending.tool, "Bash")
        XCTAssertEqual(pending.preview, "echo out; ls")
        XCTAssertNil(pending.grant, "a chained command gets no standing permission")
        model.resolveApproval(allow: true)
        try await wait(for: "the run to finish") { !model.isRunning }
        let agent = try XCTUnwrap(model.session.transcript.last { $0.kind == .tool })
        XCTAssertEqual(agent.text, "out\nCLAUDE.md\n")
        XCTAssertEqual(agent.status, .ok)

        let request = try XCTUnwrap(fixture.client.requests.first)
        XCTAssertEqual(request.tools.first?.name, "Bash")
        XCTAssertTrue(request.system.contains("Environment: box (me@10.0.0.5)"), request.system)
        XCTAssertTrue(request.system.contains("Working directory: \(home.path)/app"), request.system)
        XCTAssertTrue(request.system.contains("Always run the tests."), "the folder's CLAUDE.md is part of the prompt")
        XCTAssertEqual(request.messages.map(\.role), [.user, .user])

        let listing = try await model.browse("~")
        XCTAssertEqual(listing, FolderListing(path: home.path, display: "~", parent: Paths.parent(home.path), directories: ["app"]))

        // A folder that does not exist stops the task before anything is sent.
        model.setFolder("~/missing")
        try await send(model, "anything")
        XCTAssertEqual(model.session.transcript.last?.kind, .error)
        XCTAssertEqual(model.session.transcript.last?.text, "folder not found on box: \(home.path)/missing")
        XCTAssertEqual(fixture.client.requests.count, 2)
    }

    @MainActor
    func testCompactRetryAndCopy() async throws {
        let fixture = makeModel([[.text("answer one")], [.text("answer two")], [.text("answer two again")], [.text("SUMMARY")]])
        let model = fixture.model
        try await send(model, "question one")
        try await send(model, "question two")
        try await send(model, "/retry")
        XCTAssertEqual(model.session.messages.map(\.content), ["question one", "answer one", "question two", "answer two again"])

        try await send(model, "/copy")
        XCTAssertEqual(fixture.clipboard.values, ["answer two again"])

        try await send(model, "/compact")
        XCTAssertEqual(model.session.messages.count, 1)
        XCTAssertTrue(model.session.messages[0].content.hasSuffix("SUMMARY"))
        XCTAssertEqual(model.session.transcript.last?.text, "Compacted 4 messages into a summary.")
        let request = try XCTUnwrap(fixture.client.requests.last)
        XCTAssertEqual(request.messages.count, 5)
        XCTAssertFalse(request.tools.isEmpty, "the summary request keeps the tools so cached prompts still match")
        XCTAssertEqual(fixture.storage.loadSession(id: model.session.id)?.messages.count, 1)

        try await send(model, "/export")
        XCTAssertTrue(model.shareItem?.text.hasPrefix("# question one") == true)
    }

    @MainActor
    func testConnectionsKeepSecretsOutOfTheSettingsFile() async throws {
        let fixture = makeModel(profile: nil)
        let model = fixture.model
        XCTAssertTrue(model.needsSetup)
        model.input = "hello"
        model.submit()
        XCTAssertEqual(model.session.transcript.last?.kind, .error)
        XCTAssertEqual(model.input, "hello", "the prompt is kept when it could not be sent")

        let profile = Profile(name: " Gateway ", baseURL: " https://llm-gateway.example.com ", authScheme: .xAPIKey)
        model.saveProfile(profile, apiKey: " sk-secret-1 ", headers: [HeaderField(name: "X-Tenant", value: "tenant-7"), HeaderField(name: " ", value: "dropped")])
        XCTAssertFalse(model.needsSetup)
        XCTAssertEqual(model.activeProfile?.name, "Gateway")
        let saved = try XCTUnwrap(model.activeProfile)
        XCTAssertEqual(model.apiKey(for: saved), "sk-secret-1")
        XCTAssertEqual(model.headers(for: saved).map(\.name), ["X-Tenant"])
        XCTAssertEqual(model.connection(for: saved).headers.first?.value, "tenant-7")
        XCTAssertEqual(model.connection(for: saved).authScheme, .xAPIKey)
        let file = try String(contentsOf: directory.appendingPathComponent("support/profiles.json"), encoding: .utf8)
        XCTAssertTrue(file.contains("llm-gateway.example.com"))
        XCTAssertFalse(file.contains("sk-secret-1"))
        XCTAssertFalse(file.contains("tenant-7"))

        try await wait(for: "model discovery") { model.activeProfile?.discovered.isEmpty == false }
        XCTAssertEqual(model.currentModel, "d1")
        XCTAssertEqual(fixture.storage.loadProfiles().first?.discovered.map(\.id), ["d1"])
        let fetched = try await model.fetchModels(for: saved, apiKey: "other", headers: [])
        XCTAssertEqual(fetched.map(\.id), ["d1"])

        let second = Profile(name: "Other", baseURL: "https://other.example.com", format: .openAI, modelDiscovery: false, models: ["gpt-x"])
        model.saveProfile(second, apiKey: "", headers: [])
        XCTAssertEqual(model.activeProfile?.id, saved.id, "adding a connection does not switch to it")
        model.selectModel("d1")
        model.activateProfile(second.id)
        XCTAssertEqual(model.currentModel, "gpt-x", "a model ID does not carry over to another connection")

        model.deleteProfile(second.id)
        XCTAssertEqual(model.activeProfile?.id, saved.id)
        model.deleteProfile(saved.id)
        XCTAssertTrue(model.needsSetup)
        XCTAssertNil(fixture.secrets.secret(for: saved.secretKey))
        XCTAssertNil(fixture.secrets.secret(for: saved.headersKey))
    }

    @MainActor
    func testAttachmentsAndHosts() async throws {
        let fixture = makeModel([[.text("read it")]])
        let model = fixture.model
        model.attach(name: "image.png", data: Data([0x89, 0x00, 0x01]))
        XCTAssertEqual(model.session.transcript.last?.text, "image.png is not a text file.")
        model.attach(name: "notes.txt", data: Data("remember the milk".utf8))
        model.attach(name: "extra.txt", data: Data("x".utf8))
        model.removeAttachment(model.attachments[1].id)
        XCTAssertEqual(model.attachments.map(\.name), ["notes.txt"])
        XCTAssertTrue(model.canSend)

        try await send(model, "see the file")
        XCTAssertEqual(fixture.client.requests[0].messages[0].content, "see the file\n\n<file name=\"notes.txt\">\nremember the milk\n</file>")
        XCTAssertEqual(model.session.transcript[1].attachments, ["notes.txt"])
        XCTAssertEqual(model.session.transcript[1].text, "see the file")
        XCTAssertTrue(model.attachments.isEmpty)

        let host = SSHHost(name: " web1 ", host: " 10.0.0.12 ", username: " deploy ", auth: .privateKey)
        model.saveHost(host, secret: "KEY", passphrase: "pass")
        XCTAssertEqual(model.hosts.first?.address, "deploy@10.0.0.12")
        XCTAssertEqual(model.hostSecret(for: host), "KEY")
        XCTAssertEqual(model.hostPassphrase(for: host), "pass")
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("support/hosts.json"), encoding: .utf8).contains("KEY"))
        model.newSession()
        model.selectEnvironment(host.id)
        XCTAssertEqual(model.environmentLabel, "web1")
        XCTAssertEqual(model.folderLabel, "~")
        model.deleteHost(host.id)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertNil(model.session.hostID)
        XCTAssertNil(fixture.secrets.secret(for: host.secretKey))
        XCTAssertNil(fixture.secrets.secret(for: host.passphraseKey))
    }

    @MainActor
    func testStoppingARun() async throws {
        let fixture = makeModel([[.text("About to write."), toolCall("Write", #"{"file_path":"a.txt","content":"x"}"#)]])
        let model = fixture.model
        try await send(model, "write")
        XCTAssertNotNil(model.pendingApproval)
        model.cancel()
        try await wait(for: "the run to stop") { !model.isRunning }
        XCTAssertNil(model.pendingApproval)
        XCTAssertEqual(model.session.transcript.last?.text, "Interrupted")
        XCTAssertEqual(model.session.transcript.first { $0.kind == .tool }?.status, .denied)
        // The history is complete, so the next message can be sent.
        XCTAssertEqual(History.sanitized(model.session.messages), model.session.messages)
        XCTAssertEqual(fixture.storage.loadSession(id: model.session.id)?.messages.count, 3)
    }

    @MainActor
    func testDemoScreens() {
        for screen in DemoScreen.allCases {
            let storage = Storage(directory: directory.appendingPathComponent("demo-\(screen.rawValue)"))
            let model = AppModel(dependencies: AppDependencies(storage: storage, secrets: InMemorySecretStore(), workspace: workspace),
                                 demo: screen, theme: "light")
            XCTAssertEqual(model.theme, .light)
            XCTAssertEqual(model.modelLabel, "Opus 5.5")
            XCTAssertEqual(model.currentEffort, .high)
            XCTAssertEqual(model.isRunning, screen == .approval)
            XCTAssertEqual(model.pendingApproval != nil, screen == .approval)
            XCTAssertEqual(model.showSidebar, screen == .sidebar)
            XCTAssertEqual(model.showFolderPicker, screen == .folder)
            XCTAssertFalse(model.groups().isEmpty)
        }
    }
}
