import XCTest
@testable import SSHProtocol

final class SSHConfigFileTests: XCTestCase {
    func testTheFirstValueWinsAndWildcardsSupplyDefaults() throws {
        let file = SSHConfigFile(parsing: """
        # mine
        User everyone

        Host web web2
            HostName %h.example.com
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
            IdentityFile ~/.ssh/other
            ForwardAgent yes

        Host db
            HostName=10.0.0.5
            User "db admin"
            ServerAliveInterval 15

        Host *.internal !skip.internal
            TCPKeepAlive no

        Host *
            User fallback
            Port 22
            ServerAliveInterval 60
        """)
        XCTAssertEqual(file.hosts.map(\.alias), ["web", "web2", "db"])
        let web = file.hosts[0]
        XCTAssertEqual(web.hostName, "web.example.com")
        XCTAssertEqual(web.port, 2222)
        XCTAssertEqual(web.user, "everyone", "lines before the first Host apply to all, and come first")
        XCTAssertEqual(web.identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(web.identityName, "id_ed25519")
        XCTAssertEqual(web.serverAliveInterval, 60)
        XCTAssertEqual(file.hosts[1].hostName, "web2.example.com")
        let db = file.hosts[2]
        XCTAssertEqual(db.hostName, "10.0.0.5")
        XCTAssertEqual(db.user, "everyone")
        XCTAssertEqual(db.port, 22)
        XCTAssertEqual(db.serverAliveInterval, 15)
        XCTAssertNil(db.tcpKeepAlive)
        XCTAssertEqual(file.unread, ["ForwardAgent"])
    }

    func testProxyJumpLinksHostsAndMakesTheOnesItNames() throws {
        let file = SSHConfigFile(parsing: """
        Host bastion
            HostName bastion.example.com
            User jumper
            TCPKeepAlive no

        Host inner
            HostName 10.1.0.2
            ProxyJump bastion

        Host deep
            HostName 10.2.0.3
            ProxyJump ops@gate.example.com:2200,bastion

        Host loop
            ProxyJump loop

        Match host foo
            User ignored
        Include ~/.ssh/more
        """)
        func host(_ alias: String) throws -> SSHConfigFile.Host {
            try XCTUnwrap(file.hosts.first { $0.alias == alias }, "no \(alias) in \(file.hosts.map(\.alias))")
        }
        XCTAssertEqual(try host("bastion").tcpKeepAlive, false)
        XCTAssertEqual(try host("inner").jump, "bastion")
        // A chain: bastion is reached through the first hop there, so it is
        // a variant of its own.
        let gate = try host("ops@gate.example.com:2200")
        XCTAssertEqual(gate.hostName, "gate.example.com")
        XCTAssertEqual(gate.user, "ops")
        XCTAssertEqual(gate.port, 2200)
        XCTAssertNil(gate.jump)
        let viaGate = try host("bastion via ops@gate.example.com:2200")
        XCTAssertEqual(viaGate.hostName, "bastion.example.com")
        XCTAssertEqual(viaGate.user, "jumper")
        XCTAssertEqual(try host("deep").jump, viaGate.alias)
        XCTAssertNil(try host("loop").jump, "a host cannot be its own jump host")
        XCTAssertEqual(Set(file.unread), ["Match", "Include"])
        // Jump hosts come before the hosts that use them.
        let order = file.hosts.map(\.alias)
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: gate.alias)), try XCTUnwrap(order.firstIndex(of: "deep")))
    }

    func testAJumpWithTheSameSettingsIsTheHostItself() throws {
        let file = SSHConfigFile(parsing: """
        Host target
            ProxyJump jumper@bastion
        Host bastion
            User jumper
        """)
        XCTAssertEqual(file.hosts.map(\.alias), ["bastion", "target"])
        XCTAssertEqual(file.hosts[1].jump, "bastion")
    }

    func testHops() {
        XCTAssertEqual(SSHConfigFile.hop("a")?.host, "a")
        XCTAssertEqual(SSHConfigFile.hop("u@a:23")?.user, "u")
        XCTAssertEqual(SSHConfigFile.hop("u@a:23")?.port, 23)
        XCTAssertEqual(SSHConfigFile.hop("ssh://[fe80::1]:2222")?.host, "fe80::1")
        XCTAssertEqual(SSHConfigFile.hop("ssh://[fe80::1]:2222")?.port, 2222)
        XCTAssertEqual(SSHConfigFile.hop("fe80::1")?.host, "fe80::1", "a bare IPv6 address has no port")
        XCTAssertNil(SSHConfigFile.hop(""))
    }

    func testWritingReadsBack() {
        let hosts = [
            SSHConfigFile.Host(alias: "踏み台 1", hostName: "bastion.example.com", port: 22, user: "me",
                               identityFile: "~/.ssh/work key", tcpKeepAlive: false),
            SSHConfigFile.Host(alias: "inner", hostName: "10.0.0.2", port: 2022, jump: "踏み台 1",
                               serverAliveInterval: 30),
        ]
        let text = SSHConfigFile(hosts: hosts).text
        XCTAssertTrue(text.contains("Host 踏み台-1\n"), text)
        XCTAssertFalse(text.contains("Port 22\n"), "the default port is left out")
        let read = SSHConfigFile(parsing: text)
        XCTAssertEqual(read.hosts.map(\.alias), ["踏み台-1", "inner"])
        XCTAssertEqual(read.hosts[0].identityFile, "~/.ssh/work key")
        XCTAssertEqual(read.hosts[0].tcpKeepAlive, false)
        XCTAssertEqual(read.hosts[1].jump, "踏み台-1")
        XCTAssertEqual(read.hosts[1].port, 2022)
        XCTAssertEqual(read.hosts[1].serverAliveInterval, 30)
        XCTAssertTrue(read.unread.isEmpty, "\(read.unread)")
    }
}
