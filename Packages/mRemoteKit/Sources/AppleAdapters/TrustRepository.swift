import Foundation
import Security
import SessionCore

/// A certificate the user explicitly approved for one endpoint.
///
/// The fingerprint alone never authorises a different host or port: an
/// approval is a statement about one endpoint, and reusing it elsewhere would
/// turn one accepted self-signed certificate into a wildcard.
public struct TrustRecord: Hashable, Sendable, Codable {
    public var host: String
    public var port: UInt16
    /// SHA-256 over the complete leaf DER. Subject and issuer are for display
    /// only and are never the basis of identity.
    public var leafSHA256: String
    public var subject: String
    public var issuer: String
    public var notBefore: Date
    public var notAfter: Date
    public var approvedAt: Date
    /// True when the name could not be checked because the endpoint is an IP
    /// literal. The review UI has to keep saying so on every reconnect.
    public var hostnameUnverified: Bool

    public init(
        host: String,
        port: UInt16,
        leafSHA256: String,
        subject: String,
        issuer: String,
        notBefore: Date,
        notAfter: Date,
        approvedAt: Date = Date(),
        hostnameUnverified: Bool = false
    ) {
        self.host = host
        self.port = port
        self.leafSHA256 = leafSHA256
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.approvedAt = approvedAt
        self.hostnameUnverified = hostnameUnverified
    }

    public var endpointKey: String { "\(host):\(port)" }
}

public enum TrustDecision: Hashable, Sendable {
    case noRecord
    case matches(TrustRecord)
    /// A record exists for this endpoint but the certificate changed. This is
    /// never auto-replaced: it is either a reissue or an interception, and
    /// only the user can tell which.
    case fingerprintChanged(TrustRecord)
}

public protocol TrustRepository: Sendable {
    func decision(host: String, port: UInt16, leafSHA256: String) throws -> TrustDecision
    func store(_ record: TrustRecord) throws
    func remove(host: String, port: UInt16) throws
    func allRecords() throws -> [TrustRecord]
}

extension TrustRepository {
    /// Convenience for the connect path.
    public func decision(for challenge: CertificateChallenge) throws -> TrustDecision {
        try decision(
            host: challenge.host,
            port: challenge.port,
            leafSHA256: challenge.leafSHA256
        )
    }
}

/// Pins live in the Keychain rather than the profile document: they are not
/// secret, but a modified pin is as dangerous as a stolen password.
public struct KeychainTrustRepository: TrustRepository {
    private let service: String
    private let accessGroup: String?
    private let store: KeychainStore

    public init(
        service: String = "com.mikuta0407.mRemote.trust",
        accessGroup: String? = nil,
        store: KeychainStore = .dataProtection
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.store = store
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        store.apply(to: &query)
        return query
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

    private func record(host: String, port: UInt16) throws -> TrustRecord? {
        try record(account: "\(host):\(port)")
    }

    private var login: LoginKeychain? {
        store == .login ? LoginKeychain(service: service) : nil
    }

    /// The login keychain cannot be listed from Mac Catalyst, so it keeps the
    /// endpoints that have a record in an item of their own.
    private static let indexAccount = "endpoints"

    private func loginIndex(_ login: LoginKeychain) throws -> [String] {
        guard let data = try login.read(account: Self.indexAccount) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func updateLoginIndex(_ login: LoginKeychain, _ change: (inout [String]) -> Void) throws {
        let before = try loginIndex(login)
        var after = before
        change(&after)
        guard after != before else { return }
        if after.isEmpty { return try login.delete(account: Self.indexAccount) }
        try login.write(try JSONEncoder().encode(after), account: Self.indexAccount)
    }

    private func record(account: String) throws -> TrustRecord? {
        if let login {
            return try login.read(account: account).map { try Self.decoder.decode(TrustRecord.self, from: $0) }
        }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecItemCopyMatching", status: status)
        }
        guard let data = item as? Data else { return nil }
        return try Self.decoder.decode(TrustRecord.self, from: data)
    }

    public func decision(host: String, port: UInt16, leafSHA256: String) throws -> TrustDecision {
        guard let stored = try record(host: host, port: port) else { return .noRecord }
        return stored.leafSHA256 == leafSHA256 ? .matches(stored) : .fingerprintChanged(stored)
    }

    public func store(_ record: TrustRecord) throws {
        let data = try Self.encoder.encode(record)
        if let login {
            try login.write(data, account: record.endpointKey)
            try updateLoginIndex(login) { if !$0.contains(record.endpointKey) { $0.append(record.endpointKey) } }
            return
        }
        let query = baseQuery(account: record.endpointKey)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(operation: "SecItemUpdate", status: updateStatus)
        }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(operation: "SecItemAdd", status: addStatus)
        }
    }

    public func remove(host: String, port: UInt16) throws {
        if let login {
            try login.delete(account: "\(host):\(port)")
            try updateLoginIndex(login) { $0.removeAll { $0 == "\(host):\(port)" } }
            return
        }
        let status = SecItemDelete(baseQuery(account: "\(host):\(port)") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "SecItemDelete", status: status)
        }
    }

    public func allRecords() throws -> [TrustRecord] {
        if let login {
            return try loginIndex(login).compactMap { try? record(account: $0) }
        }
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecItemCopyMatching", status: status)
        }
        guard let attributes = items as? [[String: Any]] else { return [] }
        return attributes
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap { try? record(account: $0) }
    }
}

public final class InMemoryTrustRepository: TrustRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: TrustRecord] = [:]

    public init() {}

    public func decision(host: String, port: UInt16, leafSHA256: String) throws -> TrustDecision {
        guard let stored = lock.withLock({ storage["\(host):\(port)"] }) else { return .noRecord }
        return stored.leafSHA256 == leafSHA256 ? .matches(stored) : .fingerprintChanged(stored)
    }

    public func store(_ record: TrustRecord) throws {
        lock.withLock { storage[record.endpointKey] = record }
    }

    public func remove(host: String, port: UInt16) throws {
        _ = lock.withLock { storage.removeValue(forKey: "\(host):\(port)") }
    }

    public func allRecords() throws -> [TrustRecord] {
        lock.withLock { Array(storage.values) }
    }
}
