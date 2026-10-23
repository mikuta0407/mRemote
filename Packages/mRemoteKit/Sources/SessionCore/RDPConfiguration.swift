import Foundation

public enum ResolutionPolicy: Hashable, Sendable, Codable {
    /// Follow the viewport, requesting a remote resize when the server
    /// negotiated the display channel.
    case adaptive
    case fixed(width: Int, height: Int)
}

extension ResolutionPolicy {
    /// What the pickers offer besides following the screen: the common 4:3,
    /// 16:9 and 16:10 desktop sizes, smallest first.
    public static let presets: [ResolutionPolicy] = [
        .fixed(width: 1_024, height: 768),
        .fixed(width: 1_280, height: 720),
        .fixed(width: 1_280, height: 800),
        .fixed(width: 1_280, height: 1_024),
        .fixed(width: 1_366, height: 768),
        .fixed(width: 1_440, height: 900),
        .fixed(width: 1_600, height: 900),
        .fixed(width: 1_680, height: 1_050),
        .fixed(width: 1_920, height: 1_080),
        .fixed(width: 1_920, height: 1_200),
        .fixed(width: 2_560, height: 1_440),
        .fixed(width: 2_560, height: 1_600),
        .fixed(width: 3_840, height: 2_160),
    ]

    /// The desktop size to ask for, given the size the surface would fill.
    /// Nil while an adaptive policy has nothing to follow yet.
    public func desktopSize(
        fitting renderSize: (width: Int, height: Int)?
    ) -> (width: Int, height: Int)? {
        switch self {
        case .adaptive: return renderSize
        case let .fixed(width, height): return (width, height)
        }
    }
}

public enum InitialScale: String, Hashable, Sendable, Codable, CaseIterable {
    case fit
    case oneToOne
}

public enum DisplayQuality: Hashable, Sendable, Codable {
    case automatic
    case explicit(colorDepth: Int)
}

public enum KeyboardLayoutPreference: String, Hashable, Sendable, Codable, CaseIterable {
    /// The only configuration in which Eisu/Kana to Muhenkan/Henkan is
    /// promised. The connection form says so where the other options are
    /// selected.
    case japanese
    case us
    case automatic
}

public enum ClipboardPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case disabled
    /// Permission to transfer in both directions on an explicit user action.
    /// It does not mean the pasteboard is monitored - except on the Mac,
    /// where the app mirrors the permitted directions by itself.
    case bidirectional
    case sendOnly
    case receiveOnly

    public var allowsSend: Bool { self == .bidirectional || self == .sendOnly }
    public var allowsReceive: Bool { self == .bidirectional || self == .receiveOnly }
}

public enum ScrollDirection: String, Hashable, Sendable, Codable, CaseIterable {
    case normal
    case reversed
}

public enum ReconnectPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case disabled
    case automatic
}

/// How much transport security may be negotiated down. There is no inherit
/// case: a global default that silently weakens every connection is exactly
/// what this setting exists to prevent.
public enum SecurityPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case secureAutomatic
    case nlaRequired
    case tlsRequired
    /// Legacy RDP security, only ever by explicit per-profile choice, and
    /// surfaced in the UI as a warning.
    case legacyExplicit
}

/// An RD Gateway the connection goes through.
public struct RDPGatewayConfiguration: Hashable, Sendable, Codable {
    public var host: String
    public var port: UInt16
    /// True to sign in to the gateway as the computer's user; otherwise with
    /// `account`, whose password is in the Keychain.
    public var usesComputerCredentials: Bool
    public var account: RemoteAccount
    /// Computers on the local network are reached without the gateway.
    public var bypassesLocalAddresses: Bool

    public static let defaultPort: UInt16 = 443

    public init(
        host: String,
        port: UInt16 = RDPGatewayConfiguration.defaultPort,
        usesComputerCredentials: Bool = true,
        account: RemoteAccount = RemoteAccount(),
        bypassesLocalAddresses: Bool = false
    ) {
        self.host = host
        self.port = port
        self.usesComputerCredentials = usesComputerCredentials
        self.account = account
        self.bypassesLocalAddresses = bypassesLocalAddresses
    }
}

