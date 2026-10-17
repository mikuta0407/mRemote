import Foundation
import OSLog
import AppleAdapters
import SSHProtocol
import SessionCore

private let sshLog = Logger(subsystem: "com.mikuta0407.mRemote", category: "ssh")

/// Keystrokes and pastes on their way to the bridge. Retargeted to each
/// attempt's native session; refuses while not connected.
final class SSHTerminalInput: TerminalInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var native: SSHNativeSession?

    func attach(_ native: SSHNativeSession?) {
        lock.withLock { self.native = native }
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard let native = lock.withLock({ native }) else { return false }
        return native.write(bytes)
    }
}

/// One SSH connection with one shell, behind `TerminalSession`
/// (docs/ssh-design.md section 6.2).
///
/// Like `RDPRemoteSession`, the actor is the control plane only: output goes
/// from the bridge's callback into `terminalOutput`, and keystrokes from the
/// view into `terminalInput`, without passing through here. And like it, the
/// session is authoritative for its state and pending challenge.
actor SSHRemoteSession: TerminalSession {
    nonisolated let id: SessionID
    nonisolated let profileID: ProfileID?
    nonisolated let terminalOutput = TerminalOutputBuffer()
    nonisolated var terminalInput: any TerminalInputSink { input }
    private nonisolated let input = SSHTerminalInput()

    private let configuration: EffectiveConnectionConfiguration
    private let settings: EffectiveSSHSettings
    private let credentials: any CredentialRepository
    private let knownHosts: any KnownHostRepository
    private let keys: any SSHKeyRepository

    private var machine = SessionStateMachine()
    private var continuations: [UUID: AsyncStream<SessionControlEvent>.Continuation] = [:]
    private(set) var pendingChallenge: SessionChallenge?

    /// What the bridge is waiting on behind `pendingChallenge`.
    private enum BridgeWait {
        case hostKey(id: UInt64, keyType: String, fingerprint: String)
        case signIn(id: UInt64, offered: SSHSignInMethods)
        case keyboardInteractive(id: UInt64)
    }
    private var bridgeWait: BridgeWait?

    private var native: SSHNativeSession?
    private var pumpTask: Task<Void, Never>?
    private var workerFinished: [CheckedContinuation<Void, Never>] = []
    private var planner: SSHSignInPlanner?
    private var privateKey: [UInt8] = []
    /// The username, when the profile has none and the user typed one.
    private var typedUsername: String?
    /// Kept until the sign-in succeeds, then stored: a wrong passphrase or
    /// password must not end up in the Keychain.
    private var passphraseToSave: String?
    private var passwordToSave: String?
    private var signInExhausted = false
    private var terminationCause: Termination?
    private var size = TerminalSize.standard

    private enum Termination {
        case failed(RemoteSessionError)
        case shellExited(Int32?)
        case stopped
    }

    init(
        id: SessionID = SessionID(),
        configuration: EffectiveConnectionConfiguration,
        credentials: any CredentialRepository,
        knownHosts: any KnownHostRepository,
        keys: any SSHKeyRepository
    ) {
        self.id = id
        self.profileID = configuration.profileID
        self.configuration = configuration
        self.settings = configuration.ssh ?? EffectiveSSHSettings(authentication: SSHAuthentication(), startupCommand: nil)
        self.credentials = credentials
        self.knownHosts = knownHosts
        self.keys = keys
    }

    deinit {
        native?.requestStop()
        pumpTask?.cancel()
    }

    // MARK: - RemoteSession

    var state: SessionState { machine.state }
    var generation: SessionGeneration { machine.generation }

    func controlEvents() -> AsyncStream<SessionControlEvent> {
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

    func connect() async throws {
        guard machine.transition(to: .connecting) != nil else { return }
        emit(.stateChanged(machine.state, generation: machine.generation))
        await beginAttempt()
    }

    func disconnect(reason: DisconnectReason) async {
        guard machine.state != .disconnected, machine.state != .idle else { return }
        cancelBridgeWait()
        pendingChallenge = nil
        if case .failed(let error) = reason { terminationCause = .failed(error) }
        input.attach(nil)
        if machine.transition(to: .disconnecting) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        }
        guard let native else {
            finishTeardown()
            return
        }
        native.requestStop()
        await withCheckedContinuation { workerFinished.append($0) }
    }

    func respond(to challengeID: ChallengeID, with response: ChallengeResponse) async throws {
        guard let pending = pendingChallenge, pending.id == challengeID else {
            throw StaleChallengeError(challengeID: challengeID)
        }
        pendingChallenge = nil
        let wait = bridgeWait
        bridgeWait = nil

        if case .cancel = response {
            if let wait { cancel(wait) }
            terminationCause = .failed(.userCancelled)
            emit(.error(.userCancelled))
            await disconnect(reason: .userRequested)
            return
        }

        switch (pending, wait, response) {
        case let (.hostKey(challenge), .hostKey(id, keyType, fingerprint), .trustOnce),
             let (.hostKey(challenge), .hostKey(id, keyType, fingerprint), .trustPersistently):
            if response == .trustPersistently {
                do {
                    try knownHosts.store(KnownHost(
                        host: challenge.host, port: challenge.port, keyType: keyType, fingerprint: fingerprint))
                } catch {
                    sshLog.error("could not store the host key: \(String(describing: error), privacy: .public)")
                }
            }
            native?.answerHostKey(id, accept: true)
            resumeAttempt()

        case let (.keyPassphrase, .signIn(id, offered), .passphrase(passphrase, save)):
            passphraseToSave = save ? passphrase : nil
            guard var planner else { return }
            let step = planner.passphraseProvided(passphrase)
            self.planner = planner
            resumeAttempt()
            perform(step, challengeID: id, offered: offered)

        case let (.credential, .signIn(id, offered), .credential(_, _, password, save)):
            passwordToSave = save && !password.isEmpty ? password : nil
            resumeAttempt()
            native?.answerSignIn(id, method: SSHSignInMethods.password.rawValue, secret: Array(password.utf8))
            _ = offered

        case let (.credential, nil, .credential(username, _, password, save)):
            // Asked before connecting: the profile has no user name.
            typedUsername = username
            passwordToSave = save && !password.isEmpty ? password : nil
            if !password.isEmpty { typedPassword = password }
            resumeAttempt()
            await beginAttempt()

        case let (.keyboardInteractive, .keyboardInteractive(id), .keyboardInteractive(answers)):
            resumeAttempt()
            native?.answerKeyboardInteractive(id, answers: answers)

        default:
            throw StaleChallengeError(challengeID: challengeID)
        }
    }

    /// A password typed before the connection existed, used once.
    private var typedPassword: String?

    func setVisibility(_ visibility: SessionVisibility) {
        // The shell keeps running and its output keeps being drained off
        // screen: the terminal's state is the sum of all of it.
    }

    // MARK: - TerminalSession

    func resizeTerminal(_ size: TerminalSize) async {
        guard size != self.size else { return }
        self.size = size
        if machine.state == .connected { native?.resize(size) }
    }

    // MARK: - Attempts

    private func beginAttempt() async {
        if native != nil {
            native?.requestStop()
            await withCheckedContinuation { workerFinished.append($0) }
        }
        guard machine.state == .connecting else { return }

        let username = (typedUsername ?? configuration.account.username ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else {
            raise(.credential(CredentialChallenge(
                generation: machine.generation,
                host: configuration.endpoint.host,
                username: nil,
                domain: nil
            )))
            return
        }

        planner = makePlanner()
        signInExhausted = false
        terminationCause = nil
        terminalOutput.reset()

        let session = SSHNativeSession(label: "com.mikuta0407.mRemote.ssh.\(machine.generation.rawValue)", output: terminalOutput)
        native = session
        let events = session.events
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
        sshLog.info("connecting g=\(self.machine.generation.rawValue, privacy: .public)")
        session.start(SSHNativeConnection(
            host: configuration.endpoint.host,
            port: configuration.endpoint.port,
            username: username,
            terminalType: settings.terminalType,
            size: size,
            keepAliveSeconds: settings.keepAliveSeconds,
            forwards: Array(settings.portForwards.prefix(Int(MR_SSH_MAX_FORWARDS)))
        ))
    }

    private func makePlanner() -> SSHSignInPlanner {
        privateKey = []
        var encrypted = false
        var passphrase: String?
        if let keyID = settings.authentication.keyID,
           let data = try? keys.privateKey(for: keyID) {
            privateKey = Array(data)
            encrypted = (try? keys.metadata(for: keyID))??.isEncrypted ?? false
            passphrase = try? keys.passphrase(for: keyID)
        }
        var password = typedPassword
        typedPassword = nil
        if password == nil, let reference = configuration.account.credentialReference {
            password = try? credentials.password(for: reference)
        }
        return SSHSignInPlanner(
            authentication: settings.authentication,
            hasKey: !privateKey.isEmpty,
            keyIsEncrypted: encrypted,
            storedPassphrase: passphrase,
            storedPassword: password)
    }

    private func apply(_ event: SSHNativeEvent) async {
        switch event {
        case let .state(state, failure, detail):
            applyState(state, failure: failure, detail: detail)

        case let .hostKey(id, keyType, blob):
            let fingerprint = HostKeyFingerprint.sha256(of: blob)
            let host = configuration.endpoint.host
            let port = configuration.endpoint.port
            let decision = (try? knownHosts.decision(host: host, port: port, fingerprint: fingerprint)) ?? .unknown
            switch decision {
            case .matches:
                native?.answerHostKey(id, accept: true)
            case .unknown, .changed:
                var disposition = HostKeyDisposition.unknown
                if case .changed(let previous) = decision {
                    disposition = .changed(previousKeyType: previous.keyType, previousFingerprint: previous.fingerprint)
                    sshLog.error("host key changed for an endpoint")
                }
                bridgeWait = .hostKey(id: id, keyType: keyType, fingerprint: fingerprint)
                raise(.hostKey(HostKeyChallenge(
                    generation: machine.generation, host: host, port: port,
                    keyType: keyType, fingerprint: fingerprint, disposition: disposition)))
            }

        case let .signIn(id, offeredRaw, _, rejectedRaw):
            guard var planner else { return }
            let offered = SSHSignInMethods(rawValue: offeredRaw)
            let step = planner.next(offered: offered, rejected: SSHSignInMethods(rawValue: rejectedRaw))
            self.planner = planner
            perform(step, challengeID: id, offered: offered)

        case let .keyboardInteractive(id, name, instruction, prompts):
            bridgeWait = .keyboardInteractive(id: id)
            raise(.keyboardInteractive(KeyboardInteractiveChallenge(
                generation: machine.generation, host: configuration.endpoint.host,
                name: name, instruction: instruction, prompts: prompts)))

        case let .forward(index, error):
            guard error != 0, index < settings.portForwards.count else { return }
            sshLog.error("port forward \(index, privacy: .public) could not listen: \(error, privacy: .public)")
            emit(.portForwardFailed(localPort: settings.portForwards[index].localPort, error: error))

        case .finished:
            finishAttempt()
        }
    }

    private func perform(_ step: SSHSignInPlanner.Step, challengeID: UInt64, offered: SSHSignInMethods) {
        switch step {
        case .publicKey(let passphrase):
            native?.answerSignIn(
                challengeID, method: SSHSignInMethods.publicKey.rawValue,
                secret: privateKey, passphrase: passphrase.map { Array($0.utf8) } ?? [])
        case .askPassphrase(let previousWasRejected):
            bridgeWait = .signIn(id: challengeID, offered: offered)
            let name = settings.authentication.keyID.flatMap { try? keys.metadata(for: $0) }?.name ?? ""
            raise(.keyPassphrase(KeyPassphraseChallenge(
                generation: machine.generation, keyName: name, previousWasRejected: previousWasRejected)))
        case .keyboardInteractive:
            native?.answerSignIn(challengeID, method: SSHSignInMethods.keyboardInteractive.rawValue)
        case .password(let password):
            native?.answerSignIn(challengeID, method: SSHSignInMethods.password.rawValue, secret: Array(password.utf8))
        case .askPassword(let storedWasRejected):
            bridgeWait = .signIn(id: challengeID, offered: offered)
            raise(.credential(CredentialChallenge(
                generation: machine.generation,
                host: configuration.endpoint.host,
                username: typedUsername ?? configuration.account.username,
                domain: nil,
                storedCredentialWasRejected: storedWasRejected)))
        case .giveUp:
            signInExhausted = true
            native?.answerSignIn(challengeID, method: 0)
        }
    }

    private func applyState(_ state: mr_ssh_state, failure: UInt32, detail: Int32) {
        switch Int32(bitPattern: state) {
        case Int32(MR_SSH_STATE_CONNECTED):
            privateKey.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
            privateKey = []
            saveSecretsAfterSignIn()
            input.attach(native)
            if machine.state == .awaitingUser { resumeAttempt() }
            if machine.transition(to: .connected) != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
            if size != .standard { native?.resize(size) }
            if let command = settings.startupCommand {
                _ = native?.write(Array((command + "\r").utf8))
            }
        case Int32(MR_SSH_STATE_CLOSED):
            let bridgeFailure = SSHBridgeFailure(rawValue: failure) ?? .internal
            if bridgeFailure == .cancelled {
                terminationCause = signInExhausted ? .failed(.authenticationFailed) : (terminationCause ?? .stopped)
            } else {
                terminationCause = .shellExited(detail >= 0 ? detail : nil)
            }
        case Int32(MR_SSH_STATE_FAILED):
            let bridgeFailure = SSHBridgeFailure(rawValue: failure) ?? .internal
            sshLog.error("ssh failed: \(failure, privacy: .public) detail \(detail, privacy: .public)")
            terminationCause = .failed(bridgeFailure.sessionError(detail: detail) ?? .internalFailure(detail: "ssh"))
        default:
            break
        }
    }

    private func saveSecretsAfterSignIn() {
        if let passphrase = passphraseToSave, let keyID = settings.authentication.keyID {
            try? keys.storePassphrase(passphrase, for: keyID)
        }
        if let password = passwordToSave, let reference = configuration.account.credentialReference {
            try? credentials.store(password: password, for: reference)
        }
        passphraseToSave = nil
        passwordToSave = nil
    }

    /// The worker has returned and the handle is destroyed: the only place
    /// that publishes how the attempt ended.
    private func finishAttempt() {
        native = nil
        input.attach(nil)
        pumpTask = nil
        pendingChallenge = nil
        bridgeWait = nil
        privateKey = []

        switch terminationCause {
        case .failed(let error) where machine.state != .disconnecting:
            if machine.state == .awaitingUser { resumeAttempt() }
            if machine.state != .failed, machine.transition(to: .failed) != nil {
                emit(.error(error))
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
            resumeWorkerWaiters()
        case .shellExited(let status) where machine.state != .disconnecting:
            emit(.endedByServer(.shellExited(status: status)))
            if machine.transition(to: .disconnecting) != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
            finishTeardown()
        case .stopped where machine.state != .disconnecting, nil where machine.state != .disconnecting:
            if machine.transition(to: .disconnecting) != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
            finishTeardown()
        default:
            finishTeardown()
        }
    }

    private func finishTeardown() {
        if machine.state == .disconnecting {
            machine.transition(to: .disconnected)
            emit(.stateChanged(machine.state, generation: machine.generation))
        }
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        resumeWorkerWaiters()
    }

    private func resumeWorkerWaiters() {
        let waiters = workerFinished
        workerFinished.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func cancelBridgeWait() {
        if let bridgeWait { cancel(bridgeWait) }
        bridgeWait = nil
    }

    private func cancel(_ wait: BridgeWait) {
        switch wait {
        case .hostKey(let id, _, _): native?.answerHostKey(id, accept: false)
        case .signIn(let id, _): native?.answerSignIn(id, method: 0)
        case .keyboardInteractive(let id): native?.cancelChallenge(id)
        }
    }

    /// Back from awaitingUser within the same attempt.
    private func resumeAttempt() {
        if machine.resumeAttempt() != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        } else if machine.state == .failed || machine.state == .idle {
            if machine.transition(to: .connecting) != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
        }
    }

    private func raise(_ challenge: SessionChallenge) {
        pendingChallenge = challenge
        if machine.transition(to: .awaitingUser) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        }
        emit(.userActionRequired(challenge))
    }

    private func emit(_ event: SessionControlEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }
}

/// Registers SSH with the factory registry: the second registration
/// docs/architecture.md planned for, and no call site changes.
struct SSHSessionFactory: RemoteSessionFactory {
    let protocolKind: ProtocolKind = .ssh
    let credentials: any CredentialRepository
    let knownHosts: any KnownHostRepository
    let keys: any SSHKeyRepository

    func makeSession(configuration: EffectiveConnectionConfiguration) async throws -> any RemoteSession {
        SSHRemoteSession(configuration: configuration, credentials: credentials, knownHosts: knownHosts, keys: keys)
    }
}
