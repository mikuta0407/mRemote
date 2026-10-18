import XCTest
import AppleAdapters
import RDPProtocol
import SessionCore
@testable import mRemote

/// Exercises the real bridge, on the Simulator, against endpoints that are
/// guaranteed not to answer.
///
/// These are the only tests that run FreeRDP: everything up to the error
/// mapping is covered on the host in `RDPProtocolTests`, and what is left -
/// create, run, the failure path and the teardown order - cannot be tested
/// without the native session. A refused socket and a black-holed address are
/// enough to reach both, and neither needs a Windows machine or the network.
final class RDPRemoteSessionTests: XCTestCase {
    /// Nothing listens on port 1 of the loopback interface, so this refuses
    /// immediately rather than waiting for a timeout.
    private let refusedEndpoint = RemoteEndpoint(host: "127.0.0.1", port: 1)
    /// RFC 5737 TEST-NET-3, reserved for documentation and routed nowhere.
    /// Whether it hangs or fails fast depends on the network the Simulator is
    /// on, so a test using it may only assert what is true either way.
    private let blackHoleEndpoint = RemoteEndpoint(host: "203.0.113.1", port: 3389)

    private func makeSession(
        endpoint: RemoteEndpoint,
        username: String? = "tester",
        password: String? = "secret",
        proxy: ProxyServer? = nil
    ) async throws -> RDPRemoteSession {
        let credentials = InMemoryCredentialRepository()
        var account = RemoteAccount(username: username)
        if let password {
            let reference = CredentialReference()
            try credentials.store(password: password, for: reference)
            account.credentialReference = reference
        }
        let configuration = EffectiveConnectionConfiguration(
            profileID: ProfileID(),
            displayName: "test",
            endpoint: endpoint,
            account: account,
            resolutionPolicy: .fixed(width: 1_280, height: 720),
            initialScale: .fit,
            displayQuality: .automatic,
            keyboardLayout: .japanese,
            audioPlayback: false,
            clipboardPolicy: .disabled,
            scrollDirection: .normal,
            reconnectPolicy: .disabled,
            securityPolicy: .secureAutomatic,
            proxy: proxy
        )
        return RDPRemoteSession(
            configuration: configuration,
            credentials: credentials,
            trust: InMemoryTrustRepository(),
            desktopSize: (1_280, 720)
        )
    }

