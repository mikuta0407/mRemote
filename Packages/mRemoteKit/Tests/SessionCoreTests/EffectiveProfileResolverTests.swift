import XCTest
@testable import SessionCore

final class EffectiveProfileResolverTests: XCTestCase {
    private func profile(_ rdp: RDPConfiguration) -> ConnectionProfile {
        ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            configuration: .rdp(rdp)
        )
    }

    func testInheritTakesTheGlobalValue() {
        let settings = GlobalSettings(keyboardLayout: .us, scrollDirection: .reversed)
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration()),
            globalSettings: settings
        )
        XCTAssertEqual(resolved.keyboardLayout, .us)
        XCTAssertEqual(resolved.scrollDirection, .reversed)
    }

    func testExplicitOverridesTheGlobalValue() {
        let settings = GlobalSettings(scrollDirection: .reversed)
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(scrollDirection: .explicit(.normal))),
            globalSettings: settings
        )
        XCTAssertEqual(resolved.scrollDirection, .normal)
    }

    func testSecurityPolicyHasNoGlobalOverride() {
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(securityPolicy: .nlaRequired)),
            globalSettings: .default
        )
        XCTAssertEqual(resolved.securityPolicy, .nlaRequired)
    }

    func testJapaneseKeyGuaranteeFollowsLayout() {
        let japanese = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(keyboardLayout: .explicit(.japanese))),
            globalSettings: .default
        )
        let us = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(keyboardLayout: .explicit(.us))),
            globalSettings: .default
        )
        XCTAssertTrue(japanese.guaranteesJapaneseImeKeys)
        XCTAssertFalse(us.guaranteesJapaneseImeKeys)
    }

    func testRuntimeStateStartsFromResolvedConfiguration() {
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(
                resolutionPolicy: .explicit(.fixed(width: 1_600, height: 900)),
                initialScale: .explicit(.oneToOne),
                scrollDirection: .explicit(.reversed)
            )),
            globalSettings: .default
        )
        let runtime = SessionRuntimeState(from: resolved)
        XCTAssertEqual(runtime.resolution, .fixed(width: 1_600, height: 900))
        XCTAssertEqual(runtime.scale, .oneToOne)
        XCTAssertEqual(runtime.scrollDirection, .reversed)
        XCTAssertEqual(runtime.zoom, 1.0)
    }

    func testDuplicateDropsCredentialAndConnectionHistory() {
        var original = profile(RDPConfiguration())
        original.account.credentialReference = CredentialReference()
        original.lastConnectedAt = Date()

        let copy = original.duplicated(displayName: "desk copy")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNil(copy.account.credentialReference)
        XCTAssertNil(copy.lastConnectedAt)
        XCTAssertEqual(copy.configuration, original.configuration)
    }

    func testAGatewayAndAFolderReachTheConnectionAndDuplicatesDropTheGatewayPassword() {
        var gateway = RDPGatewayConfiguration(host: "gw.example", usesComputerCredentials: false)
        gateway.account = RemoteAccount(username: "gw", credentialReference: CredentialReference())
        let folder = SharedFolder(location: .appDocuments, driveName: "iPad")
        let original = profile(RDPConfiguration(gateway: gateway, sharedFolder: folder))
        let resolved = EffectiveProfileResolver().resolve(profile: original, globalSettings: .default)
        XCTAssertEqual(resolved.gateway?.host, "gw.example")
        XCTAssertEqual(resolved.sharedFolder, folder)
        let copy = original.duplicated(displayName: "copy")
        XCTAssertNil(copy.configuration.rdp?.gateway?.account.credentialReference)
        XCTAssertEqual(copy.configuration.rdp?.gateway?.host, "gw.example")
    }

    /// Documents written before the gateway and the folder existed read as
    /// having neither.
    func testOlderConfigurationsDecodeWithoutTheNewFields() throws {
        let encoded = try JSONEncoder().encode(RDPConfiguration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "gateway")
        object.removeValue(forKey: "sharedFolder")
        let decoded = try JSONDecoder().decode(
            RDPConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.gateway)
        XCTAssertNil(decoded.sharedFolder)
    }

    func testDriveNamesKeepToWhatServersAccept() {
        XCTAssertEqual(SharedFolder.sanitizedDriveName("My Files: 2026/10"), "My Files 202610")
        XCTAssertEqual(SharedFolder.sanitizedDriveName("書類"), "mRemote")
        XCTAssertEqual(SharedFolder.sanitizedDriveName(String(repeating: "a", count: 40)).count, 32)
    }

    func testIPLiteralDetection() {
        XCTAssertTrue(RemoteEndpoint(host: "192.168.1.10", port: 3389).isIPLiteral)
        XCTAssertTrue(RemoteEndpoint(host: "fe80::1", port: 3389).isIPLiteral)
        XCTAssertTrue(RemoteEndpoint(host: "[fe80::1]", port: 3389).isIPLiteral)
        XCTAssertFalse(RemoteEndpoint(host: "desk.example", port: 3389).isIPLiteral)
        XCTAssertFalse(RemoteEndpoint(host: "192.168.1", port: 3389).isIPLiteral)
    }
}

