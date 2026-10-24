import Foundation
import Observation
import UIKit
import InputCore
import SessionCore
import AppleAdapters

/// Drives the full-screen session: it mirrors the session's authoritative
/// state into something a view can render, and turns the floating menu's
/// actions into session calls.
///
/// It never holds frames or input. Those go directly between the surface and
/// the session, because routing them through an observable object would put
/// every frame on the main actor.
@MainActor
@Observable
final class SessionWorkspaceModel: Identifiable, Hashable {
    nonisolated let id: SessionID
    let displayName: String
    let configuration: EffectiveConnectionConfiguration

    private(set) var state: SessionState = .idle
    private(set) var lastError: RemoteSessionError?
    /// Why the server ended the session, when it did so on purpose.
    private(set) var endReason: RemoteEndReason?
    /// What protects the connection, as the server selected it.
    private(set) var transportSecurity: TransportSecurity?
    private(set) var pendingChallenge: SessionChallenge?
    /// Zoom, scale mode and the like: not part of the handshake, so they live
    /// here and may change while the session runs without writing back to the
    /// profile.
    private(set) var runtime: SessionRuntimeState
    private(set) var desktopSize: (width: Int, height: Int)?
    private(set) var supportsDynamicResolution = false
    /// The floating menu is open. Input is gated while it is, so a key held
    /// when it opened is released rather than left down behind the sheet.
    var isMenuPresented = false
    /// Set by the workspace, which reads the hinge: the menu offers a
    /// floating deck only where there is room for one.
    var deviceHasHinge = false
    /// Non-nil while an automatic reconnect is waiting or running: the
    /// attempt number out of `reconnectSchedule.maximumAttempts`.
    private(set) var reconnectAttempt: Int?
    private var hadConnected = false
    private(set) var remoteHasText = false
    private(set) var remoteHasImage = false
    private(set) var remoteHasFiles = false
    /// The microphone, while the server has it open.
    private(set) var microphoneFormat: MicrophoneFormat?
    /// A Mac server's Mac extensions, once it has agreed to them.
    private(set) var macExtensions: MacExtensionStatus?
    /// The host is a Mac: the profile says so, or the server agreed to the
    /// Mac extensions. Kept across reconnects, so the keyboard does not
    /// flip back to a PC's while the session reconnects.
    private(set) var isMacHost: Bool
    /// Shown as a toast; never contains clipboard text (docs/ui-flow.md 6.2).
    var clipboardMessage: String?
    private(set) var isTransferringClipboard = false
    /// The last text taken from the remote clipboard, kept only to recognise
    /// it coming back: pasting it straight back needs no new offer, because
    /// the remote still holds it (docs/architecture.md section 9).
    private var lastReceivedText: String?
    /// The Mac only: the pasteboard and the remote clipboard kept the same
    /// without being asked (`ClipboardMirror`).
    @ObservationIgnored private var clipboardMirror = ClipboardMirror()
    @ObservationIgnored private var clipboardWatch: Task<Void, Never>?
    @ObservationIgnored private var isMirroringClipboard = false
    /// The Mac only: this session's window is the key window of the app in
    /// front (`WindowKeyReader`). The clipboard follows the user only then: a
    /// copy made in another app must not be overwritten by whatever the
    /// remote announces meanwhile, and the remote is not sent what the user
    /// copies elsewhere.
    @ObservationIgnored var isWindowInFront = true {
        didSet {
            guard isWindowInFront != oldValue else { return }
            clipboardLog.info("window in front: \(self.isWindowInFront, privacy: .public)")
            guard isWindowInFront else { return }
            Task { await catchUpClipboard() }
        }
    }
    /// The remote copied something while the window was behind; it comes to
    /// the Mac on the way back, unless the Mac copied something newer.
    @ObservationIgnored private var remoteClipboardChangedBehind = false
    /// Built once in `init`; never replaced, so observation is not needed on
    /// the property itself - the controller is observable on its own.
    @ObservationIgnored private(set) var softwareKeyboard: SoftwareKeyboardController!
    private var reconnectTask: Task<Void, Never>?
    private let reconnectSchedule = ReconnectSchedule()

    private unowned let environment: AppEnvironment
    private let session: any RemoteSession
    /// Nil for a session that draws no desktop. Phase 8's SSH session is
    /// exactly that case, and the workspace has to render something else
    /// rather than assume a framebuffer.
    private let desktop: (any DesktopSession)?
    /// Set instead for an SSH session (docs/ssh-design.md 8.2).
    let terminal: (any TerminalSession)?
    /// The session's terminal, for the menu's font size and clear commands.
    /// Held here, not by the screen: it is the terminal's state, and comes
    /// back when the session is shown again.
    @ObservationIgnored var terminalView: SessionTerminalView?

