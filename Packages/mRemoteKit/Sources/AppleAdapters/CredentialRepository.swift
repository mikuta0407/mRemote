import Foundation
import Security
import SessionCore

/// Stores connection passwords. Nothing else in the app may hold one for
/// longer than a connect attempt needs it.
public protocol CredentialRepository: Sendable {
    func password(for reference: CredentialReference) throws -> String?
    func store(password: String, for reference: CredentialReference) throws
    func delete(_ reference: CredentialReference) throws
}

public struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String { "\(operation) failed with OSStatus \(status)" }
}

/// A Keychain generic password per credential.
///
/// The account name is the credential UUID, never the host: a guessable
/// account name would let another item on the same access group be
/// correlated with a specific server. Items are `ThisDeviceOnly` and not
/// synchronised, because a foreground RDP password has no reason to leave the
/// device.
public struct KeychainCredentialRepository: CredentialRepository {
    private let service: String
    private let accessGroup: String?
    private let store: KeychainStore

    public init(
        service: String = "com.mikuta0407.mRemote.credentials",
        accessGroup: String? = nil,
        store: KeychainStore = .dataProtection
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.store = store
    }

    private func baseQuery(for reference: CredentialReference) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        store.apply(to: &query)
        return query
    }

    private var login: LoginKeychain? {
        store == .login ? LoginKeychain(service: service) : nil
    }

    public func password(for reference: CredentialReference) throws -> String? {
        if let login {
            return try login.read(account: reference.rawValue.uuidString).flatMap { String(data: $0, encoding: .utf8) }
        }
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecItemCopyMatching", status: status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func store(password: String, for reference: CredentialReference) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError(operation: "encode password", status: errSecParam)
        }
        if let login {
            return try login.write(data, account: reference.rawValue.uuidString)
        }
        let query = baseQuery(for: reference)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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

    public func delete(_ reference: CredentialReference) throws {
        if let login {
            return try login.delete(account: reference.rawValue.uuidString)
        }
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "SecItemDelete", status: status)
        }
    }
}

/// For tests and previews. Deliberately not a fallback the app can select at
/// runtime: a misconfigured build must fail to reach the Keychain rather than
/// quietly keep passwords in memory.
public final class InMemoryCredentialRepository: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialReference: String] = [:]

    public init() {}

    public func password(for reference: CredentialReference) throws -> String? {
        lock.withLock { storage[reference] }
    }

    public func store(password: String, for reference: CredentialReference) throws {
        lock.withLock { storage[reference] = password }
    }

    public func delete(_ reference: CredentialReference) throws {
        _ = lock.withLock { storage.removeValue(forKey: reference) }
    }
}
