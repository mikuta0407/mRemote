import Foundation
import Security

/// Which keychain the Keychain repositories use.
///
/// iOS has only the data-protection keychain. On a Mac it needs an
/// application identifier, which only a provisioning profile grants; the
/// ad-hoc signed Mac app that Homebrew installs has none, and every write
/// there fails with errSecMissingEntitlement (-34018). That build keeps its
/// items in the login keychain instead (`LoginKeychain`), which macOS guards
/// with the app's code signature (an update may ask once to allow access
/// again).
public enum KeychainStore: Sendable, Hashable {
    case dataProtection
    case login

    /// The data-protection keychain when this process may write to it.
    /// Only a write tells: reads succeed (as "not found") without the
    /// entitlement.
    public static func detect() -> KeychainStore {
        #if os(macOS) || targetEnvironment(macCatalyst)
        var probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mikuta0407.mRemote.keychain-probe",
            kSecAttrAccount as String: "probe",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var insert = probe
        insert[kSecValueData as String] = Data()
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecMissingEntitlement { return .login }
        probe.removeValue(forKey: kSecValueData as String)
        SecItemDelete(probe as CFDictionary)
        return .dataProtection
        #else
        return .dataProtection
        #endif
    }

    /// `SecItem*` only ever reaches the data-protection keychain here; the
    /// login keychain goes through `LoginKeychain`.
    func apply(to query: inout [String: Any]) {
        #if os(macOS) || targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
    }
}
