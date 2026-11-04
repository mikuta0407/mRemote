import Foundation
import SessionCore

/// Between an ssh config and the app's SSH connections: what importing one
/// would add or change, and the file the connections make.
///
/// A host is a connection of the same name. Its key is matched by name to a
/// stored one - IdentityFile `~/.ssh/id_ed25519` to a key named `id_ed25519`
/// - since the device cannot read the file itself. ServerAliveInterval is the
/// connection's keep-alive; TCPKeepAlive no, without one, turns it off.
public enum SSHConfigProfiles {
    public struct StoredKey: Hashable, Sendable {
        public let id: SSHKeyID
        public let name: String

        public init(id: SSHKeyID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Item: Hashable, Sendable, Identifiable {
        public var id: ProfileID { profile.id }
        public let alias: String
        /// New, or an existing connection with what the file says.
        public let profile: ConnectionProfile
        public let replacesExisting: Bool
        /// The IdentityFile's name when no stored key has it.
        public let missingKey: String?
    }

    public struct Plan: Hashable, Sendable {
        public let items: [Item]
        /// What the file had that the app does not read.
        public let unread: [String]
    }

    public static func plan(
        _ file: SSHConfigFile,
        existing: [ConnectionProfile],
        keys: [StoredKey],
        now: Date = Date()
    ) -> Plan {
        // Each alias's connection, so a jump host is linked by its id.
        var ids: [String: ProfileID] = [:]
        var existingByAlias: [String: ConnectionProfile] = [:]
        for host in file.hosts {
            // By name, or by the alias a name was written as.
            let match = existing.first { $0.protocolKind == .ssh && $0.displayName == host.alias }
                ?? existing.first { $0.protocolKind == .ssh && SSHConfigFile.alias($0.displayName) == host.alias }
            if let match {
                existingByAlias[host.alias] = match
                ids[host.alias] = match.id
            } else {
                ids[host.alias] = ProfileID()
            }
        }
        let items = file.hosts.map { host -> Item in
            let previous = existingByAlias[host.alias]
            var profile = previous ?? ConnectionProfile(
                id: ids[host.alias]!, displayName: host.alias,
                endpoint: RemoteEndpoint(host: host.hostName, port: SSHConfiguration.defaultPort),
                configuration: .ssh(SSHConfiguration()), createdAt: now, updatedAt: now)
            var ssh = profile.configuration.ssh ?? SSHConfiguration()
            profile.endpoint = RemoteEndpoint(host: host.hostName, port: host.port ?? SSHConfiguration.defaultPort)
            if let user = host.user { profile.account.username = user }
            var missingKey: String?
            if let name = host.identityName {
                if let key = matchingKey(name, in: keys) {
                    ssh.authentication.keyID = key.id
                } else {
                    missingKey = name
                }
            }
            ssh.jumpProfileID = host.jump.flatMap { ids[$0] }
            if let interval = host.serverAliveInterval {
                ssh.keepAliveSeconds = .explicit(interval)
            } else if host.tcpKeepAlive == false {
                ssh.keepAliveSeconds = .explicit(0)
            }
            profile.configuration = .ssh(ssh)
            return Item(alias: host.alias, profile: profile, replacesExisting: previous != nil, missingKey: missingKey)
        }
        return Plan(items: items, unread: file.unread)
    }

    /// A stored key by the file's name: exactly, then without an extension
    /// (`id_ed25519` for `id_ed25519.pem`), ignoring case.
    static func matchingKey(_ name: String, in keys: [StoredKey]) -> StoredKey? {
        if let exact = keys.first(where: { $0.name == name }) { return exact }
        let bare = (name as NSString).deletingPathExtension.lowercased()
        return keys.first { $0.name.lowercased() == name.lowercased() }
            ?? keys.first { ($0.name as NSString).deletingPathExtension.lowercased() == bare }
    }

    /// Every SSH connection in `profiles` as a Host block, and the jump
    /// hosts they need even if not among them (from `all`).
    public static func file(
        for profiles: [ConnectionProfile],
        all: [ConnectionProfile],
        keyNames: [SSHKeyID: String]
    ) -> SSHConfigFile {
        var chosen = profiles.filter { $0.protocolKind == .ssh }
        // The jump hosts they reach through, so the file stands alone.
        var index = 0
        while index < chosen.count {
            if let jump = chosen[index].configuration.ssh?.jumpProfileID, !chosen.contains(where: { $0.id == jump }),
               let profile = all.first(where: { $0.id == jump && $0.protocolKind == .ssh }) {
                chosen.append(profile)
            }
            index += 1
        }
        // One alias each, as ssh would read it.
        var aliases: [ProfileID: String] = [:]
        var taken: Set<String> = []
        for profile in chosen {
            let base = SSHConfigFile.alias(profile.displayName)
            var alias = base
            var counter = 2
            while taken.contains(alias.lowercased()) {
                alias = "\(base)-\(counter)"
                counter += 1
            }
            taken.insert(alias.lowercased())
            aliases[profile.id] = alias
        }
        let hosts = chosen.map { profile -> SSHConfigFile.Host in
            let ssh = profile.configuration.ssh ?? SSHConfiguration()
            var host = SSHConfigFile.Host(
                alias: aliases[profile.id]!, hostName: profile.endpoint.host, port: profile.endpoint.port,
                user: profile.account.username.flatMap { $0.isEmpty ? nil : $0 })
            host.identityFile = ssh.authentication.keyID.flatMap { keyNames[$0] }.map { "~/.ssh/\($0)" }
            host.jump = ssh.jumpProfileID.flatMap { aliases[$0] }
            if case .explicit(let seconds) = ssh.keepAliveSeconds {
                if seconds > 0 {
                    host.serverAliveInterval = seconds
                } else {
                    host.tcpKeepAlive = false
                }
            }
            return host
        }
        return SSHConfigFile(hosts: hosts)
    }
}
