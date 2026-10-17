import SwiftUI
import InputCore
import SessionCore

/// Full screen, with one floating button. docs/ui-flow.md keeps the remote
/// desktop uncontested: no navigation bar, no persistent chrome, and the
/// status text only while there is no desktop to look at.
struct SessionWorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var screenScale
    @AppStorage(RemoteScalePreference.storageKey)
    private var scalePreference = RemoteScalePreference.automatic
    @AppStorage(FoldResolutionPolicy.storageKey)
    private var foldPolicy = FoldResolutionPolicy.resizeToFit
    @AppStorage(DesktopSafeAreaPolicy.storageKey)
    private var safeAreaPolicy = DesktopSafeAreaPolicy.avoid
    @Bindable var model: SessionWorkspaceModel
    @State private var toastText: String?
    @State private var hingePosture: HingePosture = .unavailable
    @State private var windowSafeArea = EdgeInsets()
    @State private var laptopChannel = LaptopDeckChannel()
    /// A deck 自動 brought up was put away with the keyboard button: it stays
    /// away until the device is unfolded, without turning 自動 off.
    @State private var dismissesFoldedDeck = false
    @AppStorage(LaptopDeckArrangement.storageKey)
    private var deckArrangement = LaptopDeckArrangement.keyboardAboveTrackpad
    @AppStorage(TouchPointerMode.storageKey) private var touchMode = TouchPointerMode.direct
    @AppStorage(LaptopDeckPreference.storageKey) private var deckPreference = LaptopDeckPreference.automatic
    @AppStorage(CapsLockRole.storageKey) private var capsLockRole = CapsLockRole.capsLock
    @AppStorage(LaptopKeyboardPlatform.storageKey) private var deckPlatform = LaptopKeyboardPlatform.windows
    @AppStorage(LaptopDeckArrangement.trackpadButtonsStorageKey) private var showsTrackpadButtons = true
    @AppStorage(LaptopDeckPlacement.storageKey) private var deckPlacement = LaptopDeckPlacement.docked
    @AppStorage(DeckLayout.portraitFractionKey) private var deckFractionPortrait = DeckLayout.standardFraction
    @AppStorage(DeckLayout.landscapeFractionKey) private var deckFractionLandscape = DeckLayout.standardFraction
    /// Split, the keys sit at the sides and need less height.
    @AppStorage(DeckLayout.splitFractionKey) private var deckFractionSplit = DeckLayout.standardSplitFraction
    @AppStorage(FloatingDeckFrame.storageKey) private var floatingDeckFrame = FloatingDeckFrame.standard
    @AppStorage(KeyboardPointerFollowing.storageKey) private var followsPointerAboveKeyboard = true
    @AppStorage(LaptopDeckArrangement.splitInLandscapeStorageKey) private var splitsDeckInLandscape = false
    @AppStorage(LaptopDeckPreference.foldedLandscapeStorageKey) private var showsDeckFoldedInLandscape = false
    @AppStorage(KeyboardButtonTarget.storageKey) private var keyboardButtonTarget = KeyboardButtonTarget.softwareKeyboard
    @AppStorage(KeyShortcutList.storageKey) private var shortcuts = KeyShortcutList.standard
    @AppStorage(DeckShortcutStrip.storageKey) private var showsDeckShortcuts = true
    @AppStorage(ExternalDisplayMode.storageKey) private var externalMode = ExternalDisplayMode.desktop
    @AppStorage(PencilInput.storageKey) private var sendsPencilAsPen = true
    @AppStorage(MacSwipeGestureMode.storageKey) private var swipeGestureMode = MacSwipeGestureMode.shortcuts
    @AppStorage(MacPinchGestures.storageKey) private var sendsPinchToMac = true
    private let externalDisplay = ExternalDisplayCoordinator.shared

    /// A monitor shows the desktop, and this screen is all keyboard and
    /// trackpad.
    private var externalTakesDesktop: Bool {
        externalDisplay.screen != nil && externalMode == .desktop
    }

    /// A monitor carries the right-hand part of one desktop spread over both
    /// screens.
    private var externalExtends: Bool {
        externalDisplay.screen != nil && externalMode == .extend
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HingePostureReader { hingePosture = $0 }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            WindowSafeAreaReader { windowSafeArea = $0 }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if Platform.isMac {
                // The clipboard follows the user only while this window is
                // the one in front.
                WindowKeyReader { model.isWindowInFront = $0 }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            SoftwareKeyboardHost(controller: model.softwareKeyboard)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                split(in: proxy.size, safeArea: windowSafeArea)
            }
            .ignoresSafeArea()
            privacyCover
        }
        .onAppear { showToast() }
        .onChange(of: model.transportSecurity) { _, security in
            // The audit display, at the moment it becomes true.
            guard security == .legacyRDP else { return }
            withAnimation { toastText = String(localized: "⚠︎ \(model.displayName) は古い RDP セキュリティで接続しています") }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { if toastText?.hasPrefix("⚠︎") == true { toastText = nil } }
            }
        }
        // A monitor's desktop is drawn for the monitor's density.
        .onChange(of: scalePreference.resolved(
            screenScale: externalTakesDesktop ? externalDisplay.screen?.scale ?? 1 : screenScale
        ), initial: true) { _, scale in
            model.setDisplayScale(scale)
        }
        .onChange(of: hingePosture, initial: true) { _, posture in
            model.deviceHasHinge = posture != .unavailable
        }
        .onChange(of: model.clipboardMessage) { _, message in
            guard let message else { return }
            withAnimation { toastText = message }
            model.clipboardMessage = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { if toastText == message { toastText = nil } }
            }
        }
        // Naming the container must not hide what is inside it: the status
        // text and the floating menu have to stay individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-workspace")
        #if DEBUG
        // What the input gate is made of, for UI tests that drive a live host.
        .accessibilityValue(
            "state=\(model.state) focused=\(model.isFocused) menu=\(model.isMenuPresented) "
                + "phase=\(scenePhase) accepts=\(model.acceptsInput) "
                + "safeArea=\(Int(windowSafeArea.top)),\(Int(windowSafeArea.leading)),"
                + "\(Int(windowSafeArea.bottom)),\(Int(windowSafeArea.trailing)) hinge=\(hingePosture)"
                + " external=\(externalTakesDesktop)"
        )
        #endif
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Only the presented session raises its challenge here; one waiting in
        // the background shows as 確認待ち in the list and the switcher.
        .sheet(item: challengeBinding) { identified in
            SessionChallengeSheet(
                challenge: identified.challenge,
                defaultUsername: model.configuration.account.username,
                defaultDomain: model.configuration.account.domain,
                onCredential: { username, domain, password, save in
                    Task {
                        await model.answerCredential(
                            username: username,
                            domain: domain,
                            password: password,
                            save: save
                        )
                    }
                },
                onTrust: { persist in
                    Task { await model.answer(persist ? .trustPersistently : .trustOnce) }
                },
                onKeyboardInteractive: { answers in
                    Task { await model.answer(.keyboardInteractive(answers: answers)) }
                },
                onPassphrase: { passphrase, save in
                    Task { await model.answer(.passphrase(passphrase, save: save)) }
                },
                asksForDomain: model.configuration.protocolKind == .rdp,
                onCancel: {
                    Task { await model.answer(.cancel) }
                }
            )
            .macSheetSize(height: 640)
        }
        .onChange(of: scenePhase, initial: false) { _, phase in
            // A Mac window behind another app is still on screen, and that is
            // all inactive means there; only a hidden or minimised one goes
            // to the background.
            if Platform.isMac, phase == .inactive { return }
            Task {
                if phase == .active {
                    await model.sceneBecameActive()
                } else {
                    await model.sceneBecameInactive()
                }
            }
        }
    }

    /// The whole screen, or - with the laptop deck - the part above it. At a
    /// foldable's hinge the deck takes the lower half; elsewhere it is docked
    /// along the bottom at the height the user dragged it to, or floats over
    /// the desktop on a screen with room for that.
    ///
    /// The desktop keeps its place in the hierarchy either way: the deck is
    /// added after it rather than the two being swapped between layouts,
    /// which would rebuild the surface and drop its texture.
    @ViewBuilder
    private func split(in size: CGSize, safeArea: EdgeInsets) -> some View {
        let isPortrait = size.height > size.width
        // The Mac has its own keyboard and trackpad, and a terminal has no
        // use for a PC keyboard and a trackpad.
        let preferenceWantsDeck = !Platform.isMac && model.terminal == nil && deckPreference.showsDeck(
            posture: hingePosture,
            isPortrait: isPortrait,
            landscapeWhenFolded: showsDeckFoldedInLandscape
        )
        let foldWantsDeck = preferenceWantsDeck && deckPreference == .automatic
        let wantsDeck = preferenceWantsDeck && !(foldWantsDeck && dismissesFoldedDeck)
        // One keyboard at a time: while the iOS keyboard is up the deck
        // steps aside (at a hinge it comes back when the keyboard goes).
        let showsDeck = wantsDeck && !model.softwareKeyboard.isVisible
        let hingeAcross = hingePosture == .partiallyOpen && isPortrait
        let splitsDeck = splitsDeckInLandscape && !isPortrait && canFloatDeck
        let fraction = isPortrait ? deckFractionPortrait
            : splitsDeck ? deckFractionSplit : deckFractionLandscape
        let docked: DeckLayout = hingeAcross ? .atHinge : .docked(fraction: fraction)
        let deck: DeckLayout = externalTakesDesktop ? .fullScreen
            : !showsDeck ? .hidden
            : hingeAcross ? .atHinge
            : deckPlacement == .floating && canFloatDeck ? .floating
            : docked
        let layout = WorkspaceLayout(
            size: size,
            safeArea: safeAreaPolicy == .avoid ? safeArea : EdgeInsets(),
            deck: deck,
            foldPolicy: foldPolicy,
            lockedDeck: docked
        )
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    desktop(
                        // The keyboard-only deck has no pad of its own, so the
                        // desktop is its trackpad whatever touch mode is chosen.
                        touchMode: showsDeck && !deckArrangement.hasTrackpad ? .trackpad : touchMode,
                        renderSizeOverride: layout.renderSizeOverride
                    )
                    // Inset by what the system reports for this device and
                    // rotation, so the surface - and the size it asks the
                    // server for - stays clear of the island, the corners and
                    // the home indicator.
                    .padding(layout.desktopInsets)
                    if !model.showsRemoteContent {
                        status
                    }
                    endBanner
                    if !externalTakesDesktop {
                        floatingMenu(showsDeck: showsDeck, foldWantsDeck: foldWantsDeck, keyboardButton: !Platform.isMac)
                    }
                    toast
                }
                .frame(height: layout.desktopFrameHeight)
                .clipped()
                if layout.deckHeight > 0 {
                    VStack(spacing: 0) {
                        if deck == .fullScreen {
                            externalDisplayBar
                                .padding(.top, safeArea.top)
                        }
                        if case .docked = deck {
                            DeckResizeHandle(
                                fraction: isPortrait ? $deckFractionPortrait
                                    : splitsDeck ? $deckFractionSplit : $deckFractionLandscape,
                                standardFraction: splitsDeck ? DeckLayout.standardSplitFraction
                                    : DeckLayout.standardFraction,
                                screenHeight: size.height
                            )
                        }
                        // Halves at the sides for the thumbs, on a screen wide
                        // enough to hold the device by them.
                        laptopDeck(split: splitsDeck)
                    }
                    .frame(height: layout.deckHeight)
                    // Placed where it ends up rather than slid in: the desktop
                    // above resizes as the deck arrives, and the resize request
                    // that follows cut a slide short, leaving the deck parked
                    // below the screen with its keys out of reach.
                    .transition(.identity)
                }
            }
            if deck == .floating {
                FloatingDeckPanel(frame: $floatingDeckFrame) {
                    laptopDeck(split: false)
                }
                .padding(layout.safeArea)
                .transition(.opacity)
            }
            if externalTakesDesktop {
                floatingMenu(showsDeck: true, foldWantsDeck: false, keyboardButton: false)
                    .padding(.top, safeArea.top)
            }
            #if DEBUG
            if externalDisplay.isFaked {
                // The Simulator's stand-in monitor, in a corner.
                ExternalDisplayRoot()
                    .frame(width: 256, height: 144)
                    .border(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, safeArea.top + 40)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("fake-external-display")
            }
            #endif
        }
        .onChange(of: externalMode, initial: true) { _, _ in
            updateExternalDisplay()
        }
        .onChange(of: externalDisplay.pixelSize?.width) { _, _ in
            updateExternalDisplay()
        }
        .onChange(of: externalDisplay.screen != nil) { _, _ in
            updateExternalDisplay()
        }
        .onChange(of: model.extendedLayout) { _, layout in
            model.desktopMirror.sourceRect = layout?.secondaryRect
        }
        .onDisappear {
            if externalDisplay.mirror === model.desktopMirror {
                externalDisplay.mirror = nil
            }
            model.setExternalDesktopSize(nil)
            model.setExtendedDisplaySize(nil)
        }
        .animation(.easeInOut(duration: 0.25), value: showsDeck)
        .onChange(of: wantsDeck, initial: true) { _, wants in
            // The deck is the keyboard now; the system one would only cover it.
            if wants { model.softwareKeyboard.hide() }
        }
        .onChange(of: foldWantsDeck) { _, wants in
            // Unfolded: the next fold brings the deck up again.
            if !wants { dismissesFoldedDeck = false }
        }
        // The keyboard button brings back whichever keyboard was on screen
        // last, however it got there.
        .onChange(of: showsDeck && deck != .fullScreen, initial: true) { _, shown in
            if shown { keyboardButtonTarget = .laptopDeck }
        }
        .onChange(of: model.softwareKeyboard.isVisible) { _, visible in
            guard visible else { return }
            keyboardButtonTarget = .softwareKeyboard
            // Brought up over a deck the user had shown: switched to, so it
            // does not come back when this keyboard is put away.
            if deckPreference == .always { deckPreference = .never }
        }
    }

    /// Says where the desktop went, above the keyboard and trackpad.
    private var externalDisplayBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
            Text(model.showsDesktop
                 ? String(localized: "\(model.displayName) を外部ディスプレイに表示中")
                 : model.statusText)
                .lineLimit(1)
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color.black)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("external-display-bar")
    }

    /// The monitor gets this session's desktop at its own size, the right
    /// half of a desktop spread over both screens, or nothing.
    private func updateExternalDisplay() {
        let takes = externalTakesDesktop
        let extends = externalExtends
        if takes || extends {
            externalDisplay.mirror = model.desktopMirror
        } else if externalDisplay.mirror === model.desktopMirror {
            externalDisplay.mirror = nil
        }
        model.desktopMirror.sourceRect = extends ? model.extendedLayout?.secondaryRect : nil
        model.setExternalDesktopSize(takes ? externalDisplay.pixelSize : nil)
        model.setExtendedDisplaySize(extends ? externalDisplay.pixelSize : nil)
    }

    /// An iPad, or a foldable: a screen with room for a panel over the
    /// desktop. A phone keeps the deck docked.
    private var canFloatDeck: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || hingePosture != .unavailable
    }

    /// A Mac host gets the Mac's own shortcuts; the user's list is for Windows.
    private var deckShortcuts: [KeyShortcut] {
        model.configuration.remotePlatform == .macOS ? KeyShortcut.macDefaults : shortcuts.shortcuts
    }

    private func laptopDeck(split: Bool) -> some View {
        VStack(spacing: 0) {
            if showsDeckShortcuts, !deckShortcuts.isEmpty {
                ShortcutStrip(
                    shortcuts: deckShortcuts,
                    isEnabled: model.acceptsInput && scenePhase == .active
                ) { model.send($0) }
            }
            laptopKeys(split: split)
        }
    }

    private func laptopKeys(split: Bool) -> some View {
        LaptopDeck(
            layout: model.configuration.keyboardLayout,
            // With the desktop on a monitor, the pad is the only pointer.
            arrangement: externalTakesDesktop && !deckArrangement.hasTrackpad
                ? .keyboardAboveTrackpad : deckArrangement,
            channel: laptopChannel,
            isInputEnabled: model.acceptsInput && scenePhase == .active,
            capsLockRole: capsLockRole,
            showsTrackpadButtons: showsTrackpadButtons,
            // A Mac server is typed on with a Mac's keys (⌘, 英数/かな).
            platform: model.configuration.remotePlatform == .macOS ? .mac : deckPlatform,
            isSplit: split
        )
    }

    @ViewBuilder
    private func desktop(touchMode: TouchPointerMode, renderSizeOverride: CGSize?) -> some View {
        if let terminal = model.terminal, let settings = model.configuration.ssh {
            // An SSH session draws a terminal instead (docs/ssh-design.md 8.2).
            TerminalSurface(
                session: terminal,
                settings: settings,
                isInputEnabled: model.acceptsInput && scenePhase == .active,
                onSendRefused: { model.terminalSendRefused() },
                onPasteNeedsConfirmation: { text, proceed in model.confirmPaste(text, proceed: proceed) },
                onOpenLink: { url in model.pendingLink = url },
                onTitle: { title in model.terminalTitle = title },
                onReady: { view in model.terminalView = view }
            )
            .opacity(model.showsTerminal ? 1 : 0)
            .accessibilityIdentifier("terminal-surface")
            .alert("複数行を貼り付けますか？", isPresented: pasteAlertBinding) {
                Button("貼り付ける") { model.resolvePaste(confirmed: true) }
                    .accessibilityIdentifier("paste-confirm")
                Button("キャンセル", role: .cancel) { model.resolvePaste(confirmed: false) }
            } message: {
                Text("改行を含むため、貼り付けた各行がそのままコマンドとして実行されます。")
            }
            .alert("リンクを開きますか？", isPresented: linkAlertBinding) {
                Button("開く") {
                    if let url = model.pendingLink { UIApplication.shared.open(url) }
                    model.pendingLink = nil
                }
                Button("キャンセル", role: .cancel) { model.pendingLink = nil }
            } message: {
                Text(model.pendingLink?.absoluteString ?? "")
            }
        } else if let frameStore = model.frameStore {
            RemoteDesktopSurface(
                frameStore: frameStore,
                cursorStore: model.cursorStore,
                inputSink: model.inputSink,
                scaleMode: model.runtime.scale,
                scrollDirection: model.runtime.scrollDirection,
                laptopChannel: laptopChannel,
                touchMode: touchMode,
                followsPointerAboveKeyboard: followsPointerAboveKeyboard,
                sendsPencilAsPen: sendsPencilAsPen,
                swipeGestureMode: swipeGestureMode,
                sendsPinchToMac: sendsPinchToMac,
                renderSizeOverride: renderSizeOverride,
                mirror: model.desktopMirror,
                primaryRegion: model.extendedLayout,
                // Input is gated on both halves of docs/architecture.md
                // section 10: the session must be able to deliver it, and the
                // scene must be the one the user is looking at.
                // A third: the session must be the focused one, so a surface
                // left behind during a switch can never type into it.
                isInputEnabled: model.acceptsInput && scenePhase == .active,
                // The proxy owns the keyboard while the software keyboard is
                // up; the surface must not take it back on the next tap.
                suppressesKeyboardCapture: model.softwareKeyboard.isVisible,
                isInputTraceEnabled: environment.inputDiagnostics.isTraceRequested,
                onRenderSizeChange: { width, height in
                    model.renderSizeChanged(width: width, height: height)
                },
                onDesktopSizeChange: { width, height in
                    model.desktopSizeChanged(width: width, height: height)
                },
                onInputDiagnostics: { diagnostics in
                    environment.inputDiagnostics.update(diagnostics)
                }
            )
            // Edge to edge only when asked: ignoring the safe area here would
            // grow the surface back over the insets it was padded by.
            .ignoresSafeArea(edges: safeAreaPolicy == .fullScreen ? .all : [])
            .opacity(model.showsDesktop ? 1 : 0)
        }
    }

    private var status: some View {
        VStack(spacing: 12) {
            Text(model.displayName)
                .font(.title2)
                .foregroundStyle(.white)
            Text(model.statusText)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("session-status")
            if model.isBusy {
                ProgressView().tint(.white)
            }
            if let error = model.lastError {
                Text(Formatting.errorLabel(error, protocolKind: model.configuration.protocolKind))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 40)
            }
            if model.canRetry {
                Button("再接続") {
                    Task { await model.retry() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("session-retry")
            }
        }
    }

    /// docs/architecture.md section 10: the remote screen must not be what the
    /// app switcher snapshots. The cover is part of the view hierarchy rather
    /// than something applied on the way out, so there is no window in which
    /// the snapshot could be taken before it appears.
    @ViewBuilder
    private var privacyCover: some View {
        if scenePhase != .active, !Platform.isMac {
            ZStack {
                Rectangle()
                    .fill(.ultraThickMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    Image(systemName: "lock.display")
                        .font(.system(size: 44))
                    Text(model.displayName)
                        .font(.headline)
                    Text("接続は維持されています")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
            .accessibilityIdentifier("session-privacy-cover")
        }
    }

    private func floatingMenu(showsDeck: Bool, foldWantsDeck: Bool, keyboardButton: Bool = true) -> some View {
        let softwareKeyboardShown = model.softwareKeyboard.isVisible
        return Group {
            if Platform.isMac {
                // The Mac has the セッション menu in the menu bar instead of a
                // button over the desktop; the sheet still comes up from it.
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            } else {
                floatingMenuButton(softwareKeyboardShown: softwareKeyboardShown, showsDeck: showsDeck,
                                   foldWantsDeck: foldWantsDeck, keyboardButton: keyboardButton)
            }
        }
        // On the button rather than the workspace: the workspace already
        // carries the challenge sheet, and two sheets on one view do not both
        // present.
        .sheet(isPresented: $model.isMenuPresented) {
            SessionMenuSheet(model: model)
                .presentationDetents([.medium, .large])
                .macSheetSize()
        }
    }

    private var pasteAlertBinding: Binding<Bool> {
        Binding(get: { model.pendingPaste != nil }, set: { if !$0 { model.resolvePaste(confirmed: false) } })
    }

    private var linkAlertBinding: Binding<Bool> {
        Binding(get: { model.pendingLink != nil }, set: { if !$0 { model.pendingLink = nil } })
    }

    private func floatingMenuButton(
        softwareKeyboardShown: Bool, showsDeck: Bool, foldWantsDeck: Bool, keyboardButton: Bool
    ) -> some View {
        FloatingMenuButton(
            keyboard: !keyboardButton ? nil : .init(
                isShowingKeyboard: softwareKeyboardShown || showsDeck,
                isEnabled: softwareKeyboardShown || showsDeck || keyboardButtonTarget == .laptopDeck
                    || model.state.acceptsInput,
                toggle: { toggleKeyboard(showsDeck: showsDeck, foldWantsDeck: foldWantsDeck) }
            )
        ) {
            model.isMenuPresented = true
        }
    }

    /// Whichever keyboard is up goes away; with none up, the one used last
    /// comes up. A deck 自動 brought up for the fold is only put aside, so
    /// unfolding and folding again still brings it.
    private func toggleKeyboard(showsDeck: Bool, foldWantsDeck: Bool) {
        if model.terminal != nil {
            // The terminal is its own text input; its keyboard comes with
            // SwiftTerm's Esc/Ctrl/Tab/arrow bar.
            model.toggleTerminalKeyboard()
        } else if model.softwareKeyboard.isVisible {
            model.softwareKeyboard.hide()
        } else if showsDeck {
            if foldWantsDeck {
                dismissesFoldedDeck = true
            } else {
                deckPreference = .never
            }
        } else {
            switch keyboardButtonTarget {
            case .softwareKeyboard:
                model.showSoftwareKeyboard()
            case .laptopDeck:
                if foldWantsDeck {
                    dismissesFoldedDeck = false
                } else {
                    deckPreference = .always
                }
            }
        }
    }

    /// The session's state over the desktop it left behind. The last frame
    /// stays on screen after the connection goes, and the status text above
    /// only shows when there is no desktop - so without this, a dropped
    /// connection, a reconnect in progress, or a session taken over by another
    /// device would all just look like a frozen desktop.
    @ViewBuilder
    private var endBanner: some View {
        if model.showsRemoteContent, let banner = model.stateBanner {
            VStack(spacing: 10) {
                if banner.busy {
                    ProgressView()
                }
                Label(banner.title, systemImage: banner.symbol)
                    .font(.headline)
                if let detail = banner.detail {
                    Text(detail)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                if banner.offersReconnect {
                    // Offered, not done: after a takeover it would take the
                    // session back from whoever has it now.
                    Button("再接続") {
                        Task { await model.reconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("session-end-reconnect")
                }
            }
            .padding(16)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session-end-reason")
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toastText {
            Text(toastText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 24)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityIdentifier("session-toast")
        }
    }

    /// docs/ui-flow.md section 6: the session's name, briefly, when it is
    /// connected to or switched to.
    private func showToast() {
        withAnimation { toastText = "\(model.displayName) ・ \(model.statusText)" }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toastText = nil }
        }
    }

    private var challengeBinding: Binding<IdentifiedChallenge?> {
        Binding(
            get: { model.pendingChallenge.map(IdentifiedChallenge.init) },
            // The sheet cannot be dismissed interactively, and every button on
            // it answers the challenge, so there is nothing to write back.
            set: { _ in }
        )
    }
}

/// `sheet(item:)` needs an Identifiable; the challenge ID already is the
/// identity, so this only adapts the shape.
struct IdentifiedChallenge: Identifiable {
    let challenge: SessionChallenge

    var id: ChallengeID { challenge.id }
}
