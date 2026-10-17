import Foundation
import Security
import SessionCore

// MARK: - Known hosts

/// A host key the user trusted for one endpoint (docs/ssh-design.md 7.1).
public struct KnownHost: Hashable, Sendable, Codable {
    public var host: String
    public var port: UInt16
    public var keyType: String
    /// "SHA256:" and unpadded base64, as `ssh-keygen -lf` prints it.
    public var fingerprint: String
    public var trustedAt: Date

    public init(host: String, port: UInt16, keyType: String, fingerprint: String, trustedAt: Date = Date()) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.trustedAt = trustedAt
    }

    public var endpointKey: String { "\(host.lowercased()):\(port)" }
}

public enum KnownHostDecision: Hashable, Sendable {
    case unknown
    case matches(KnownHost)
    /// Never replaced silently: a reinstall or an interception, and only the
    /// user can tell which.
    case changed(KnownHost)
}

public protocol KnownHostRepository: Sendable {
    func decision(host: String, port: UInt16, fingerprint: String) throws -> KnownHostDecision
    func store(_ host: KnownHost) throws
    func remove(host: String, port: UInt16) throws
    func allHosts() throws -> [KnownHost]
}

/// One trusted key per endpoint. A server with several host keys offers the
/// strongest one the bridge prefers, so one is enough; a different one later
/// is a change.
public struct KeychainKnownHostRepository: KnownHostRepository {
    private let items: KeychainDataStore

    public init(
        service: String = "com.mikuta0407.mRemote.known-hosts",
        accessGroup: String? = nil,
        store: KeychainStore = .dataProtection
    ) {
        items = KeychainDataStore(
            service: service, accessGroup: accessGroup, store: store,
            accessible: .afterFirstUnlock)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func host(account: String) throws -> KnownHost? {
        try items.read(account: account).map { try Self.decoder.decode(KnownHost.self, from: $0) }
    }

    public func decision(host: String, port: UInt16, fingerprint: String) throws -> KnownHostDecision {
        let key = KnownHost(host: host, port: port, keyType: "", fingerprint: "").endpointKey
        guard let stored = try self.host(account: key) else { return .unknown }
        return stored.fingerprint == fingerprint ? .matches(stored) : .changed(stored)
    }

    public func store(_ host: KnownHost) throws {
        try items.write(try Self.encoder.encode(host), account: host.endpointKey)
    }

    public func remove(host: String, port: UInt16) throws {
        try items.delete(account: KnownHost(host: host, port: port, keyType: "", fingerprint: "").endpointKey)
    }

    public func allHosts() throws -> [KnownHost] {
        try items.accounts().compactMap { try? host(account: $0) }
            .sorted { $0.endpointKey < $1.endpointKey }
    }
}

public final class InMemoryKnownHostRepository: KnownHostRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: KnownHost] = [:]

    public init() {}

    public func decision(host: String, port: UInt16, fingerprint: String) throws -> KnownHostDecision {
        let key = KnownHost(host: host, port: port, keyType: "", fingerprint: "").endpointKey
        guard let stored = lock.withLock({ storage[key] }) else { return .unknown }
        return stored.fingerprint == fingerprint ? .matches(stored) : .changed(stored)
    }

    public func store(_ host: KnownHost) throws {
        lock.withLock { storage[host.endpointKey] = host }
    }

    public func remove(host: String, port: UInt16) throws {
        let key = KnownHost(host: host, port: port, keyType: "", fingerprint: "").endpointKey
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }

    public func allHosts() throws -> [KnownHost] {
        lock.withLock { storage.values.sorted { $0.endpointKey < $1.endpointKey } }
    }
}

// MARK: - Private keys

/// What the key list shows. Not secret, but kept next to the key so the two
/// cannot drift apart.
public struct SSHKeyMetadata: Hashable, Sendable, Codable, Identifiable {
    public var id: SSHKeyID
    public var name: String
    /// "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"…
    public var keyType: String
    /// The authorized_keys line: type, base64 blob, comment.
    public var publicKey: String
    public var fingerprint: String
    public var isEncrypted: Bool
    public var createdAt: Date

    public init(
        id: SSHKeyID = SSHKeyID(),
        name: String,
        keyType: String,
        publicKey: String,
        fingerprint: String,
        isEncrypted: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.isEncrypted = isEncrypted
        self.createdAt = createdAt
    }
}

