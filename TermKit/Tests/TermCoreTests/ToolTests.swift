import XCTest
@testable import TermCore

final class ToolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try scratchDirectory("tools")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ tools: ToolBox, _ name: String, _ arguments: String) async -> ToolResult {
        await tools.run(ToolCall(id: "1", name: name, arguments: arguments)) { _ in }
    }

    private func info(_ tools: ToolBox, _ name: String, _ arguments: String) -> ToolInfo {
        tools.info(ToolCall(id: "1", name: name, arguments: arguments))
    }

    func testFileToolsOnTheDevice() async throws {
        let tools = ToolBox(environment: LocalEnvironment(root: root, folder: "proj"))
        XCTAssertEqual(tools.specs.map(\.name), ["Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "TodoWrite"])

        let created = await run(tools, "Write", #"{"file_path":"src/a.txt","content":"one\ntwo\nthree\n"}"#)
        XCTAssertEqual(created, ToolResult(text: "created /proj/src/a.txt (3 lines)", diff: "@@ -1 +1 @@\n+one\n+two\n+three"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("proj/src/a.txt").path))
        _ = await run(tools, "Write", #"{"file_path":"src/deep/b.swift","content":"let two = 2\n"}"#)
        _ = await run(tools, "Write", #"{"file_path":"c.swift","content":"// three\n"}"#)
        _ = await run(tools, "Write", #"{"file_path":"node_modules/dep/x.swift","content":"two\n"}"#)

        let read = await run(tools, "Read", #"{"file_path":"src/a.txt"}"#)
        XCTAssertEqual(read.text, "     1\tone\n     2\ttwo\n     3\tthree\n")
        let part = await run(tools, "Read", #"{"file_path":"/proj/src/a.txt","offset":2,"limit":1}"#)
        XCTAssertEqual(part.text, "     2\ttwo\n[lines 2-2 of 3; pass offset 3 to continue]")
        let past = await run(tools, "Read", #"{"file_path":"src/a.txt","offset":9}"#)
        XCTAssertTrue(past.isError)

        // Dependency folders are skipped; a pattern without ** stays at one level.
        let swift = await run(tools, "Glob", #"{"pattern":"**/*.swift"}"#)
        XCTAssertEqual(swift.text, "c.swift\nsrc/deep/b.swift")
        let top = await run(tools, "Glob", #"{"pattern":"*.swift"}"#)
        XCTAssertEqual(top.text, "c.swift")
        let none = await run(tools, "Glob", #"{"pattern":"*.md"}"#)
        XCTAssertEqual(none.text, "no files match *.md")

        let grep = await run(tools, "Grep", #"{"pattern":"TWO","ignore_case":true}"#)
        XCTAssertEqual(grep.text, "/proj/src/a.txt:2:two\n/proj/src/deep/b.swift:1:let two = 2")
        let filtered = await run(tools, "Grep", #"{"pattern":"two","glob":"*.swift"}"#)
        XCTAssertEqual(filtered.text, "/proj/src/deep/b.swift:1:let two = 2")
        let nothing = await run(tools, "Grep", #"{"pattern":"absent"}"#)
        XCTAssertEqual(nothing.text, "no matches")

        let edited = await run(tools, "Edit", #"{"file_path":"src/a.txt","old_string":"two","new_string":"2"}"#)
        XCTAssertEqual(edited, ToolResult(text: "edited /proj/src/a.txt (1 replacement)", diff: "@@ -1 +1 @@\n one\n-two\n+2\n three"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("proj/src/a.txt"), encoding: .utf8), "one\n2\nthree\n")

        let missing = await run(tools, "Edit", #"{"file_path":"src/a.txt","old_string":"two","new_string":"x"}"#)
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("was not found"), missing.text)
        _ = await run(tools, "Write", #"{"file_path":"d.txt","content":"x and x"}"#)
        let ambiguous = await run(tools, "Edit", #"{"file_path":"d.txt","old_string":"x","new_string":"y"}"#)
        XCTAssertTrue(ambiguous.text.contains("appears 2 times"), ambiguous.text)
        let all = await run(tools, "Edit", #"{"file_path":"d.txt","old_string":"x","new_string":"y","replace_all":true}"#)
        XCTAssertEqual(all.text, "edited /proj/d.txt (2 replacements)")

        let rewritten = await run(tools, "Write", #"{"file_path":"d.txt","content":"y and z\n"}"#)
        XCTAssertEqual(rewritten, ToolResult(text: "wrote /proj/d.txt (1 lines)", diff: "@@ -1 +1 @@\n-y and y\n+y and z"))

        try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("proj/image.png"))
        let binary = await run(tools, "Read", #"{"file_path":"image.png"}"#)
        XCTAssertTrue(binary.isError)
        XCTAssertTrue(binary.text.contains("binary file"), binary.text)

        let todos = await run(tools, "TodoWrite", #"{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"in_progress"}]}"#)
        XCTAssertEqual(todos.text, "task list updated (1/2 done)")
        XCTAssertEqual(todos.todos, [TodoItem(content: "a", status: .completed), TodoItem(content: "b", status: .inProgress)])

        let shell = await run(tools, "Bash", #"{"command":"ls"}"#)
        XCTAssertTrue(shell.isError)
        let unknown = await run(tools, "Nope", "{}")
        XCTAssertEqual(unknown, ToolResult(text: "unknown tool: Nope", isError: true))
    }

    func testTheDeviceWorkspaceCannotBeLeft() async throws {
        let outside = try scratchDirectory("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let tools = ToolBox(environment: LocalEnvironment(root: root))

        // `..` cannot climb above the root of the on-device file system.
        let climbed = await run(tools, "Read", #"{"file_path":"../../../etc/passwd"}"#)
        XCTAssertTrue(climbed.isError)
        XCTAssertFalse(climbed.text.contains("root:"), climbed.text)

        let followed = await run(tools, "Read", #"{"file_path":"link/s.txt"}"#)
        XCTAssertTrue(followed.text.contains("outside the workspace"), followed.text)
        // A file that does not exist yet must not be created through the link either.
        let planted = await run(tools, "Write", #"{"file_path":"link/new.txt","content":"x"}"#)
        XCTAssertTrue(planted.text.contains("outside the workspace"), planted.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))

        // Everything on the device counts as inside the folder, so reads never prompt.
        XCTAssertTrue(info(tools, "Read", #"{"file_path":"/elsewhere/x"}"#).insideFolder)
    }

    func testDescribingCalls() {
        let tools = ToolBox(environment: LocalEnvironment(root: root, folder: "proj"))
        let bash = info(tools, "Bash", #"{"command":"git status"}"#)
        XCTAssertEqual(bash, ToolInfo(kind: .execute, title: "Bash", summary: "git status", preview: "git status", command: "git status"))
        let edit = info(tools, "Edit", #"{"file_path":"src/a.txt","old_string":"a\nb","new_string":"a\nc"}"#)
        XCTAssertEqual(edit.kind, .edit)
        XCTAssertEqual(edit.summary, "src/a.txt")
        XCTAssertEqual(edit.path, "/proj/src/a.txt")
        XCTAssertEqual(edit.preview, "@@ -2 +2 @@\n-b\n+c")
        XCTAssertTrue(edit.previewIsDiff)
        let fetch = info(tools, "WebFetch", #"{"url":"https://Example.com/a?b=1"}"#)
        XCTAssertEqual(fetch.kind, .network)
        XCTAssertEqual(fetch.domain, "example.com")
        XCTAssertEqual(info(tools, "Glob", #"{"pattern":"**/*.ts"}"#).summary, "**/*.ts")
        XCTAssertEqual(info(tools, "TodoWrite", #"{"todos":[{"content":"a","status":"pending"}]}"#).summary, "1 item")
        XCTAssertEqual(info(tools, "Mystery", "{}").kind, .meta)
    }

    func testPlanModeOffersOnlyReadOnlyTools() async {
        let tools = ToolBox(environment: LocalEnvironment(root: root), readOnly: true)
        XCTAssertEqual(tools.specs.map(\.name), ["Read", "Glob", "Grep", "WebFetch", "TodoWrite"])
        let write = await run(tools, "Write", #"{"file_path":"a.txt","content":"x"}"#)
        XCTAssertTrue(write.isError)
        XCTAssertTrue(write.text.contains("plan mode"), write.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testRemoteEnvironmentThroughAShell() async throws {
        let home = try scratchDirectory("remote-home")
        defer { try? FileManager.default.removeItem(at: home) }
        for (path, content) in [
            "app/src/main.swift": "let port = 8080\n",
            "app/README.md": "# app\n",
            "app/node_modules/dep/index.swift": "let port = 1\n",
            "app/.git/config": "[core]\n",
        ] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let connection = LocalShellConnection(home: home)
        let environment = try await RemoteEnvironment.open(connection: connection, name: "box", detail: "me@box", folder: "~/app")
        XCTAssertEqual(environment.home, home.path)
        XCTAssertEqual(environment.cwd, home.path + "/app")
        XCTAssertNotEqual(environment.platform, "unknown")

        let tools = ToolBox(environment: environment)
        XCTAssertEqual(tools.specs.first?.name, "Bash")

        // Commands start in the working folder; output and the exit code come back together.
        let shell = await run(tools, "Bash", #"{"command":"pwd; echo oops 1>&2; exit 3"}"#)
        XCTAssertEqual(shell, ToolResult(text: "\(environment.cwd)\noops\n[exit 3]", isError: true))

        let files = try await environment.listFiles(under: environment.cwd, limit: 100)
        XCTAssertEqual(files, ["README.md", "src/main.swift"], "VCS and dependency folders are pruned")
        let folders = try await environment.listDirectories(environment.cwd)
        XCTAssertEqual(folders, ["node_modules", "src"])
        let glob = await run(tools, "Glob", #"{"pattern":"**/*.swift"}"#)
        XCTAssertEqual(glob.text, "src/main.swift")
        let grep = await run(tools, "Grep", #"{"pattern":"port = [0-9]+","path":"src","glob":"*.swift"}"#)
        XCTAssertEqual(grep.text, "\(environment.cwd)/src/main.swift:1:let port = 8080")

        // Writing creates missing folders even though the transfer itself does not.
        let write = await run(tools, "Write", #"{"file_path":"new/dir/note.txt","content":"héllo ✓\n"}"#)
        XCTAssertFalse(write.isError, write.text)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("app/new/dir/note.txt"), encoding: .utf8), "héllo ✓\n")
        let edit = await run(tools, "Edit", #"{"file_path":"src/main.swift","old_string":"8080","new_string":"8081"}"#)
        XCTAssertEqual(edit.diff, "@@ -1 +1 @@\n-let port = 8080\n+let port = 8081")
        let read = await run(tools, "Read", #"{"file_path":"~/app/src/main.swift"}"#)
        XCTAssertEqual(read.text, "     1\tlet port = 8081\n")

        // Paths outside the working folder are flagged, so reading them can ask first.
        let inside = info(tools, "Read", #"{"file_path":"src/main.swift"}"#)
        XCTAssertTrue(inside.insideFolder)
        XCTAssertEqual(inside.summary, "src/main.swift")
        let outside = info(tools, "Read", #"{"file_path":"~/other/x.txt"}"#)
        XCTAssertFalse(outside.insideFolder)
        XCTAssertEqual(outside.summary, "~/other/x.txt")
        XCTAssertFalse(info(tools, "Grep", #"{"pattern":"x","path":"/etc"}"#).insideFolder)

        do {
            _ = try await RemoteEnvironment.open(connection: connection, name: "box", detail: "", folder: "~/nope")
            XCTFail("expected the missing folder to be reported")
        } catch {
            XCTAssertEqual(error as? EnvironmentError, EnvironmentError("folder not found on box: \(home.path)/nope"))
        }
        do {
            _ = try await environment.listDirectories(environment.cwd + "/nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? EnvironmentError, EnvironmentError("no such folder: \(environment.cwd)/nope"))
        }
    }

    func testPermissionRules() {
        XCTAssertEqual(Permissions.commandPrefix("git status"), "git status")
        XCTAssertEqual(Permissions.commandPrefix("git -C x log"), "git")
        XCTAssertEqual(Permissions.commandPrefix("ls -la /tmp"), "ls")
        XCTAssertEqual(Permissions.commandPrefix("  npm   test  "), "npm test")
        for unsafe in ["ls; rm -rf /", "git status && reboot", "cat a | sh", "echo $(id)", "echo `id`", "ls > out",
                       "sudo ls", "rm -rf x", "FOO=1 ls", "python3 -c 1", "bash -c ls", "a\nb", ""] {
            XCTAssertNil(Permissions.commandPrefix(unsafe), unsafe)
        }

        func call(_ kind: ToolKind, inside: Bool = true, command: String? = nil, domain: String? = nil) -> ToolInfo {
            ToolInfo(kind: kind, title: "T", summary: "s", insideFolder: inside, command: command, domain: domain)
        }
        var rules = PermissionRules()
        func decide(_ info: ToolInfo, _ mode: PermissionMode) -> PermissionDecision {
            Permissions.decide(info, mode: mode, rules: rules)
        }

        XCTAssertEqual(decide(call(.read), .ask), .allow)
        XCTAssertEqual(decide(call(.read, inside: false), .ask), .ask)
        XCTAssertEqual(decide(call(.edit), .ask), .ask)
        XCTAssertEqual(decide(call(.execute, command: "ls"), .ask), .ask)
        XCTAssertEqual(decide(call(.network, domain: "example.com"), .ask), .ask)
        XCTAssertEqual(decide(call(.meta), .ask), .allow)

        XCTAssertEqual(decide(call(.edit), .acceptEdits), .allow)
        XCTAssertEqual(decide(call(.edit, inside: false), .acceptEdits), .ask)
        XCTAssertEqual(decide(call(.execute, command: "ls"), .acceptEdits), .ask)

        XCTAssertEqual(decide(call(.read), .plan), .allow)
        XCTAssertEqual(decide(call(.network, domain: "example.com"), .plan), .ask)
        for kind in [ToolKind.edit, .execute] {
            guard case .deny = decide(call(kind, command: "ls"), .plan) else { return XCTFail("plan mode must refuse \(kind)") }
        }

        for kind in [ToolKind.read, .edit, .execute, .network] {
            XCTAssertEqual(decide(call(kind, inside: false, command: "rm -rf /", domain: "x"), .bypass), .allow)
        }

        rules.insert(.commandPrefix("git status"))
        XCTAssertEqual(decide(call(.execute, command: "git status --short"), .ask), .allow)
        XCTAssertEqual(decide(call(.execute, command: "git status; rm -rf /"), .ask), .ask)
        XCTAssertEqual(decide(call(.execute, command: "git push"), .ask), .ask)
        rules.insert(.edits)
        XCTAssertEqual(decide(call(.edit, inside: false), .ask), .allow)
        guard case .deny = decide(call(.edit), .plan) else { return XCTFail("a standing rule does not override plan mode") }
        rules.insert(.domain("example.com"))
        XCTAssertEqual(decide(call(.network, domain: "example.com"), .ask), .allow)
        XCTAssertEqual(decide(call(.network, domain: "other.com"), .ask), .ask)
        rules.insert(.outsideReads)
        XCTAssertEqual(decide(call(.read, inside: false), .ask), .allow)

        XCTAssertEqual(Permissions.grant(for: call(.execute, command: "npm test")), .commandPrefix("npm test"))
        XCTAssertNil(Permissions.grant(for: call(.execute, command: "sudo reboot")))
        XCTAssertEqual(Permissions.grant(for: call(.edit)), .edits)
        XCTAssertEqual(Permissions.grant(for: call(.network, domain: "example.com")), .domain("example.com"))
        XCTAssertNil(Permissions.grant(for: call(.read)))
        XCTAssertEqual(Permissions.grant(for: call(.read, inside: false)), .outsideReads)
        XCTAssertEqual(PermissionGrant.commandPrefix("git status").label, "Always allow git status commands")
    }
}
