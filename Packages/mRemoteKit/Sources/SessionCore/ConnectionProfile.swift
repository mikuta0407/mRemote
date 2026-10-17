import Foundation

/// A setting that either takes the global default or overrides it.
///
/// `inherit` is resolved once, when a connection starts, so that changing a
/// global default never mutates a running session underneath the user.
public enum Inheritable<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    case inherit
    case explicit(Value)

    public func resolved(default fallback: Value) -> Value {
        switch self {
        case .inherit: return fallback
        case .explicit(let value): return value
        }
    }
}

public struct RemoteEndpoint: Hashable, Sendable, Codable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// True when the host is an IPv4 or IPv6 literal rather than a name. The
    /// certificate review needs this: a Windows self-signed certificate has no
    /// iPAddress SAN, so a name binding cannot succeed for a literal endpoint.
    public var isIPLiteral: Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        let unbracketed = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return inet_pton(AF_INET6, unbracketed, &v6) == 1
    }
}

public struct RemoteAccount: Hashable, Sendable, Codable {
    public var username: String?
    public var domain: String?
    /// A reference only. The password lives in the Keychain under this name.
    public var credentialReference: CredentialReference?

    public init(
        username: String? = nil,
        domain: String? = nil,
        credentialReference: CredentialReference? = nil
    ) {
        self.username = username
        self.domain = domain
        self.credentialReference = credentialReference
    }
}

public enum ProtocolKind: String, Hashable, Sendable, Codable, CaseIterable {
    case rdp
    /// Phase 8 (docs/ssh-design.md). Added without changing the list query or
    /// the common columns above.
    case ssh

    public var defaultPort: UInt16 {
        switch self {
        case .rdp: return 3389
        case .ssh: return SSHConfiguration.defaultPort
        }
    }
}

public enum ProtocolConfiguration: Hashable, Sendable, Codable {
    case rdp(RDPConfiguration)
    case ssh(SSHConfiguration)

    public var kind: ProtocolKind {
        switch self {
        case .rdp: return .rdp
        case .ssh: return .ssh
        }
    }

    public var rdp: RDPConfiguration? {
        if case .rdp(let configuration) = self { return configuration }
        return nil
    }

    public var ssh: SSHConfiguration? {
        if case .ssh(let configuration) = self { return configuration }
        return nil
    }
}

public struct ConnectionProfile: Identifiable, Hashable, Sendable, Codable {
    public var id: ProfileID
    public var displayName: String
    public var endpoint: RemoteEndpoint
    public var account: RemoteAccount
    public var configuration: ProtocolConfiguration
    public var createdAt: Date
    public var updatedAt: Date
    public var lastConnectedAt: Date?
    /// Added after schema version 1; absent in older documents.
    public var wakeOnLAN: WakeOnLANConfiguration?
    /// A heading the list groups the connection under; nil for none.
    public var group: String?
    private var favorite: Bool?

    /// Listed first, under お気に入り.
    public var isFavorite: Bool {
        get { favorite ?? false }
        set { favorite = newValue ? true : nil }
    }

    /// The group as shown: trimmed, nil when empty.
    public var groupName: String? {
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(
        id: ProfileID = ProfileID(),
        displayName: String,
        endpoint: RemoteEndpoint,
        account: RemoteAccount = RemoteAccount(),
        configuration: ProtocolConfiguration = .rdp(RDPConfiguration()),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.account = account
        self.configuration = configuration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var protocolKind: ProtocolKind { configuration.kind }

    /// A copy for the list's duplicate action. The credential is deliberately
    /// not carried over: sharing one stored password between two profiles has
    /// to be an explicit choice, not a side effect of duplicating.
    public func duplicated(
        displayName: String,
        id: ProfileID = ProfileID(),
        now: Date = Date()
    ) -> ConnectionProfile {
        var copy = self
        copy.id = id
        copy.displayName = displayName
        copy.account.credentialReference = nil
        if case .rdp(var rdp) = copy.configuration, rdp.gateway != nil {
            rdp.gateway?.account.credentialReference = nil
            copy.configuration = .rdp(rdp)
        }
        copy.createdAt = now
        copy.updatedAt = now
        copy.lastConnectedAt = nil
        return copy
    }
}
