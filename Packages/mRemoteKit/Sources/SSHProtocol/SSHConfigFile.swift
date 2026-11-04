import Foundation

/// An OpenSSH client configuration (`~/.ssh/config`), as far as the app can
/// use one: HostName, Port, User, IdentityFile, ProxyJump, TCPKeepAlive and
/// ServerAliveInterval. Everything else is listed as not read.
///
/// Read as ssh reads it for each host: every `Host` block whose patterns
/// match, top to bottom, the first value of each keyword winning - so
/// `Host *` at the end supplies defaults, and lines before the first `Host`
/// apply to all.
public struct SSHConfigFile: Hashable, Sendable {
    /// One host the file names, with what applies to it.
    public struct Host: Hashable, Sendable {
        /// What `ssh <alias>` is typed with; a host's own name when it came
        /// from a ProxyJump that named no `Host`.
        public var alias: String
        public var hostName: String
        public var port: UInt16?
        public var user: String?
        /// The first IdentityFile, as written (`~/.ssh/id_ed25519`).
        public var identityFile: String?
        /// The alias of the host this one is reached through, among `hosts`.
        public var jump: String?
        public var tcpKeepAlive: Bool?
        public var serverAliveInterval: Int?

        public init(alias: String, hostName: String, port: UInt16? = nil, user: String? = nil,
                    identityFile: String? = nil, jump: String? = nil, tcpKeepAlive: Bool? = nil,
                    serverAliveInterval: Int? = nil) {
            self.alias = alias
            self.hostName = hostName
            self.port = port
            self.user = user
            self.identityFile = identityFile
            self.jump = jump
            self.tcpKeepAlive = tcpKeepAlive
            self.serverAliveInterval = serverAliveInterval
        }

        /// The key's file name, which is what a stored key is matched by:
        /// `~/.ssh/id_ed25519` is `id_ed25519`.
        public var identityName: String? {
            guard let identityFile else { return nil }
            let name = (identityFile as NSString).lastPathComponent
            return name.isEmpty ? nil : name
        }
    }

    /// In the order the file names them; a jump host made up from a
    /// ProxyJump comes before the first host that uses it.
    public var hosts: [Host]
    /// Keywords the app does not use, each once, as written; and `Match`,
    /// `Include` when there were any.
    public var unread: [String]

    public init(hosts: [Host], unread: [String] = []) {
        self.hosts = hosts
        self.unread = unread
    }
}

// MARK: - Reading

extension SSHConfigFile {
    private static let read: Set<String> = [
        "hostname", "port", "user", "identityfile", "proxyjump", "tcpkeepalive", "serveraliveinterval",
    ]

    private struct Block {
        /// Nil for the lines before the first Host, which apply to all.
        var patterns: [String]?
        var options: [(keyword: String, value: String)] = []
        /// A Match block: not read.
        var skipped = false

        func matches(_ alias: String) -> Bool {
            guard let patterns else { return true }
            var matched = false
            for pattern in patterns {
                if pattern.hasPrefix("!") {
                    if SSHConfigFile.glob(String(pattern.dropFirst()), alias) { return false }
                } else if SSHConfigFile.glob(pattern, alias) {
                    matched = true
                }
            }
            return matched
        }
    }

