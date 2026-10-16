import Foundation
import Observation
import SwiftUI
import UIKit
import AppleAdapters
import Persistence
import SessionCore

/// Composition root. Everything the screens need is assembled here, so no view
/// constructs a repository or a session of its own and a UI test can swap the
/// whole graph for an in-memory one.
@MainActor
@Observable
final class AppEnvironment {
    let credentials: any CredentialRepository
    let trust: any TrustRepository
    let sessions: SessionManager
    let factories: SessionFactoryRegistry

    private let store: any ProfileStore
    private(set) var repository: ProfileRepository?
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var globalSettings: GlobalSettings = .default
    private(set) var loadFailure: String?

    var presentedSession: SessionWorkspaceModel?
    /// A profile read from a `.rdp` file or an `rdp://` link, waiting for
    /// the user to look at it and save it.
    var pendingImport: ProfileEditorModel?
    /// A file that could not be read as a connection, said once.
    var importFailure: String?
    /// The connection being woken up, while the list waits for it.
    private(set) var wakingProfileID: ProfileID?
    /// Said once on the list, then cleared: a wake that could not be sent.
    var listMessage: String?
    /// What the menu bar asked the list to show, taken and cleared by it.
    var listRequest: ListRequest?
    /// Opens, or brings forward, the window for a connection. Set by the
    /// scene, because only a view can open a window; on the Mac every
    /// session is shown this way.
    @ObservationIgnored var openSessionWindow: ((UUID) -> Void)?
    /// Session windows asked for in this run. On the Mac the system also
    /// brings back the windows of the last run; those close rather than
    /// connect on their own at launch.
    @ObservationIgnored var requestedSessionWindows: Set<UUID> = []
    /// How many list windows are open, so the menu bar opens one only when
    /// there is none.
    @ObservationIgnored var listWindowCount = 0
    /// Sessions that are still connected while the user is back on the list.
    /// SES-02 keeps a foreground connection alive until an explicit
    /// disconnect, so without this they would be running with no way back to
    /// them.
    private(set) var runningSessions: [SessionWorkspaceModel] = []
    /// A main-actor mirror of `SessionManager.focusedSessionID`, so a view
    /// can gate input on it without awaiting the actor.
    private(set) var focusedSessionID: SessionID?
    let inputDiagnostics = InputDiagnosticsCenter()

    private let logger = AppLog.logger(.app)
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?

