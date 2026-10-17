import Foundation
import SessionCore

/// Sign-in methods as the bridge counts them (`mr_ssh_auth_method`).
public struct SSHSignInMethods: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let publicKey = SSHSignInMethods(rawValue: 1 << 0)
    public static let keyboardInteractive = SSHSignInMethods(rawValue: 1 << 1)
    public static let password = SSHSignInMethods(rawValue: 1 << 2)
}

/// Decides how to answer each sign-in request (docs/ssh-design.md 7.3), so
/// the policy lives here, testable, and the session only carries it out.
///
/// The order is public key, a stored password, keyboard-interactive, then a
/// password typed at the prompt: a server that offers both (macOS's sshd
/// does) would otherwise never get the saved one. A stored secret
/// is offered once: after the server refuses it the user is asked instead,
/// never the same secret again - retrying a rejected password is how an
/// account gets locked out.
public struct SSHSignInPlanner: Sendable {
    public enum Step: Hashable, Sendable {
        /// Sign in with the stored key; `passphrase` when it is encrypted.
        case publicKey(passphrase: String?)
        /// The key is encrypted and its passphrase is unknown, or was wrong.
        /// Answer with `passphraseProvided`.
        case askPassphrase(previousWasRejected: Bool)
        case keyboardInteractive
        case password(String)
        case askPassword(storedWasRejected: Bool)
        /// Nothing left to try.
        case giveUp
    }

    /// Wrong passphrases before the key is given up on.
    public static let maximumPassphraseTries = 3
    /// One-time codes can be mistyped too.
    public static let maximumKeyboardInteractiveTries = 3

    private let usesKey: Bool
    private let keyIsEncrypted: Bool
    private let allowsKeyboardInteractive: Bool
    private let allowsPassword: Bool

    private var passphrase: String?
    private var storedPassword: String?
    private var keyFinished = false
    private var passphraseTries = 0
    private var keyboardInteractiveTries = 0
    private var lastStep: Step?

    /// - Parameter hasKey: the profile names a key and it could be read.
    public init(
        authentication: SSHAuthentication,
        hasKey: Bool,
        keyIsEncrypted: Bool,
        storedPassphrase: String?,
        storedPassword: String?
    ) {
        usesKey = hasKey && authentication.keyID != nil
        self.keyIsEncrypted = keyIsEncrypted
        allowsKeyboardInteractive = authentication.allowsKeyboardInteractive
        allowsPassword = authentication.allowsPassword
        passphrase = keyIsEncrypted ? storedPassphrase : nil
        self.storedPassword = storedPassword
    }

    /// The step for a request offering `offered`; `rejected` is what the
    /// server refused last time (from the bridge), empty the first time.
    public mutating func next(offered: SSHSignInMethods, rejected: SSHSignInMethods) -> Step {
        var storedPasswordWasRejected = false
        if rejected.contains(.publicKey), case .publicKey = lastStep {
            if keyIsEncrypted {
                // Maybe the passphrase was wrong rather than the key unknown:
                // ask again, a few times.
                passphrase = nil
                if passphraseTries >= Self.maximumPassphraseTries { keyFinished = true }
            } else {
                keyFinished = true
            }
        }
        if rejected.contains(.password), case .password = lastStep {
            storedPassword = nil
            storedPasswordWasRejected = true
        }

        let step = choose(offered: offered, storedPasswordWasRejected: storedPasswordWasRejected)
        lastStep = step
        return step
    }

    /// The user answered `askPassphrase`.
    public mutating func passphraseProvided(_ value: String) -> Step {
        passphrase = value
        passphraseTries += 1
        let step = Step.publicKey(passphrase: value)
        lastStep = step
        return step
    }

    /// The user typed a password at `askPassword`; a refusal of it is then
    /// reported as one, like a stored one's.
    public mutating func passwordTyped() {
        lastStep = .password("")
    }

    /// The user declined to give the passphrase: sign in another way.
    public mutating func keySkipped(offered: SSHSignInMethods) -> Step {
        keyFinished = true
        let step = choose(offered: offered, storedPasswordWasRejected: false)
        lastStep = step
        return step
    }

    private mutating func choose(offered: SSHSignInMethods, storedPasswordWasRejected: Bool) -> Step {
        if usesKey, !keyFinished, offered.contains(.publicKey) {
            if !keyIsEncrypted {
                return .publicKey(passphrase: nil)
            }
            if let passphrase, passphraseTries == 0 {
                // The stored passphrase, once.
                passphraseTries = 1
                return .publicKey(passphrase: passphrase)
            }
            return .askPassphrase(previousWasRejected: passphraseTries > 0)
        }
        if allowsPassword, offered.contains(.password), let storedPassword {
            return .password(storedPassword)
        }
        if allowsKeyboardInteractive, offered.contains(.keyboardInteractive),
           keyboardInteractiveTries < Self.maximumKeyboardInteractiveTries {
            keyboardInteractiveTries += 1
            return .keyboardInteractive
        }
        if allowsPassword, offered.contains(.password) {
            return .askPassword(storedWasRejected: storedPasswordWasRejected)
        }
        return .giveUp
    }
}