    private func waitForState(
        _ session: RDPRemoteSession,
        timeout: TimeInterval = 30,
        until predicate: @escaping @Sendable (SessionState) -> Bool
    ) async -> SessionState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await session.state
            if predicate(state) { return state }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await session.state
    }

    func testARefusedConnectionFailsWithAMappedErrorRatherThanARawCode() async throws {
        let session = try await makeSession(endpoint: refusedEndpoint)
        let errors = ErrorRecorder()
        let stream = await session.controlEvents()
        let observer = Task {
            for await event in stream {
                if case .error(let error) = event { errors.append(error) }
            }
        }
        defer { observer.cancel() }

        try await session.connect()
        let state = await waitForState(session) { $0 == .failed || $0 == .disconnected }
        XCTAssertEqual(state, .failed)

        // Whatever FreeRDP called it, the app only ever sees a category.
        let reported = errors.values
        XCTAssertFalse(reported.isEmpty, "a failed connect must report an error")
        for error in reported {
            if case .internalFailure(let detail) = error {
                XCTFail("an unmapped bridge status reached the UI: \(detail)")
            }
        }
    }

    /// Nothing listens where the proxy should be: the error names the proxy,
    /// not the computer behind it.
    func testAProxyThatIsNotThereIsReportedAsTheProxys() async throws {
        let session = try await makeSession(
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            proxy: ProxyServer(host: "127.0.0.1", port: 1))
        let errors = ErrorRecorder()
        let stream = await session.controlEvents()
        let observer = Task {
            for await event in stream {
                if case .error(let error) = event { errors.append(error) }
            }
        }
        defer { observer.cancel() }

        try await session.connect()
        let state = await waitForState(session) { $0 == .failed || $0 == .disconnected }
        XCTAssertEqual(state, .failed)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(errors.values, [.proxyUnreachable])
    }

    /// The whole RDP stack through a real SOCKS5 proxy to a real server.
    /// Skipped unless TEST_RUNNER_MREMOTE_RDP_PROXY_PORT (on 127.0.0.1),
    /// _HOST (as the proxy resolves it), _USER and _PASSWORD are given.
    func testAProxyCarriesARealConnection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["MREMOTE_RDP_PROXY_PORT"], let proxyPort = UInt16(portText),
              let host = environment["MREMOTE_RDP_PROXY_HOST"],
              let user = environment["MREMOTE_RDP_PROXY_USER"],
              let password = environment["MREMOTE_RDP_PROXY_PASSWORD"] else {
            throw XCTSkip("no proxy and server given")
        }
        let session = try await makeSession(
            endpoint: RemoteEndpoint(host: host, port: 3389), username: user, password: password,
            proxy: ProxyServer(host: "127.0.0.1", port: proxyPort))
        try await session.connect()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let state = await session.state
            if state == .connected || state == .failed || state == .disconnected { break }
            if let pending = await session.pendingChallenge, case .certificate = pending {
                try await session.respond(to: pending.id, with: .trustOnce)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = await session.state
        XCTAssertEqual(state, .connected)
        await session.disconnect(reason: .userRequested)
    }

    func testAFailedSessionCanBeDisconnectedAndReachesATerminalState() async throws {
        let session = try await makeSession(endpoint: refusedEndpoint)
        try await session.connect()
        _ = await waitForState(session) { $0 == .failed || $0 == .disconnected }

        await session.disconnect(reason: .userRequested)
        let state = await session.state
        XCTAssertEqual(state, .disconnected)
        // Idempotent: every exit path may call it, including one that runs
        // after the session already stopped.
        await session.disconnect(reason: .sceneTerminating)
        let repeated = await session.state
        XCTAssertEqual(repeated, .disconnected)
    }

    func testAConnectInFlightCanBeCancelled() async throws {
        // Two halves of the exit criterion that a connect is cancellable at
        // every stage: `connect` hands back a session that is still
        // connecting rather than blocking until the handshake resolves, and a
        // disconnect issued against that in-flight attempt completes instead
        // of waiting for the attempt to finish on its own.
        let session = try await makeSession(endpoint: blackHoleEndpoint)
        try await session.connect()
        let connecting = await session.state
        XCTAssertEqual(connecting, .connecting)

        let cancelled = Task { await session.disconnect(reason: .userRequested) }
        let disconnected = await waitForState(session, timeout: 20) { $0 == .disconnected }
        await cancelled.value
        XCTAssertEqual(disconnected, .disconnected)
    }

    func testAProfileWithNoPasswordAsksInsteadOfFailingToCreate() async throws {
        // `mr_rdp_session_create` refuses an empty password, and "invalid
        // argument" is not something to show a user who simply has not saved
        // one yet.
        let session = try await makeSession(endpoint: refusedEndpoint, password: nil)
        try await session.connect()

        let awaiting = await session.state
        XCTAssertEqual(awaiting, .awaitingUser)
        let pending = await session.pendingChallenge
        guard case .credential(let challenge)? = pending else {
            return XCTFail("expected a credential challenge")
        }
        XCTAssertEqual(challenge.host, refusedEndpoint.host)
        XCTAssertFalse(challenge.storedCredentialWasRejected)

        await session.disconnect(reason: .userRequested)
        let disconnected = await session.state
        XCTAssertEqual(disconnected, .disconnected)
    }

    func testCancellingACredentialChallengeEndsTheSession() async throws {
        let session = try await makeSession(endpoint: refusedEndpoint, password: nil)
        try await session.connect()
        let raised = await session.pendingChallenge
        let challengeID = try XCTUnwrap(raised?.id)

        try await session.respond(to: challengeID, with: .cancel)
        let cancelled = await session.state
        XCTAssertEqual(cancelled, .disconnected)

        // The attempt is over, so the same answer must not be applied twice.
        do {
            try await session.respond(to: challengeID, with: .cancel)
            XCTFail("a challenge answered twice was accepted")
        } catch {
            XCTAssertTrue(error is StaleChallengeError)
        }
    }

    func testTwentyConnectDisconnectCyclesLeaveNoSessionBehind() async throws {
        // The Phase 2 exit criterion, at the scale docs/README.md sets: enough
        // repetitions to catch a teardown that leaks a worker or a handle,
        // without pretending to be a soak test.
        for cycle in 1...20 {
            let session = try await makeSession(endpoint: refusedEndpoint)
            try await session.connect()
            _ = await waitForState(session) { $0 == .failed || $0 == .disconnected }
            await session.disconnect(reason: .userRequested)
            let finished = await session.state
            XCTAssertEqual(finished, .disconnected, "cycle \(cycle)")
        }
    }

    func testDisplayResizeIsRefusedUntilTheDisplayChannelIsNegotiated() async throws {
        let session = try await makeSession(endpoint: refusedEndpoint)
        let supported = await session.supportsDynamicResolution
        XCTAssertFalse(supported)
        // A no-op rather than an error: a server without the channel is not
        // broken, it simply keeps its own desktop size.
        await session.requestDesktopSize(width: 1_920, height: 1_080)
        let size = await session.desktopSize
        XCTAssertEqual(size.width, 1_280)
    }

    func testResizeDimensionsAreClampedToWhatTheBridgeAccepts() {
        // The bridge refuses an odd width because FreeRDP 3.31.1 would round
        // it and then disagree with us about the surface size.
        XCTAssertEqual(RDPRemoteSession.clampDimension(1_921, roundToEven: true), 1_920)
        XCTAssertEqual(RDPRemoteSession.clampDimension(10, roundToEven: true), 200)
        XCTAssertEqual(RDPRemoteSession.clampDimension(99_999, roundToEven: false), 8_192)
    }
}