    public init(parsing text: String) {
        var blocks = [Block(patterns: nil)]
        var unread: [String] = []
        func noteUnread(_ keyword: String) {
            if !unread.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) { unread.append(keyword) }
        }
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (keyword, arguments) = Self.split(String(rawLine)) else { continue }
            switch keyword.lowercased() {
            case "host":
                blocks.append(Block(patterns: arguments))
            case "match":
                blocks.append(Block(patterns: [], skipped: true))
                noteUnread("Match")
            case "include":
                noteUnread("Include")
            case let lower where Self.read.contains(lower):
                guard !blocks[blocks.count - 1].skipped, !arguments.isEmpty else { continue }
                // IdentityFile and the rest take one argument; ProxyJump's
                // list has no spaces in it.
                blocks[blocks.count - 1].options.append((lower, arguments.joined(separator: " ")))
            default:
                if !blocks[blocks.count - 1].skipped { noteUnread(keyword) }
            }
        }

        // The hosts the file names: the concrete patterns of each Host line.
        var aliases: [String] = []
        for block in blocks {
            for pattern in block.patterns ?? [] where !pattern.hasPrefix("!") && !Self.isWildcard(pattern) {
                if !aliases.contains(pattern) { aliases.append(pattern) }
            }
        }

        // What applies to an alias: the first of each keyword, top down.
        func options(for alias: String) -> [String: String] {
            var found: [String: String] = [:]
            for block in blocks where !block.skipped && block.matches(alias) {
                for option in block.options where found[option.keyword] == nil {
                    found[option.keyword] = option.value
                }
            }
            return found
        }

        var hosts: [Host] = []
        var resolving: Set<String> = []

        /// The host for an alias, made with its jump hosts first. `user` and
        /// `port` override the file's, as `user@alias:port` in a ProxyJump
        /// does; so does `via`, the hop before in a chain, for its jump host.
        /// Such a variant gets a name of its own, unless it is the same.
        func host(_ alias: String, user: String? = nil, port: UInt16? = nil, via: String? = nil) -> String {
            let found = options(for: alias)
            var made = Host(alias: alias, hostName: alias)
            if let name = found["hostname"] {
                made.hostName = name.replacingOccurrences(of: "%h", with: alias)
                    .replacingOccurrences(of: "%%", with: "%")
            }
            made.port = port ?? found["port"].flatMap { UInt16($0) }
            made.user = user ?? found["user"]
            made.identityFile = found["identityfile"]
            made.tcpKeepAlive = found["tcpkeepalive"].flatMap(Self.yesNo)
            made.serverAliveInterval = found["serveraliveinterval"].flatMap { Int($0) }.map { max(0, $0) }
            if let via {
                made.jump = via
            } else if let proxyJump = found["proxyjump"], proxyJump.lowercased() != "none",
                      !resolving.contains(alias) {
                resolving.insert(alias)
                made.jump = chain(proxyJump)
                resolving.remove(alias)
            }
            if user != nil || port != nil || via != nil {
                // The file's own host by that name, made first if it is not yet.
                if aliases.contains(alias), !resolving.contains(alias) {
                    let name = hosts.contains { $0.alias == alias } ? alias : host(alias)
                    if let plain = hosts.first(where: { $0.alias == name }),
                       plain.port == made.port, plain.user == made.user, plain.jump == made.jump {
                        return plain.alias
                    }
                }
                made.alias = (user.map { "\($0)@" } ?? "") + alias + (port.map { ":\($0)" } ?? "")
                    + (via.map { " via \($0)" } ?? "")
            }
            if let existing = hosts.first(where: { $0.alias == made.alias }) { return existing.alias }
            hosts.append(made)
            return made.alias
        }

        /// A ProxyJump list, each hop through the one before: the alias of
        /// its last hop.
        func chain(_ list: String) -> String? {
            var previous: String?
            for (index, spec) in list.split(separator: ",").enumerated() {
                guard let hop = Self.hop(String(spec)) else { return nil }
                // The first hop takes its own jump from the file; the rest
                // are reached through the hop before, whatever theirs says.
                previous = host(hop.host, user: hop.user, port: hop.port, via: index == 0 ? nil : previous)
            }
            return previous
        }

        for alias in aliases where !hosts.contains(where: { $0.alias == alias }) {
            _ = host(alias)
        }
        self.init(hosts: hosts, unread: unread)
    }

    /// `[user@]host[:port]`, or `ssh://[user@]host[:port]`.
    static func hop(_ spec: String) -> (user: String?, host: String, port: UInt16?)? {
        var rest = spec.trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix("ssh://") { rest = String(rest.dropFirst(6)) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port: UInt16?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = UInt16(after.dropFirst()) }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
        } else if let colon = rest.lastIndex(of: ":"), rest.firstIndex(of: ":") == colon {
            port = UInt16(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty else { return nil }
        return (user.flatMap { $0.isEmpty ? nil : $0 }, rest, port)
    }

    /// A line's keyword and arguments: `Keyword arg ...` or `Keyword=arg`,
    /// with double quotes around an argument that has spaces. Nil for a blank
    /// line or a comment.
    static func split(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var keyword = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex, !trimmed[index].isWhitespace, trimmed[index] != "=" {
            keyword.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        // Whitespace, at most one "=", whitespace.
        var rest = trimmed[index...].drop { $0.isWhitespace }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0.isWhitespace } }
        var arguments: [String] = []
        var current = ""
        var quoted = false
        var inArgument = false
        for character in rest {
            if character == "\"" {
                quoted.toggle()
                inArgument = true
            } else if character.isWhitespace, !quoted {
                if inArgument { arguments.append(current) }
                current = ""
                inArgument = false
            } else if character == "#", !quoted, !inArgument {
                break
            } else {
                current.append(character)
                inArgument = true
            }
        }
        if inArgument { arguments.append(current) }
        return keyword.isEmpty ? nil : (keyword, arguments)
    }

    static func isWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    /// ssh's patterns: `*` any run, `?` one character, case-insensitively.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func yesNo(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }
}

// MARK: - Writing

extension SSHConfigFile {
    /// The file: a `Host` block per host, jump hosts named by alias. Aliases
    /// with spaces are written with dashes instead, as ssh would take them
    /// for two hosts.
    public var text: String {
        var lines = ["# mRemote から書き出した SSH 接続先"]
        for host in hosts {
            lines.append("")
            lines.append("Host \(Self.alias(host.alias))")
            lines.append("    HostName \(host.hostName)")
            if let port = host.port, port != 22 { lines.append("    Port \(port)") }
            if let user = host.user, !user.isEmpty { lines.append("    User \(Self.quoted(user))") }
            if let identityFile = host.identityFile { lines.append("    IdentityFile \(Self.quoted(identityFile))") }
            if let jump = host.jump { lines.append("    ProxyJump \(Self.alias(jump))") }
            if let interval = host.serverAliveInterval { lines.append("    ServerAliveInterval \(interval)") }
            if let tcpKeepAlive = host.tcpKeepAlive { lines.append("    TCPKeepAlive \(tcpKeepAlive ? "yes" : "no")") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An alias ssh reads as one host: no whitespace, no pattern characters.
    public static func alias(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).map { character -> Character in
            character.isWhitespace || "*?!,\"#".contains(character) ? "-" : character
        }
        let result = String(cleaned)
        return result.isEmpty ? "host" : result
    }

    private static func quoted(_ value: String) -> String {
        value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }
}
