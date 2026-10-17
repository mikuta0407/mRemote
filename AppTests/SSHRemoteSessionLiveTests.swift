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
    }

    private func makeSession(
        keys: InMemorySSHKeyRepository,
        knownHosts: InMemoryKnownHostRepository,
        keyID: SSHKeyID?,
        startupCommand: String? = nil,
        forwards: [SSHPortForward]? = nil
    ) -> SSHRemoteSession {
        let profile = ConnectionProfile(
            displayName: "live",
            endpoint: RemoteEndpoint(host: "127.0.0.1", port: port),
            account: RemoteAccount(username: user),
            configuration: .ssh(SSHConfiguration(
                authentication: SSHAuthentication(keyID: keyID, allowsKeyboardInteractive: false, allowsPassword: false),
                startupCommand: startupCommand,
                portForwards: forwards)))
        let configuration = EffectiveProfileResolver().resolve(profile: profile, globalSettings: .default)
        return SSHRemoteSession(
            configuration: configuration, credentials: InMemoryCredentialRepository(),
            knownHosts: knownHosts, keys: keys)
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

    func testWithoutAnAcceptedKeySignInFails() async throws {
        let session = makeSession(keys: InMemorySSHKeyRepository(), knownHosts: InMemoryKnownHostRepository(), keyID: nil)
        try await session.connect()
        try await wait(for: .failed, in: session)
        await session.disconnect(reason: .userRequested)
    }
}