final class SSHProfileResolverTests: XCTestCase {
    private func profile(_ ssh: SSHConfiguration) -> ConnectionProfile {
        ConnectionProfile(
            displayName: "shell",
            endpoint: RemoteEndpoint(host: "shell.example", port: 22),
            account: RemoteAccount(username: "dev"),
            configuration: .ssh(ssh)
        )
    }

    private var desk: ConnectionProfile {
        ConnectionProfile(displayName: "desk", endpoint: RemoteEndpoint(host: "desk.example", port: 3389))
    }

    func testTheProxyIsLookedUpForBothProtocols() {
        let proxy = ProxyServer(host: "socks.example")
        var desk = desk
        desk.proxyID = proxy.id
        var shell = profile(SSHConfiguration())
        shell.proxyID = proxy.id
        let resolver = EffectiveProfileResolver()
        XCTAssertEqual(resolver.resolve(profile: desk, globalSettings: .default, proxies: [proxy]).proxy, proxy)
        XCTAssertEqual(resolver.resolve(profile: shell, globalSettings: .default, proxies: [proxy]).proxy, proxy)
        // None chosen, or one that is gone: a direct connection.
        XCTAssertNil(resolver.resolve(profile: self.desk, globalSettings: .default, proxies: [proxy]).proxy)
        XCTAssertNil(resolver.resolve(profile: desk, globalSettings: .default, proxies: []).proxy)
    }

    func testADuplicateKeepsTheProxy() {
        var desk = desk
        desk.proxyID = ProxyID()
        XCTAssertEqual(desk.duplicated(displayName: "copy").proxyID, desk.proxyID)
    }

    func testAProxyIsShownByNameOrAddress() {
        XCTAssertEqual(ProxyServer(name: " office ", host: "h").displayName, "office")
        XCTAssertEqual(ProxyServer(host: "socks.example").displayName, "socks.example:1080")
        XCTAssertEqual(ProxyServer(host: "::1", port: 9050).displayName, "[::1]:9050")
    }

    func testTerminalSettingsInheritTheGlobalDefaults() {
        var settings = GlobalSettings()
        settings.terminal = TerminalDefaults(fontSize: 17, theme: .dark, optionAsMeta: false)
        let resolved = EffectiveProfileResolver().resolve(profile: profile(SSHConfiguration()), globalSettings: settings)
        XCTAssertEqual(resolved.protocolKind, .ssh)
        let ssh = try! XCTUnwrap(resolved.ssh)
        XCTAssertEqual(ssh.fontSize, 17)
        XCTAssertEqual(ssh.theme, .dark)
        XCTAssertFalse(ssh.optionAsMeta)
        XCTAssertEqual(ssh.terminalType, "xterm-256color")
        XCTAssertNil(ssh.startupCommand)
    }

