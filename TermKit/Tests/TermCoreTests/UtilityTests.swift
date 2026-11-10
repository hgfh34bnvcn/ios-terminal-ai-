import XCTest
@testable import TermCore

final class UtilityTests: XCTestCase {
    func testPaths() {
        XCTAssertEqual(Paths.normalize("/a//b/./c/../d/"), "/a/b/d")
        XCTAssertEqual(Paths.normalize("/../.."), "/")
        XCTAssertEqual(Paths.resolve("", cwd: "/w", home: "/h"), "/w")
        XCTAssertEqual(Paths.resolve(".", cwd: "/w", home: "/h"), "/w")
        XCTAssertEqual(Paths.resolve("~", cwd: "/w", home: "/h"), "/h")
        XCTAssertEqual(Paths.resolve("~/x/../y", cwd: "/w", home: "/h"), "/h/y")
        XCTAssertEqual(Paths.resolve("/abs/", cwd: "/w", home: "/h"), "/abs")
        XCTAssertEqual(Paths.resolve(" rel/f ", cwd: "/w", home: "/h"), "/w/rel/f")
        XCTAssertEqual(Paths.resolve("../up", cwd: "/w", home: "/h"), "/up")

        XCTAssertTrue(Paths.isInside("/w/a", "/w"))
        XCTAssertTrue(Paths.isInside("/w", "/w/"))
        XCTAssertFalse(Paths.isInside("/wx", "/w"))
        XCTAssertFalse(Paths.isInside("/w/../etc", "/w"))
        XCTAssertTrue(Paths.isInside("/a", "/"))

        XCTAssertEqual(Paths.abbreviate("/h/app", home: "/h"), "~/app")
        XCTAssertEqual(Paths.abbreviate("/h", home: "/h"), "~")
        XCTAssertEqual(Paths.abbreviate("/hx", home: "/h"), "/hx")
        XCTAssertEqual(Paths.abbreviate("/x", home: "/"), "/x")
        XCTAssertEqual(Paths.display("/w/src/a", cwd: "/w", home: "/h"), "src/a")
        XCTAssertEqual(Paths.display("/w", cwd: "/w", home: "/h"), ".")
        XCTAssertEqual(Paths.display("/h/o", cwd: "/w", home: "/h"), "~/o")
        XCTAssertEqual(Paths.display("/proj/a", cwd: "/", home: "/"), "proj/a")
        XCTAssertEqual(Paths.parent("/a/b"), "/a")
        XCTAssertEqual(Paths.parent("/a"), "/")
        XCTAssertEqual(Paths.parent("/"), "/")
        XCTAssertEqual(Paths.name("/a/b.txt"), "b.txt")
        XCTAssertEqual(Paths.shellQuote("it's $HOME"), "'it'\\''s $HOME'")
    }

    func testGlob() {
        XCTAssertTrue(Glob.matches("**/*.swift", "a.swift"))
        XCTAssertTrue(Glob.matches("**/*.swift", "x/y/a.swift"))
        XCTAssertFalse(Glob.matches("*.swift", "x/a.swift"))
        XCTAssertTrue(Glob.matches("src/**", "src/a/b"))
        XCTAssertTrue(Glob.matches("src/**/*.ts", "src/a.ts"))
        XCTAssertTrue(Glob.matches("src/**/*.ts", "src/x/y/a.ts"))
        XCTAssertFalse(Glob.matches("src/*.ts", "src/a/b.ts"))
        XCTAssertTrue(Glob.matches("a?c", "abc"))
        XCTAssertFalse(Glob.matches("a?c", "a/c"))
        XCTAssertTrue(Glob.matches("*.{js,ts}", "x.ts"))
        XCTAssertFalse(Glob.matches("*.{js,ts}", "x.py"))
        XCTAssertTrue(Glob.matches("[ab].txt", "a.txt"))
        XCTAssertTrue(Glob.matches("[!ab].txt", "c.txt"))
        XCTAssertFalse(Glob.matches("[!ab].txt", "a.txt"))
        XCTAssertFalse(Glob.matches("file.txt", "fileXtxt"))
        XCTAssertTrue(Glob.matches("a+b(1).txt", "a+b(1).txt"))
        XCTAssertNotNil(Glob("{unclosed"))
    }

