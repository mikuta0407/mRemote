import Foundation
import Security

/// Generic passwords in the login keychain, through the file-keychain API
/// (`SecKeychainAddGenericPassword` and friends).
///
/// A Mac Catalyst process always gets the data-protection keychain from
/// `SecItem*`: it ignores `kSecUseDataProtectionKeychain = false`, and
/// `kSecUseKeychain` is unavailable there. Without an application identifier
/// every one of those calls fails with errSecMissingEntitlement (-34018). The
/// file-keychain API still reaches the login keychain from Catalyst, but its
/// headers mark it unavailable, so the functions are looked up at run time.
/// The same path is used on macOS, so the host tests exercise it.
struct LoginKeychain: Sendable {
    let service: String

    func read(account: String) throws -> Data? {
        var length: UInt32 = 0
        var bytes: UnsafeMutableRawPointer?
        let status = service.withCString { service in
            account.withCString { account in
                Self.api.find(
                    nil,
                    UInt32(strlen(service)), service,
                    UInt32(strlen(account)), account,
                    &length, &bytes, nil
                )
            }
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecKeychainFindGenericPassword", status: status)
        }
        guard let bytes else { return Data() }
        defer { _ = Self.api.freeContent(nil, bytes) }
        return Data(bytes: bytes, count: Int(length))
    }

    func write(_ data: Data, account: String) throws {
        if let item = try item(account: account) {
            let status = data.withUnsafeBytes { buffer in
                Self.api.modify(item, nil, UInt32(buffer.count), buffer.baseAddress)
            }
            guard status == errSecSuccess else {
                throw KeychainError(operation: "SecKeychainItemModifyAttributesAndData", status: status)
            }
            return
        }
        let status = service.withCString { service in
            account.withCString { account in
                // An empty Data has no address to hand over; the length says
                // none of it is read.
                (data.isEmpty ? Data([0]) : data).withUnsafeBytes { buffer in
                    Self.api.add(
                        nil,
                        UInt32(strlen(service)), service,
                        UInt32(strlen(account)), account,
                        UInt32(data.count), buffer.baseAddress!,
                        nil
                    )
                }
            }
        }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecKeychainAddGenericPassword", status: status)
        }
    }

    func delete(account: String) throws {
        guard let item = try item(account: account) else { return }
        let status = Self.api.delete(item)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "SecKeychainItemDelete", status: status)
        }
    }

    private func item(account: String) throws -> CFTypeRef? {
        var item: Unmanaged<CFTypeRef>?
        let status = service.withCString { service in
            account.withCString { account in
                Self.api.find(
                    nil,
                    UInt32(strlen(service)), service,
                    UInt32(strlen(account)), account,
                    nil, nil, &item
                )
            }
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "SecKeychainFindGenericPassword", status: status)
        }
        return item?.takeRetainedValue()
    }

    // MARK: - The functions

    private struct API: @unchecked Sendable {
        typealias Find = @convention(c) (
            CFTypeRef?, UInt32, UnsafePointer<CChar>, UInt32, UnsafePointer<CChar>,
            UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
            UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?
        ) -> OSStatus
        typealias Add = @convention(c) (
            CFTypeRef?, UInt32, UnsafePointer<CChar>, UInt32, UnsafePointer<CChar>,
            UInt32, UnsafeRawPointer, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?
        ) -> OSStatus
        typealias Modify = @convention(c) (CFTypeRef, UnsafeRawPointer?, UInt32, UnsafeRawPointer?) -> OSStatus
        typealias Delete = @convention(c) (CFTypeRef) -> OSStatus
        typealias FreeContent = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> OSStatus

        let find: Find
        let add: Add
        let modify: Modify
        let delete: Delete
        let freeContent: FreeContent
    }

    private static let api: API = {
        // Security.framework is already linked, so this only finds it.
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            fatalError("Security.framework is not loadable")
        }
        func function<T>(_ name: String, as type: T.Type) -> T {
            guard let symbol = dlsym(handle, name) else { fatalError("\(name) is missing") }
            return unsafeBitCast(symbol, to: type)
        }
        return API(
            find: function("SecKeychainFindGenericPassword", as: API.Find.self),
            add: function("SecKeychainAddGenericPassword", as: API.Add.self),
            modify: function("SecKeychainItemModifyAttributesAndData", as: API.Modify.self),
            delete: function("SecKeychainItemDelete", as: API.Delete.self),
            freeContent: function("SecKeychainItemFreeContent", as: API.FreeContent.self)
        )
    }()
}
