import XCTest
import TermCore
@testable import TermSSH

final class TermSSHTests: XCTestCase {
    func testFingerprintMatchesSSHKeygenFormat() {
        // SHA-256 of the three bytes "abc", base64 without padding.
        XCTAssertEqual(SSHKeys.fingerprint(ofOpenSSHKey: "ssh-ed25519 YWJj"),
                       "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
        XCTAssertEqual(SSHKeys.fingerprint(ofOpenSSHKey: "garbage"), "(unreadable key)")
    }

    func testRejectsUnreadablePrivateKey() {
        let credentials = SSHCredentials(host: "h", username: "u", secret: .privateKey(pem: "not a key", passphrase: nil))
        XCTAssertThrowsError(try SSHKeys.authentication(for: credentials))
    }

    // MARK: Live (needs an SSH server)

    private func credentials() throws -> SSHCredentials {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TERMAI_SSH_HOST"], let user = env["TERMAI_SSH_USER"] else {
            throw XCTSkip("set TERMAI_SSH_HOST, TERMAI_SSH_USER and TERMAI_SSH_PASSWORD or TERMAI_SSH_KEYFILE to run")
        }
        let secret: SSHCredentials.Secret
        if let keyFile = env["TERMAI_SSH_KEYFILE"] {
            secret = .privateKey(pem: try String(contentsOfFile: keyFile, encoding: .utf8), passphrase: env["TERMAI_SSH_PASSPHRASE"])
        } else {
            secret = .password(env["TERMAI_SSH_PASSWORD"] ?? "")
        }
        return SSHCredentials(host: host, port: Int(env["TERMAI_SSH_PORT"] ?? "22") ?? 22, username: user, secret: secret)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    func testLiveExecExitCodesTimeoutAndHostKeyPinning() async throws {
        let credentials = try credentials()
        let connection = try await SSHConnection.connect(credentials, trustedHostKey: nil)
        XCTAssertTrue(connection.isConnected)
        XCTAssertTrue(connection.hostKey.hasPrefix("ssh-") || connection.hostKey.hasPrefix("ecdsa-"), connection.hostKey)
        if let expected = ProcessInfo.processInfo.environment["TERMAI_SSH_FINGERPRINT"] {
            XCTAssertEqual(connection.hostKeyFingerprint, expected)
        }

        let output = Output()
        let ok = try await connection.exec("echo out; echo err 1>&2", timeout: 20) { output.append($0) }
        XCTAssertEqual(ok, 0)
        XCTAssertTrue(output.value.contains("out"), output.value)
        XCTAssertTrue(output.value.contains("err"), output.value)
        let failed = try await connection.exec("exit 7", timeout: 20) { _ in }
        XCTAssertEqual(failed, 7)
        do {
            _ = try await connection.exec("sleep 30", timeout: 1) { _ in }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SSHError, .timedOut(seconds: 1))
        }
        await connection.close()

        // The recorded key is accepted again; a different pinned key is refused.
        let again = try await SSHConnection.connect(credentials, trustedHostKey: connection.hostKey)
        await again.close()
        do {
            _ = try await SSHConnection.connect(credentials, trustedHostKey: "ssh-ed25519 YWJj")
            XCTFail("expected a host key mismatch")
        } catch {
            XCTAssertEqual(error as? SSHError, .hostKeyMismatch(expected: "ssh-ed25519 YWJj", received: connection.hostKey))
        }
    }

    func testLiveWrongPasswordAndUnreachableHost() async throws {
        var credentials = try credentials()
        credentials.secret = .password("definitely-wrong")
        do {
            _ = try await SSHConnection.connect(credentials, trustedHostKey: nil)
            XCTFail("expected authentication to fail")
        } catch {
            XCTAssertEqual(error as? SSHError, .authenticationFailed, "\(error)")
        }
        credentials.port = 1
        do {
            _ = try await SSHConnection.connect(credentials, trustedHostKey: nil)
            XCTFail("expected the connection to fail")
        } catch {
            guard case SSHError.connectionFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testLiveFileTransferAndTools() async throws {
        let connection = try await SSHConnection.connect(try credentials(), trustedHostKey: nil)
        let folder = "termai-test-\(UUID().uuidString.prefix(8))"
        let home = try await RemoteEnvironment.open(connection: connection, name: "box", detail: "test", folder: "")
        XCTAssertTrue(home.home.hasPrefix("/"))
        XCTAssertEqual(home.cwd, home.home)
        _ = try await home.exec("mkdir -p \(folder)/src", timeout: 20) { _ in }

        let environment = try await RemoteEnvironment.open(connection: connection, name: "box", detail: "test", folder: "~/\(folder)")
        XCTAssertEqual(environment.cwd, "\(home.home)/\(folder)")

        // Files go over SFTP byte for byte, including ones larger than a single packet.
        let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await environment.writeFile(environment.cwd + "/blob.bin", large)
        let back = try await environment.readFile(environment.cwd + "/blob.bin", maxBytes: 1_000_000)
        XCTAssertEqual(back, large)
        do {
            _ = try await environment.readFile(environment.cwd + "/blob.bin", maxBytes: 1_000)
            XCTFail("expected the size limit to apply")
        } catch {
            XCTAssertEqual(error as? EnvironmentError, EnvironmentError("file is too large (300000 bytes)"))
        }
        do {
            _ = try await environment.readFile(environment.cwd + "/absent.txt", maxBytes: 1_000)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(ErrorText.describe(error).contains("absent.txt"), ErrorText.describe(error))
        }

        // The agent's tools on the host.
        let tools = ToolBox(environment: environment)
        func run(_ name: String, _ arguments: String) async -> ToolResult {
            await tools.run(ToolCall(id: "1", name: name, arguments: arguments)) { _ in }
        }
        let written = await run("Write", #"{"file_path":"new/dir/héllo.txt","content":"one ✓\ntwo\n"}"#)
        XCTAssertEqual(written.text, "created \(environment.cwd)/new/dir/héllo.txt (2 lines)")
        let edited = await run("Edit", #"{"file_path":"new/dir/héllo.txt","old_string":"two","new_string":"2"}"#)
        XCTAssertEqual(edited.diff, "@@ -1 +1 @@\n one ✓\n-two\n+2")
        let read = await run("Read", #"{"file_path":"~/\#(folder)/new/dir/héllo.txt"}"#)
        XCTAssertEqual(read.text, "     1\tone ✓\n     2\t2\n")
        let glob = await run("Glob", #"{"pattern":"**/*.txt"}"#)
        XCTAssertEqual(glob.text, "new/dir/héllo.txt")
        let grep = await run("Grep", #"{"pattern":"^one","glob":"*.txt"}"#)
        XCTAssertEqual(grep.text, "\(environment.cwd)/new/dir/héllo.txt:1:one ✓")
        let shell = await run("Bash", #"{"command":"pwd && cat new/dir/héllo.txt | wc -l && exit 4"}"#)
        XCTAssertTrue(shell.isError)
        XCTAssertTrue(shell.text.hasPrefix(environment.cwd + "\n"), shell.text)
        XCTAssertTrue(shell.text.hasSuffix("[exit 4]"), shell.text)
        let folders = try await environment.listDirectories(environment.cwd)
        XCTAssertEqual(folders, ["new", "src"])

        _ = try await home.exec("rm -rf \(folder)", timeout: 20) { _ in }
        await connection.close()
        XCTAssertFalse(connection.isConnected)
    }
}
