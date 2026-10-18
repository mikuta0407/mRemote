import Foundation

/// A saved proxy, by reference. Profiles keep only this, so several can share
/// one proxy and editing it changes all of them.
public struct ProxyID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum ProxyKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// RFC 1928. The proxy resolves the destination's name, so a name only
    /// the proxy's side knows works.
    case socks5

    public var defaultPort: UInt16 {
        switch self {
        case .socks5: return 1080
        }
    }
}

/// How the app signs in at the proxy. Only `none` today; a user name and a
/// Keychain password (RFC 1929) would be another case here, and the bridges
/// already reserve the fields for it.
public enum ProxyAuthentication: Hashable, Sendable, Codable {
    case none
}

/// A proxy the user saved once and picks from any connection, RDP or SSH,
/// as Windows App does with its saved accounts.
public struct ProxyServer: Identifiable, Hashable, Sendable, Codable {
    public var id: ProxyID
    /// What the pickers show. Falls back to host:port when empty.
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: UInt16
    public var authentication: ProxyAuthentication

    public init(
        id: ProxyID = ProxyID(),
        name: String = "",
        kind: ProxyKind = .socks5,
        host: String,
        port: UInt16 = ProxyKind.socks5.defaultPort,
        authentication: ProxyAuthentication = .none
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.authentication = authentication
    }

    public var address: String {
        let shown = host.contains(":") ? "[\(host)]" : host
        return "\(shown):\(port)"
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }
}
