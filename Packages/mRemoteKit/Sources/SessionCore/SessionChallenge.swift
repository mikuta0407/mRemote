import Foundation

/// Something only the user can answer, raised while connecting.
public enum SessionChallenge: Hashable, Sendable {
    case credential(CredentialChallenge)
    case certificate(CertificateChallenge)
    /// SSH: the server's host key is new, or changed.
    case hostKey(HostKeyChallenge)
    /// SSH: the server's own prompts (one-time codes and the like).
    case keyboardInteractive(KeyboardInteractiveChallenge)
    /// SSH: the stored private key is encrypted and its passphrase is not
    /// stored, or was wrong.
    case keyPassphrase(KeyPassphraseChallenge)

    public var id: ChallengeID {
        switch self {
        case .credential(let challenge): return challenge.id
        case .certificate(let challenge): return challenge.id
        case .hostKey(let challenge): return challenge.id
        case .keyboardInteractive(let challenge): return challenge.id
        case .keyPassphrase(let challenge): return challenge.id
        }
    }
}

/// docs/ssh-design.md section 7.1. The fingerprint is the OpenSSH form,
/// "SHA256:" and unpadded base64 of the key blob's SHA-256, so it can be
/// compared with `ssh-keygen -lf` on the server.
public struct HostKeyChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let port: UInt16
    /// The SSH name, e.g. "ssh-ed25519".
    public let keyType: String
    public let fingerprint: String
    public let disposition: HostKeyDisposition

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        host: String,
        port: UInt16,
        keyType: String,
        fingerprint: String,
        disposition: HostKeyDisposition
    ) {
        self.id = id
        self.generation = generation
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.disposition = disposition
    }
}

public enum HostKeyDisposition: Hashable, Sendable {
    /// First connection to this endpoint.
    case unknown
    /// A different key than the one the user trusted. Presented as a
    /// warning, never like a first connection, and never replaced silently.
    case changed(previousKeyType: String, previousFingerprint: String)

    public var isIdentityChange: Bool {
        if case .changed = self { return true }
        return false
    }
}

public struct KeyboardInteractivePrompt: Hashable, Sendable {
    public let text: String
    /// False for secrets: the answer field hides what is typed.
    public let echo: Bool

    public init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }
}

public struct KeyboardInteractiveChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let name: String
    public let instruction: String
    /// May be empty: an instruction to acknowledge.
    public let prompts: [KeyboardInteractivePrompt]

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        host: String,
        name: String,
        instruction: String,
        prompts: [KeyboardInteractivePrompt]
    ) {
        self.id = id
        self.generation = generation
        self.host = host
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

public struct KeyPassphraseChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let keyName: String
    /// A passphrase was already tried for this key and failed.
    public let previousWasRejected: Bool

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        keyName: String,
        previousWasRejected: Bool
    ) {
        self.id = id
        self.generation = generation
        self.keyName = keyName
        self.previousWasRejected = previousWasRejected
    }
}

public struct CredentialChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let username: String?
    public let domain: String?
    /// Set when a stored password was already tried and rejected. The UI uses
    /// it to explain the second prompt, and the connect path uses it to avoid
    /// retrying the same stored secret into an account lockout.
    public let storedCredentialWasRejected: Bool

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        host: String,
        username: String? = nil,
        domain: String? = nil,
        storedCredentialWasRejected: Bool = false
    ) {
        self.id = id
        self.generation = generation
        self.host = host
        self.username = username
        self.domain = domain
        self.storedCredentialWasRejected = storedCredentialWasRejected
    }
}

/// A server certificate the platform did not accept. The DER is already copied
/// out of the native callback by the time this exists: nothing here points at
/// memory the protocol layer owns.
public struct CertificateChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let port: UInt16
    public let leafSHA256: String
    public let chainSHA256: String
    public let subject: String
    public let issuer: String
    public let notBefore: Date
    public let notAfter: Date
    /// Which requirement the user is being asked to override, and whether an
    /// override may be offered at all.
    public let disposition: CertificateDisposition

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        host: String,
        port: UInt16,
        leafSHA256: String,
        chainSHA256: String,
        subject: String,
        issuer: String,
        notBefore: Date,
        notAfter: Date,
        disposition: CertificateDisposition
    ) {
        self.id = id
        self.generation = generation
        self.host = host
        self.port = port
        self.leafSHA256 = leafSHA256
        self.chainSHA256 = chainSHA256
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.disposition = disposition
    }
}