/// A folder on this device that the computer sees as a drive.
public struct SharedFolder: Hashable, Sendable, Codable {
    public enum Location: Hashable, Sendable, Codable {
        /// The app's own Documents, which the Files app shows as "mRemote".
        case appDocuments
        /// A folder the user picked, kept as a security-scoped bookmark.
        case bookmark(Data, displayName: String)
    }

    public var location: Location
    /// What the drive is called on the computer.
    public var driveName: String

    public init(location: Location, driveName: String) {
        self.location = location
        self.driveName = driveName
    }

    /// Letters, digits, space, '-' and '_' only, at most 32 characters: the
    /// name a server shows, kept to what every server accepts.
    public static func sanitizedDriveName(_ name: String) -> String {
        let allowed = name.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_")
        }
        let trimmed = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "mRemote" : String(trimmed.prefix(32))
    }
}

/// A program to run as a RemoteApp: an alias the server publishes, such as
/// "||notepad", or a path.
public struct RemoteAppConfiguration: Hashable, Sendable, Codable {
    public var program: String
    public var arguments: String

    public init(program: String, arguments: String = "") {
        self.program = program
        self.arguments = arguments
    }
}

/// Version 1 of the RDP-specific profile payload.
public struct RDPConfiguration: Hashable, Sendable, Codable {
    public var resolutionPolicy: Inheritable<ResolutionPolicy>
    public var initialScale: Inheritable<InitialScale>
    public var displayQuality: Inheritable<DisplayQuality>
    public var keyboardLayout: Inheritable<KeyboardLayoutPreference>
    public var audioPlayback: Inheritable<Bool>
    public var clipboardPolicy: Inheritable<ClipboardPolicy>
    public var scrollDirection: Inheritable<ScrollDirection>
    public var reconnectPolicy: Inheritable<ReconnectPolicy>
    public var securityPolicy: SecurityPolicy
    /// Added after version 1; absent in older documents, which decode as nil.
    public var gateway: RDPGatewayConfiguration?
    public var sharedFolder: SharedFolder?
    /// RemoteApp: one program instead of the desktop.
    public var remoteApp: RemoteAppConfiguration?
    /// Sends this device's microphone when the computer asks for it.
    public var microphone: Bool?
    /// H.264 (AVC420) graphics. Nil is the default, on.
    public var usesH264: Bool?
    /// What kind of computer this reaches. Nil is automatic: the Mac
    /// extensions are offered and a Mac server takes them up.
    public var platform: RemotePlatform?
    /// The stream a Mac server is asked for. Nil is automatic.
    public var streamQuality: StreamQuality?

    public var redirectsMicrophone: Bool { microphone ?? false }
    public var prefersH264: Bool { usesH264 ?? true }
    public var remotePlatform: RemotePlatform { platform ?? .automatic }
    public var preferredStreamQuality: StreamQuality { streamQuality ?? .automatic }

    public init(
        resolutionPolicy: Inheritable<ResolutionPolicy> = .inherit,
        initialScale: Inheritable<InitialScale> = .inherit,
        displayQuality: Inheritable<DisplayQuality> = .inherit,
        keyboardLayout: Inheritable<KeyboardLayoutPreference> = .inherit,
        audioPlayback: Inheritable<Bool> = .inherit,
        clipboardPolicy: Inheritable<ClipboardPolicy> = .inherit,
        scrollDirection: Inheritable<ScrollDirection> = .inherit,
        reconnectPolicy: Inheritable<ReconnectPolicy> = .inherit,
        securityPolicy: SecurityPolicy = .secureAutomatic,
        gateway: RDPGatewayConfiguration? = nil,
        sharedFolder: SharedFolder? = nil
    ) {
        self.resolutionPolicy = resolutionPolicy
        self.initialScale = initialScale
        self.displayQuality = displayQuality
        self.keyboardLayout = keyboardLayout
        self.audioPlayback = audioPlayback
        self.clipboardPolicy = clipboardPolicy
        self.scrollDirection = scrollDirection
        self.reconnectPolicy = reconnectPolicy
        self.securityPolicy = securityPolicy
        self.gateway = gateway
        self.sharedFolder = sharedFolder
    }
}
