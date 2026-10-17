import Foundation

/// A scripted `RemoteSession` with no protocol behind it.
///
/// It exists so the whole app above the protocol layer - list, workspace,
/// focus, settings, error presentation - can be built and tested before the
/// FreeRDP session is wired in, and so UI tests do not need a Windows host.
/// It is deliberately part of the shipping module rather than a test target:
/// SwiftUI previews and the UI test target both need it.
public actor FakeRemoteSession: RemoteSession, ClipboardCapableSession {
    public enum Script: Sendable {
        /// Connects cleanly.
        case succeeds
        /// Asks for a password first, then connects if one is supplied.
        case requiresCredential
        /// Presents a certificate the user must review.
        case requiresCertificateReview(CertificateDisposition)
        /// Fails at the connect step.
        case fails(RemoteSessionError)
    }

    public nonisolated let id: SessionID
    public nonisolated let profileID: ProfileID?
    public let configuration: EffectiveConnectionConfiguration

    private let script: Script
    private var machine = SessionStateMachine()
    private var continuations: [UUID: AsyncStream<SessionControlEvent>.Continuation] = [:]
    public private(set) var pendingChallenge: SessionChallenge?
    private var visibility: SessionVisibility = .focused

    public init(
        id: SessionID = SessionID(),
        configuration: EffectiveConnectionConfiguration,
        script: Script = .succeeds
    ) {
        self.id = id
        self.profileID = configuration.profileID
        self.configuration = configuration
        self.script = script
    }

    public var state: SessionState { machine.state }
    public var generation: SessionGeneration { machine.generation }
    public var currentVisibility: SessionVisibility { visibility }

    public func controlEvents() -> AsyncStream<SessionControlEvent> {
        // Bounded and newest-dropping: a slow consumer must not let events
        // accumulate without limit. State and the pending challenge stay
        // readable from the session, so a dropped event costs a re-read rather
        // than a lost challenge.
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let key = UUID()
            continuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(key) }
            }
        }
    }

    private func removeContinuation(_ key: UUID) {
        continuations[key] = nil
    }

    public func connect() async throws {
        guard machine.transition(to: .connecting) != nil else { return }
        emit(.stateChanged(machine.state, generation: machine.generation))

        switch script {
        case .succeeds:
            finishConnecting()
        case .fails(let error):
            machine.transition(to: .failed)
            emit(.error(error))
            emit(.stateChanged(machine.state, generation: machine.generation))
        case .requiresCredential:
            raise(.credential(CredentialChallenge(
                generation: machine.generation,
                host: configuration.endpoint.host,
                username: configuration.account.username,
                domain: configuration.account.domain
            )))
        case .requiresCertificateReview(let disposition):
            raise(.certificate(CertificateChallenge(
                generation: machine.generation,
                host: configuration.endpoint.host,
                port: configuration.endpoint.port,
                leafSHA256: String(repeating: "ab", count: 32),
                chainSHA256: String(repeating: "cd", count: 32),
                subject: "CN=\(configuration.endpoint.host)",
                issuer: "CN=\(configuration.endpoint.host)",
                notBefore: Date(timeIntervalSinceNow: -86_400),
                notAfter: Date(timeIntervalSinceNow: 86_400 * 365),
                disposition: disposition
            )))
        }
    }

    public func respond(to challengeID: ChallengeID, with response: ChallengeResponse) throws {
        // A challenge answers exactly once. A second answer, or one that
        // arrives after the attempt ended, names a challenge that is no longer
        // pending and is refused rather than applied to the current attempt.
        guard let pending = pendingChallenge, pending.id == challengeID else {
            throw StaleChallengeError(challengeID: challengeID)
        }
        pendingChallenge = nil

        switch response {
        case .cancel:
            machine.transition(to: .disconnecting)
            emit(.stateChanged(machine.state, generation: machine.generation))
            emit(.error(.userCancelled))
            machine.transition(to: .disconnected)
            emit(.stateChanged(machine.state, generation: machine.generation))
        case .credential, .trustOnce, .trustPersistently, .keyboardInteractive, .passphrase:
            machine.transition(to: .connecting)
            emit(.stateChanged(machine.state, generation: machine.generation))
            finishConnecting()
        }
    }

    public func disconnect(reason: DisconnectReason) async {
        // Idempotent: every exit path may call this, including one that runs
        // after the session already stopped.
        guard machine.state != .disconnected, machine.state != .idle else { return }
        pendingChallenge = nil
        if machine.transition(to: .disconnecting) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        }
        if case .failed(let error) = reason {
            emit(.error(error))
        }
        machine.transition(to: .disconnected)
        emit(.stateChanged(machine.state, generation: machine.generation))
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    public func setVisibility(_ visibility: SessionVisibility) {
        self.visibility = visibility
    }

    // MARK: - Clipboard

    public private(set) var remoteClipboard: String?
    public private(set) var offeredTexts: [String] = []

    public var remoteHasText: Bool { remoteClipboard != nil }

    /// Stands in for a copy made on the remote desktop.
    public func simulateRemoteCopy(_ text: String?) {
        remoteClipboard = text
        emit(.clipboardChanged(hasRemoteText: text != nil))
    }

    /// Drops a live connection the way a network loss would, so reconnect
    /// handling can be exercised without a server.
    public func simulateConnectionLoss(_ error: RemoteSessionError = .networkUnreachable) {
        guard machine.transition(to: .failed) != nil else { return }
        emit(.error(error))
        emit(.stateChanged(machine.state, generation: machine.generation))
    }

    /// The server ending the session on purpose: a takeover, a sign-out.
    public func simulateServerEnded(_ reason: RemoteEndReason) {
        guard machine.transition(to: .disconnecting) != nil else { return }
        emit(.endedByServer(reason))
        emit(.stateChanged(machine.state, generation: machine.generation))
        machine.transition(to: .disconnected)
        emit(.stateChanged(machine.state, generation: machine.generation))
    }

    public func offerClipboardText(_ text: String) async throws {
        guard machine.state == .connected, configuration.clipboardPolicy.allowsSend else {
            throw ClipboardTransferError.unavailable
        }
        offeredTexts.append(text)
        remoteClipboard = text
    }

    public func fetchRemoteClipboardText() async throws -> String {
        guard machine.state == .connected, configuration.clipboardPolicy.allowsReceive else {
            throw ClipboardTransferError.unavailable
        }
        guard let remoteClipboard else { throw ClipboardTransferError.nothingToCopy }
        return remoteClipboard
    }

    private func finishConnecting() {
        machine.transition(to: .connected)
        emit(.stateChanged(machine.state, generation: machine.generation))
    }

    private func raise(_ challenge: SessionChallenge) {
        pendingChallenge = challenge
        machine.transition(to: .awaitingUser)
        emit(.stateChanged(machine.state, generation: machine.generation))
        emit(.userActionRequired(challenge))
    }

    private func emit(_ event: SessionControlEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