/// Mirrors the staged evaluation in docs/data-and-security.md: a certificate
/// that is broken is refused outright, while one that is merely unknown, or
/// that cannot bind a name because the endpoint is an IP literal, may be
/// approved with the fingerprint as the only identity.
public enum CertificateDisposition: Hashable, Sendable {
    /// Private CA or self-signed, but otherwise sound.
    case untrustedRoot
    /// Sound chain that does not meet Apple's server-certificate requirements.
    case serverPurposeUnmet
    /// The endpoint is an IP literal, so the name was never checked.
    case hostnameUnverifiable
    /// Expired, mismatched hostname, or a broken chain. No override offered.
    case rejected(reason: String)
    /// A previously pinned fingerprint changed. Never approve this the way a
    /// first-time self-signed certificate is approved: docs/data-and-security.md
    /// requires a strong warning and refuses to replace the stored approval
    /// silently, so this is its own presentation with its own wording.
    case fingerprintChanged(previousLeafSHA256: String)

    public var allowsUserApproval: Bool {
        switch self {
        case .untrustedRoot, .serverPurposeUnmet, .hostnameUnverifiable:
            return true
        case .fingerprintChanged:
            // An approval action is offered, but not the same one: a
            // certificate that is merely unknown and one that replaced a
            // certificate the user already approved are different questions.
            // Without a path forward here, an ordinary certificate renewal
            // would leave the profile permanently unusable inside the app,
            // which teaches the user to delete trust records rather than to
            // read the warning.
            return true
        case .rejected:
            return false
        }
    }

    /// True where the user is being told that something they already approved
    /// has changed. The review UI must not present this like a first-time
    /// approval.
    public var isIdentityChange: Bool {
        if case .fingerprintChanged = self { return true }
        return false
    }
}

public enum ChallengeResponse: Hashable, Sendable {
    case credential(username: String, domain: String?, password: String, save: Bool)
    case trustOnce
    case trustPersistently
    /// One answer per prompt, in order.
    case keyboardInteractive(answers: [String])
    case passphrase(String, save: Bool)
    case cancel
}

public enum DisconnectReason: Hashable, Sendable {
    case userRequested
    case profileDeleted
    case sceneTerminating
    case replacedByReconnect
    case failed(RemoteSessionError)
}

/// Stable categories the UI can explain. The protocol layer maps its own error
/// codes into these so that no FreeRDP type reaches a feature module.
public enum RemoteSessionError: Hashable, Sendable, Error {
    case nameResolutionFailed
    case networkUnreachable
    case connectionRefused
    case connectionTimedOut
    case tlsHandshakeFailed
    /// The client and server share no transport security both allow - in
    /// practice a server that accepts only the legacy RDP Security Layer.
    case securityNegotiationFailed
    case authenticationFailed
    case accountRestricted
    case certificateRejected
    /// SSH: the host key was refused, or a changed one was not accepted.
    case hostKeyRejected
    case userCancelled
    case protocolFailure(detail: String)
    case resourceUnavailable
    case internalFailure(detail: String)

    /// Whether an automatic retry could plausibly succeed without the user
    /// changing anything. Retrying an authentication failure risks locking the
    /// account out, so it is deliberately excluded.
    public var isRetriable: Bool {
        switch self {
        case .networkUnreachable, .connectionTimedOut, .protocolFailure:
            return true
        case .nameResolutionFailed, .connectionRefused, .tlsHandshakeFailed, .securityNegotiationFailed,
             .authenticationFailed, .accountRestricted, .certificateRejected, .hostKeyRejected,
             .userCancelled, .resourceUnavailable, .internalFailure:
            return false
        }
    }
}