public protocol SSHKeyRepository: Sendable {
    func allKeys() throws -> [SSHKeyMetadata]
    func metadata(for id: SSHKeyID) throws -> SSHKeyMetadata?
    /// The private key file as imported or generated (OpenSSH format).
    func privateKey(for id: SSHKeyID) throws -> Data?
    func passphrase(for id: SSHKeyID) throws -> String?
    func store(_ metadata: SSHKeyMetadata, privateKey: Data) throws
    func rename(_ id: SSHKeyID, to name: String) throws
    func storePassphrase(_ passphrase: String?, for id: SSHKeyID) throws
    func delete(_ id: SSHKeyID) throws
}

/// Three items per key under one service: the private key, its metadata and,
/// when the user chose to keep it, the passphrase. All ThisDeviceOnly: a key
/// generated here never leaves the device by way of a Keychain backup.
public struct KeychainSSHKeyRepository: SSHKeyRepository {
    private let items: KeychainDataStore

    public init(
        service: String = "com.mikuta0407.mRemote.ssh-keys",
        accessGroup: String? = nil,
        store: KeychainStore = .dataProtection
    ) {
        items = KeychainDataStore(
            service: service, accessGroup: accessGroup, store: store,
            accessible: .whenUnlocked)
    }

    private static func account(_ id: SSHKeyID, _ part: String) -> String { "\(id.rawValue.uuidString).\(part)" }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func allKeys() throws -> [SSHKeyMetadata] {
        try items.accounts()
            .filter { $0.hasSuffix(".meta") }
            .compactMap { try? items.read(account: $0) }
            .compactMap { try? Self.decoder.decode(SSHKeyMetadata.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func metadata(for id: SSHKeyID) throws -> SSHKeyMetadata? {
        try items.read(account: Self.account(id, "meta")).map { try Self.decoder.decode(SSHKeyMetadata.self, from: $0) }
    }

    public func privateKey(for id: SSHKeyID) throws -> Data? {
        try items.read(account: Self.account(id, "key"))
    }

    public func passphrase(for id: SSHKeyID) throws -> String? {
        try items.read(account: Self.account(id, "passphrase")).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func store(_ metadata: SSHKeyMetadata, privateKey: Data) throws {
        try items.write(privateKey, account: Self.account(metadata.id, "key"))
        try items.write(try Self.encoder.encode(metadata), account: Self.account(metadata.id, "meta"))
    }

    public func rename(_ id: SSHKeyID, to name: String) throws {
        guard var metadata = try metadata(for: id) else { return }
        metadata.name = name
        try items.write(try Self.encoder.encode(metadata), account: Self.account(id, "meta"))
    }

    public func storePassphrase(_ passphrase: String?, for id: SSHKeyID) throws {
        if let passphrase, !passphrase.isEmpty {
            try items.write(Data(passphrase.utf8), account: Self.account(id, "passphrase"))
        } else {
            try items.delete(account: Self.account(id, "passphrase"))
        }
    }

    public func delete(_ id: SSHKeyID) throws {
        // Metadata last: a key that half-deleted stays listed, so the user
        // can delete it again.
        try items.delete(account: Self.account(id, "passphrase"))
        try items.delete(account: Self.account(id, "key"))
        try items.delete(account: Self.account(id, "meta"))
    }
}

public final class InMemorySSHKeyRepository: SSHKeyRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [SSHKeyID: (SSHKeyMetadata, Data)] = [:]
    private var passphrases: [SSHKeyID: String] = [:]

    public init() {}

    public func allKeys() throws -> [SSHKeyMetadata] {
        lock.withLock { keys.values.map(\.0).sorted { $0.createdAt < $1.createdAt } }
    }

    public func metadata(for id: SSHKeyID) throws -> SSHKeyMetadata? { lock.withLock { keys[id]?.0 } }
    public func privateKey(for id: SSHKeyID) throws -> Data? { lock.withLock { keys[id]?.1 } }
    public func passphrase(for id: SSHKeyID) throws -> String? { lock.withLock { passphrases[id] } }

    public func store(_ metadata: SSHKeyMetadata, privateKey: Data) throws {
        lock.withLock { keys[metadata.id] = (metadata, privateKey) }
    }

    public func rename(_ id: SSHKeyID, to name: String) throws {
        lock.withLock { keys[id]?.0.name = name }
    }

    public func storePassphrase(_ passphrase: String?, for id: SSHKeyID) throws {
        lock.withLock { passphrases[id] = (passphrase?.isEmpty ?? true) ? nil : passphrase }
    }

    public func delete(_ id: SSHKeyID) throws {
        lock.withLock {
            keys[id] = nil
            passphrases[id] = nil
        }
    }
}
