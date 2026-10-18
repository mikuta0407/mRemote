import XCTest
import SessionCore
@testable import Persistence

final class ProfileRepositoryTests: XCTestCase {
    private func profile(_ name: String, credential: CredentialReference? = nil) -> ConnectionProfile {
        ConnectionProfile(
            displayName: name,
            endpoint: RemoteEndpoint(host: "\(name).example", port: 3389),
            account: RemoteAccount(credentialReference: credential)
        )
    }

    func testUpsertAddsThenUpdates() async throws {
        let repository = try await ProfileRepository(store: InMemoryProfileStore())
        var desk = profile("desk")
        try await repository.upsert(desk)
        await AsyncAssertEqual(await repository.profiles.count, 1)

        desk.displayName = "desk renamed"
        try await repository.upsert(desk)
        let profiles = await repository.profiles
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.displayName, "desk renamed")
    }

    func testProfilesAreSortedByDisplayName() async throws {
        let repository = try await ProfileRepository(store: InMemoryProfileStore())
        try await repository.upsert(profile("zeta"))
        try await repository.upsert(profile("alpha"))
        let names = await repository.profiles.map(\.displayName)
        XCTAssertEqual(names, ["alpha", "zeta"])
    }

    func testDeleteReportsAnOrphanedCredential() async throws {
        let repository = try await ProfileRepository(store: InMemoryProfileStore())
        let credential = CredentialReference()
        let desk = profile("desk", credential: credential)
        try await repository.upsert(desk)

        let orphaned = try await repository.delete(id: desk.id)
        XCTAssertEqual(orphaned, credential)
    }

    func testDeleteKeepsACredentialThatIsStillShared() async throws {
        let repository = try await ProfileRepository(store: InMemoryProfileStore())
        let credential = CredentialReference()
        let first = profile("first", credential: credential)
        let second = profile("second", credential: credential)
        try await repository.upsert(first)
        try await repository.upsert(second)

        let orphaned = try await repository.delete(id: first.id)
        XCTAssertNil(orphaned, "a credential another profile still uses must not be reported")
    }

    func testEffectiveConfigurationUsesCurrentGlobalSettings() async throws {
        let repository = try await ProfileRepository(store: InMemoryProfileStore())
        let desk = profile("desk")
        try await repository.upsert(desk)
        try await repository.updateGlobalSettings(GlobalSettings(scrollDirection: .reversed))

        let resolved = await repository.effectiveConfiguration(for: desk.id)
        XCTAssertEqual(resolved?.scrollDirection, .reversed)
    }

    func testAProfileConnectsThroughItsProxy() async throws {
        let repository = try await ProfileRepository(store: InMemoryProfileStore())
        let proxy = ProxyServer(host: "socks.example")
        try await repository.upsertProxy(proxy)
        var desk = profile("desk")
        desk.proxyID = proxy.id
        try await repository.upsert(desk)

        let resolved = await repository.effectiveConfiguration(for: desk.id)
        XCTAssertEqual(resolved?.proxy, proxy)

        // An edit reaches every profile that uses it.
        var moved = proxy
        moved.port = 9050
        try await repository.upsertProxy(moved)
        await AsyncAssertEqual(await repository.effectiveConfiguration(for: desk.id)?.proxy?.port, 9050)
        await AsyncAssertEqual(await repository.proxies.count, 1)
    }

    func testDeletingAProxyMakesItsProfilesDirect() async throws {
        let store = InMemoryProfileStore()
        let repository = try await ProfileRepository(store: store)
        let proxy = ProxyServer(host: "socks.example")
        let other = ProxyServer(host: "other.example")
        try await repository.upsertProxy(proxy)
        try await repository.upsertProxy(other)
        var first = profile("first")
        first.proxyID = proxy.id
        var second = profile("second")
        second.proxyID = proxy.id
        var third = profile("third")
        third.proxyID = other.id
        for item in [first, second, third] { try await repository.upsert(item) }
        await AsyncAssertEqual(await repository.profileCount(usingProxy: proxy.id), 2)

        try await repository.deleteProxy(id: proxy.id)
        let reloaded = try await ProfileRepository(store: store)
        await AsyncAssertEqual(await reloaded.proxies.map(\.id), [other.id])
        await AsyncAssertEqual(await reloaded.profile(id: first.id)?.proxyID, nil)
        await AsyncAssertEqual(await reloaded.profile(id: second.id)?.proxyID, nil)
        await AsyncAssertEqual(await reloaded.profile(id: third.id)?.proxyID, other.id)
        await AsyncAssertEqual(await reloaded.effectiveConfiguration(for: first.id)?.proxy, nil)
    }

    func testWritesSurviveAReload() async throws {
        let store = InMemoryProfileStore()
        let repository = try await ProfileRepository(store: store)
        let desk = profile("desk")
        try await repository.upsert(desk)

        let reloaded = try await ProfileRepository(store: store)
        await AsyncAssertEqual(await reloaded.profiles.count, 1)
    }

    func testFileStoreRoundTripsThroughDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mremote-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FileProfileStore(url: url)
        let repository = try await ProfileRepository(store: store)
        try await repository.upsert(profile("desk"))

        let reopened = try await ProfileRepository(store: FileProfileStore(url: url))
        let names = await reopened.profiles.map(\.displayName)
        XCTAssertEqual(names, ["desk"])
    }

    func testMissingFileLoadsAsAnEmptyStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mremote-missing-\(UUID().uuidString)")
            .appendingPathComponent("profiles.json")
        let repository = try await ProfileRepository(store: FileProfileStore(url: url))
        await AsyncAssertEqual(await repository.profiles.isEmpty, true)
    }
}

func AsyncAssertEqual<T: Equatable>(
    _ value: @autoclosure () async -> T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let actual = await value()
    XCTAssertEqual(actual, expected, file: file, line: line)
}
