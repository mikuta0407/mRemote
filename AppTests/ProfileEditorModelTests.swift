import XCTest
import SessionCore
@testable import mRemote

@MainActor
final class ProfileEditorModelTests: XCTestCase {
    func testHostAndPortAreRequired() {
        let model = ProfileEditorModel(mode: .create)
        XCTAssertFalse(model.isValid)

        model.host = "desk.example"
        XCTAssertTrue(model.isValid)

        model.portText = "0"
        XCTAssertFalse(model.isValid, "port 0 is not a usable port")

        model.portText = "70000"
        XCTAssertFalse(model.isValid, "a port above 65535 does not fit")

        model.portText = "3390"
        XCTAssertTrue(model.isValid)
    }

    func testAnEmptyPortIsTheRDPDefault() throws {
        let model = ProfileEditorModel(mode: .create)
        model.host = "desk.example"
        XCTAssertEqual(model.portText, "", "a new connection starts with the port left blank")
        XCTAssertTrue(model.isValid)
        let profile = try XCTUnwrap(model.makeProfile())
        XCTAssertEqual(profile.endpoint.port, 3389)
        // Editing shows a 3389 connection's port blank again, any other as typed.
        XCTAssertEqual(ProfileEditorModel(mode: .edit(profile)).portText, "")
        model.portText = " 3390 "
        let other = try XCTUnwrap(model.makeProfile())
        XCTAssertEqual(ProfileEditorModel(mode: .edit(other)).portText, "3390")
    }

