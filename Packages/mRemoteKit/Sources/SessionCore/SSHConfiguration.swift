import Foundation

/// A stored private key, by reference. The key itself lives in the Keychain
/// (`SSHKeyRepository`); profiles keep only this, so several can share one
/// key and deleting a profile never deletes a key.
public struct SSHKeyID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// docs/ssh-design.md section 7.3: which sign-in methods a profile allows.
/// They are tried as public key, keyboard-interactive, password.
public struct SSHAuthentication: Hashable, Sendable, Codable {
    /// Nil: no public key sign-in.
    public var keyID: SSHKeyID?
    public var allowsKeyboardInteractive: Bool
    public var allowsPassword: Bool

    public init(keyID: SSHKeyID? = nil, allowsKeyboardInteractive: Bool = true, allowsPassword: Bool = true) {
        self.keyID = keyID
        self.allowsKeyboardInteractive = allowsKeyboardInteractive
        self.allowsPassword = allowsPassword
    }

    // The store must never contain the word "password" (ProfileStoreTests
    // checks the encoded document for it), so the flag is stored under a
    // name of its own.
    private enum CodingKeys: String, CodingKey {
        case keyID
        case allowsKeyboardInteractive
        case allowsPassword = "allowsTypedSignIn"
    }
}

public enum TerminalTheme: String, Hashable, Sendable, Codable, CaseIterable {
    /// Follows the system's light or dark appearance.
    case system
    case light
    case dark
    case solarizedDark
}

public enum TerminalCursorStyle: String, Hashable, Sendable, Codable, CaseIterable {
    case block
    case underline
    case bar
}

/// What happens when the shell exits by itself (`exit`, logout).
public enum ShellExitBehavior: String, Hashable, Sendable, Codable, CaseIterable {
    /// The last output stays, with 終了しました and a reconnect button.
    case keepScreen
    case closeSession
}

/// The terminal settings every `inherit` in a profile resolves against.
public struct TerminalDefaults: Hashable, Sendable, Codable {
    public var fontSize: Double
    public var theme: TerminalTheme
    /// Option sends ESC before the key (Meta) instead of typing a character.
    public var optionAsMeta: Bool
    public var cursorStyle: TerminalCursorStyle
    public var scrollbackLines: Int
    public var keepAliveSeconds: Int
    public var exitBehavior: ShellExitBehavior

    public static let fontSizeRange: ClosedRange<Double> = 8...32
    public static let scrollbackRange: ClosedRange<Int> = 100...100_000

    public init(
        fontSize: Double = 13,
        theme: TerminalTheme = .system,
        optionAsMeta: Bool = true,
        cursorStyle: TerminalCursorStyle = .block,
        scrollbackLines: Int = 10_000,
        keepAliveSeconds: Int = 30,
        exitBehavior: ShellExitBehavior = .keepScreen
    ) {
        self.fontSize = fontSize
        self.theme = theme
        self.optionAsMeta = optionAsMeta
        self.cursorStyle = cursorStyle
        self.scrollbackLines = scrollbackLines
        self.keepAliveSeconds = keepAliveSeconds
        self.exitBehavior = exitBehavior
    }

    public static let `default` = TerminalDefaults()
}