private final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RemoteSessionError] = []

    func append(_ error: RemoteSessionError) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }

    var values: [RemoteSessionError] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The pointer path never reaches a real server here, so what these cover is
/// the gate in front of it: input is only delivered while a session can
/// actually carry it, and `send` is safe on every other path.
final class RDPInputSinkTests: XCTestCase {
    func testInputIsRefusedUntilAnAttemptIsRunning() {
        let sink = RDPInputSink()
        XCTAssertFalse(sink.acceptsInput)
        // Safe, and a no-op: the surface is allowed to send without checking.
        sink.send(.move(PixelPoint(x: 10, y: 10)))
        sink.send(.button(.left, .down, at: PixelPoint(x: 10, y: 10)))
        sink.send(.scroll(horizontal: 0, vertical: 120))

        // Accepting alone is not enough; there has to be a worker to send to.
        sink.setAccepting(true)
        XCTAssertFalse(sink.acceptsInput)
    }

    func testDetachingAWorkerAlsoStopsAcceptingInput() {
        let sink = RDPInputSink()
        sink.setAccepting(true)
        sink.attach(nil)
        XCTAssertFalse(sink.acceptsInput)
        sink.send(.move(PixelPoint(x: 1, y: 1)))
    }

    func testKeyInputIsGatedTheSameWayPointerInputIs() {
        let sink = RDPInputSink()
        XCTAssertFalse(sink.acceptsInput)
        // Safe on every path, including one that never reaches a worker.
        sink.send(KeyboardInput(usage: 0x91, transition: .down))
        sink.send(KeyboardInput(usage: 0x91, transition: .up))
    }

    func testAnUnmappableUsageIsDroppedRatherThanGuessedAt() {
        // Pause is an EXTENDED1 two-code sequence the event cannot express,
        // and 0xFFFF is not a usage at all. Neither may reach the bridge.
        let sink = RDPInputSink()
        sink.setAccepting(true)
        sink.send(KeyboardInput(usage: 0x48, transition: .down))
        sink.send(KeyboardInput(usage: 0xFFFF, transition: .down))
        XCTAssertThrowsError(try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0x48))
        XCTAssertThrowsError(try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xFFFF))
    }
}