    func testDiff() {
        XCTAssertEqual(Diff.unified(old: "a\nb\nc\n", new: "a\nb\nc\n"), "")
        XCTAssertEqual(Diff.unified(old: "a\nb\nc\nd\ne\nf\ng\n", new: "a\nb\nc\nD\ne\nf\ng\n", context: 1),
                       "@@ -3 +3 @@\n c\n-d\n+D\n e")
        let old = (1...10).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n2\n", with: "\ntwo\n").replacingOccurrences(of: "\n9\n", with: "\nnine\n")
        XCTAssertEqual(Diff.unified(old: old, new: new, context: 1),
                       "@@ -1 +1 @@\n 1\n-2\n+two\n 3\n@@ -8 +8 @@\n 8\n-9\n+nine\n 10")
        // Line numbers in later hunks follow earlier insertions.
        XCTAssertEqual(Diff.unified(old: "a\nb\n", new: "a\nx\ny\nb\n", context: 0), "@@ -2 +2 @@\n+x\n+y")
        XCTAssertEqual(Diff.unified(old: "a\nb\nc\n", new: "x\na\nb\n", context: 0), "@@ -1 +1 @@\n+x\n@@ -3 +4 @@\n-c")
        XCTAssertEqual(Diff.unified(old: "", new: "one\ntwo"), "@@ -1 +1 @@\n+one\n+two")

        let long = Diff.unified(old: "", new: (1...300).map(String.init).joined(separator: "\n"), maxLines: 50)
        let lines = long.split(separator: "\n")
        XCTAssertEqual(lines.count, 51)
        XCTAssertEqual(lines.last, "… 251 more lines")

        let stats = Diff.stats("@@ -1 +1 @@\n a\n-b\n+c\n+d")
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 1)
    }

    func testMarkdownBlocks() {
        let text = """
            # Title

            Intro line
            second line

            - one
            - two
              more
              - nested
            1. first

            ```swift
            let a = 1

            print(a)
            ```
            > quoted

            | a | b |
            |---|---|

            ---
            **end**
            """
        XCTAssertEqual(Markdown.blocks(text), [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro line\nsecond line"),
            .list([
                Markdown.ListItem(marker: "•", text: "one", indent: 0),
                Markdown.ListItem(marker: "•", text: "two\nmore", indent: 0),
                Markdown.ListItem(marker: "•", text: "nested", indent: 1),
                Markdown.ListItem(marker: "1.", text: "first", indent: 0),
            ]),
            .code(language: "swift", text: "let a = 1\n\nprint(a)"),
            .quote("quoted"),
            .code(language: nil, text: "| a | b |\n|---|---|"),
            .rule,
            .paragraph("**end**"),
        ])
        // A fence still open while streaming renders as code.
        XCTAssertEqual(Markdown.blocks("a\n```\nx = 1"), [.paragraph("a"), .code(language: nil, text: "x = 1")])
        XCTAssertEqual(Markdown.blocks("2024 was fine\n- [x] done"), [
            .paragraph("2024 was fine"),
            .list([Markdown.ListItem(marker: "☑", text: "done", indent: 0)]),
        ])
        XCTAssertEqual(Markdown.blocks(""), [])
    }

    func testExport() {
        let session = Session(title: "t", transcript: [
            TranscriptItem(kind: .user, text: "hi"),
            TranscriptItem(kind: .info, text: "noise"),
            TranscriptItem(kind: .tool, text: "up 3 days", title: "uptime", tool: "Bash"),
            TranscriptItem(kind: .tool, text: "edited", title: "a.txt", tool: "Edit", diff: "@@ -1 +1 @@\n-a\n+b"),
            TranscriptItem(kind: .assistant, text: "fine"),
        ])
        XCTAssertEqual(Markdown.export(session),
                       "# t\n\n**> hi**\n\n```\nBash: uptime\nup 3 days\n```\n\n```\nEdit: a.txt\n@@ -1 +1 @@\n-a\n+b\n```\n\nfine\n")
    }

    func testCommandParsing() {
        XCTAssertEqual(Commands.parse("  "), .empty)
        XCTAssertEqual(Commands.parse("hello"), .prompt("hello"))
        XCTAssertEqual(Commands.parse("/model  claude-x "), .command(name: "model", args: "claude-x"))
        XCTAssertEqual(Commands.parse("/NEW"), .command(name: "new", args: ""))
        XCTAssertEqual(Commands.parse("/etc/hosts looks odd"), .prompt("/etc/hosts looks odd"))
        XCTAssertEqual(Commands.parse("! ls -la"), .shell("ls -la"))
        XCTAssertEqual(Commands.parse("!"), .empty)
        XCTAssertEqual(Commands.suggestions(for: "/co").map(\.name), ["compact", "copy", "config"])
        XCTAssertEqual(Commands.suggestions(for: "/model x"), [])
        XCTAssertEqual(Commands.suggestions(for: "hi"), [])
        XCTAssertEqual(Set(Commands.all.map(\.name)).count, Commands.all.count)
    }

    func testModelNames() {
        XCTAssertEqual(ModelInfo.shortName(id: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelInfo.shortName(id: "claude-opus-5-5-20261001"), "Opus 5.5")
        XCTAssertEqual(ModelInfo.shortName(id: "claude-3-5-haiku-20241022"), "3.5 Haiku")
        XCTAssertEqual(ModelInfo.shortName(id: "anthropic/claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelInfo.shortName(id: "gpt-6.1-sol"), "gpt-6.1-sol")
        XCTAssertEqual(ModelInfo.shortName(id: "x", displayName: "Claude Fable 5.2"), "Fable 5.2")
        XCTAssertEqual(ModelInfo.shortName(id: "x", displayName: "Mock One"), "Mock One")

        var profile = Profile(name: "p", baseURL: "https://x", models: ["mine"],
                              discovered: [ModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"), ModelInfo(id: "mine")])
        XCTAssertEqual(profile.pickerModels, ["mine", "claude-opus-5-5"], "hand-added models come first, without duplicates")
        XCTAssertEqual(profile.defaultModel, "mine")
        XCTAssertEqual(profile.shortName(for: "claude-opus-5-5"), "Opus 5.5")
        profile.modelDiscovery = false
        XCTAssertEqual(profile.pickerModels, ["mine"])
        profile.models = []
        XCTAssertNil(profile.defaultModel)
    }

    func testStorageRoundTrip() throws {
        let directory = try scratchDirectory("storage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(directory: directory)

        var profile = Profile(name: "p", baseURL: "https://x", authScheme: .xAPIKey, models: ["a", "b"], defaultEffort: .high)
        profile.lastModel = "b"
        profile.lastEffort = .max
        storage.saveProfiles([profile])
        let host = SSHHost(name: "h", host: "example.com", port: 2222, username: "u", auth: .privateKey)
        storage.saveHosts([host])
        var settings = AppSettings(themeID: "crt-amber", defaultMode: .acceptEdits, instructions: "be brief", lastHostID: host.id)
        settings.lastFolders = ["local": "/notes"]
        settings.recentFolders = [host.id.uuidString: ["~/app"]]
        storage.saveSettings(settings)

        // Whole-second dates: the store keeps ISO 8601 timestamps without fractions.
        var older = Session(title: "older", createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 100),
                            messages: [ChatMessage(role: .user, content: "1")])
        older.pinned = true
        var newer = Session(
            title: "newer", createdAt: Date(timeIntervalSince1970: 60), updatedAt: Date(timeIntervalSince1970: 200),
            messages: [ChatMessage(role: .user, content: "2"),
                       ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c", name: "Bash", arguments: "{}")],
                                   providerContent: "[]", model: "m"),
                       ChatMessage(role: .tool, content: "out", toolCallID: "c", isError: true)],
            transcript: [TranscriptItem(kind: .tool, text: "out", title: "ls", status: .ok, tool: "Bash", diff: "+a",
                                        todos: [TodoItem(content: "t", status: .inProgress)])],
            hostID: host.id, folder: "~/app", mode: .plan)
        newer.model = "b"
        newer.effort = .low
        newer.contextTokens = 42
        storage.saveSession(older)
        storage.saveSession(newer)
        storage.saveSession(Session())  // empty sessions are not persisted

        let reloaded = Storage(directory: directory)
        XCTAssertEqual(reloaded.loadProfiles(), [profile])
        XCTAssertEqual(reloaded.loadHosts(), [host])
        XCTAssertEqual(reloaded.loadHosts().first?.address, "u@example.com:2222")
        XCTAssertEqual(reloaded.loadSettings(), settings)
        XCTAssertEqual(reloaded.sessionSummaries(), [newer.summary, older.summary])
        XCTAssertEqual(reloaded.loadSession(id: newer.id), newer)
        reloaded.deleteSession(id: newer.id)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["older"])
        XCTAssertEqual(Theme.named("nope"), .dark)
        XCTAssertEqual(Set(Theme.all.map(\.id)).count, Theme.all.count)
    }

    func testFilesFromTheFirstVersionStillLoad() throws {
        let directory = try scratchDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let profileID = UUID(), hostID = UUID(), sessionID = UUID()
        try Data(#"[{"id":"\#(profileID.uuidString)","name":"old","baseURL":"https://api.example.com/v1","models":["a","b"],"defaultModel":"b"}]"#.utf8)
            .write(to: directory.appendingPathComponent("profiles.json"))
        try Data(#"{"activeProfileID":"\#(profileID.uuidString)","activeModel":"b","activeHostID":"\#(hostID.uuidString)","themeID":"crt-green","fontSize":13,"approvalMode":"auto","systemPrompt":"be brief"}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))
        try Data(#"{"id":"\#(sessionID.uuidString)","title":"old chat","createdAt":"2026-11-10T17:00:00Z","updatedAt":"2026-11-10T17:05:00Z","messages":[{"role":"user","content":"hi"}],"transcript":[{"id":"\#(UUID().uuidString)","kind":"tool","text":"out","title":"ssh web1 $ ls","status":"ok"}]}"#.utf8)
            .write(to: directory.appendingPathComponent("sessions/\(sessionID.uuidString).json"))

        let storage = Storage(directory: directory)
        let profile = try XCTUnwrap(storage.loadProfiles().first)
        XCTAssertEqual(profile.format, .openAI, "profiles from before the format setting were OpenAI-compatible")
        XCTAssertEqual(profile.models, ["b", "a"], "the old default moves to the front")
        XCTAssertEqual(profile.authScheme, .bearer)
        XCTAssertTrue(profile.modelDiscovery)
        XCTAssertEqual(profile.maxOutputTokens, 16_000)

        let settings = storage.loadSettings()
        XCTAssertEqual(settings.activeProfileID, profileID)
        XCTAssertEqual(settings.themeID, "crt-green")
        XCTAssertEqual(settings.defaultMode, .bypass)
        XCTAssertEqual(settings.instructions, "be brief")
        XCTAssertEqual(settings.lastHostID, hostID)

        let session = try XCTUnwrap(storage.loadSession(id: sessionID))
        XCTAssertEqual(session.title, "old chat")
        XCTAssertEqual(session.mode, .ask)
        XCTAssertNil(session.hostID)
        XCTAssertEqual(session.transcript.first?.title, "ssh web1 $ ls")
        XCTAssertEqual(storage.sessionSummaries().map(\.title), ["old chat"])
    }
}