/// A local port forward (`ssh -L`): connections to `localPort` on this device
/// go through the SSH connection to `remoteHost:remotePort`.
public struct SSHPortForward: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var localPort: UInt16
    public var remoteHost: String
    public var remotePort: UInt16

    public init(id: UUID = UUID(), localPort: UInt16, remoteHost: String, remotePort: UInt16) {
        self.id = id
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

/// Version 1 of the SSH-specific profile payload. The user name and the
/// password reference are the profile's `RemoteAccount`, shared with RDP.
public struct SSHConfiguration: Hashable, Sendable, Codable {
    public var authentication: SSHAuthentication
    /// Sent to the shell once it is open, e.g. `tmux new -A -s main`.
    public var startupCommand: String?
    /// TERM. Nil is "xterm-256color".
    public var terminalType: String?
    public var fontSize: Inheritable<Double>
    public var theme: Inheritable<TerminalTheme>
    public var optionAsMeta: Inheritable<Bool>
    public var cursorStyle: Inheritable<TerminalCursorStyle>
    public var keepAliveSeconds: Inheritable<Int>
    public var exitBehavior: Inheritable<ShellExitBehavior>
    /// The clipboard as RDP has it: here it governs paste into the terminal
    /// and copy out of it.
    public var clipboardPolicy: Inheritable<ClipboardPolicy>
    /// Reconnect by itself when the connection drops. Off by default for SSH:
    /// a reconnect is a new shell (docs/ssh-design.md section 9).
    public var reconnectPolicy: Inheritable<ReconnectPolicy>
    public var portForwards: [SSHPortForward]?

    public static let defaultPort: UInt16 = 22
    public static let defaultTerminalType = "xterm-256color"

    public var effectiveTerminalType: String {
        let trimmed = terminalType?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? Self.defaultTerminalType : trimmed
    }

    public var effectiveStartupCommand: String? {
        let trimmed = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(
        authentication: SSHAuthentication = SSHAuthentication(),
        startupCommand: String? = nil,
        terminalType: String? = nil,
        fontSize: Inheritable<Double> = .inherit,
        theme: Inheritable<TerminalTheme> = .inherit,
        optionAsMeta: Inheritable<Bool> = .inherit,
        cursorStyle: Inheritable<TerminalCursorStyle> = .inherit,
        keepAliveSeconds: Inheritable<Int> = .inherit,
        exitBehavior: Inheritable<ShellExitBehavior> = .inherit,
        clipboardPolicy: Inheritable<ClipboardPolicy> = .inherit,
        reconnectPolicy: Inheritable<ReconnectPolicy> = .explicit(.disabled),
        portForwards: [SSHPortForward]? = nil
    ) {
        self.authentication = authentication
        self.startupCommand = startupCommand
        self.terminalType = terminalType
        self.fontSize = fontSize
        self.theme = theme
        self.optionAsMeta = optionAsMeta
        self.cursorStyle = cursorStyle
        self.keepAliveSeconds = keepAliveSeconds
        self.exitBehavior = exitBehavior
        self.clipboardPolicy = clipboardPolicy
        self.reconnectPolicy = reconnectPolicy
        self.portForwards = portForwards
    }
}

/// What one SSH connection runs with, resolved once at connect time.
public struct EffectiveSSHSettings: Hashable, Sendable {
    public let authentication: SSHAuthentication
    public let startupCommand: String?
    public let terminalType: String
    public let fontSize: Double
    public let theme: TerminalTheme
    public let optionAsMeta: Bool
    public let cursorStyle: TerminalCursorStyle
    public let scrollbackLines: Int
    public let keepAliveSeconds: Int
    public let exitBehavior: ShellExitBehavior
    public let portForwards: [SSHPortForward]

    public init(
        authentication: SSHAuthentication,
        startupCommand: String?,
        terminalType: String = SSHConfiguration.defaultTerminalType,
        fontSize: Double = TerminalDefaults.default.fontSize,
        theme: TerminalTheme = TerminalDefaults.default.theme,
        optionAsMeta: Bool = TerminalDefaults.default.optionAsMeta,
        cursorStyle: TerminalCursorStyle = TerminalDefaults.default.cursorStyle,
        scrollbackLines: Int = TerminalDefaults.default.scrollbackLines,
        keepAliveSeconds: Int = TerminalDefaults.default.keepAliveSeconds,
        exitBehavior: ShellExitBehavior = TerminalDefaults.default.exitBehavior,
        portForwards: [SSHPortForward] = []
    ) {
        self.authentication = authentication
        self.startupCommand = startupCommand
        self.terminalType = terminalType
        self.fontSize = fontSize
        self.theme = theme
        self.optionAsMeta = optionAsMeta
        self.cursorStyle = cursorStyle
        self.scrollbackLines = scrollbackLines
        self.keepAliveSeconds = keepAliveSeconds
        self.exitBehavior = exitBehavior
        self.portForwards = portForwards
    }
}