    /// The session closed for good.
    func releaseTerminal() {
        terminalView?.detach()
        terminalView = nil
    }
    /// What the shell put in the title (OSC 0/2), shown in the window title.
    var terminalTitle: String?
    /// A multi-line paste waiting for the user to confirm it.
    private(set) var pendingPaste: String?
    @ObservationIgnored private var pendingPasteAction: (() -> Void)?
    /// A link in the terminal the user tapped, waiting for confirmation.
    var pendingLink: URL?
    /// Cancelled in `disconnect`, which is the only path that ends a session.
    /// There is no `deinit` cleanup because the model is main-actor isolated
    /// and `deinit` is not: the environment owns the model until the session
    /// is disconnected, so the task cannot outlive it.
    private var eventTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var renderSize: (width: Int, height: Int)?
    /// A monitor's size in pixels while the desktop is on it, followed
    /// instead of this screen's.
    private var externalRenderSize: (width: Int, height: Int)?
    private var extendedSecondarySize: (width: Int, height: Int)?
    private var lastRequestedSecondary: (width: Int, height: Int)?
    /// Where this screen's part of a desktop spread over two monitors ends
    /// and the monitor's begins; nil with one monitor.
    private(set) var extendedLayout: DesktopSpan?
    /// What a monitor draws this session's desktop from.
    @ObservationIgnored let desktopMirror = DesktopMirror()
    private var lastRequestedDesktopSize: (width: Int, height: Int)?

    /// A rotation or a Stage Manager resize arrives as a burst of layout
    /// passes. Asking the server to resize on each one would renegotiate the
    /// desktop several times for one gesture.
    private static let resizeDebounce = Duration.milliseconds(500)

    init(
        environment: AppEnvironment,
        session: any RemoteSession,
        configuration: EffectiveConnectionConfiguration
    ) {
        self.environment = environment
        self.session = session
        self.desktop = session as? any DesktopSession
        self.terminal = session as? any TerminalSession
        self.configuration = configuration
        self.id = session.id
        self.displayName = configuration.displayName
        self.runtime = SessionRuntimeState(from: configuration)
        self.isMacHost = configuration.remotePlatform == .macOS
        self.softwareKeyboard = SoftwareKeyboardController(
            mode: environment.globalSettings.softwareKeyboardMode,
            layout: configuration.keyboardLayout,
            canSend: { [weak self] in self?.acceptsInput ?? false },
            paste: configuration.clipboardPolicy.allowsSend
                ? { [weak self] text in Task { await self?.pasteToRemote(text) } }
                : nil,
            isMacHost: configuration.remotePlatform == .macOS,
            send: { [weak self] output in
                guard let sink = self?.inputSink else { return }
                switch output {
                case .key(let input): sink.send(input)
                case .unicode(let unit): sink.send(unicode: unit)
                }
            }
        )
    }

    /// From the menu: close it, then bring the keyboard up once the sheet is
    /// gone and the gate is open again.
    /// Shown in a window of its own rather than over the list.
    var isWindowed = false
    /// Set by that window: bring it to the front, or close it.
    @ObservationIgnored var requestWindowFront: (() -> Void)?
    @ObservationIgnored var closeWindow: (() -> Void)?

    /// The desktop as last seen, for the list and the switcher.
    private(set) var thumbnail: UIImage?

    func captureThumbnail() {
        if let terminalView, terminalView.bounds.width > 0 {
            let renderer = UIGraphicsImageRenderer(bounds: terminalView.bounds)
            thumbnail = renderer.image { _ in
                terminalView.drawHierarchy(in: terminalView.bounds, afterScreenUpdates: false)
            }
            return
        }
        guard let frame = frameStore?.latestSurface else { return }
        thumbnail = SessionThumbnail.make(from: frame)
    }

    func showSoftwareKeyboard() {
        isMenuPresented = false
        softwareKeyboard.show()
    }

