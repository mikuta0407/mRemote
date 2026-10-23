import Foundation
import AppleAdapters
import RDPProtocol
import SessionCore

/// One RDP connection, behind the protocol-independent `DesktopSession`.
///
/// The actor is the control plane and nothing else: state, challenges and
/// lifecycle. Frames go from the native callback straight into `frameStore`
/// without touching it, because routing a framebuffer through an actor would
/// serialise the renderer behind every state change.
///
/// Two invariants are worth stating because most of the code exists to keep
/// them. First, this object never holds the C handle: `RDPNativeCallGate`
/// does, and it is the only thing allowed to hand it to the bridge. Second,
/// the session is authoritative for its own state and pending challenge -
/// docs/architecture.md requires the event stream to be a "read me again"
/// signal rather than a log a consumer rebuilds state from.
actor RDPRemoteSession: DesktopSession, AudioCapableSession, ClipboardCapableSession, MicrophoneCapableSession,
    MacExtensionCapableSession {
    nonisolated let id: SessionID
    nonisolated let profileID: ProfileID?
    nonisolated let frameStore = LatestDesktopFrameStore()
    nonisolated let cursorStore = RemoteCursorStore()
    nonisolated let audioStream = PCMAudioStream()
    nonisolated var audioSource: any RemoteAudioSource { audioStream }
    nonisolated let inputSink: any DesktopInputSink
    nonisolated var microphoneSink: any MicrophoneSink { microphone }
    private nonisolated let microphone = RDPMicrophoneSink()
    nonisolated let initialDesktopSize: (width: Int, height: Int)
    /// The concrete sink, kept separately so the actor can retarget it without
    /// casting back out of the protocol.
    private nonisolated let pointerSink: RDPInputSink

    private let configuration: EffectiveConnectionConfiguration
    private let credentials: any CredentialRepository
    private let trust: any TrustRepository
    private let logger: RDPSessionLogger

    private var machine = SessionStateMachine()
    private var continuations: [UUID: AsyncStream<SessionControlEvent>.Continuation] = [:]
    private(set) var pendingChallenge: SessionChallenge?
    /// The bridge identity behind `pendingChallenge` when it is a certificate.
    private var pendingCertificate: RDPCertificateReview?

    private var native: RDPNativeSession?
    /// A picked folder in use as a drive; its security scope is held open
    /// until the attempt that shares it ends.
    private var sharedFolderURL: URL?
    private var pumpTask: Task<Void, Never>?
    private var workerFinished: [CheckedContinuation<Void, Never>] = []

    /// Set when the stored password was rejected, so the next attempt asks
    /// instead of replaying a password the server has already refused. An
    /// automatic replay is how an account ends up locked out.
    private var storedCredentialWasRejected = false
    private var suppliedCredential: SuppliedCredential?
    private var terminationCause: RDPTerminationCause?
    private var visibility: SessionVisibility = .focused
    private var negotiatedChannels: Set<RDPBridgeChannel> = []
    private var currentDesktopSize: (width: Int, height: Int)
    private var nextResizeRequestID: UInt64 = 0
    /// The size the workspace last asked for. Kept because the surface lays
    /// out - and asks - while the session is still connecting, when nothing
    /// can be sent yet; it is sent once the session is connected and the
    /// display channel is up, whichever comes last.
    private var desiredDesktopSize: (width: Int, height: Int)?
    /// A second monitor to the right, when the desktop spans two screens.
    private var desiredSecondary: (width: Int, height: Int)?
    /// The server needs the display channel's capabilities before it acts on
    /// a layout, and they arrive just after the channel opens.
    private static let displayChannelSettle = Duration.milliseconds(500)
    /// A layout sent while Windows is still logging the user on is dropped,
    /// and the backend only reports that it was sent, not that it was used.
    /// So the size the frames actually arrive at is checked after a while,
    /// and the request repeated a few times until they match.
    private static let resizeVerifyDelay = Duration.seconds(2)
    private static let maximumResizeAttempts = 4
    private var resizeAttempts = 0
    /// How large the server should draw. Sent at connect and with every
    /// layout; a change on its own is a reason to send one.
    private var displayScale = RemoteDisplayScale.unscaled
    private var displayScaleIsPending = false

    private(set) var remoteHasText = false
    private(set) var remoteHasImage = false
    private(set) var remoteHasFiles = false
    private var pendingImageFetch: (id: UInt64, continuation: CheckedContinuation<RemoteClipboardImage, Error>)?
    private var pendingFilesFetch: (id: UInt64, files: [ClipboardFile], continuation: CheckedContinuation<[ClipboardFile], Error>)?
    private var nextClipboardID: UInt64 = 0
    private var pendingOffers: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var pendingFetch: (id: UInt64, continuation: CheckedContinuation<String, Error>)?
    /// A Mac server's agreement to the Mac extensions, nil until it answers.
    private var macStatus: MacExtensionStatus?
    /// This session's stream quality; starts as the connection's.
    private var streamQuality: StreamQuality
    private var networkObservation: Task<Void, Never>?
    /// Mirrors MR_RDP_CLIPBOARD_REQUEST_TIMEOUT_MS.
    private static let clipboardTimeout = Duration.seconds(10)

    private struct SuppliedCredential: Sendable {
        let username: String
        let domain: String?
        let password: String
    }

    init(
        id: SessionID = SessionID(),
        configuration: EffectiveConnectionConfiguration,
        credentials: any CredentialRepository,
        trust: any TrustRepository,
        desktopSize: (width: Int, height: Int)
    ) {
        let pointerSink = RDPInputSink()
        self.pointerSink = pointerSink
        self.inputSink = pointerSink
        self.id = id
        self.profileID = configuration.profileID
        self.configuration = configuration
        self.credentials = credentials
        self.trust = trust
        self.initialDesktopSize = desktopSize
        self.currentDesktopSize = desktopSize
        self.logger = RDPSessionLogger(sessionID: id, endpoint: configuration.endpoint)
        self.streamQuality = configuration.streamQuality
    }

    deinit {
        // Ownership can be lost without a disconnect - a scene torn down while
        // a connect is in flight, say. `requestStop` is thread-safe and
        // idempotent, and without it the worker would sit in a blocking wait
        // with nothing left to wake it.
        native?.requestStop()
        pumpTask?.cancel()
        networkObservation?.cancel()
    }

    // MARK: - RemoteSession

    var state: SessionState { machine.state }
    var generation: SessionGeneration { machine.generation }
    var currentVisibility: SessionVisibility { visibility }

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
        // Idempotent on every exit path, including one that runs after the
        // session already stopped.
        guard machine.state != .disconnected, machine.state != .idle else { return }
        logger.session("disconnect requested (\(reason))")

        if let pendingCertificate {
            // A worker blocked on a certificate wait has to be woken, or the
            // stop below would have nothing to interrupt.
            native?.cancelCertificate(
                generation: pendingCertificate.bridgeGeneration,
                challengeID: pendingCertificate.bridgeChallengeID
            )
        }
        pendingChallenge = nil
        pendingCertificate = nil

        if case .failed(let error) = reason {
            terminationCause = .failed(error)
        }
        pointerSink.setAccepting(false)
        if machine.transition(to: .disconnecting) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
        }

        guard native != nil else {
            finishTeardown()
            return
        }
        native?.requestStop()
        // Waiting rather than assuming: `disconnected` means the worker joined
        // and the handle was destroyed, and nothing above may see that state
        // while native memory is still being released.
        await withCheckedContinuation { continuation in
            workerFinished.append(continuation)
        }
    }

    func respond(to challengeID: ChallengeID, with response: ChallengeResponse) async throws {
        guard let pending = pendingChallenge, pending.id == challengeID else {
            throw StaleChallengeError(challengeID: challengeID)
        }
        pendingChallenge = nil

        switch response {
        case .cancel:
            terminationCause = .failed(.userCancelled)
            emit(.error(.userCancelled))
            await disconnect(reason: .userRequested)

        case let .credential(username, domain, password, save):
            pendingCertificate = nil
            suppliedCredential = SuppliedCredential(
                username: username,
                domain: domain,
                password: password
            )
            if save, !password.isEmpty, let reference = configuration.account.credentialReference {
                try? credentials.store(password: password, for: reference)
            }
            resumeConnecting()
            await beginAttempt()

        case .trustOnce, .trustPersistently:
            guard let review = pendingCertificate else {
                throw StaleChallengeError(challengeID: challengeID)
            }
            pendingCertificate = nil
            if response == .trustPersistently {
                storeApproval(for: review.challenge)
            }
            native?.respondToCertificate(
                generation: review.bridgeGeneration,
                challengeID: review.bridgeChallengeID,
                decision: mr_rdp_certificate_decision(
                    response == .trustPersistently
                        ? MR_RDP_CERTIFICATE_ACCEPT_PIN
                        : MR_RDP_CERTIFICATE_ACCEPT_USER_ONCE
                )
            )
            logger.certificate(
                "user approved \(Redaction.fingerprint(review.challenge.leafSHA256)) "
                + (response == .trustPersistently ? "persistently" : "once")
            )
            // The attempt that asked carries on, under its own generation:
            // a new one here dropped its `connected` as stale.
            if machine.resumeAttempt() != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
            }

        case .keyboardInteractive, .passphrase:
            // SSH answers; an RDP session never asks these.
            throw StaleChallengeError(challengeID: challengeID)
        }
    }

    func setVisibility(_ visibility: SessionVisibility) {
        // The connection and its channels keep running off screen: SES-02
        // keeps a foreground session alive until the user disconnects. Only
        // presentation degrades, and the frame store already holds at most one
        // surface, so there is nothing to release here in Phase 2.
        self.visibility = visibility
        // docs/architecture.md section 8: only the focused session is
        // audible. The bridge drops the rest before it reaches the app.
        native?.setAudioFocused(visibility == .focused)
    }

    // MARK: - DesktopSession

    var supportsDynamicResolution: Bool { negotiatedChannels.contains(.disp) }

    var desktopSize: (width: Int, height: Int) { currentDesktopSize }

    func requestDesktopSize(width: Int, height: Int) async {
        await requestDesktopLayout(primary: (width, height), secondary: nil)
    }

    func requestDesktopLayout(primary: (width: Int, height: Int), secondary: (width: Int, height: Int)?) async {
        desiredDesktopSize = primary
        desiredSecondary = secondary
        resizeAttempts = 0
        sendDesiredDesktopSize()
    }

    func setDisplayScale(_ scale: RemoteDisplayScale) async {
        guard scale != displayScale else { return }
        displayScale = scale
        displayScaleIsPending = true
        resizeAttempts = 0
        sendDesiredDesktopSize()
    }

    private func sendDesiredDesktopSize() {
        guard machine.state == .connected, supportsDynamicResolution else { return }
        // A scale change alone re-sends the size the desktop already has.
        let current = frameStore.desktopSize ?? currentDesktopSize
        let (width, height) = desiredDesktopSize ?? current
        // The bridge refuses an odd width because FreeRDP 3.31.1 would round
        // it silently and then disagree with us about the surface size.
        let clampedWidth = Self.clampDimension(width, roundToEven: true)
        let clampedHeight = Self.clampDimension(height, roundToEven: false)
        let secondary = desiredSecondary.map {
            (width: Self.clampDimension($0.width, roundToEven: true),
             height: Self.clampDimension($0.height, roundToEven: false))
        }
        // Measured against the frames, not against the last request: the
        // request's echo says only that it was sent. Two monitors make one
        // desktop as wide as both and as tall as the taller.
        let expectedWidth = clampedWidth + (secondary?.width ?? 0)
        let expectedHeight = max(clampedHeight, secondary?.height ?? 0)
        let actual = current
        guard expectedWidth != actual.width || expectedHeight != actual.height
                || displayScaleIsPending else {
            resizeAttempts = 0
            return
        }
        guard resizeAttempts < Self.maximumResizeAttempts else {
            logger.session("disp resize \(clampedWidth)x\(clampedHeight) not adopted; giving up")
            return
        }
        resizeAttempts += 1

        nextResizeRequestID &+= 1
        if nextResizeRequestID == 0 { nextResizeRequestID = 1 }
        let accepted = native?.requestDisplayLayout(
            requestID: nextResizeRequestID,
            primary: (UInt32(clampedWidth), UInt32(clampedHeight)),
            secondary: secondary.map { (UInt32($0.width), UInt32($0.height)) },
            scale: displayScale
        ) ?? false
        // The scale cannot be read back from the frames, so it counts as
        // delivered once the backend has taken the layout.
        if accepted { displayScaleIsPending = false }
        logger.session(
            "disp resize \(clampedWidth)x\(clampedHeight)"
                + (secondary.map { " + \($0.width)x\($0.height)" } ?? "") + " scale=\(displayScale.desktopPercent)% "
                + "accepted=\(accepted) attempt=\(resizeAttempts)"
        )
        Task { [weak self] in
            try? await Task.sleep(for: Self.resizeVerifyDelay)
            await self?.sendDesiredDesktopSize()
        }
    }

    // MARK: - ClipboardCapableSession

    func offerClipboardText(_ text: String) async throws {
        guard configuration.clipboardPolicy.allowsSend else { throw ClipboardTransferError.unavailable }
        guard machine.state == .connected, let native else { throw ClipboardTransferError.unavailable }
        let bytes: Data
        do {
            bytes = try ClipboardTextCodec.encode(text)
        } catch {
            throw ClipboardTransferError.unsupportedContent
        }
        let id = nextClipboardRequestID()
        let status = native.offerClipboardText(offerID: id, utf16le: bytes)
        guard status == .ok else {
            logger.session("clipboard offer refused: \(status.name)")
            throw ClipboardTransferError.unavailable
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingOffers[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.clipboardTimeout)
                await self?.expireOffer(id)
            }
        }
    }

    func fetchRemoteClipboardText() async throws -> String {
        guard configuration.clipboardPolicy.allowsReceive else { throw ClipboardTransferError.unavailable }
        guard machine.state == .connected, let native else { throw ClipboardTransferError.unavailable }
        guard remoteHasText else { throw ClipboardTransferError.nothingToCopy }
        guard pendingFetch == nil else { throw ClipboardTransferError.failed }
        let id = nextClipboardRequestID()
        let status = native.requestClipboardText(requestID: id)
        guard status == .ok else {
            logger.session("clipboard request refused: \(status.name)")
            throw ClipboardTransferError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingFetch = (id, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: Self.clipboardTimeout)
                await self?.expireFetch(id)
            }
        }
    }

    func offerClipboardImage(png: Data?, dib: Data?) async throws {
        guard configuration.clipboardPolicy.allowsSend else { throw ClipboardTransferError.unavailable }
        guard machine.state == .connected, let native else { throw ClipboardTransferError.unavailable }
        let id = nextClipboardRequestID()
        guard native.offerClipboardImage(offerID: id, png: png, dib: dib) == .ok else {
            throw ClipboardTransferError.unsupportedContent
        }
        try await awaitOffer(id)
    }

    func offerClipboardFiles(_ files: [ClipboardFile]) async throws {
        guard configuration.clipboardPolicy.allowsSend else { throw ClipboardTransferError.unavailable }
        guard machine.state == .connected, let native else { throw ClipboardTransferError.unavailable }
        let id = nextClipboardRequestID()
        guard native.offerClipboardFiles(offerID: id, files: files) == .ok else {
            throw ClipboardTransferError.unsupportedContent
        }
        try await awaitOffer(id)
    }

    private func awaitOffer(_ id: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingOffers[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.clipboardTimeout)
                await self?.expireOffer(id)
            }
        }
    }

    func fetchRemoteClipboardImage() async throws -> RemoteClipboardImage {
        guard configuration.clipboardPolicy.allowsReceive else { throw ClipboardTransferError.unavailable }
        guard machine.state == .connected, let native else { throw ClipboardTransferError.unavailable }
        guard remoteHasImage else { throw ClipboardTransferError.nothingToCopy }
        guard pendingFetch == nil, pendingImageFetch == nil, pendingFilesFetch == nil else {
            throw ClipboardTransferError.failed
        }
        let id = nextClipboardRequestID()
        guard native.requestClipboardImage(requestID: id) == .ok else { throw ClipboardTransferError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pendingImageFetch = (id, continuation)
        }
    }

    /// The bridge answers each message within its own timeout, so a large
    /// file is not cut short here.
    func fetchRemoteClipboardFiles() async throws -> [ClipboardFile] {
        guard configuration.clipboardPolicy.allowsReceive else { throw ClipboardTransferError.unavailable }
        guard machine.state == .connected, let native else { throw ClipboardTransferError.unavailable }
        guard remoteHasFiles else { throw ClipboardTransferError.nothingToCopy }
        guard pendingFetch == nil, pendingImageFetch == nil, pendingFilesFetch == nil else {
            throw ClipboardTransferError.failed
        }
        let id = nextClipboardRequestID()
        guard native.requestClipboardFiles(requestID: id) == .ok else { throw ClipboardTransferError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pendingFilesFetch = (id, [], continuation)
        }
    }

    private static func clipboardError(_ status: RDPBridgeStatus) -> ClipboardTransferError {
        switch status {
        case .timeout: return .timedOut
        case .unsupported: return .nothingToCopy
        case .limitExceeded: return .unsupportedContent
        default: return .failed
        }
    }

    private func nextClipboardRequestID() -> UInt64 {
        nextClipboardID &+= 1
        if nextClipboardID == 0 { nextClipboardID = 1 }
        return nextClipboardID
    }

    private func expireOffer(_ id: UInt64) {
        pendingOffers.removeValue(forKey: id)?.resume(throwing: ClipboardTransferError.timedOut)
    }

    private func expireFetch(_ id: UInt64) {
        guard let pending = pendingFetch, pending.id == id else { return }
        pendingFetch = nil
        pending.continuation.resume(throwing: ClipboardTransferError.timedOut)
    }

    /// A connection that ends answers nobody, so every waiter is released.
    private func failClipboardWaiters() {
        for continuation in pendingOffers.values {
            continuation.resume(throwing: ClipboardTransferError.unavailable)
        }
        pendingOffers.removeAll()
        pendingFetch?.continuation.resume(throwing: ClipboardTransferError.unavailable)
        pendingFetch = nil
        pendingImageFetch?.continuation.resume(throwing: ClipboardTransferError.unavailable)
        pendingImageFetch = nil
        pendingFilesFetch?.continuation.resume(throwing: ClipboardTransferError.unavailable)
        pendingFilesFetch = nil
        microphone.setOpen(false)
    }

    /// The profile's choice, as the bridge takes it. Legacy RDP Security is
    /// offered only under `.legacyExplicit`, which the editor sets only
    /// after the user confirmed it for this profile.
    static func securityPolicy(for policy: SecurityPolicy) -> mr_rdp_security_policy {
        switch policy {
        case .secureAutomatic: return mr_rdp_security_policy(MR_RDP_SECURITY_SECURE_AUTOMATIC)
        case .nlaRequired: return mr_rdp_security_policy(MR_RDP_SECURITY_NLA_REQUIRED)
        case .tlsRequired: return mr_rdp_security_policy(MR_RDP_SECURITY_TLS_REQUIRED)
        case .legacyExplicit: return mr_rdp_security_policy(MR_RDP_SECURITY_LEGACY_ALLOWED)
        }
    }

    static func keyboardProfile(for layout: KeyboardLayoutPreference) -> mr_rdp_keyboard_profile {
        switch layout {
        case .japanese: return mr_rdp_keyboard_profile(MR_RDP_KEYBOARD_JAPANESE)
        case .us: return mr_rdp_keyboard_profile(MR_RDP_KEYBOARD_US)
        case .automatic: return mr_rdp_keyboard_profile(MR_RDP_KEYBOARD_AUTOMATIC)
        }
    }

    /// A channel the profile turned off is not loaded at all, rather than
    /// negotiated and then ignored.
    static func channelFlags(for configuration: EffectiveConnectionConfiguration) -> mr_rdp_channel_flags {
        // Touch and pen are always offered: whether a finger is sent as a
        // touch is the user's live choice, and the channel costs nothing
        // until it is used.
        var flags = mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_TOUCH)
        if configuration.audioPlayback {
            flags |= mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_AUDIO)
        }
        if configuration.clipboardPolicy != .disabled {
            flags |= mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_CLIPBOARD)
        }
        if configuration.redirectsMicrophone {
            flags |= mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_MICROPHONE)
        }
        if configuration.prefersH264 {
            flags |= mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_H264)
        }
        if configuration.remotePlatform.offersMacExtensions {
            flags |= mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_MACRDPX)
        }
        return flags
    }

    static func clampDimension(_ value: Int, roundToEven: Bool) -> Int {
        var clamped = min(max(value, 200), 8_192)
        if roundToEven, !clamped.isMultiple(of: 2) { clamped -= 1 }
        return clamped
    }

    // MARK: - Connect

    private func beginAttempt() async {
        // A retry can arrive while the previous worker is still unwinding.
        // Starting a second native session on top of it is exactly the race
        // the teardown order exists to prevent.
        if native != nil {
            native?.requestStop()
            await withCheckedContinuation { workerFinished.append($0) }
        }
        guard machine.state == .connecting else { return }

        guard let credential = resolveCredential() else {
            raise(.credential(CredentialChallenge(
                generation: machine.generation,
                host: configuration.endpoint.host,
                username: configuration.account.username,
                domain: configuration.account.domain,
                storedCredentialWasRejected: storedCredentialWasRejected
            )))
            return
        }

        let session = RDPNativeSession(
            generation: machine.generation.rawValue,
            endpoint: configuration.endpoint,
            trust: trust,
            logger: logger,
            frameStore: frameStore,
            cursorStore: cursorStore,
            audioStream: audioStream
        )
        native = session
        session.setAudioFocused(visibility == .focused)
        pointerSink.attach(session)
        microphone.attach(session)
        terminationCause = nil
        negotiatedChannels = []
        currentDesktopSize = initialDesktopSize

        let events = session.events
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
        logger.session("connecting g=\(machine.generation.rawValue)")
        var connection = RDPNativeConnection(
            host: configuration.endpoint.host,
            port: configuration.endpoint.port,
            username: credential.username,
            domain: credential.domain ?? "",
            password: SecureBytes(credential.password),
            desktopWidth: UInt32(initialDesktopSize.width),
            desktopHeight: UInt32(initialDesktopSize.height),
            keyboardProfile: Self.keyboardProfile(for: configuration.keyboardLayout),
            channelFlags: Self.channelFlags(for: configuration),
            displayScale: displayScale,
            securityPolicy: Self.securityPolicy(for: configuration.securityPolicy)
        )
        if configuration.remotePlatform.offersMacExtensions {
            connection.macrdpxCaps = MacExtensionFeatures.all.rawValue
        }
        macStatus = nil
        connection.gateway = gatewayConnection()
        if let proxy = configuration.proxy {
            connection.proxy = (proxy.host, proxy.port)
        }
        if let remoteApp = configuration.remoteApp, !remoteApp.program.isEmpty {
            connection.remoteApp = (remoteApp.program, remoteApp.arguments)
        }
        if let folder = openSharedFolder() {
            connection.drive = folder
            connection.channelFlags |= mr_rdp_channel_flags(MR_RDP_CHANNEL_FLAG_DRIVE)
        }
        session.start(connection)
        // The connection carries it; nothing is owed until it changes.
        displayScaleIsPending = false
    }

    /// The gateway and how to sign in to it. A gateway account without a
    /// stored password signs in as the computer's user instead, which is
    /// what most gateways expect anyway.
    private func gatewayConnection() -> RDPNativeConnection.Gateway? {
        guard let gateway = configuration.gateway else { return nil }
        var credential: (username: String, domain: String, password: SecureBytes)?
        if !gateway.usesComputerCredentials {
            if let username = gateway.account.username, !username.isEmpty,
               let reference = gateway.account.credentialReference,
               let password = try? credentials.password(for: reference), !password.isEmpty {
                credential = (username, gateway.account.domain ?? "", SecureBytes(password))
            } else {
                logger.session("gateway has no stored password; using the computer's credentials")
            }
        }
        return RDPNativeConnection.Gateway(
            host: gateway.host,
            port: gateway.port,
            bypassesLocal: gateway.bypassesLocalAddresses,
            credential: credential
        )
    }

    /// The shared folder's path, kept open for as long as the session runs:
    /// a picked folder is only reachable while its security scope is.
    private func openSharedFolder() -> (path: String, name: String)? {
        closeSharedFolder()
        guard let folder = configuration.sharedFolder else { return nil }
        let url: URL
        switch folder.location {
        case .appDocuments:
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return nil }
            url = documents
        case .bookmark(let data, _):
            var stale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), resolved.startAccessingSecurityScopedResource() else {
                logger.session("the shared folder could not be opened")
                return nil
            }
            sharedFolderURL = resolved
            url = resolved
        }
        return (url.path, SharedFolder.sanitizedDriveName(folder.driveName))
    }

    private func closeSharedFolder() {
        sharedFolderURL?.stopAccessingSecurityScopedResource()
        sharedFolderURL = nil
    }

    /// The credential this attempt runs with, or nil when the user has to be
    /// asked. The bridge refuses an empty user name or password, so an
    /// incomplete profile becomes a prompt rather than a create failure.
    private func resolveCredential() -> SuppliedCredential? {
        if let suppliedCredential, !suppliedCredential.username.isEmpty,
           !suppliedCredential.password.isEmpty {
            return suppliedCredential
        }
        guard !storedCredentialWasRejected,
              let username = configuration.account.username, !username.isEmpty,
              let reference = configuration.account.credentialReference,
              let password = try? credentials.password(for: reference),
              !password.isEmpty else {
            return nil
        }
        return SuppliedCredential(
            username: username,
            domain: configuration.account.domain,
            password: password
        )
    }

    private func storeApproval(for challenge: CertificateChallenge) {
        let record = TrustRecord(
            host: challenge.host,
            port: challenge.port,
            leafSHA256: challenge.leafSHA256,
            subject: challenge.subject,
            issuer: challenge.issuer,
            notBefore: challenge.notBefore,
            notAfter: challenge.notAfter,
            hostnameUnverified: challenge.disposition == .hostnameUnverifiable
        )
        do {
            try trust.store(record)
        } catch {
            // The connection still proceeds on the user's approval; only the
            // convenience of not being asked again is lost.
            logger.certificate("storing the approval failed: \(error)")
        }
    }

    // MARK: - Native events

    private func apply(_ event: RDPNativeEvent) {
        switch event {
        case let .phase(phase, generation):
            guard generation == machine.generation.rawValue else { return }
            guard let target = phase.sessionState else { return }
            if machine.transition(to: target) != nil {
                // Input is gated on the state machine rather than on the
                // backend's phase, so a press cannot be delivered during a
                // handshake or while the session is tearing down.
                pointerSink.setAccepting(machine.state.acceptsInput)
                emit(.stateChanged(machine.state, generation: machine.generation))
                if machine.state == .connected { sendDesiredDesktopSize() }
            }

        case let .transportSecurity(security, generation):
            guard generation == machine.generation.rawValue else { return }
            logger.session("transport security \(security)")
            emit(.transportSecurity(security))

        case let .failure(status, nativeCode, generation):
            guard generation == machine.generation.rawValue else { return }
            var cause = RDPErrorMapper.classify(status: status, nativeCode: nativeCode)
            if configuration.proxy != nil { cause = RDPErrorMapper.throughProxy(cause) }
            terminationCause = cause
            logger.sessionError("native failure \(status.name) code=\(nativeCode) -> \(cause)")
            if case .failed(let error) = cause {
                if error == .authenticationFailed {
                    // The next attempt must ask rather than replay.
                    storedCredentialWasRejected = true
                    suppliedCredential = nil
                }
                emit(.error(error))
            }

        case let .channel(channel, isConnected):
            if isConnected {
                negotiatedChannels.insert(channel)
                if channel == .disp {
                    // A display channel that opens again belongs to a new
                    // desktop: a server redirection (GNOME's login screen
                    // handing over to the user's session) starts one at its
                    // own size and scale. Its first frame may come after the
                    // settle, so the old frames would make the size look
                    // right already; the layout is sent regardless.
                    displayScaleIsPending = true
                    resizeAttempts = 0
                    Task { [weak self] in
                        try? await Task.sleep(for: Self.displayChannelSettle)
                        await self?.sendDesiredDesktopSize()
                    }
                }
            } else {
                negotiatedChannels.remove(channel)
            }
            if channel == .rdpei { pointerSink.setTouchChannelOpen(isConnected) }
            logger.session("channel \(channel.name) connected=\(isConnected)")

        case let .certificateChallenge(review):
            guard review.bridgeGeneration == machine.generation.rawValue else { return }
            pendingCertificate = review
            raise(.certificate(review.challenge))

        case let .certificateSettled(accepted, detail):
            logger.certificate("settled accepted=\(accepted) \(detail)")

        case let .displayResized(width, height):
            currentDesktopSize = (Int(width), Int(height))
            logger.session("desktop resized to \(width)x\(height)")

        case let .clipboardRemoteFormatsRich(hasText, hasImage, hasFiles):
            remoteHasText = hasText
            remoteHasImage = hasImage
            remoteHasFiles = hasFiles
            emit(.clipboardChanged(hasRemoteText: hasText))

        case let .clipboardImage(requestID, image, status):
            guard let pending = pendingImageFetch, pending.id == requestID else { return }
            pendingImageFetch = nil
            if let image {
                pending.continuation.resume(returning: image)
            } else {
                pending.continuation.resume(throwing: Self.clipboardError(status))
            }

        case let .clipboardFile(requestID, file, isLast, status):
            guard var pending = pendingFilesFetch, pending.id == requestID else { return }
            if let file {
                pending.files.append(file)
            } else {
                pendingFilesFetch = nil
                pending.continuation.resume(throwing: Self.clipboardError(status))
                return
            }
            if isLast {
                pendingFilesFetch = nil
                pending.continuation.resume(returning: pending.files)
            } else {
                pendingFilesFetch = pending
            }

        case let .microphone(format):
            microphone.setOpen(format != nil)
            logger.session(format.map { "microphone opened \($0.sampleRate) Hz x\($0.channels)" } ?? "microphone closed")
            emit(.microphone(format))

        case let .clipboardOffer(id, stage, _):
            switch stage {
            case .accepted:
                pendingOffers.removeValue(forKey: id)?.resume()
            case .delivered:
                break
            case .failed:
                pendingOffers.removeValue(forKey: id)?.resume(throwing: ClipboardTransferError.failed)
            }

        case let .clipboardText(requestID, text, status):
            guard let pending = pendingFetch, pending.id == requestID else { return }
            pendingFetch = nil
            if let text {
                pending.continuation.resume(returning: text)
            } else {
                pending.continuation.resume(throwing: status == .timeout
                    ? ClipboardTransferError.timedOut
                    : ClipboardTransferError.failed)
            }

        case let .macExtensions(update, features):
            applyMacExtensions(update, features: MacExtensionFeatures(rawValue: features))

        case let .finished(run, destroy):
            logger.session("worker finished run=\(run.name) destroy=\(destroy?.name ?? "n/a")")
            let cause = terminationCause ?? RDPErrorMapper.classify(status: run)
            finishAttempt(cause: cause)
        }
    }

    // MARK: - Mac extensions

    var macExtensionStatus: MacExtensionStatus? { macStatus }

    func setStreamQuality(_ quality: StreamQuality) async {
        streamQuality = quality
        macStatus?.quality = quality
        sendStreamConfig()
        if let macStatus { emit(.macExtensions(macStatus)) }
    }

    private func applyMacExtensions(_ update: RDPMacExtensionsUpdate, features: MacExtensionFeatures) {
        switch update {
        case let .agreed(serverName):
            logger.session("mac extensions agreed with \(serverName): 0x\(String(features.rawValue, radix: 16))")
            pointerSink.setMacFeatures(features.rawValue)
            macStatus = MacExtensionStatus(serverName: serverName, features: features, quality: streamQuality)
            if features.contains(.macKeys) {
                var message = mrx_message()
                message.type = mrx_message_type(MRX_MSG_KEYBOARD_INFO)
                message.u.keyboard_info.keyboard_type = MacKeyboardType.current(fallback: configuration.keyboardLayout)
                native?.sendMacrdpx(&message)
            }
            sendStreamConfig()
            observeNetwork()
        case let .streamStatus(fps, scale, kbps, width, height):
            logger.session("mac stream \(width)x\(height)@\(scale)% \(fps) fps \(kbps) kbps")
            macStatus?.framesPerSecond = fps
            macStatus?.bitrateKbps = kbps
            macStatus?.scalePercent = scale
        case let .inputSource(id, ascii):
            macStatus?.inputSourceID = id
            macStatus?.isASCIICapable = ascii
        }
        if let macStatus { emit(.macExtensions(macStatus)) }
    }

    /// Asks the server for this session's quality, judged against the network
    /// the device is on right now.
    private func sendStreamConfig() {
        guard let macStatus, macStatus.features.contains(.streamConfig) else { return }
        let request = streamQuality.streamRequest(onConstrainedNetwork: NetworkConstraint.shared.isConstrained)
        var message = mrx_message()
        message.type = mrx_message_type(MRX_MSG_STREAM_CONFIG)
        message.u.stream_config.max_fps = UInt16(request.framesPerSecond)
        message.u.stream_config.bitrate_kbps = UInt32(request.bitrateKbps)
        native?.sendMacrdpx(&message)
    }

    /// Automatic quality follows the network: cellular or Low Data Mode
    /// lowers it, Wi-Fi raises it again.
    private func observeNetwork() {
        guard networkObservation == nil else { return }
        let changes = NetworkConstraint.shared.changes()
        networkObservation = Task { [weak self] in
            for await _ in changes {
                await self?.networkChanged()
            }
        }
    }

    private func networkChanged() {
        guard streamQuality == .automatic else { return }
        sendStreamConfig()
    }

    /// The worker has joined and the handle is gone, so this is the only place
    /// allowed to publish a terminal state.
    private func finishAttempt(cause: RDPTerminationCause) {
        closeSharedFolder()
        failClipboardWaiters()
        remoteHasText = false
        native = nil
        pointerSink.attach(nil)
        macStatus = nil
        pumpTask = nil
        pendingChallenge = nil
        pendingCertificate = nil

        switch cause {
        case .failed(let error) where machine.state != .disconnecting:
            if machine.state != .failed, machine.transition(to: .failed) != nil {
                emit(.error(error))
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
            resumeWorkerWaiters()

        case .remoteInitiated(let reason) where machine.state != .disconnecting:
            logger.session("remote ended the session: \(reason)")
            emit(.endedByServer(reason))
            if machine.transition(to: .disconnecting) != nil {
                emit(.stateChanged(machine.state, generation: machine.generation))
            }
            finishTeardown()

        case .stoppedLocally where machine.state != .disconnecting:
            // The backend stopped without anybody here asking. Treat it as a
            // clean end rather than inventing an error for it.
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
        frameStore.discardPending()
        cursorStore.reset()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        resumeWorkerWaiters()
    }

    private func resumeWorkerWaiters() {
        let waiters = workerFinished
        workerFinished.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func resumeConnecting() {
        if machine.transition(to: .connecting) != nil {
            emit(.stateChanged(machine.state, generation: machine.generation))
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
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}

/// Registers the RDP session with the factory registry. This is the whole of
/// the app's dependency on RDP: the list and the workspace ask for a session
/// by protocol kind, so Phase 8's SSH session is another registration rather
/// than a change at any call site.
struct RDPSessionFactory: RemoteSessionFactory {
    let protocolKind: ProtocolKind = .rdp
    let credentials: any CredentialRepository
    let trust: any TrustRepository

    /// What an `adaptive` profile connects at before the display channel is
    /// known. The real adaptive path is the DISP request the workspace makes
    /// once it knows its own size; this only has to be a desktop the device
    /// can present sensibly if the server never negotiates that channel.
    static let adaptiveDefaultSize = (width: 1_920, height: 1_080)

    func makeSession(
        configuration: EffectiveConnectionConfiguration
    ) async throws -> any RemoteSession {
        let size: (width: Int, height: Int)
        switch configuration.resolutionPolicy {
        case .adaptive:
            size = Self.adaptiveDefaultSize
        case let .fixed(width, height):
            size = (
                RDPRemoteSession.clampDimension(width, roundToEven: true),
                RDPRemoteSession.clampDimension(height, roundToEven: false)
            )
        }
        return RDPRemoteSession(
            configuration: configuration,
            credentials: credentials,
            trust: trust,
            desktopSize: size
        )
    }
}