    func testExplicitTerminalSettingsWinAndAreClamped() {
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(SSHConfiguration(startupCommand: "  tmux a  ", terminalType: " ", fontSize: .explicit(200))),
            globalSettings: .default
        )
        XCTAssertEqual(resolved.ssh?.fontSize, TerminalDefaults.fontSizeRange.upperBound)
        XCTAssertEqual(resolved.ssh?.startupCommand, "tmux a")
        XCTAssertEqual(resolved.ssh?.terminalType, "xterm-256color")
    }

    /// A reconnect is a new shell, so SSH does not reconnect by itself unless
    /// the profile asks for it - whatever the global RDP default says.
    func testSSHDoesNotReconnectByDefault() {
        let settings = GlobalSettings(reconnectPolicy: .automatic)
        let resolved = EffectiveProfileResolver().resolve(profile: profile(SSHConfiguration()), globalSettings: settings)
        XCTAssertEqual(resolved.reconnectPolicy, .disabled)
    }

    func testAnRDPProfileHasNoSSHSettings() {
        let rdp = ConnectionProfile(displayName: "d", endpoint: RemoteEndpoint(host: "d", port: 3389))
        let resolved = EffectiveProfileResolver().resolve(profile: rdp, globalSettings: .default)
        XCTAssertEqual(resolved.protocolKind, .rdp)
        XCTAssertNil(resolved.ssh)
    }
}

final class TerminalOutputBufferTests: XCTestCase {
    func testBytesComeOutInOrderAcrossTheWrap() {
        let buffer = TerminalOutputBuffer(capacity: 8)
        XCTAssertEqual(buffer.append([1, 2, 3, 4, 5, 6]), 6)
        XCTAssertEqual(buffer.drain(maximum: 4), [1, 2, 3, 4])
        XCTAssertEqual(buffer.append([7, 8, 9, 10, 11]), 5)
        XCTAssertEqual(buffer.drain(), [5, 6, 7, 8, 9, 10, 11])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testAFullBufferTakesWhatFitsAndWakesTheWriterOnDrain() {
        let buffer = TerminalOutputBuffer(capacity: 4)
        let woken = LockedCounter()
        buffer.setSpaceAvailableHandler { woken.increment() }
        XCTAssertEqual(buffer.append([1, 2, 3, 4, 5, 6]), 4)
        XCTAssertEqual(woken.value, 0)
        XCTAssertEqual(buffer.drain(maximum: 1), [1])
        XCTAssertEqual(woken.value, 1)
        // No refused append since: no second wake.
        _ = buffer.drain()
        XCTAssertEqual(woken.value, 1)
    }

    func testTheReaderIsNotifiedOncePerBatch() {
        let buffer = TerminalOutputBuffer(capacity: 64)
        let notified = LockedCounter()
        buffer.setReadableHandler { notified.increment() }
        _ = buffer.append([1])
        _ = buffer.append([2])
        XCTAssertEqual(notified.value, 1)
        _ = buffer.drain()
        _ = buffer.append([3])
        XCTAssertEqual(notified.value, 2)
    }

    func testConcurrentWriterAndReaderLoseNothing() {
        let buffer = TerminalOutputBuffer(capacity: 1024)
        let total = 200_000
        let writer = Thread {
            var next = 0
            while next < total {
                let chunk = (next..<min(next + 300, total)).map { UInt8(truncatingIfNeeded: $0) }
                var offset = 0
                while offset < chunk.count {
                    offset += chunk[offset...].withContiguousStorageIfAvailable { buffer.append(UnsafeRawBufferPointer($0)) } ?? 0
                    if offset < chunk.count { usleep(50) }
                }
                next += chunk.count
            }
        }
        writer.start()
        var received = 0
        var ok = true
        let deadline = Date().addingTimeInterval(20)
        while received < total, Date() < deadline {
            for byte in buffer.drain(maximum: 500) {
                if byte != UInt8(truncatingIfNeeded: received) { ok = false }
                received += 1
            }
        }
        XCTAssertEqual(received, total)
        XCTAssertTrue(ok)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
