import Foundation
import AppleAdapters
import InputCore
import Persistence
import SessionCore
import SSHProtocol

/// Lets the UI test drive the real screens without a Windows host, a Keychain
/// entitlement or a file store that would leak between runs.
///
/// It is keyed off a launch argument rather than a build configuration so the
/// same binary is exercised, and it only ever substitutes the outermost
/// dependencies - the views and models under test are the shipping ones.
enum UITestConfiguration {
    static let launchArgument = "-mremote-ui-testing"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Device settings a test changes through the UI, cleared on launch so
    /// one test's choice is not the next one's starting point.
    static let resetDefaultsKeys = [
        LaptopDeckPreference.storageKey,
        LaptopDeckPreference.foldedLandscapeStorageKey,
        LaptopDeckPlacement.storageKey,
        LaptopDeckArrangement.splitInLandscapeStorageKey,
        KeyboardButtonTarget.storageKey,
        FloatingButtonsIdleStyle.storageKey,
        KeyShortcutList.storageKey,
        DeckShortcutStrip.storageKey,
        ExternalDisplayMode.storageKey,
        PencilInput.storageKey,
        MacSwipeGestureMode.storageKey,
        MacPinchGestures.storageKey,
        FoldResolutionPolicy.storageKey,
        DesktopSafeAreaPolicy.storageKey,
        DeckLayout.portraitFractionKey,
        DeckLayout.landscapeFractionKey,
        DeckLayout.splitFractionKey,
        FloatingDeckFrame.storageKey,
    ]

    @MainActor
    static func makeEnvironment() -> AppEnvironment {
        for key in resetDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let seeded = ConnectionProfile(
            displayName: "テスト接続先",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            account: RemoteAccount(username: "tester", domain: nil)
        )
        var profiles = [seeded]
        let credentials = InMemoryCredentialRepository()
        let knownHosts = InMemoryKnownHostRepository()
        let keys = InMemorySSHKeyRepository()
        var factories: [any RemoteSessionFactory] = [FakeSessionFactory()]
        // A real sshd for the live SSH UI test (AppUITests/LiveSSHUITests):
        // the profile and its key come from the test, in memory only.
        let environment = ProcessInfo.processInfo.environment
        if let portText = environment["MREMOTE_UITEST_SSH_PORT"], let port = UInt16(portText),
           let user = environment["MREMOTE_UITEST_SSH_USER"],
           let keyBase64 = environment["MREMOTE_UITEST_SSH_KEY"], let keyFile = Data(base64Encoded: keyBase64),
           let key = try? OpenSSHKey(parsing: keyFile) {
            let metadata = SSHKeyMetadata(
                name: "テスト鍵", keyType: key.keyType, publicKey: key.publicKeyLine,
                fingerprint: key.fingerprint, isEncrypted: key.isEncrypted)
            try? keys.store(metadata, privateKey: keyFile)
            profiles.append(ConnectionProfile(
                displayName: "テスト SSH",
                endpoint: RemoteEndpoint(host: environment["MREMOTE_UITEST_SSH_HOST"] ?? "127.0.0.1", port: port),
                account: RemoteAccount(username: user),
                configuration: .ssh(SSHConfiguration(
                    authentication: SSHAuthentication(keyID: metadata.id),
                    startupCommand: environment["MREMOTE_UITEST_SSH_STARTUP"]))))
            factories.append(SSHSessionFactory(credentials: credentials, knownHosts: knownHosts, keys: keys))
        }
        return AppEnvironment(
            store: InMemoryProfileStore(document: ProfileDocument(profiles: profiles)),
            credentials: credentials,
            trust: InMemoryTrustRepository(),
            knownHosts: knownHosts,
            sshKeys: keys,
            factories: SessionFactoryRegistry(factories: factories)
        )
    }
}
