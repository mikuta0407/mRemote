import XCTest
import SessionCore
@testable import SSHProtocol

final class SSHConfigProfilesTests: XCTestCase {
    private let key = SSHConfigProfiles.StoredKey(id: SSHKeyID(), name: "id_ed25519")

    func testAPlanAddsHostsLinksJumpsAndKeepsWhatTheFileDoesNotSay() throws {
        var existing = ConnectionProfile(
            displayName: "bastion", endpoint: RemoteEndpoint(host: "old.example.com", port: 22),
            account: RemoteAccount(username: "old"),
            configuration: .ssh(SSHConfiguration(startupCommand: "tmux", keepAliveSeconds: .explicit(10))))
        existing.group = "仕事"
        let file = SSHConfigFile(parsing: """
        Host bastion
            HostName bastion.example.com
            TCPKeepAlive no
        Host inner
            HostName 10.0.0.2
            Port 2022
            User me
            IdentityFile ~/.ssh/id_ed25519
            ProxyJump bastion
            ServerAliveInterval 20
        Host other
            IdentityFile ~/.ssh/missing_key
        """)
        let plan = SSHConfigProfiles.plan(file, existing: [existing], keys: [key])
        XCTAssertEqual(plan.items.map(\.alias), ["bastion", "inner", "other"])

        let bastion = plan.items[0]
        XCTAssertTrue(bastion.replacesExisting)
        XCTAssertEqual(bastion.profile.id, existing.id)
        XCTAssertEqual(bastion.profile.endpoint, RemoteEndpoint(host: "bastion.example.com", port: 22))
        XCTAssertEqual(bastion.profile.account.username, "old", "no User in the file: the connection's stays")
        XCTAssertEqual(bastion.profile.group, "仕事")
        XCTAssertEqual(bastion.profile.configuration.ssh?.startupCommand, "tmux")
        XCTAssertEqual(bastion.profile.configuration.ssh?.keepAliveSeconds, .explicit(0))

        let inner = plan.items[1]
        XCTAssertFalse(inner.replacesExisting)
        XCTAssertEqual(inner.profile.endpoint, RemoteEndpoint(host: "10.0.0.2", port: 2022))
        XCTAssertEqual(inner.profile.account.username, "me")
        XCTAssertEqual(inner.profile.configuration.ssh?.authentication.keyID, key.id)
        XCTAssertEqual(inner.profile.configuration.ssh?.jumpProfileID, existing.id)
        XCTAssertEqual(inner.profile.configuration.ssh?.keepAliveSeconds, .explicit(20))
        XCTAssertNil(inner.missingKey)

        XCTAssertEqual(plan.items[2].missingKey, "missing_key")
        XCTAssertEqual(plan.items[2].profile.configuration.ssh?.keepAliveSeconds, .inherit)
    }

    func testExportedConnectionsComeBackAsThemselves() throws {
        let bastion = ConnectionProfile(
            displayName: "踏み台 A", endpoint: RemoteEndpoint(host: "bastion.example.com", port: 22),
            account: RemoteAccount(username: "me"),
            configuration: .ssh(SSHConfiguration(authentication: SSHAuthentication(keyID: key.id),
                                                 keepAliveSeconds: .explicit(0))))
        let inner = ConnectionProfile(
            displayName: "inner", endpoint: RemoteEndpoint(host: "10.0.0.2", port: 2022),
            configuration: .ssh(SSHConfiguration(keepAliveSeconds: .explicit(45), jumpProfileID: bastion.id)))
        let rdp = ConnectionProfile(displayName: "windows", endpoint: RemoteEndpoint(host: "w", port: 3389))
        // Only inner chosen: its jump host comes along, the RDP one does not.
        let file = SSHConfigProfiles.file(for: [inner, rdp], all: [bastion, inner, rdp],
                                          keyNames: [key.id: key.name])
        XCTAssertEqual(file.hosts.map(\.alias), ["inner", "踏み台-A"])
        XCTAssertEqual(file.hosts[0].jump, "踏み台-A")
        XCTAssertEqual(file.hosts[1].identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(file.hosts[1].tcpKeepAlive, false)

        let plan = SSHConfigProfiles.plan(SSHConfigFile(parsing: file.text), existing: [bastion, inner, rdp],
                                          keys: [key])
        XCTAssertTrue(plan.items.allSatisfy(\.replacesExisting), "matched by the alias their names became")
        // Jump hosts are read first.
        XCTAssertEqual(plan.items.map(\.profile), [bastion, inner])
    }

    func testTwoConnectionsWithOneAliasGetTwo() {
        let a = ConnectionProfile(displayName: "web", endpoint: RemoteEndpoint(host: "a", port: 22),
                                  configuration: .ssh(SSHConfiguration()))
        let b = ConnectionProfile(displayName: "web", endpoint: RemoteEndpoint(host: "b", port: 22),
                                  configuration: .ssh(SSHConfiguration()))
        XCTAssertEqual(SSHConfigProfiles.file(for: [a, b], all: [a, b], keyNames: [:]).hosts.map(\.alias),
                       ["web", "web-2"])
    }
}
