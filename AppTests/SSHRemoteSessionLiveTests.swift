import XCTest
import AppleAdapters
import SSHProtocol
import SessionCore
@testable import mRemote

/// The whole SSH stack - session actor, native worker, C bridge, libssh2 -
/// against a real sshd. Skipped unless one is given: run
/// bridge/ssh/tests/run_live_app_tests.sh, which starts a throwaway sshd on
/// the host's loopback (the Simulator shares it) and passes it in through
/// TEST_RUNNER_ variables.
final class SSHRemoteSessionLiveTests: XCTestCase {
    private var port: UInt16 = 0
    private var user = ""
    private var keyFile = Data()
    /// OpenSSH's own SOCKS5 proxy (`ssh -D`) through the same sshd, when the
    /// runner started one.
    private var socksPort: UInt16?

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["MREMOTE_SSH_TEST_PORT"], let port = UInt16(portText),
              let user = environment["MREMOTE_SSH_TEST_USER"],
              let keyPath = environment["MREMOTE_SSH_TEST_KEY"] else {
            throw XCTSkip("no test sshd (bridge/ssh/tests/run_live_app_tests.sh)")
        }
        self.port = port
        self.user = user
        self.keyFile = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        socksPort = environment["MREMOTE_SSH_TEST_SOCKS_PORT"].flatMap { UInt16($0) }
    }

    private func makeSession(
        keys: InMemorySSHKeyRepository,
        knownHosts: InMemoryKnownHostRepository,
        keyID: SSHKeyID?,
        startupCommand: String? = nil,
        forwards: [SSHPortForward]? = nil,
        host: String = "127.0.0.1",
        proxy: ProxyServer? = nil,
        tmux: SSHTmuxSettings? = nil
    ) -> SSHRemoteSession {
        var profile = ConnectionProfile(
            displayName: "live",
            endpoint: RemoteEndpoint(host: host, port: port),
            account: RemoteAccount(username: user),
            configuration: .ssh(SSHConfiguration(
                authentication: SSHAuthentication(keyID: keyID, allowsKeyboardInteractive: false, allowsPassword: false),
                startupCommand: startupCommand,
                portForwards: forwards,
                tmux: tmux)))
        profile.proxyID = proxy?.id
        let configuration = EffectiveProfileResolver().resolve(
            profile: profile, globalSettings: .default, proxies: proxy.map { [$0] } ?? [])
        return SSHRemoteSession(
            configuration: configuration, credentials: InMemoryCredentialRepository(),
            knownHosts: knownHosts, keys: keys)
    }

    /// MR_SSH_LINUX=1: the server is a container, whose loopback is not
    /// this machine's.
    private func skipOnLinuxHost() throws {
        if ProcessInfo.processInfo.environment["MREMOTE_SSH_TEST_TMUX_HOST"] == "isolated" {
            throw XCTSkip("the server is not this machine")
        }
    }

    private func storeKey(in keys: InMemorySSHKeyRepository) throws -> SSHKeyID {
        let parsed = try OpenSSHKey(parsing: keyFile)
        let metadata = SSHKeyMetadata(
            name: "test", keyType: parsed.keyType, publicKey: parsed.publicKeyLine,
            fingerprint: parsed.fingerprint, isEncrypted: parsed.isEncrypted)
        try keys.store(metadata, privateKey: keyFile)
        return metadata.id
    }

    /// Waits for the session to reach `state`, answering host key
    /// challenges with `hostKeyAnswer` on the way.
    private func wait(
        for state: SessionState, in session: SSHRemoteSession,
        hostKeyAnswer: ChallengeResponse = .trustPersistently,
        seen: ((HostKeyChallenge) -> Void)? = nil,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await session.state == state { return }
            if let challenge = await session.pendingChallenge, case .hostKey(let hostKey) = challenge {
                seen?(hostKey)
                try await session.respond(to: challenge.id, with: hostKeyAnswer)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let actual = await session.state
        XCTFail("state is \(actual), expected \(state)")
    }

    private func output(of session: SSHRemoteSession, containing needle: String, timeout: TimeInterval = 15) async -> String {
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            text += String(decoding: session.terminalOutput.drain(), as: UTF8.self)
            if text.contains(needle) { return text }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return text
    }

    func testAKeySignsInRunsTheStartupCommandAndTheShellEchoes() async throws {
        let keys = InMemorySSHKeyRepository()
        let knownHosts = InMemoryKnownHostRepository()
        let session = makeSession(keys: keys, knownHosts: knownHosts, keyID: try storeKey(in: keys),
                                  startupCommand: "echo started-$((20+1))")
        var seenFingerprint: String?
        try await session.connect()
        try await wait(for: .connected, in: session, seen: { seenFingerprint = $0.fingerprint })

        XCTAssertNotNil(seenFingerprint)
        XCTAssertEqual(try knownHosts.allHosts().first?.fingerprint, seenFingerprint)
        let started = await output(of: session, containing: "started-21")
        XCTAssertTrue(started.contains("started-21"), started)

        await session.resizeTerminal(TerminalSize(columns: 101, rows: 37))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(session.terminalInput.send(Array("stty size\r".utf8)))
        let size = await output(of: session, containing: "37 101")
        XCTAssertTrue(size.contains("37 101"), size)

        XCTAssertTrue(session.terminalInput.send(Array("exit 4\r".utf8)))
        try await wait(for: .disconnected, in: session)
    }

    private func output(of channel: TerminalChannel, containing needle: String, timeout: TimeInterval = 15) async -> String {
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            text += String(decoding: channel.output.drain(), as: UTF8.self)
            if text.contains(needle) { return text }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return text
    }

    /// Tabs and panes: more shells on the one connection, each with its own
    /// output, size and end; and a command run beside them.
    func testMoreShellsAndACommandShareTheConnection() async throws {
        let keys = InMemorySSHKeyRepository()
        let session = makeSession(keys: keys, knownHosts: InMemoryKnownHostRepository(), keyID: try storeKey(in: keys))
        let events = await session.controlEvents()
        var ended: [TerminalID] = []
        let watcher = Task {
            for await event in events {
                if case .terminalEnded(let id, _) = event { ended.append(id) }
            }
            return ended
        }
        try await session.connect()
        try await wait(for: .connected, in: session)

        let opened = await session.openTerminal(size: TerminalSize(columns: 90, rows: 20))
        let second = try XCTUnwrap(opened)
        XCTAssertTrue(second.input.send(Array("stty size; echo second-$((2*3))\r".utf8)))
        let secondText = await output(of: second, containing: "second-6")
        XCTAssertTrue(secondText.contains("20 90"), secondText)
        XCTAssertTrue(session.primaryTerminal.input.send(Array("echo first-$((1+6))\r".utf8)))
        let firstText = await output(of: session.primaryTerminal, containing: "first-7")
        XCTAssertTrue(firstText.contains("first-7"), firstText)
        XCTAssertFalse(firstText.contains("second-6"), "the second shell's output reached the first")

        let command = await session.runCommand("echo cmd-$((4*4)); exit 3")
        XCTAssertEqual(command?.exitStatus, 3)
        XCTAssertTrue(command?.output.contains("cmd-16") == true, command?.output ?? "nil")

        // A shell exiting ends its terminal; the session goes on.
        XCTAssertTrue(second.input.send(Array("exit\r".utf8)))
        // Its input lets go once it has ended.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, second.input.send(Array(" ".utf8)) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(second.input.send(Array(" ".utf8)), "the ended shell still takes input")
        let state = await session.state
        XCTAssertEqual(state, .connected, "the session ended with a shell still open")
        await session.closeTerminal(session.primaryTerminal.id)
        try await wait(for: .disconnected, in: session)
        let endedTerminals = await watcher.value
        XCTAssertTrue(endedTerminals.contains(second.id), "terminalEnded for the second shell: \(endedTerminals)")
        XCTAssertFalse(endedTerminals.contains(session.primaryTerminal.id), "the last one ends the session instead")
    }

    /// docs/ssh-design.md 16.4, against the Linux container's tmux: straight
    /// into a named session,
    /// then, on the next connection, that session offered and gone back into.
    func testTmuxSessionsAreFoundAndGoneBackInto() async throws {
        // It starts tmux sessions: only on a host of its own (the runner's
        // Linux container), never on the machine running the tests, whose
        // tmux it could reach.
        guard ProcessInfo.processInfo.environment["MREMOTE_SSH_TEST_TMUX_HOST"] == "isolated" else {
            throw XCTSkip("needs MR_SSH_LINUX=1 (a host of its own for tmux)")
        }
        let keys = InMemorySSHKeyRepository()
        let keyID = try storeKey(in: keys)
        let knownHosts = InMemoryKnownHostRepository()

        let first = makeSession(keys: keys, knownHosts: knownHosts, keyID: keyID,
                                tmux: SSHTmuxSettings(attach: .automatic, sessionName: "mr-live"))
        try await first.connect()
        try await wait(for: .connected, in: first)
        XCTAssertTrue(first.terminalInput.send(Array("echo inside-${TMUX:+tmux}-$((1+1))\r".utf8)))
        let inside = await output(of: first, containing: "inside-tmux-2")
        XCTAssertTrue(inside.contains("inside-tmux-2"), "the automatic session runs in tmux: \(inside)")
        await first.disconnect(reason: .userRequested)
        try await wait(for: .disconnected, in: first)

        let second = makeSession(keys: keys, knownHosts: knownHosts, keyID: keyID, tmux: SSHTmuxSettings(attach: .ask))
        try await second.connect()
        var offered: TmuxSessionChallenge?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, offered == nil {
            if let challenge = await second.pendingChallenge {
                switch challenge {
                case .hostKey: try await second.respond(to: challenge.id, with: .trustPersistently)
                case .tmuxSession(let tmux): offered = tmux
                default: break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let challenge = try XCTUnwrap(offered, "the host's tmux sessions are offered")
        XCTAssertEqual(challenge.sessions.map(\.name), ["mr-live"])
        try await second.respond(to: challenge.id, with: .tmux(.attach("mr-live", controlMode: false)))
        try await wait(for: .connected, in: second)
        XCTAssertTrue(second.terminalInput.send(Array("echo back-${TMUX:+tmux}-$((2+2))\r".utf8)))
        let back = await output(of: second, containing: "back-tmux-4")
        XCTAssertTrue(back.contains("back-tmux-4"), "back in the session: \(back)")
        XCTAssertTrue(back.contains("inside-tmux-2"), "with what it showed before: \(back)")

        await second.disconnect(reason: .userRequested)
    }

    func testATrustedHostKeyIsNotAskedAgainAndAChangedOneIsFlagged() async throws {
        let keys = InMemorySSHKeyRepository()
        let knownHosts = InMemoryKnownHostRepository()
        let keyID = try storeKey(in: keys)

        let first = makeSession(keys: keys, knownHosts: knownHosts, keyID: keyID)
        try await first.connect()
        try await wait(for: .connected, in: first)
        await first.disconnect(reason: .userRequested)

        var asked = false
        let second = makeSession(keys: keys, knownHosts: knownHosts, keyID: keyID)
        try await second.connect()
        try await wait(for: .connected, in: second, seen: { _ in asked = true })
        XCTAssertFalse(asked, "a trusted key was asked about again")
        await second.disconnect(reason: .userRequested)

        // Pretend the stored key was a different one.
        let stored = try XCTUnwrap(knownHosts.allHosts().first)
        try knownHosts.store(KnownHost(host: stored.host, port: stored.port, keyType: "ssh-rsa", fingerprint: "SHA256:old"))
        var disposition: HostKeyDisposition?
        let third = makeSession(keys: keys, knownHosts: knownHosts, keyID: keyID)
        try await third.connect()
        try await wait(for: .disconnected, in: third, hostKeyAnswer: .cancel, seen: { disposition = $0.disposition })
        XCTAssertEqual(disposition, .changed(previousKeyType: "ssh-rsa", previousFingerprint: "SHA256:old"))
        XCTAssertEqual(try knownHosts.allHosts().first?.fingerprint, "SHA256:old", "a refused key replaced the trusted one")
    }

    /// A forward to the sshd itself: what comes back through it is the SSH
    /// banner, so the bytes went device -> tunnel -> server -> target.
    func testALocalForwardReachesTheTargetThroughTheServer() async throws {
        // Its target is this machine's loopback, as the server sees it.
        try skipOnLinuxHost()
        let keys = InMemorySSHKeyRepository()
        let localPort = UInt16.random(in: 40000...50000)
        let session = makeSession(
            keys: keys, knownHosts: InMemoryKnownHostRepository(), keyID: try storeKey(in: keys),
            forwards: [SSHPortForward(localPort: localPort, remoteHost: "127.0.0.1", remotePort: port)])
        try await session.connect()
        try await wait(for: .connected, in: session)
        try await Task.sleep(for: .milliseconds(300))

        let banner = try await Task.detached { () throws -> String in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = localPort.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            var buffer = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buffer, buffer.count)
            return String(decoding: buffer.prefix(max(0, n)), as: UTF8.self)
        }.value
        XCTAssertTrue(banner.hasPrefix("SSH-2.0-"), banner)
        await session.disconnect(reason: .userRequested)
    }

    /// The name goes to the proxy unresolved: "localhost" is looked up on the
    /// proxy's side.
    func testAProxyCarriesTheConnection() async throws {
        // Its target is this machine's loopback, as the server sees it.
        try skipOnLinuxHost()
        guard let socksPort else { throw XCTSkip("no SOCKS proxy (run_live_app_tests.sh starts one)") }
        let keys = InMemorySSHKeyRepository()
        let session = makeSession(
            keys: keys, knownHosts: InMemoryKnownHostRepository(), keyID: try storeKey(in: keys),
            startupCommand: "echo proxied-$((40+2))", host: "localhost",
            proxy: ProxyServer(host: "127.0.0.1", port: socksPort))
        try await session.connect()
        try await wait(for: .connected, in: session)
        let text = await output(of: session, containing: "proxied-42")
        XCTAssertTrue(text.contains("proxied-42"), text)
        await session.disconnect(reason: .userRequested)
    }

    func testAProxyThatIsNotThereIsSaidSo() async throws {
        let session = makeSession(
            keys: InMemorySSHKeyRepository(), knownHosts: InMemoryKnownHostRepository(), keyID: nil,
            proxy: ProxyServer(host: "127.0.0.1", port: 1))
        let events = await session.controlEvents()
        try await session.connect()
        var error: RemoteSessionError?
        for await event in events {
            if case .error(let reported) = event {
                error = reported
                break
            }
        }
        XCTAssertEqual(error, .proxyUnreachable)
        await session.disconnect(reason: .userRequested)
    }

    /// ProxyJump: the target through a jump host, both this sshd, each with
    /// its own host key question; then a target the jump host cannot reach.
    func testAJumpHostCarriesTheConnection() async throws {
        let keys = InMemorySSHKeyRepository()
        let knownHosts = InMemoryKnownHostRepository()
        let keyID = try storeKey(in: keys)
        // The target as the jump host sees it: on the Linux host, its own sshd.
        let isolated = ProcessInfo.processInfo.environment["MREMOTE_SSH_TEST_TMUX_HOST"] == "isolated"
        func profiles(targetPort: UInt16) -> (ConnectionProfile, [ConnectionProfile]) {
            let auth = SSHAuthentication(keyID: keyID, allowsKeyboardInteractive: false, allowsPassword: false)
            let bastion = ConnectionProfile(
                displayName: "bastion", endpoint: RemoteEndpoint(host: "127.0.0.1", port: port),
                account: RemoteAccount(username: user),
                configuration: .ssh(SSHConfiguration(authentication: auth, tmux: SSHTmuxSettings(attach: .off))))
            let target = ConnectionProfile(
                displayName: "target", endpoint: RemoteEndpoint(host: "localhost", port: targetPort),
                account: RemoteAccount(username: user),
                configuration: .ssh(SSHConfiguration(
                    authentication: auth, startupCommand: "echo jumped-$((40+3))",
                    tmux: SSHTmuxSettings(attach: .off), jumpProfileID: bastion.id)))
            return (target, [bastion, target])
        }
        func session(targetPort: UInt16) -> SSHRemoteSession {
            let (target, all) = profiles(targetPort: targetPort)
            let configuration = EffectiveProfileResolver().resolve(
                profile: target, globalSettings: .default, profiles: all)
            return SSHRemoteSession(configuration: configuration, credentials: InMemoryCredentialRepository(),
                                    knownHosts: knownHosts, keys: keys)
        }

        let through = session(targetPort: isolated ? 22 : port)
        var asked: [String] = []
        try await through.connect()
        try await wait(for: .connected, in: through, seen: { asked.append("\($0.host):\($0.port)") })
        XCTAssertEqual(asked, ["127.0.0.1:\(port)", "localhost:\(isolated ? 22 : port)"],
                       "the jump host's key is asked about first, then the target's")
        let text = await output(of: through, containing: "jumped-43")
        XCTAssertTrue(text.contains("jumped-43"), text)
        XCTAssertTrue(through.terminalInput.send(Array("exit\r".utf8)))
        try await wait(for: .disconnected, in: through)

        // Nothing listens there: the jump host signs in (its key now known),
        // the stream to the target does not get through.
        let unreachable = session(targetPort: 1)
        let events = await unreachable.controlEvents()
        try await unreachable.connect()
        var error: RemoteSessionError?
        for await event in events {
            if case .error(let reported) = event {
                error = reported
                break
            }
        }
        XCTAssertEqual(error, .jumpHost(name: "bastion", error: nil))
        await unreachable.disconnect(reason: .userRequested)
    }

    func testWithoutAnAcceptedKeySignInFails() async throws {
        let session = makeSession(keys: InMemorySSHKeyRepository(), knownHosts: InMemoryKnownHostRepository(), keyID: nil)
        try await session.connect()
        try await wait(for: .failed, in: session)
        await session.disconnect(reason: .userRequested)
    }
}

/// Password and keyboard-interactive sign-in against a host with a real
/// account (a macOS VM's リモートログイン, say) - the loopback sshd cannot
/// check passwords. Skipped unless TEST_RUNNER_MREMOTE_SSH_PW_HOST, _USER
/// and _PASSWORD are given.
final class SSHPasswordLiveTests: XCTestCase {
    private var host = ""
    private var user = ""
    private var password = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MREMOTE_SSH_PW_HOST"], let user = environment["MREMOTE_SSH_PW_USER"],
              let password = environment["MREMOTE_SSH_PW_PASSWORD"] else {
            throw XCTSkip("no password host")
        }
        self.host = host
        self.user = user
        self.password = password
    }

    private func session(
        storedPassword: String?, keyboardInteractive: Bool, password allowsPassword: Bool
    ) throws -> SSHRemoteSession {
        let credentials = InMemoryCredentialRepository()
        let reference = CredentialReference()
        if let storedPassword { try credentials.store(password: storedPassword, for: reference) }
        let profile = ConnectionProfile(
            displayName: "pw",
            endpoint: RemoteEndpoint(host: host, port: 22),
            account: RemoteAccount(username: user, credentialReference: reference),
            configuration: .ssh(SSHConfiguration(authentication: SSHAuthentication(
                keyID: nil, allowsKeyboardInteractive: keyboardInteractive, allowsPassword: allowsPassword))))
        return SSHRemoteSession(
            configuration: EffectiveProfileResolver().resolve(profile: profile, globalSettings: .default),
            credentials: credentials, knownHosts: InMemoryKnownHostRepository(), keys: InMemorySSHKeyRepository())
    }

    /// Answers whatever is asked with `answer`, until `state`. Returns the
    /// kinds of challenge seen.
    private func drive(_ session: SSHRemoteSession, to state: SessionState, answer: String) async throws -> [String] {
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if await session.state == state { return seen }
            if let challenge = await session.pendingChallenge {
                switch challenge {
                case .hostKey:
                    seen.append("hostKey")
                    try await session.respond(to: challenge.id, with: .trustOnce)
                case .keyboardInteractive(let prompts):
                    seen.append("keyboardInteractive")
                    try await session.respond(to: challenge.id, with: .keyboardInteractive(
                        answers: prompts.prompts.map { _ in answer }))
                case .credential(let credential):
                    seen.append(credential.storedCredentialWasRejected ? "credential-again" : "credential")
                    try await session.respond(to: challenge.id, with: .credential(
                        username: user, domain: nil, password: answer, save: false))
                default:
                    seen.append("other")
                    try await session.respond(to: challenge.id, with: .cancel)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let actual = await session.state
        XCTFail("state \(actual), expected \(state); seen \(seen)")
        return seen
    }

    func testKeyboardInteractiveSignsIn() async throws {
        let s = try session(storedPassword: nil, keyboardInteractive: true, password: false)
        try await s.connect()
        let seen = try await drive(s, to: .connected, answer: password)
        XCTAssertTrue(seen.contains("keyboardInteractive"), "\(seen)")
        await s.disconnect(reason: .userRequested)
    }

    func testAStoredPasswordSignsInWithoutAsking() async throws {
        let s = try session(storedPassword: password, keyboardInteractive: false, password: true)
        try await s.connect()
        let seen = try await drive(s, to: .connected, answer: "unused")
        XCTAssertEqual(seen, ["hostKey"])
        await s.disconnect(reason: .userRequested)
    }

    /// A wrong stored password is sent once; then the user is asked, and
    /// what they type signs in.
    func testAWrongStoredPasswordIsAskedForInstead() async throws {
        let s = try session(storedPassword: "wrong-\(UUID().uuidString)", keyboardInteractive: false, password: true)
        try await s.connect()
        let seen = try await drive(s, to: .connected, answer: password)
        XCTAssertEqual(seen, ["hostKey", "credential-again"])
        await s.disconnect(reason: .userRequested)
    }
}
