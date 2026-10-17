import UIKit
import AppleAdapters

/// docs/ssh-design.md section 9: a little time before iOS suspends the app,
/// so a quick trip to another app - looking up a password, answering a
/// message - does not cost the connections.
///
/// iOS gives a background task about half a minute, and nothing here asks
/// for more: the app does not claim a background mode it would not
/// otherwise need. While the time lasts, the sockets keep being served and
/// keepalives keep going out, so the server and any NAT in between do not
/// give up on the connection; past it, the app is suspended as usual and the
/// workspace finds out on the way back (docs/architecture.md section 10).
@MainActor
final class BackgroundGrace {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private let hasLiveSessions: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []

    init(hasLiveSessions: @escaping @MainActor () -> Bool) {
        self.hasLiveSessions = hasLiveSessions
        // The Mac keeps running in the background anyway.
        guard !Platform.isMac else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        })
    }

    private func begin() {
        guard task == .invalid, hasLiveSessions() else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "mRemote.connections") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        AppLog.logger(.app).info("background grace started")
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
