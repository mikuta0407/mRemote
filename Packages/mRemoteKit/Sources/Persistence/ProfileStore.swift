import Foundation
import SessionCore

/// Reads and writes the profile document. The protocol exists so features can
/// be tested against the in-memory store, and so a different backing store
/// would not reach the feature modules.
public protocol ProfileStore: Actor {
    func load() throws -> ProfileDocument
    func save(_ document: ProfileDocument) throws
}

public actor InMemoryProfileStore: ProfileStore {
    private var document: ProfileDocument

    public init(document: ProfileDocument = ProfileDocument()) {
        self.document = document
    }

    public func load() throws -> ProfileDocument { document }

    public func save(_ document: ProfileDocument) throws {
        var stamped = document
        stamped.schemaVersion = .current
        self.document = stamped
    }
}

/// A single JSON file, written atomically.
public actor FileProfileStore: ProfileStore {
    private let url: URL
    private let codec: ProfileDocumentCodec

    public init(url: URL, codec: ProfileDocumentCodec = ProfileDocumentCodec()) {
        self.url = url
        self.codec = codec
    }

    /// The store lives in Application Support rather than Documents so it is
    /// not exposed through file sharing.
    public static func defaultURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent("mRemote-profiles.json", isDirectory: false)
    }

    public func load() throws -> ProfileDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First launch is an empty store, not an error.
            return ProfileDocument()
        }
        return try codec.decode(try Data(contentsOf: url))
    }

    public func save(_ document: ProfileDocument) throws {
        let data = try codec.encode(document)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic so an interrupted write cannot leave a half-written store,
        // and protected so the file is unreadable before the first unlock.
        // Both the replacement and the final file need the attribute: the
        // atomic write creates a new inode, which would otherwise inherit the
        // directory's default protection instead of this one.
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

/// The profile list's operations, kept out of the view so they can be tested
/// and so the same rules apply wherever a profile is edited.
public actor ProfileRepository {
    private let store: any ProfileStore
    private var document: ProfileDocument

    public init(store: any ProfileStore) async throws {
        self.store = store
        self.document = try await store.load()
    }

    public var profiles: [ConnectionProfile] {
        document.profiles.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    public var globalSettings: GlobalSettings { document.globalSettings }

    // MARK: Proxies

    public var proxies: [ProxyServer] {
        document.proxies.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    public func proxy(id: ProxyID) -> ProxyServer? {
        document.proxies.first { $0.id == id }
    }

    public func upsertProxy(_ proxy: ProxyServer) async throws {
        if let index = document.proxies.firstIndex(where: { $0.id == proxy.id }) {
            document.proxies[index] = proxy
        } else {
            document.proxies.append(proxy)
        }
        try await persist()
    }

    /// How many profiles go through the proxy: deleting it turns them into
    /// direct connections, so the list says so first.
    public func profileCount(usingProxy id: ProxyID) -> Int {
        document.profiles.filter { $0.proxyID == id }.count
    }

    /// Removes the proxy, and the reference to it from every profile, in one
    /// save: a profile never points at a proxy that is gone.
    public func deleteProxy(id: ProxyID) async throws {
        document.proxies.removeAll { $0.id == id }
        for index in document.profiles.indices where document.profiles[index].proxyID == id {
            document.profiles[index].proxyID = nil
        }
        try await persist()
    }

    public func profile(id: ProfileID) -> ConnectionProfile? {
        document.profiles.first { $0.id == id }
    }

    public func upsert(_ profile: ConnectionProfile, now: Date = Date()) async throws {
        var updated = profile
        updated.updatedAt = now
        if let index = document.profiles.firstIndex(where: { $0.id == profile.id }) {
            document.profiles[index] = updated
        } else {
            document.profiles.append(updated)
        }
        try await persist()
    }

    /// Removes the profile and reports the credential it referenced, if no
    /// remaining profile still uses it. The caller offers to delete that
    /// Keychain item; deleting it here would silently break a profile that
    /// shares the reference.
    @discardableResult
    public func delete(id: ProfileID) async throws -> CredentialReference? {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = document.profiles.remove(at: index)
        try await persist()
        guard let reference = removed.account.credentialReference else { return nil }
        let stillReferenced = document.profiles.contains {
            $0.account.credentialReference == reference
        }
        return stillReferenced ? nil : reference
    }

    public func markConnected(id: ProfileID, at date: Date = Date()) async throws {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else { return }
        document.profiles[index].lastConnectedAt = date
        try await persist()
    }

    public func updateGlobalSettings(_ settings: GlobalSettings) async throws {
        document.globalSettings = settings
        try await persist()
    }

    /// The configuration a connect attempt should run with.
    public func effectiveConfiguration(
        for id: ProfileID,
        resolver: EffectiveProfileResolver = EffectiveProfileResolver()
    ) -> EffectiveConnectionConfiguration? {
        guard let profile = profile(id: id) else { return nil }
        return resolver.resolve(
            profile: profile, globalSettings: document.globalSettings, proxies: document.proxies)
    }

    private func persist() async throws {
        try await store.save(document)
    }
}
