import Foundation
import OSLog
import AppleAdapters
import SSHProtocol
import SessionCore

let sshLog = Logger(subsystem: "com.mikuta0407.mRemote", category: "ssh")

/// Keystrokes and pastes on their way to the bridge. Retargeted to each
/// attempt's shell; refuses while it has none.
final class SSHTerminalInput: TerminalInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (native: SSHNativeSession, channel: UInt32)?

    func attach(_ native: SSHNativeSession?, channel: UInt32 = 0) {
        lock.withLock { target = native.map { ($0, channel) } }
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard let target = lock.withLock({ target }) else { return false }
        return target.native.write(target.channel, bytes)
    }
}

/// One SSH connection with its shells - the first one, and those opened for
/// tabs and panes - behind `TerminalSession` (docs/ssh-design.md sections 6.2
/// and 16).
///
/// Like `RDPRemoteSession`, the actor is the control plane only: output goes
/// from the bridge's callback into `terminalOutput`, and keystrokes from the
/// view into `terminalInput`, without passing through here. And like it, the
/// session is authoritative for its state and pending challenge.
actor SSHRemoteSession: TerminalSession {
    nonisolated let id: SessionID
    nonisolated let profileID: ProfileID?
    nonisolated let primaryTerminal: TerminalChannel
    private nonisolated let input = SSHTerminalInput()

    /// A terminal and this attempt's shell behind it.
    private final class Terminal {
        let channel: TerminalChannel
        let input: SSHTerminalInput
        var size: TerminalSize
        /// The bridge's channel in this attempt; nil until it is open, and
        /// once it ends.
        var native: UInt32?
        init(channel: TerminalChannel, input: SSHTerminalInput, size: TerminalSize) {
            self.channel = channel
            self.input = input
            self.size = size
        }
    }
    /// Every terminal still wanted, the primary first: what a reconnect
    /// opens again.
    private var terminals: [Terminal] = []
    /// Commands waiting for their channel to end.
    private var commands: [UInt32: (output: SSHCommandOutput, waiter: CheckedContinuation<TerminalCommandResult?, Never>)] = [:]

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
    /// The shell opened on a password, so a password worth keeping.
    private(set) var signedInWithPassword = false
    private var signInExhausted = false
    /// Signed in on this attempt's connection, whether or not a shell is
    /// open yet.
    private var bridgeConnected = false
    /// This attempt looks for tmux before opening the first shell.
    private var detectsTmux = false
    private var terminationCause: Termination?

    /// What the session is for: the user's terminals, or a jump host another
    /// session connects through - signed in, with no shell, until stopped.
    enum Role {
        case terminals
        case jumpHost
    }
    private let role: Role

    /// ProxyJump: the session for the last jump host, itself reached through
    /// any before it. This attempt connects over a stream through it once it
    /// is signed in.
    private var jump: SSHRemoteSession?
    private var jumpEventsTask: Task<Void, Never>?
    /// The challenge on screen is the jump host's, answered there.
    private var jumpChallengeID: ChallengeID?
    /// How the jump host failed, as it said.
    private var jumpError: RemoteSessionError?

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
        keys: any SSHKeyRepository,
        role: Role = .terminals
    ) {
        self.id = id
        self.role = role
        self.profileID = configuration.profileID
        let primary = TerminalChannel(input: input)
        self.primaryTerminal = primary
        self.terminals = [Terminal(channel: primary, input: input, size: .standard)]
        self.configuration = configuration
        self.settings = configuration.ssh ?? EffectiveSSHSettings(authentication: SSHAuthentication(), startupCommand: nil)
        self.credentials = credentials
        self.knownHosts = knownHosts
        self.keys = keys
    }

    deinit {
        native?.requestStop()
        pumpTask?.cancel()
        jumpEventsTask?.cancel()
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
        for terminal in terminals { terminal.input.attach(nil) }
        if machine.transition(to: .disconnecting) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        }
        await stopJump()
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

        // The jump host's: answered there, where its connection waits.
        if let jump, jumpChallengeID == challengeID {
            jumpChallengeID = nil
            if case .cancel = response {
                terminationCause = .failed(.userCancelled)
                emit(.error(.userCancelled))
                await disconnect(reason: .userRequested)
                return
            }
            resumeAttempt()
            try await jump.respond(to: challengeID, with: response)
            return
        }

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
            lastSignInMethod = .password
            planner?.passwordTyped()
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

        case let (.tmuxSession, nil, .tmux(choice)):
            resumeAttempt()
            openFirstShell(command: TmuxCommands.command(for: choice) ?? settings.startupCommand)

        default:
            throw StaleChallengeError(challengeID: challengeID)
        }
    }

    /// A password typed before the connection existed, used once.
    private var typedPassword: String?
    /// What the last sign-in answer used; the one the server accepted once
    /// the shell opens.
    private var lastSignInMethod: SSHSignInMethods?

    func setVisibility(_ visibility: SessionVisibility) {
        // The shell keeps running and its output keeps being drained off
        // screen: the terminal's state is the sum of all of it.
    }

    // MARK: - TerminalSession

    func resizeTerminal(_ id: TerminalID, to size: TerminalSize) async {
        guard let terminal = terminals.first(where: { $0.channel.id == id }), size != terminal.size else { return }
        terminal.size = size
        if let channel = terminal.native, machine.state == .connected { native?.resize(channel, size) }
    }

    func openTerminal(size: TerminalSize) async -> TerminalChannel? {
        guard machine.state == .connected, let native else { return nil }
        let input = SSHTerminalInput()
        let terminal = Terminal(channel: TerminalChannel(input: input), input: input, size: size)
        guard openShell(for: terminal, on: native) else { return nil }
        terminals.append(terminal)
        return terminal.channel
    }

    func closeTerminal(_ id: TerminalID) async {
        guard let index = terminals.firstIndex(where: { $0.channel.id == id }) else { return }
        let terminal = terminals.remove(at: index)
        terminal.input.attach(nil)
        if let channel = terminal.native {
            terminal.native = nil
            native?.close(channel)
        }
        // The last one ends the session: the bridge reports it closed.
    }

    func runCommand(_ command: String) async -> TerminalCommandResult? {
        guard bridgeConnected, let native else { return nil }
        let output = SSHCommandOutput()
        guard let channel = native.openCommand(command, output: output) else { return nil }
        return await withCheckedContinuation { waiter in
            commands[channel] = (output, waiter)
        }
    }

    /// Opens a terminal's shell on this attempt's connection.
    @discardableResult
    private func openShell(for terminal: Terminal, on native: SSHNativeSession) -> Bool {
        terminal.channel.output.reset()
        guard let channel = native.openShell(size: terminal.size, output: terminal.channel.output) else {
            return false
        }
        terminal.native = channel
        terminal.input.attach(native, channel: channel)
        return true
    }

    // MARK: - Attempts

    private func beginAttempt() async {
        if native != nil {
            native?.requestStop()
            await withCheckedContinuation { workerFinished.append($0) }
        }
        await stopJump()
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
        jumpError = nil
        // A reconnect opens every terminal again: the first one as the
        // session's first shell, the rest once it is up.
        if terminals.isEmpty { terminals = [Terminal(channel: primaryTerminal, input: input, size: .standard)] }
        for terminal in terminals {
            terminal.native = nil
            terminal.input.attach(nil)
            terminal.channel.output.reset()
        }
        bridgeConnected = false
        if let hop = configuration.lastJumpHost {
            // The jump host first; this connection goes over a stream through
            // it once it is signed in (jumpEvent).
            await startJump(hop)
            return
        }
        startNative(username: username, transport: nil)
    }

    /// This attempt's connection: to the host, or over `transport` through a
    /// jump host.
    private func startNative(username: String, transport: Int32?) {
        let first = terminals[0]
        let session = SSHNativeSession(label: "com.mikuta0407.mRemote.ssh.\(machine.generation.rawValue)")
        // Looking for tmux first: no shell until it is known which to open.
        // A jump host opens none at all.
        detectsTmux = role == .terminals && settings.tmux.attach != .off
        if role == .terminals && !detectsTmux {
            session.route(0, to: first.channel.output)
            first.native = 0
        }
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
            size: first.size,
            keepAliveSeconds: settings.keepAliveSeconds,
            forwards: role == .terminals ? Array(settings.portForwards.prefix(Int(MR_SSH_MAX_FORWARDS))) : [],
            proxy: configuration.proxy.map { ($0.host, $0.port) },
            deferShell: detectsTmux || role == .jumpHost,
            transport: transport
        ))
    }

    // MARK: - ProxyJump

    private var jumpName: String {
        configuration.lastJumpHost?.displayName ?? ""
    }

    private func startJump(_ hop: EffectiveConnectionConfiguration) async {
        let session = SSHRemoteSession(
            configuration: hop, credentials: credentials, knownHosts: knownHosts, keys: keys, role: .jumpHost)
        jump = session
        let events = await session.controlEvents()
        jumpEventsTask = Task { [weak self] in
            for await event in events {
                await self?.jumpEvent(event, from: session)
            }
        }
        sshLog.info("connecting through a jump host g=\(self.machine.generation.rawValue, privacy: .public)")
        Task { try? await session.connect() }
    }

    /// Opens a stream through this session, signed in as a jump host, to
    /// the host behind it.
    func openStream(host: String, port: UInt16) -> Int32? {
        guard role == .jumpHost, bridgeConnected else { return nil }
        return native?.openStream(host: host, port: port)
    }

    private func jumpEvent(_ event: SessionControlEvent, from session: SSHRemoteSession) async {
        guard session === jump else { return }
        switch event {
        case .userActionRequired(let challenge):
            // Its host key, sign-in or prompts: on screen as this session's,
            // answered there (respond).
            jumpChallengeID = challenge.id
            raise(challenge)
        case .error(let error):
            jumpError = error
        case .stateChanged(.connected, _):
            guard native == nil, machine.state == .connecting || machine.state == .awaitingUser else { return }
            let username = (typedUsername ?? configuration.account.username ?? "").trimmingCharacters(in: .whitespaces)
            guard let stream = await session.openStream(host: configuration.endpoint.host, port: configuration.endpoint.port),
                  native == nil, session === jump else {
                jumpFailed(.jumpHost(name: jumpName, error: nil))
                return
            }
            startNative(username: username, transport: stream)
        case .stateChanged(.failed, _), .stateChanged(.disconnected, _):
            // Before this connection is up, the attempt ends with the jump
            // host's reason; after, this connection drops by itself.
            guard native == nil else { return }
            jumpFailed(.jumpHost(name: jumpName, error: jumpError ?? .networkUnreachable))
        default:
            break
        }
    }

    private func jumpFailed(_ error: RemoteSessionError) {
        if jumpChallengeID != nil {
            jumpChallengeID = nil
            pendingChallenge = nil
        }
        if case .jumpHost(_, .userCancelled?) = error {
            terminationCause = .failed(.userCancelled)
        } else {
            terminationCause = .failed(error)
        }
        finishAttempt()
    }

    private func stopJump() async {
        jumpEventsTask?.cancel()
        jumpEventsTask = nil
        jumpChallengeID = nil
        guard let jump else { return }
        self.jump = nil
        await jump.disconnect(reason: .userRequested)
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
        let passwordIsTyped = password != nil
        typedPassword = nil
        if password == nil, let reference = configuration.account.credentialReference {
            password = try? credentials.password(for: reference)
        }
        return SSHSignInPlanner(
            authentication: settings.authentication,
            hasKey: !privateKey.isEmpty,
            keyIsEncrypted: encrypted,
            storedPassphrase: passphrase,
            storedPassword: password,
            storedPasswordIsTyped: passwordIsTyped)
    }

    private func apply(_ event: SSHNativeEvent) async {
        switch event {
        case let .state(state, failure, detail):
            applyState(state, failure: failure, detail: detail)

        case let .hostKey(id, keyType, blob):
            let fingerprint = HostKeyFingerprint.sha256(of: blob)
            let host = configuration.endpoint.host
            let port = configuration.endpoint.port
            let decision: KnownHostDecision
            do {
                decision = try knownHosts.decision(host: host, port: port, fingerprint: fingerprint)
            } catch {
                // Unreadable is not unknown: a changed key would be offered
                // as a first connection and overwritten. Refuse instead.
                sshLog.error("could not read the known host: \(String(describing: error), privacy: .public)")
                terminationCause = .failed(.internalFailure(
                    detail: String(localized: "保存済みのホスト鍵を読めませんでした（\(String(describing: error))）")))
                native?.answerHostKey(id, accept: false)
                return
            }
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

        case let .channel(channel, state, detail):
            applyChannel(channel, state: state, detail: detail)

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
            lastSignInMethod = .publicKey
            native?.answerSignIn(
                challengeID, method: SSHSignInMethods.publicKey.rawValue,
                secret: privateKey, passphrase: passphrase.map { Array($0.utf8) } ?? [])
        case .askPassphrase(let previousWasRejected):
            bridgeWait = .signIn(id: challengeID, offered: offered)
            let name = settings.authentication.keyID.flatMap { try? keys.metadata(for: $0) }?.name ?? ""
            raise(.keyPassphrase(KeyPassphraseChallenge(
                generation: machine.generation, keyName: name, previousWasRejected: previousWasRejected)))
        case .keyboardInteractive:
            lastSignInMethod = .keyboardInteractive
            native?.answerSignIn(challengeID, method: SSHSignInMethods.keyboardInteractive.rawValue)
        case .password(let password):
            lastSignInMethod = .password
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
            bridgeConnected = true
            if role == .jumpHost {
                // Signed in: ready to carry the next hop's stream.
                if machine.state == .awaitingUser { resumeAttempt() }
                if machine.transition(to: .connected) != nil {
                    emit(.stateChanged(machine.state, generation: machine.generation))
                }
                return
            }
            if detectsTmux {
                Task { await chooseTmuxSession() }
                return
            }
            if let native, let first = terminals.first, first.native == 0 {
                first.input.attach(native, channel: 0)
                if let command = settings.startupCommand {
                    _ = native.write(0, Array((command + "\r").utf8))
                }
                // Tabs and panes from before a reconnect.
                for terminal in terminals.dropFirst() { openShell(for: terminal, on: native) }
            }
            if machine.state == .awaitingUser { resumeAttempt() }
            if machine.transition(to: .connected) != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
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
            // A host key refused because the store could not be read keeps
            // that reason rather than reading as the user's rejection.
            if bridgeFailure == .hostKeyRejected, case .failed = terminationCause { break }
            // Through a jump host, a stream that ends before the handshake
            // did is the jump host not reaching this one.
            if jump != nil, !bridgeConnected, bridgeFailure == .disconnected || bridgeFailure == .protocol {
                terminationCause = .failed(.jumpHost(name: jumpName, error: nil))
                break
            }
            terminationCause = .failed(bridgeFailure.sessionError(detail: detail) ?? .internalFailure(detail: "ssh"))
        default:
            break
        }
    }

    // MARK: - tmux (docs/ssh-design.md section 16.4)

    /// Signed in with no shell yet: what tmux has decides what the first
    /// shell runs.
    private func chooseTmuxSession() async {
        let listing = await runCommand(TmuxCommands.listSessions)
        guard bridgeConnected else { return }
        let sessions = listing?.exitStatus == 0 ? TmuxCommands.parseSessions(listing?.output ?? "") : []
        let hasTmux = listing != nil && listing?.exitStatus != 127
        sshLog.info("tmux: \(hasTmux ? "found" : "none", privacy: .public), \(sessions.count, privacy: .public) session(s)")
        switch settings.tmux.attach {
        case .automatic where hasTmux:
            let name = settings.tmux.effectiveSessionName
            openFirstShell(command: TmuxCommands.command(for: .new(name, controlMode: settings.tmux.controlMode)))
        case .ask where !sessions.isEmpty:
            raise(.tmuxSession(TmuxSessionChallenge(
                generation: machine.generation, host: configuration.endpoint.host,
                sessions: sessions, prefersControlMode: settings.tmux.controlMode)))
        default:
            openFirstShell(command: settings.startupCommand)
        }
    }

    /// The first terminal's shell, then the others' after a reconnect; then
    /// the session is up. `command` is typed into the first.
    private func openFirstShell(command: String?) {
        guard let native, let first = terminals.first else { return }
        guard openShell(for: first, on: native), let channel = first.native else {
            terminationCause = .failed(.internalFailure(detail: String(localized: "シェルを開けませんでした")))
            native.requestStop()
            return
        }
        if let command { _ = native.write(channel, Array((command + "\r").utf8)) }
        for terminal in terminals.dropFirst() { openShell(for: terminal, on: native) }
        if machine.state == .awaitingUser { resumeAttempt() }
        if machine.transition(to: .connected) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        }
    }

    private func applyChannel(_ channel: UInt32, state: mr_ssh_channel_state, detail: Int32) {
        guard state != mr_ssh_channel_state(MR_SSH_CHANNEL_OPEN) else { return }
        if let command = commands.removeValue(forKey: channel) {
            let ok = state == mr_ssh_channel_state(MR_SSH_CHANNEL_CLOSED)
            command.waiter.resume(returning: ok
                ? TerminalCommandResult(output: command.output.text, exitStatus: detail >= 0 ? detail : nil)
                : nil)
            return
        }
        guard let index = terminals.firstIndex(where: { $0.native == channel }) else { return }
        let terminal = terminals.remove(at: index)
        terminal.native = nil
        terminal.input.attach(nil)
        // The last shell ends the session, which says so itself.
        guard terminals.contains(where: { $0.native != nil }) else {
            terminals.insert(terminal, at: index)
            return
        }
        emit(.terminalEnded(terminal.channel.id, exitStatus: detail >= 0 ? detail : nil))
    }

    private func saveSecretsAfterSignIn() {
        // Only a passphrase the key actually signed in with: one typed wrong
        // before falling back to a password must not be kept.
        if lastSignInMethod == .publicKey, let passphrase = passphraseToSave,
           let keyID = settings.authentication.keyID {
            try? keys.storePassphrase(passphrase, for: keyID)
        }
        signedInWithPassword = lastSignInMethod == .password
        if signedInWithPassword, let password = passwordToSave,
           let reference = configuration.account.credentialReference {
            try? credentials.store(password: password, for: reference)
        }
        passphraseToSave = nil
        passwordToSave = nil
    }

    /// The worker has returned and the handle is destroyed: the only place
    /// that publishes how the attempt ended.
    private func finishAttempt() {
        native = nil
        bridgeConnected = false
        // The jump host has nothing left to carry.
        if let jump {
            self.jump = nil
            jumpEventsTask?.cancel()
            jumpEventsTask = nil
            Task { await jump.disconnect(reason: .userRequested) }
        }
        for terminal in terminals {
            terminal.native = nil
            terminal.input.attach(nil)
        }
        for command in commands.values { command.waiter.resume(returning: nil) }
        commands.removeAll()
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