    nonisolated static func == (lhs: SessionWorkspaceModel, rhs: SessionWorkspaceModel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var statusText: String {
        if let reconnectAttempt {
            return String(localized: "再接続中 (\(reconnectAttempt)/\(reconnectSchedule.maximumAttempts))")
        }
        return Formatting.stateLabel(state)
    }

    var isBusy: Bool {
        state == .connecting || state == .reconnecting || reconnectAttempt != nil
    }

    var canRetry: Bool { state == .failed && reconnectAttempt == nil }

    /// The input gate, in one place: connected, focused, menu closed. The
    /// scene half is added by the view, which owns `scenePhase`.
    var acceptsInput: Bool { state.acceptsInput && isFocused && !isMenuPresented }

    /// Present only once the session has a desktop to draw. Until then the
    /// workspace shows its status rather than a black rectangle.
    var frameStore: LatestDesktopFrameStore? { desktop?.frameStore }

    /// Where the surface sends pointer input. Nil for a session that has no
    /// desktop, which is how a future terminal session gets a workspace
    /// without pretending to have a mouse.
    var inputSink: (any DesktopInputSink)? { desktop?.inputSink }

    var cursorStore: RemoteCursorStore? { desktop?.cursorStore }

    /// docs/input-design.md section 5: only the focused session may receive
    /// input. Mirrored from `SessionManager` by the environment.
    var isFocused: Bool { environment.focusedSessionID == id }

    /// docs/data-and-security.md section 4 asks for an audit display when a
    /// profile allows legacy RDP Security. Whether the server actually chose
    /// it is not reported by the bridge, so this says what was allowed.
    var allowsLegacySecurity: Bool { configuration.securityPolicy == .legacyExplicit }

    /// What to say over a desktop that is no longer live: the last frame
    /// stays on screen after the connection goes, so a drop, a reconnect in
    /// progress or a takeover would otherwise look like a frozen desktop.
    struct StateBanner: Equatable {
        var title: String
        var symbol: String
        var detail: String?
        var busy = false
        var offersReconnect = false
    }

    var stateBanner: StateBanner? {
        if reconnectAttempt != nil || state == .reconnecting {
            return StateBanner(
                title: statusText,
                symbol: "arrow.triangle.2.circlepath",
                detail: lastError.map { Formatting.errorLabel($0, protocolKind: configuration.protocolKind) },
                busy: true
            )
        }
        switch state {
        case .failed:
            return StateBanner(
                title: String(localized: "接続が切れました"),
                symbol: "exclamationmark.triangle",
                detail: lastError.map { Formatting.errorLabel($0, protocolKind: configuration.protocolKind) },
                offersReconnect: true
            )
        case .disconnected:
            return StateBanner(
                title: String(localized: "切断されました"),
                symbol: "rectangle.portrait.and.arrow.right",
                detail: endReason.map(Formatting.endReasonLabel),
                offersReconnect: true
            )
        default:
            return nil
        }
    }

    /// The server actually chose the legacy RDP Security Layer.
    var isUsingLegacySecurity: Bool { transportSecurity == .legacyRDP }

    var showsDesktop: Bool { desktop != nil && (state == .connected || desktopSize != nil) }

    /// The terminal stays on screen after the connection goes, with what the
    /// shell printed last.
    var showsTerminal: Bool { terminal != nil && (state == .connected || hadConnected) }

    var showsRemoteContent: Bool { showsDesktop || showsTerminal }

    // MARK: - Terminal

    func toggleTerminalKeyboard() {
        guard let terminalView else { return }
        if terminalView.isFirstResponder {
            terminalView.resignFirstResponder()
        } else {
            terminalView.becomeFirstResponder()
        }
    }

    func terminalSendRefused() {
        clipboardMessage = String(localized: "送信が詰まっています。接続を確認してください。")
    }

    func confirmPaste(_ text: String, proceed: @escaping () -> Void) {
        pendingPaste = text
        pendingPasteAction = proceed
    }

    func resolvePaste(confirmed: Bool) {
        let action = pendingPasteAction
        pendingPaste = nil
        pendingPasteAction = nil
        if confirmed { action?() }
    }

    /// From the menu: what the clipboard holds, into the terminal.
    func pasteIntoTerminal() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        terminalView?.pasteText(text)
    }

    func start() async {
        let stream = await session.controlEvents()
        eventTask = Task { [weak self] in
            for await event in stream {
                await self?.apply(event)
            }
        }
        // A terminal has no remote clipboard to keep in step.
        if Platform.isMac, clipboardPolicy != .disabled, session is any ClipboardCapableSession {
            watchMacPasteboard()
        }
        do {
            try await session.connect()
        } catch {
            lastError = .internalFailure(detail: String(describing: error))
        }
        // Events arrive asynchronously, so read the authoritative state once
        // connect returns rather than waiting for the stream to catch up.
        await refresh()
    }

    /// Re-reads state from the session. Used after connect and after a
    /// challenge answer; the session, not this model, is the source of truth.
    func refresh() async {
        state = await session.state
        pendingChallenge = await session.pendingChallenge
        if let desktop {
            supportsDynamicResolution = await desktop.supportsDynamicResolution
        }
    }