    func testAnImportIsANewProfileThatKeepsTheFilesSettings() throws {
        let file = RDPFile(text: "full address:s:pc.example:3390\nusername:s:CORP\\taro\naudiomode:i:2")
        let imported = try XCTUnwrap(file.profile(named: "会社"))
        let model = ProfileEditorModel(mode: .importing(imported, unsupported: ["RD Gateway"]))
        XCTAssertTrue(model.isImport)
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.title, "接続先を読み込む")
        XCTAssertEqual(model.host, "pc.example")
        XCTAssertEqual(model.portText, "3390")
        XCTAssertEqual(model.username, "taro")
        XCTAssertEqual(model.domain, "CORP")
        XCTAssertEqual(model.unsupportedImportSettings, ["RD Gateway"])
        let profile = try XCTUnwrap(model.makeProfile())
        XCTAssertEqual(profile.displayName, "会社")
        XCTAssertEqual(profile.configuration.rdp?.audioPlayback, .explicit(false))
    }

    func testDisplayNameFallsBackToTheHost() {
        let model = ProfileEditorModel(mode: .create)
        model.host = "  desk.example  "
        let profile = model.makeProfile()
        XCTAssertEqual(profile?.displayName, "desk.example")
        XCTAssertEqual(profile?.endpoint.host, "desk.example")
    }

    func testTheProxyIsKeptAndCanBeCleared() {
        let proxy = ProxyID()
        var existing = ConnectionProfile(
            displayName: "shell",
            endpoint: RemoteEndpoint(host: "shell.example", port: 22),
            configuration: .ssh(SSHConfiguration()))
        existing.proxyID = proxy
        let model = ProfileEditorModel(mode: .edit(existing))
        XCTAssertEqual(model.proxyID, proxy)
        XCTAssertEqual(model.makeProfile()?.proxyID, proxy)
        model.proxyID = nil
        XCTAssertNil(model.makeProfile()?.proxyID)

        let rdp = ProfileEditorModel(mode: .create)
        rdp.host = "desk.example"
        rdp.proxyID = proxy
        XCTAssertEqual(rdp.makeProfile()?.proxyID, proxy)
    }

    func testEditingKeepsTheIdentityAndCredentialReference() {
        let reference = CredentialReference()
        var existing = ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            account: RemoteAccount(username: "user", credentialReference: reference)
        )
        existing.lastConnectedAt = Date(timeIntervalSince1970: 1)

        let model = ProfileEditorModel(mode: .edit(existing))
        model.displayName = "desk renamed"
        let updated = model.makeProfile()

        XCTAssertEqual(updated?.id, existing.id)
        XCTAssertEqual(updated?.displayName, "desk renamed")
        XCTAssertEqual(updated?.account.credentialReference, reference)
        XCTAssertEqual(updated?.lastConnectedAt, existing.lastConnectedAt)
    }

    func testEmptyUsernameBecomesNilRatherThanAnEmptyString() {
        let model = ProfileEditorModel(mode: .create)
        model.host = "desk.example"
        model.username = ""
        model.domain = ""
        let profile = model.makeProfile()
        XCTAssertNil(profile?.account.username)
        XCTAssertNil(profile?.account.domain)
    }

    func testJapaneseKeyWarningOnlyForNonJapaneseLayouts() {
        let model = ProfileEditorModel(mode: .create)
        XCTAssertFalse(model.showsJapaneseKeyWarning, "inherit must not warn on its own")

        model.keyboardLayout = .explicit(.japanese)
        XCTAssertFalse(model.showsJapaneseKeyWarning)

        model.keyboardLayout = .explicit(.us)
        XCTAssertTrue(model.showsJapaneseKeyWarning)
    }

    func testLegacySecurityIsFlagged() {
        let model = ProfileEditorModel(mode: .create)
        XCTAssertFalse(model.showsLegacySecurityWarning)
        model.securityPolicy = .legacyExplicit
        XCTAssertTrue(model.showsLegacySecurityWarning)
    }

    func testChoosingLegacySecurityAsksFirst() {
        let model = ProfileEditorModel(mode: .create)
        model.choose(.legacyExplicit)
        XCTAssertTrue(model.isConfirmingLegacySecurity)
        XCTAssertEqual(model.securityPolicy, .secureAutomatic, "nothing changes before consent")
        model.declineLegacySecurity()
        XCTAssertEqual(model.securityPolicy, .secureAutomatic)

        model.choose(.legacyExplicit)
        model.confirmLegacySecurity()
        XCTAssertEqual(model.securityPolicy, .legacyExplicit)
        XCTAssertFalse(model.isConfirmingLegacySecurity)

        model.choose(.nlaRequired)
        XCTAssertEqual(model.securityPolicy, .nlaRequired, "leaving legacy needs no consent")
        XCTAssertFalse(model.isConfirmingLegacySecurity)
    }

    func testConfigurationIsCarriedIntoTheProfile() {
        let model = ProfileEditorModel(mode: .create)
        model.host = "desk.example"
        model.clipboardPolicy = .explicit(.receiveOnly)
        model.scrollDirection = .explicit(.reversed)
        model.audioPlayback = .explicit(false)

        let rdp = model.makeProfile()?.configuration.rdp
        XCTAssertEqual(rdp?.clipboardPolicy, .explicit(.receiveOnly))
        XCTAssertEqual(rdp?.scrollDirection, .explicit(.reversed))
        XCTAssertEqual(rdp?.audioPlayback, .explicit(false))
    }

    func testTheResolutionIsSavedAndWhatTheFormDoesNotShowIsKept() {
        let existing = ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            configuration: .rdp(RDPConfiguration(initialScale: .explicit(.oneToOne)))
        )
        let model = ProfileEditorModel(mode: .edit(existing))
        XCTAssertEqual(model.resolutionPolicy, .inherit)

        model.resolutionPolicy = .explicit(.fixed(width: 1_920, height: 1_080))
        let rdp = model.makeProfile()?.configuration.rdp
        XCTAssertEqual(rdp?.resolutionPolicy, .explicit(.fixed(width: 1_920, height: 1_080)))
        XCTAssertEqual(rdp?.initialScale, .explicit(.oneToOne))
        XCTAssertEqual(
            ProfileEditorModel(mode: .edit(model.makeProfile()!)).resolutionPolicy,
            .explicit(.fixed(width: 1_920, height: 1_080))
        )
    }

    func testResolutionLabelsNameTheAspectRatio() {
        XCTAssertEqual(Formatting.resolutionLabel(.fixed(width: 1_920, height: 1_080)), "1920×1080（16:9）")
        XCTAssertEqual(Formatting.resolutionLabel(.fixed(width: 1_280, height: 1_024)), "1280×1024（5:4）")
        XCTAssertEqual(Formatting.resolutionLabel(.fixed(width: 1_366, height: 768)), "1366×768（16:9）")
        XCTAssertEqual(Formatting.resolutionLabel(.fixed(width: 1_280, height: 768)), "1280×768")
    }
}
