import SwiftUI
import InputCore
import SessionCore

@main
struct mRemoteApp: App {
    /// Only for a monitor's scene, which SwiftUI does not create.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(environment)
                .task {
                    IntentRouter.attach(environment)
                    await environment.start()
                }
                // .rdp files, rdp:// links and the Shortcuts app's
                // mremote://connect.
                .onOpenURL { url in Task { await environment.open(url) } }
        }
        .commands { MacCommands(environment: environment) }
        // iPad: a session in a window of its own. The Mac: every session.
        WindowGroup("セッション", id: "session", for: UUID.self) { $profileID in
            SessionWindowRoot(profileID: profileID)
                .environment(environment)
        }
        // docs/architecture.md section 10: no audio from the background.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: AudioCoordinator.shared.suspend()
            case .active: AudioCoordinator.shared.resume()
            default: break
            }
        }
    }
}

/// The app is one window with two levels: the connection list, and a
/// full-screen session on top of it. docs/ui-flow.md keeps the session
/// full-screen with a floating menu rather than a navigation bar, so nothing
/// competes with the remote desktop for space.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ConnectionListView()
            // Presented by a flag rather than by item, so switching sessions
            // swaps the content in place instead of dismissing and presenting
            // a second cover. `.id` rebuilds the surface per session: each
            // one draws a different frame store.
            .fullScreenCover(isPresented: Binding(
                get: { environment.presentedSession != nil },
                set: { if !$0 { environment.returnToList() } }
            )) {
                if let session = environment.presentedSession {
                    SessionWorkspaceView(model: session)
                        .id(session.id)
                        .environment(environment)
                }
            }
            .onAppear {
                environment.openSessionWindow = { [openWindow, environment] profileID in
                    environment.requestedSessionWindows.insert(profileID)
                    openWindow(value: profileID)
                }
                environment.listWindowCount += 1
            }
            .onDisappear { environment.listWindowCount -= 1 }
            .macWindow(title: String(localized: "接続先"), minimumSize: CGSize(width: 420, height: 360))
            // With several windows, the one in front decides what types:
            // this one's session, or nothing while the list is up.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, UIApplication.shared.supportsMultipleScenes else { return }
                Task { await environment.focus(environment.presentedSession?.id) }
            }
    }
}

/// The Mac's menu bar. The list's own sheets (⌘, and ⌘N) open in the list
/// window, which comes back if it was closed. While a session has the
/// keyboard these shortcuts go to Windows instead, like every other ⌘ key
/// (MacKeyboardCapture); the menu items still work with the pointer.
struct MacCommands: Commands {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if Platform.isMac {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { showList(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("新しい接続先…") { showList(.newConnection) }
                    .keyboardShortcut("n", modifiers: .command)
                // ⌘0 is the terminal's 標準の文字サイズ while one has focus,
                // as in Terminal.app; the first menu item with a key wins.
                Button("接続先の一覧") { showList(nil) }
                    .keyboardShortcut(focusedTerminal ? nil : KeyboardShortcut("0", modifiers: .command))
            }
            CommandMenu("セッション") {
                SessionCommands(session: environment.runningSessions.first { $0.id == environment.focusedSessionID })
            }
        }
    }

    /// `openWindow(id:)` makes another list window every time, so it is
    /// only called when none is open.
    private var focusedTerminal: Bool {
        environment.runningSessions.first { $0.id == environment.focusedSessionID }?.terminal != nil
    }

    private func showList(_ request: ListRequest?) {
        if environment.listWindowCount == 0 {
            openWindow(id: "main")
        }
        environment.listRequest = request
    }
}

/// The Mac's セッション menu: what the iPad's floating button holds, for the
/// session whose window is in front. Without a session in front it is all
/// disabled.
private struct SessionCommands: View {
    let session: SessionWorkspaceModel?
    @AppStorage(KeyShortcutList.storageKey) private var shortcuts = KeyShortcutList.standard

    var body: some View {
        Button("セッションのメニュー…") { session?.isMenuPresented = true }
            .disabled(session == nil)
        Divider()
        if let session, session.terminal != nil {
            terminalCommands(session)
        } else {
            desktopCommands
        }
        Divider()
        Button("再接続") {
            guard let session else { return }
            Task { await session.reconnect() }
        }
        .disabled(session.map { !($0.canRetry || $0.state == .disconnected) } ?? true)
        Button("切断") {
            guard let session else { return }
            Task { await session.disconnect() }
        }
        .disabled(session == nil)
    }

    @ViewBuilder
    private var desktopCommands: some View {
        Menu("ショートカットを送る") {
            ForEach(shortcuts.shortcuts) { shortcut in
                Button(shortcut.displayTitle) {
                    guard let session else { return }
                    Task { await session.sendFromMenu(shortcut) }
                }
            }
        }
        .disabled(session?.state.acceptsInput != true)
        Picker("解像度", selection: Binding(
            get: { session?.runtime.resolution ?? .adaptive },
            set: { session?.setResolution($0) }
        )) {
            ForEach([ResolutionPolicy.adaptive] + ResolutionPolicy.presets, id: \.self) { policy in
                Text(Formatting.resolutionLabel(policy)).tag(policy)
            }
        }
        .disabled(session?.supportsDynamicResolution != true)
        if let session, let mac = session.macExtensions, mac.features.contains(.streamConfig) {
            Picker("画質", selection: Binding(
                get: { mac.quality },
                set: { quality in Task { await session.setStreamQuality(quality) } }
            )) {
                ForEach(StreamQuality.allCases, id: \.self) { quality in
                    Text(StreamQualityLabel.text(quality)).tag(quality)
                }
            }
        }
    }

    /// An SSH session's terminal: ⌘ stays with the Mac here, so these keep
    /// the shortcuts Terminal.app has (docs/ssh-design.md 8.3).
    @ViewBuilder
    private func terminalCommands(_ session: SessionWorkspaceModel) -> some View {
        Button("文字を大きく") { session.terminalView?.adjustFontSize(by: 1) }
            .keyboardShortcut("+", modifiers: .command)
        Button("文字を小さく") { session.terminalView?.adjustFontSize(by: -1) }
            .keyboardShortcut("-", modifiers: .command)
        Button("文字の大きさを標準に") { session.terminalView?.resetFontSize() }
            .keyboardShortcut("0", modifiers: .command)
        Button("スクロールバックを消去") { session.terminalView?.clearLocalScrollback() }
            .keyboardShortcut("k", modifiers: .command)
    }
}