    private func apply(_ event: SessionControlEvent) async {
        switch event {
        case .stateChanged(let state, _):
            self.state = state
            // Only awaitingUser has a challenge to answer. A review that
            // timed out or a session that ended has none, and a sheet left up
            // would answer a challenge the session no longer holds.
            if state != .awaitingUser { pendingChallenge = nil }
            if state == .connected || state == .connecting {
                endReason = nil
            }
            if state == .connecting {
                transportSecurity = nil
                macExtensions = nil
            }
            if state == .connected, let pending = credentialToSaveOnConnect {
                credentialToSaveOnConnect = nil
                // Only a password the server took: a key or the server's
                // own prompts may have signed in after it was refused.
                let accepted = await (session as? SSHRemoteSession)?.signedInWithPassword ?? true
                if accepted, let profileID = configuration.profileID {
                    await environment.persistCredential(
                        profileID: profileID, username: pending.username,
                        domain: pending.domain, password: pending.password)
                }
            }
            if state == .failed || state == .disconnected {
                credentialToSaveOnConnect = nil
                // Nothing takes typing now, and the keyboard would cover the
                // banner's reconnect button.
                terminalView?.resignFirstResponder()
                softwareKeyboard.hide()
            }
            if state == .connected {
                lastError = nil
                hadConnected = true
                reconnectAttempt = nil
                if let desktop {
                    supportsDynamicResolution = await desktop.supportsDynamicResolution
                }
            }
            if state == .failed { scheduleReconnectIfNeeded() }
        case .userActionRequired(let challenge):
            pendingChallenge = challenge
            // A reconnect that needs the user is no longer automatic.
            reconnectAttempt = nil
        case .error(let error):
            lastError = error
            if state == .failed { scheduleReconnectIfNeeded() }
        case .transportSecurity(let security):
            transportSecurity = security
        case .endedByServer(let reason):
            // Shown instead of an error; the state is already on its way to
            // disconnected, which never reconnects on its own.
            endReason = reason
            if case .shellExited = reason, configuration.ssh?.exitBehavior == .closeSession {
                await disconnect()
            }
        case .clipboardChanged(let hasRemoteText):
            remoteHasText = hasRemoteText
            // A new remote copy: whatever was received before is no longer
            // what the remote holds.
            lastReceivedText = nil
            await refreshRemoteClipboardKinds()
            if Platform.isMac { await mirrorRemoteClipboard() }
        case .macExtensions(let status):
            macExtensions = status
            if !isMacHost {
                isMacHost = true
                softwareKeyboard.isMacHost = true
            }
        case let .portForwardFailed(localPort, error):
            clipboardMessage = error == EADDRINUSE
                ? String(localized: "ポート転送 localhost:\(localPort) は使用中のため開けませんでした。")
                : String(localized: "ポート転送 localhost:\(localPort) を開けませんでした（\(error)）。")
        case .microphone(let format):
            microphoneFormat = format
            if let format, let capable = session as? any MicrophoneCapableSession {
                await MicrophoneCapture.shared.start(format: format, sink: capable.microphoneSink, owner: self)
            } else {
                MicrophoneCapture.shared.stop(for: self)
            }
        }
    }

    // MARK: - Mac extensions

    /// Asks a Mac server for another stream quality, for this session.
    func setStreamQuality(_ quality: StreamQuality) async {
        guard let capable = session as? any MacExtensionCapableSession else { return }
        await capable.setStreamQuality(quality)
    }

    // MARK: - Clipboard

    @ObservationIgnored private let clipboardLog = AppLog.logger(.clipboard)

    private func refreshRemoteClipboardKinds() async {
        guard let clipboard = session as? any ClipboardCapableSession else { return }
        remoteHasImage = await clipboard.remoteHasImage
        remoteHasFiles = await clipboard.remoteHasFiles
    }

    /// An image from this device, pasted into the focused remote window.
    func pasteImageToRemote(_ image: UIImage) async {
        guard canSendClipboard, let clipboard = session as? any ClipboardCapableSession else { return }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        let encoded = ClipboardMedia.encode(image)
        do {
            clipboardLog.info("image offer: png \(encoded.png?.count ?? 0, privacy: .public) dib \(encoded.dib?.count ?? 0, privacy: .public)")
            try await clipboard.offerClipboardImage(png: encoded.png, dib: encoded.dib)
            await pasteAfterOffer()
            clipboardMessage = String(localized: "\(displayName) に画像を貼り付けました")
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
        }
    }