    init(
        store: any ProfileStore,
        credentials: any CredentialRepository,
        trust: any TrustRepository,
        factories: SessionFactoryRegistry
    ) {
        self.store = store
        self.credentials = credentials
        self.trust = trust
        self.factories = factories
        self.sessions = SessionManager()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryWarning() }
        }
    }

    /// The shipping graph. The only place that knows RDP exists: everything
    /// above asks the registry for a session by protocol kind, so Phase 8's
    /// SSH session is one more registration here.
    static func live() -> AppEnvironment {
        if UITestConfiguration.isActive {
            return UITestConfiguration.makeEnvironment()
        }
        let store: any ProfileStore
        do {
            store = FileProfileStore(url: try FileProfileStore.defaultURL())
        } catch {
            // A store that cannot be located is reported on screen rather than
            // silently replaced by an in-memory one, which would look like the
            // user's profiles had vanished.
            store = FailingProfileStore(reason: String(describing: error))
        }
        let keychain = KeychainStore.detect()
        let credentials = KeychainCredentialRepository(store: keychain)
        let trust = KeychainTrustRepository(store: keychain)
        return AppEnvironment(
            store: store,
            credentials: credentials,
            trust: trust,
            factories: SessionFactoryRegistry(factories: [
                RDPSessionFactory(credentials: credentials, trust: trust)
            ])
        )
    }

    func start() async {
        do {
            let repository = try await ProfileRepository(store: store)
            self.repository = repository
            await refresh()
        } catch {
            loadFailure = String(describing: error)
            logger.error("profile store load failed")
        }
    }

    func refresh() async {
        guard let repository else { return }
        profiles = await repository.profiles
        globalSettings = await repository.globalSettings
    }

    func save(_ profile: ConnectionProfile, password: String?, gatewayPassword: String? = nil) async {
        guard let repository else { return }
        var profile = profile
        do {
            // The gateway's own password, when it signs in apart from the
            // computer; kept in the Keychain like the computer's.
            if let gatewayPassword, !gatewayPassword.isEmpty,
               case .rdp(var rdp) = profile.configuration, var gateway = rdp.gateway {
                let reference = gateway.account.credentialReference ?? CredentialReference()
                try credentials.store(password: gatewayPassword, for: reference)
                gateway.account.credentialReference = reference
                rdp.gateway = gateway
                profile.configuration = .rdp(rdp)
            }
            if let password, !password.isEmpty {
                // A new password gets a fresh reference only when the profile
                // does not already have one, so rotating a password does not
                // orphan the previous Keychain item.
                let reference = profile.account.credentialReference ?? CredentialReference()
                try credentials.store(password: password, for: reference)
                profile.account.credentialReference = reference
            }
            try await repository.upsert(profile)
            await refresh()
        } catch {
            // The list itself is fine; replacing it with a load failure left
            // nothing to do but restart the app.
            listMessage = String(localized: "接続先を保存できませんでした（\(String(describing: error))）。")
            logger.error("saving a profile failed")
        }
    }

    func delete(_ profile: ConnectionProfile) async {
        guard let repository else { return }
        do {
            if let orphaned = try await repository.delete(id: profile.id) {
                // Only deleted once no remaining profile references it.
                try credentials.delete(orphaned)
            }
            // A gateway password belongs to its one profile.
            if let reference = profile.configuration.rdp?.gateway?.account.credentialReference {
                try? credentials.delete(reference)
            }
            await refresh()
        } catch {
            listMessage = String(localized: "接続先を削除できませんでした（\(String(describing: error))）。")
            logger.error("deleting a profile failed")
        }
    }

    func setFavorite(_ favorite: Bool, for profile: ConnectionProfile) async {
        guard let repository else { return }
        var updated = profile
        updated.isFavorite = favorite
        do {
            try await repository.upsert(updated)
            await refresh()
        } catch {
            logger.error("saving a favourite failed")
        }
    }

    func duplicate(_ profile: ConnectionProfile) async {
        let copy = profile.duplicated(displayName: String(localized: "\(profile.displayName) のコピー"))
        await save(copy, password: nil)
    }

    func updateGlobalSettings(_ settings: GlobalSettings) async {
        guard let repository else { return }
        do {
            try await repository.updateGlobalSettings(settings)
            await refresh()
        } catch {
            loadFailure = String(describing: error)
        }
    }

    /// Saves a password that was typed into a connection prompt rather than
    /// into the editor. A profile that never had one has no Keychain
    /// reference, so one is created and written back with the user name the
    /// connection actually succeeded with.
    func persistCredential(
        profileID: ProfileID,
        username: String,
        domain: String?,
        password: String
    ) async {
        guard let repository, var profile = profiles.first(where: { $0.id == profileID }) else {
            return
        }
        do {
            let reference = profile.account.credentialReference ?? CredentialReference()
            try credentials.store(password: password, for: reference)
            profile.account.credentialReference = reference
            profile.account.username = username
            profile.account.domain = domain
            try await repository.upsert(profile)
            await refresh()
        } catch {
            // The connection itself went ahead; only the saving failed, so the
            // list stays and says so once. (A Mac build signed without a team
            // cannot reach the Keychain: errSecMissingEntitlement.)
            listMessage = String(localized: "パスワードを保存できませんでした（\(String(describing: error))）。")
            logger.error("saving a connection credential failed")
        }
    }

    func storedPassword(for profile: ConnectionProfile) -> String? {
        guard let reference = profile.account.credentialReference else { return nil }
        return try? credentials.password(for: reference)
    }

    /// The magic packet, then a wait until the computer answers on its
    /// RDP port. Returns false when it never did.
    @discardableResult
    func wake(_ profile: ConnectionProfile, waitsForAnswer: Bool = true) async -> Bool {
        guard let wake = profile.wakeOnLAN else { return false }
        wakingProfileID = profile.id
        defer { wakingProfileID = nil }
        do {
            try await WakeOnLANSender.send(wake)
        } catch {
            listMessage = String(localized: "起動の合図を送れませんでした。MAC アドレスと送信先を確かめてください。")
            return false
        }
        guard waitsForAnswer else { return true }
        let answered = await WakeOnLANSender.waitUntilReachable(
            host: profile.endpoint.host,
            port: profile.endpoint.port,
            timeout: .seconds(120)
        )
        if !answered {
            listMessage = String(localized: "\(profile.displayName) が起動しませんでした（2 分待ちました）。")
        }
        return answered
    }

    func connect(to profile: ConnectionProfile) async {
        // The Mac: a window per session, the list stays where it is. The
        // window connects when it opens (SessionWindowRoot).
        if Platform.isMac, let openSessionWindow {
            openSessionWindow(profile.id.rawValue)
            return
        }
        await connect(to: profile, presents: true)
    }

    /// `presents` false for a session that opens in a window of its own.
    @discardableResult
    func connect(to profile: ConnectionProfile, presents: Bool) async -> SessionWorkspaceModel? {
        // A computer that may be asleep is woken first, unless it already
        // answers.
        if let wakeConfiguration = profile.wakeOnLAN, wakeConfiguration.wakesBeforeConnecting {
            wakingProfileID = profile.id
            let awake = await WakeOnLANSender.waitUntilReachable(
                host: profile.endpoint.host, port: profile.endpoint.port, timeout: .seconds(3)
            )
            if !awake {
                await self.wake(profile)
            }
            wakingProfileID = nil
        }
        guard let repository,
              let configuration = await repository.effectiveConfiguration(for: profile.id)
        else { return nil }

        do {
            let session = try await factories.makeSession(
                kind: profile.protocolKind,
                configuration: configuration
            )
            try await sessions.add(session)
            focusedSessionID = await sessions.focusedSessionID
            await sessions.applyVisibilityPolicy()
            try? await repository.markConnected(id: profile.id)
            await refresh()

            let model = SessionWorkspaceModel(
                environment: self,
                session: session,
                configuration: configuration
            )
            runningSessions.append(model)
            if presents {
                presentedSession = model
            } else {
                model.isWindowed = true
            }
            refreshAudioFocus()
            await model.start()
            return model
        } catch let error as SessionBudgetExceededError {
            loadFailure = String(localized: "同時接続はあと \(error.limit) セッションまでです。")
        } catch {
            loadFailure = String(describing: error)
        }
        return nil
    }

    /// Called when the workspace closes. Removing the session frees its budget
    /// slot; focus moves to whatever is still connected.
    func endSession(_ id: SessionID) async {
        _ = await sessions.remove(id)
        focusedSessionID = await sessions.focusedSessionID
        await sessions.applyVisibilityPolicy()
        runningSessions.removeAll { $0.id == id }
        if presentedSession?.id == id { presentedSession = nil }
        refreshAudioFocus()
    }

    func present(_ model: SessionWorkspaceModel) {
        // A session in a window of its own is shown there, never twice.
        if model.isWindowed {
            model.requestWindowFront?()
            return
        }
        // The Mac never shows a session over the list: a session whose window
        // was closed comes back in a new one.
        if Platform.isMac, let openSessionWindow, let profileID = model.configuration.profileID {
            openSessionWindow(profileID.rawValue)
            return
        }
        presentedSession = model
        Task { await focus(model.id) }
    }

    /// docs/ui-flow.md section 7: switching sessions. The old surface's gate
    /// closes when focus moves, which releases whatever it held, and the new
    /// one is built fresh from its session's retained frame.
    func switchTo(_ model: SessionWorkspaceModel) {
        guard presentedSession?.id != model.id else { return }
        presentedSession?.isMenuPresented = false
        presentedSession?.softwareKeyboard.hide()
        presentedSession?.captureThumbnail()
        present(model)
    }

    /// Back to the list with every connection kept (SES-02). Input focus goes
    /// with the workspace: nothing on the list may type into a session.
    func returnToList() {
        presentedSession?.captureThumbnail()
        presentedSession = nil
        Task { await focus(nil) }
    }

    func runningSession(for profile: ConnectionProfile) -> SessionWorkspaceModel? {
        runningSessions.last { $0.configuration.profileID == profile.id }
    }

    /// docs/architecture.md section 7.2: memory pressure sheds what can be
    /// rebuilt - the retained surfaces of sessions nobody is looking at - and
    /// never a connection.
    func handleMemoryWarning() {
        for model in runningSessions where model.id != focusedSessionID {
            model.frameStore?.discardRetained()
        }
        logger.notice("memory warning: released background surfaces")
    }

    /// Moves input focus. The view of the previous session sees its gate
    /// close through `focusedSessionID` and releases what it held before the
    /// new one can open.
    func focus(_ id: SessionID?) async {
        _ = await sessions.setFocus(to: id)
        focusedSessionID = await sessions.focusedSessionID
        await sessions.applyVisibilityPolicy()
        refreshAudioFocus()
    }

    /// Points the audio engine at the focused session, or at nothing.
    func refreshAudioFocus() {
        let focused = runningSessions.first { $0.id == focusedSessionID }
        AudioCoordinator.shared.setFocused(
            focused?.audioStream,
            muted: focused?.isAudioMuted ?? true
        )
    }
}

/// Stands in for a store that could not be located, so the failure surfaces
/// once at launch instead of on every save.
actor FailingProfileStore: ProfileStore {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func load() throws -> ProfileDocument {
        throw StoreError.malformedDocument(detail: reason)
    }

    func save(_ document: ProfileDocument) throws {
        throw StoreError.malformedDocument(detail: reason)
    }
}

/// The list's own sheets, opened from the Mac's menu bar.
enum ListRequest {
    case settings
    case newConnection
}
