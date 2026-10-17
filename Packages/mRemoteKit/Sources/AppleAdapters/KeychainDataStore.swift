import Foundation
import Security

/// Data items under one Keychain service, one per account name - the shape
/// the SSH stores share. The data protection keychain on iOS, and the login
/// keychain on the ad-hoc signed Mac build (`KeychainStore`), where items
/// cannot be listed, so an index item keeps the account names.
struct KeychainDataStore: Sendable {
    enum Accessibility: Sendable {
        case afterFirstUnlock
        case whenUnlocked

        var attribute: CFString {
            switch self {
            case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    let service: String
    let accessGroup: String?
    let store: KeychainStore
    let accessible: Accessibility

    private static let indexAccount = "_index"

    init(service: String, accessGroup: String?, store: KeychainStore, accessible: Accessibility) {
        self.service = service
        self.accessGroup = accessGroup
        self.store = store
        self.accessible = accessible
    }

    private var login: LoginKeychain? {
        store == .login ? LoginKeychain(service: service) : nil
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        store.apply(to: &query)
        return query
    }

    func read(account: String) throws -> Data? {
        if let login { return try login.read(account: account) }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecItemCopyMatching", status: status)
        }
        return item as? Data
    }

    func write(_ data: Data, account: String) throws {
        if let login {
            try login.write(data, account: account)
            try updateIndex(login) { if !$0.contains(account) { $0.append(account) } }
            return
        }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible.attribute,
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

    func delete(account: String) throws {
        if let login {
            try login.delete(account: account)
            try updateIndex(login) { $0.removeAll { $0 == account } }
            return
        }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "SecItemDelete", status: status)
        }
    }

    func accounts() throws -> [String] {
        if let login { return try index(login) }
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecItemCopyMatching", status: status)
        }
        return ((items as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func index(_ login: LoginKeychain) throws -> [String] {
        guard let data = try login.read(account: Self.indexAccount) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func updateIndex(_ login: LoginKeychain, _ change: (inout [String]) -> Void) throws {
        let before = try index(login)
        var after = before
        change(&after)
        guard after != before else { return }
        if after.isEmpty { return try login.delete(account: Self.indexAccount) }
        try login.write(try JSONEncoder().encode(after), account: Self.indexAccount)
    }
}