    /// Files from this device onto the remote clipboard; pasted with Ctrl+V
    /// into Explorer, or wherever the user pastes them next.
    func sendFilesToRemote(_ urls: [URL]) async {
        guard canSendClipboard, let clipboard = session as? any ClipboardCapableSession else { return }
        let files = ClipboardMedia.read(urls)
        guard !files.isEmpty else { return }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            try await clipboard.offerClipboardFiles(files)
            await pasteAfterOffer()
            clipboardMessage = String(localized: "\(files.count) 個のファイルを \(displayName) に貼り付けました")
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
        }
    }

    private func pasteAfterOffer() async {
        isMenuPresented = false
        for _ in 0..<50 where !acceptsInput {
            try? await Task.sleep(for: .milliseconds(20))
        }
        sendPasteChord()
    }

    func copyRemoteImageToDevice() async -> UIImage? {
        guard canReceiveClipboardMedia, let clipboard = session as? any ClipboardCapableSession else { return nil }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            let remote = try await clipboard.fetchRemoteClipboardImage()
            let image = ClipboardMedia.image(from: remote)
            switch remote {
            case .png(let data): clipboardLog.info("image fetched: png \(data.count, privacy: .public) bytes, decoded=\(image != nil, privacy: .public)")
            case .dib(let data): clipboardLog.info("image fetched: dib \(data.count, privacy: .public) bytes, decoded=\(image != nil, privacy: .public)")
            }
            clipboardMessage = image == nil
                ? String(localized: "画像を読み取れませんでした")
                : String(localized: "\(displayName) から画像をコピーしました")
            return image
        } catch {
            clipboardLog.error("image fetch failed: \(String(describing: error), privacy: .public)")
            clipboardMessage = Self.clipboardFailureText(error)
            return nil
        }
    }

    func saveRemoteFilesToDevice() async {
        guard canReceiveClipboardMedia, let clipboard = session as? any ClipboardCapableSession else { return }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            let files = try await clipboard.fetchRemoteClipboardFiles()
            clipboardLog.info("files fetched: \(files.count, privacy: .public)")
            _ = try ClipboardMedia.save(files)
            clipboardMessage = String(localized: "\(files.count) 個のファイルをファイル App の「mRemote › 受信」に保存しました")
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
        }
    }

    var clipboardPolicy: ClipboardPolicy { configuration.clipboardPolicy }

    // MARK: Mac: a clipboard that follows the user

    /// Looks at the pasteboard's change count twice a second while this
    /// session has the keyboard and its window is in front, and offers
    /// Windows whatever is new. Reading the count reads nothing of the
    /// content; the content is read only when the count has moved. Copies made in another app while this window was
    /// behind are picked up the moment it comes back to the front.
    private func watchMacPasteboard() {
        clipboardWatch?.cancel()
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.mirrorLocalClipboard()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Back in front: what the Mac copied meanwhile goes to the remote; if
    /// it copied nothing, what the remote copied meanwhile comes here.
    private func catchUpClipboard() async {
        guard Platform.isMac, clipboardPolicy != .disabled else { return }
        let localChanged = clipboardMirror.handledChangeCount != UIPasteboard.general.changeCount
        await mirrorLocalClipboard()
        if remoteClipboardChangedBehind {
            remoteClipboardChangedBehind = false
            if !localChanged { await mirrorRemoteClipboard() }
        }
    }

    private func mirrorLocalClipboard() async {
        guard clipboardPolicy.allowsSend, state == .connected, isFocused, isWindowInFront, !isMirroringClipboard,
              !isTransferringClipboard, let clipboard = session as? any ClipboardCapableSession
        else { return }
        let pasteboard = UIPasteboard.general
        guard clipboardMirror.takeLocalChange(changeCount: pasteboard.changeCount) else { return }
        isMirroringClipboard = true
        defer { isMirroringClipboard = false }
        do {
            if pasteboard.hasStrings, let text = pasteboard.string {
                guard clipboardMirror.shouldOffer(text) else { return }
                try await clipboard.offerClipboardText(text)
                clipboardLog.info("mirrored local text: \(text.utf16.count, privacy: .public) units")
            } else if pasteboard.hasImages, let image = pasteboard.image {
                clipboardMirror.forgetText()
                let encoded = ClipboardMedia.encode(image)
                try await clipboard.offerClipboardImage(png: encoded.png, dib: encoded.dib)
                clipboardLog.info("mirrored local image")
            }
        } catch {
            // Tried again on the next change; a toast for a copy nobody asked
            // to send would only be noise.
            clipboardLog.error("mirroring local clipboard failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Windows copied something: text, or failing that an image, goes on the
    /// Mac's pasteboard. Files stay on the menu's explicit save.
    private func mirrorRemoteClipboard() async {
        guard clipboardPolicy.allowsReceive, state == .connected, !isMirroringClipboard,
              let clipboard = session as? any ClipboardCapableSession
        else { return }
        guard isWindowInFront else {
            remoteClipboardChangedBehind = true
            return
        }
        isMirroringClipboard = true
        defer { isMirroringClipboard = false }
        do {
            if remoteHasText {
                let text = try await clipboard.fetchRemoteClipboardText()
                lastReceivedText = text
                guard isLocalClipboardUnchanged() else { return }
                guard clipboardMirror.shouldWrite(text) else { return }
                UIPasteboard.general.string = text
                clipboardLog.info("mirrored remote text: \(text.utf16.count, privacy: .public) units")
            } else if remoteHasImage {
                guard let image = ClipboardMedia.image(from: try await clipboard.fetchRemoteClipboardImage()),
                      isLocalClipboardUnchanged()
                else { return }
                clipboardMirror.forgetText()
                UIPasteboard.general.image = image
                clipboardLog.info("mirrored remote image")
            } else {
                return
            }
            clipboardMirror.wrote(changeCount: UIPasteboard.general.changeCount)
        } catch {
            clipboardLog.error("mirroring remote clipboard failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The Mac copied nothing the mirror has not dealt with, so writing the
    /// remote's copy loses nothing. A copy made while the remote's was on its
    /// way is newer, and stays.
    private func isLocalClipboardUnchanged() -> Bool {
        guard clipboardMirror.handledChangeCount == UIPasteboard.general.changeCount else {
            clipboardLog.info("remote clipboard not mirrored: the Mac copied something newer")
            return false
        }
        return true
    }

    var canSendClipboard: Bool {
        clipboardPolicy.allowsSend && state == .connected
            && session is any ClipboardCapableSession && !isTransferringClipboard
    }

    var canReceiveClipboard: Bool {
        canReceiveClipboardMedia && remoteHasText
    }

    /// Images and files have their own flags; text is not required.
    var canReceiveClipboardMedia: Bool {
        clipboardPolicy.allowsReceive && state == .connected
            && session is any ClipboardCapableSession && !isTransferringClipboard
    }

    /// Local to remote: offer the text, wait for the server to take it, then
    /// close the menu and send the paste chord into the focused window. The
    /// chord is sent only here, on this explicit action.
    func pasteToRemote(_ text: String) async {
        guard canSendClipboard, let clipboard = session as? any ClipboardCapableSession else { return }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            if text != lastReceivedText || !remoteHasText {
                try await clipboard.offerClipboardText(text)
            }
            isMenuPresented = false
            // The chord needs the gate open again, which happens once the
            // sheet has gone and the surface has the keyboard back.
            for _ in 0..<50 where !acceptsInput {
                try? await Task.sleep(for: .milliseconds(20))
            }
            sendPasteChord()
            clipboardMessage = String(localized: "\(displayName) に貼り付けました")
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
        }
    }

    /// Remote to local: fetch on request, then write the pasteboard here on
    /// the main actor.
    func copyRemoteToDevice() async -> String? {
        guard canReceiveClipboard, let clipboard = session as? any ClipboardCapableSession else {
            return nil
        }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            let text = try await clipboard.fetchRemoteClipboardText()
            lastReceivedText = text
            clipboardMessage = String(localized: "\(displayName) からコピーしました")
            return text
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
            return nil
        }
    }

    /// One of the user's shortcuts, as a whole chord.
    func send(_ shortcut: KeyShortcut) {
        guard acceptsInput, let inputSink else { return }
        shortcut.inputs.forEach(inputSink.send)
    }

    /// From the menu: close it, wait for the gate, then send.
    func sendFromMenu(_ shortcut: KeyShortcut) async {
        isMenuPresented = false
        for _ in 0..<50 where !acceptsInput {
            try? await Task.sleep(for: .milliseconds(20))
        }
        send(shortcut)
    }

    private func sendPasteChord() {
        guard acceptsInput, let inputSink else { return }
        // Left Control + V as HID usages; the session maps them to its own
        // protocol. Down/up in order, so nothing is left held.
        let control: UInt16 = 0xE0
        let v: UInt16 = 0x19
        inputSink.send(KeyboardInput(usage: control, transition: .down))
        inputSink.send(KeyboardInput(usage: v, transition: .down))
        inputSink.send(KeyboardInput(usage: v, transition: .up))
        inputSink.send(KeyboardInput(usage: control, transition: .up))
    }

    private static func clipboardFailureText(_ error: Error) -> String {
        switch error as? ClipboardTransferError {
        case .unavailable: return String(localized: "クリップボードを使えません。接続設定の「クリップボード」で許可されているか、リモート側でクリップボードのリダイレクトが許可されているかを確認してください")
        case .timedOut: return String(localized: "リモートが応答しませんでした。少し待ってからもう一度試してください")
        case .unsupportedContent: return String(localized: "このテキストは送れません（大きすぎるか NUL を含みます）。長いテキストは分けて送ってください")
        case .nothingToCopy: return String(localized: "リモートにコピーされたテキストがありません。リモート側で先にコピーしてください")
        case .failed, .none: return String(localized: "クリップボードの転送に失敗しました。もう一度試してください")
        }
    }

    // MARK: - Audio

    var audioStream: PCMAudioStream? {
        (session as? any AudioCapableSession)?.audioSource as? PCMAudioStream
    }

    var isAudioMuted: Bool { runtime.isLocallyMuted || !configuration.audioPlayback }

    func setLocallyMuted(_ muted: Bool) {
        runtime.isLocallyMuted = muted
        environment.refreshAudioFocus()
    }

    // MARK: - Reconnect

    /// The failure and the error arrive as two events in either order, so
    /// both call this and the task itself is the guard against a second
    /// attempt for the same drop.
    private func scheduleReconnectIfNeeded() {
        guard reconnectTask == nil, state == .failed else { return }
        let attempt = (reconnectAttempt ?? 0) + 1
        guard let delay = reconnectSchedule.delay(
            beforeAttempt: attempt,
            after: lastError,
            policy: configuration.reconnectPolicy,
            hadConnected: hadConnected
        ) else {
            reconnectAttempt = nil
            return
        }
        reconnectAttempt = attempt
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            guard self.state == .failed else { return }
            await self.retry()
            // A failed attempt arrives as another `.failed`, which schedules
            // the next one; a success clears `reconnectAttempt`.
            if self.state == .failed { self.scheduleReconnectIfNeeded() }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = nil
    }

    // MARK: - Presentation

    func setScaleMode(_ mode: InitialScale) {
        runtime.scale = mode
    }

    /// Live, per-session, and never written back to the profile unless the
    /// user saves it as that connection's default.
    func setScrollDirection(_ direction: ScrollDirection) {
        runtime.scrollDirection = direction
    }

    /// The surface reports its drawable size in pixels. A server that
    /// negotiated the display channel is asked to match it - or to take the
    /// fixed resolution the user chose; one that did not keeps its own size
    /// and the surface scales locally, which is why this is not an error path.
    func renderSizeChanged(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        renderSize = (width, height)
        requestDesktopLayout()
    }

    /// Live, for this session only: a chosen size is kept through rotation and
    /// the deck, and 自動 goes back to following the screen.
    func setResolution(_ resolution: ResolutionPolicy) {
        guard resolution != runtime.resolution else { return }
        runtime.resolution = resolution
        requestDesktopLayout()
    }

    func setExternalDesktopSize(_ size: (width: Int, height: Int)?) {
        guard size?.width != externalRenderSize?.width || size?.height != externalRenderSize?.height else { return }
        externalRenderSize = size
        requestDesktopLayout()
    }

    /// A monitor that extends the desktop: its size in pixels, as a second
    /// monitor to the right of this screen.
    func setExtendedDisplaySize(_ size: (width: Int, height: Int)?) {
        guard size?.width != extendedSecondarySize?.width
                || size?.height != extendedSecondarySize?.height else { return }
        extendedSecondarySize = size
        requestDesktopLayout()
    }

    private func requestDesktopLayout() {
        guard var (width, height) = runtime.resolution.desktopSize(fitting: externalRenderSize ?? renderSize) else { return }
        let secondary = externalRenderSize == nil ? extendedSecondarySize : nil
        if secondary != nil {
            // The bridge takes even widths only; the split must fall where
            // the session will put it.
            width -= width % 2
            width = min(max(width, 200), 8_192)
            height = min(max(height, 200), 8_192)
        }
        let layout = secondary.map { DesktopSpan(primary: (width, height), secondary: $0) }
        if layout != extendedLayout { extendedLayout = layout }
        guard lastRequestedDesktopSize?.width != width
                || lastRequestedDesktopSize?.height != height
                || lastRequestedSecondary?.width != secondary?.width
                || lastRequestedSecondary?.height != secondary?.height else { return }
        lastRequestedDesktopSize = (width, height)
        lastRequestedSecondary = secondary

        resizeTask?.cancel()
        guard let desktop else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled else { return }
            await desktop.requestDesktopLayout(primary: (width, height), secondary: secondary)
            await self?.refresh()
        }
    }

    @ObservationIgnored private var displayScale: RemoteDisplayScale?

    /// How large Windows should draw. Resolved by the view, which knows the
    /// screen; the session sends it with the next layout, or at once.
    func setDisplayScale(_ scale: RemoteDisplayScale) {
        guard scale != displayScale else { return }
        displayScale = scale
        guard let desktop else { return }
        Task { await desktop.setDisplayScale(scale) }
    }

    func desktopSizeChanged(width: Int, height: Int) {
        desktopSize = (width, height)
    }

    var desktopSizeText: String? {
        guard let desktopSize else { return nil }
        return "\(desktopSize.width)×\(desktopSize.height)"
    }

    // MARK: - Challenges

    func answer(_ response: ChallengeResponse) async {
        guard let challenge = pendingChallenge else { return }
        pendingChallenge = nil
        do {
            try await session.respond(to: challenge.id, with: response)
            await refresh()
        } catch {
            // A stale answer is reported rather than retried: the attempt it
            // belonged to is already over.
            lastError = .internalFailure(detail: String(describing: error))
        }
    }

    private struct PendingCredential {
        let username: String
        let domain: String?
        let password: String
    }
    private var credentialToSaveOnConnect: PendingCredential?

    /// Saving happens here rather than inside the session because a profile
    /// that has never stored a password has no Keychain reference yet, and
    /// creating one is a change to the profile document.
    func answerCredential(
        username: String,
        domain: String?,
        password: String,
        save: Bool
    ) async {
        // SSH keeps it until the server has accepted it (docs/ssh-design.md
        // 7.3): a mistyped password saved now would be sent, and rejected,
        // on every later connect.
        if configuration.protocolKind == .ssh {
            credentialToSaveOnConnect = save && !password.isEmpty
                ? PendingCredential(username: username, domain: domain, password: password) : nil
        } else if save, !password.isEmpty, let profileID = configuration.profileID {
            await environment.persistCredential(
                profileID: profileID,
                username: username,
                domain: domain,
                password: password
            )
        }
        await answer(.credential(
            username: username,
            domain: domain,
            password: password,
            save: false
        ))
    }

    /// The 再接続 the user asks for. A failed session can try again in place;
    /// a disconnected one is finished - its state machine has no way back -
    /// so the workspace closes and the same profile connects anew.
    func reconnect() async {
        guard state == .disconnected else {
            await retry()
            return
        }
        let profileID = configuration.profileID
        await disconnect()
        guard let profileID,
              let profile = environment.profiles.first(where: { $0.id == profileID }) else { return }
        await environment.connect(to: profile)
    }

    func retry() async {
        if reconnectAttempt == nil { cancelReconnect() }
        do {
            try await session.connect()
            await refresh()
        } catch {
            lastError = .internalFailure(detail: String(describing: error))
        }
    }

    // MARK: - Lifecycle

    /// docs/architecture.md section 10: an inactive scene releases input and
    /// hides the remote screen from the app switcher. The connection itself is
    /// left alone - losing focus is not a reason to drop it.
    func sceneBecameInactive() async {
        await session.setVisibility(.background)
    }

    func sceneBecameActive() async {
        await session.setVisibility(isFocused ? .focused : .background)
        await refresh()
        // docs/architecture.md section 10: a connection that died while the
        // app was away is found on the way back, and handled by policy.
        if state == .failed { scheduleReconnectIfNeeded() }
    }

    /// Leaves the workspace without disconnecting. docs/requirements.md SES-02
    /// keeps a foreground connection alive until the user disconnects
    /// explicitly, so going back to the list must not tear it down.
    func returnToList() {
        isMenuPresented = false
        softwareKeyboard.hide()
        if isWindowed {
            // Its window closes; the session stays connected and listed.
            captureThumbnail()
            closeWindow?()
        } else {
            environment.returnToList()
        }
    }

    func disconnect() async {
        MicrophoneCapture.shared.stop(for: self)
        clipboardWatch?.cancel()
        clipboardWatch = nil
        cancelReconnect()
        isMenuPresented = false
        softwareKeyboard.hide()
        resizeTask?.cancel()
        resizeTask = nil
        await session.disconnect(reason: .userRequested)
        eventTask?.cancel()
        eventTask = nil
        await environment.endSession(id)
    }
}

/// When the laptop deck takes the lower half of the screen. Any device can
/// show it; only a foldable shows it by itself.
enum LaptopDeckPreference: String, CaseIterable {
    /// In a foldable's laptop posture: half open, hinge across the screen.
    /// A device without a hinge never reaches it.
    case automatic
    case always
    case never

    /// Saved on the device and shared by every session: whether a PC
    /// keyboard is wanted on screen is a matter of the device and the
    /// user's hands, not of the host.
    static let storageKey = "laptop-deck-preference"
    /// Whether 自動 also brings the deck up when a foldable is folded while
    /// held sideways, like a book, rather than only in the laptop posture.
    static let foldedLandscapeStorageKey = "laptop-deck-folded-landscape"

    /// - Parameter landscapeWhenFolded: the foldable may be folded while
    ///   held sideways, and the deck comes up then too.
    func showsDeck(posture: HingePosture, isPortrait: Bool, landscapeWhenFolded: Bool = false) -> Bool {
        switch self {
        case .automatic: return posture == .partiallyOpen && (isPortrait || landscapeWhenFolded)
        case .always: return true
        case .never: return false
        }
    }
}

/// One desktop over two monitors: this screen on the left, a monitor on the
/// right, top-aligned.
struct DesktopSpan: Equatable {
    var primary: (width: Int, height: Int)
    var secondary: (width: Int, height: Int)

    init(primary: (width: Int, height: Int), secondary: (width: Int, height: Int)) {
        self.primary = primary
        self.secondary = secondary
    }

    static func == (lhs: DesktopSpan, rhs: DesktopSpan) -> Bool {
        lhs.primary == rhs.primary && lhs.secondary == rhs.secondary
    }

    /// The monitor's part of the desktop, in pixels.
    var secondaryRect: CGRect {
        CGRect(x: primary.width, y: 0, width: secondary.width, height: secondary.height)
    }
}
