import SwiftUI
import SessionCore

/// One session in a window of its own (iPad, Stage Manager or an external
/// display): opened from the list's 新しいウィンドウで接続, keyed by the
/// connection, so opening it again brings the same window forward.
struct SessionWindowRoot: View {
    let profileID: UUID?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SessionWorkspaceModel?
    @State private var isMissing = false
    @State private var isConfirmingClose = false

    var body: some View {
        Group {
            if let model {
                SessionWorkspaceView(model: model)
                    .id(model.id)
            } else if isMissing {
                // A window restored for a connection that is gone, or one
                // that failed to start: the list, so the window is useful.
                RootView()
            } else {
                ProgressView()
            }
        }
        .macWindow(
            title: model?.displayName,
            minimumSize: CGSize(width: 640, height: 400)
        )
        .task { await attach() }
        // The Mac's close button and ⌘W ask what to do with a live session,
        // instead of leaving it connected behind the list unnoticed.
        .macWindowCloseGuard {
            guard let model, model.state.isActive else { return true }
            isConfirmingClose = true
            return false
        }
        .alert(
            String(localized: "\(model?.displayName ?? "") のウィンドウを閉じます"),
            isPresented: $isConfirmingClose
        ) {
            Button("切断して閉じる", role: .destructive) {
                // The window closes itself once the session has ended.
                guard let model else { return }
                Task { await model.disconnect() }
            }
            .accessibilityIdentifier("session-close-disconnect")
            Button("接続を維持して閉じる") {
                model?.returnToList()
            }
            .accessibilityIdentifier("session-close-keep")
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("接続を維持すると、セッションは接続先一覧から再び開けます。")
        }
        // The window in front is the one that types.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let model else { return }
            Task { await environment.focus(model.id) }
        }
        // Disconnected: the window has nothing left to show.
        .onChange(of: environment.runningSessions.map(\.id)) { _, running in
            guard let model, !running.contains(model.id) else { return }
            dismissWindow()
        }
        .onDisappear {
            // Closed by the system or the user: the session stays connected
            // and goes back to being shown over the list.
            model?.isWindowed = false
            model?.closeWindow = nil
            model?.requestWindowFront = nil
        }
    }

    /// The Mac has the list in a window of its own, so a session window with
    /// nothing to show simply closes.
    private func showMissing() {
        if Platform.isMac {
            dismissWindow()
        } else {
            isMissing = true
        }
    }

    private func attach() async {
        guard model == nil else { return }
        for _ in 0..<300 where environment.repository == nil {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard let profileID,
              let profile = environment.profiles.first(where: { $0.id.rawValue == profileID }) else {
            showMissing()
            return
        }
        // The Mac reopens the last run's windows at launch; a session is only
        // connected when someone asked for it.
        if Platform.isMac,
           environment.requestedSessionWindows.remove(profileID) == nil,
           environment.runningSession(for: profile) == nil {
            dismissWindow()
            return
        }
        let attached: SessionWorkspaceModel?
        if let running = environment.runningSession(for: profile) {
            // Moved here from the main window, never shown in both.
            if environment.presentedSession === running {
                environment.returnToList()
            }
            running.isWindowed = true
            attached = running
        } else {
            attached = await environment.connect(to: profile, presents: false)
        }
        guard let attached else {
            showMissing()
            return
        }
        attached.closeWindow = { dismissWindow() }
        attached.requestWindowFront = { openWindow(value: profileID) }
        model = attached
        await environment.focus(attached.id)
    }
}
