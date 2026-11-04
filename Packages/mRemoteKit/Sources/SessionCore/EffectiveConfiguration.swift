import Foundation

/// What one connection attempt actually runs with, resolved once at connect
/// time and immutable thereafter. Changing a profile or a global default while
/// a session is live has no effect on it until the next connect, which is what
/// keeps the handshake parameters consistent with what the server was told.
public struct EffectiveConnectionConfiguration: Hashable, Sendable {
    public let profileID: ProfileID?
    public let displayName: String
    public let endpoint: RemoteEndpoint
    public let account: RemoteAccount
    public let resolutionPolicy: ResolutionPolicy
    public let initialScale: InitialScale
    public let displayQuality: DisplayQuality
    public let keyboardLayout: KeyboardLayoutPreference
    public let audioPlayback: Bool
    public let clipboardPolicy: ClipboardPolicy
    public let scrollDirection: ScrollDirection
    public let reconnectPolicy: ReconnectPolicy
    public let securityPolicy: SecurityPolicy
    public let gateway: RDPGatewayConfiguration?
    public let sharedFolder: SharedFolder?
    public let remoteApp: RemoteAppConfiguration?
    public let redirectsMicrophone: Bool
    public let prefersH264: Bool
    public let remotePlatform: RemotePlatform
    public let streamQuality: StreamQuality
    /// Set for an SSH connection, which then ignores the RDP settings above
    /// (they hold the global defaults, unused). docs/ssh-design.md 5.2.
    public let ssh: EffectiveSSHSettings?
    /// The proxy the connection goes through; nil for a direct one.
    public let proxy: ProxyServer?

    public var protocolKind: ProtocolKind { ssh == nil ? .rdp : .ssh }

    public init(
        profileID: ProfileID?,
        displayName: String,
        endpoint: RemoteEndpoint,
        account: RemoteAccount,
        resolutionPolicy: ResolutionPolicy,
        initialScale: InitialScale,
        displayQuality: DisplayQuality,
        keyboardLayout: KeyboardLayoutPreference,
        audioPlayback: Bool,
        clipboardPolicy: ClipboardPolicy,
        scrollDirection: ScrollDirection,
        reconnectPolicy: ReconnectPolicy,
        securityPolicy: SecurityPolicy,
        gateway: RDPGatewayConfiguration? = nil,
        sharedFolder: SharedFolder? = nil,
        remoteApp: RemoteAppConfiguration? = nil,
        redirectsMicrophone: Bool = false,
        prefersH264: Bool = true,
        remotePlatform: RemotePlatform = .standard,
        streamQuality: StreamQuality = .automatic,
        ssh: EffectiveSSHSettings? = nil,
        proxy: ProxyServer? = nil
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.endpoint = endpoint
        self.account = account
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
        self.remoteApp = remoteApp
        self.redirectsMicrophone = redirectsMicrophone
        self.prefersH264 = prefersH264
        self.remotePlatform = remotePlatform
        self.streamQuality = streamQuality
        self.ssh = ssh
        self.proxy = proxy
    }

    /// An SSH connection's last jump host, reached through the ones before
    /// it: the hop a session for this connection connects through.
    public var lastJumpHost: EffectiveConnectionConfiguration? {
        guard let ssh, let last = ssh.jumpHosts.last, let lastSSH = last.ssh else { return nil }
        return last.replacingSSH(lastSSH.through(Array(ssh.jumpHosts.dropLast())))
    }

    public func replacingSSH(_ ssh: EffectiveSSHSettings) -> EffectiveConnectionConfiguration {
        EffectiveConnectionConfiguration(
            profileID: profileID, displayName: displayName, endpoint: endpoint, account: account,
            resolutionPolicy: resolutionPolicy, initialScale: initialScale, displayQuality: displayQuality,
            keyboardLayout: keyboardLayout, audioPlayback: audioPlayback, clipboardPolicy: clipboardPolicy,
            scrollDirection: scrollDirection, reconnectPolicy: reconnectPolicy, securityPolicy: securityPolicy,
            gateway: gateway, sharedFolder: sharedFolder, remoteApp: remoteApp,
            redirectsMicrophone: redirectsMicrophone, prefersH264: prefersH264, remotePlatform: remotePlatform,
            streamQuality: streamQuality, ssh: ssh, proxy: proxy)
    }

    /// Eisu/Kana to Muhenkan/Henkan is only promised for the Japanese layout,
    /// so the UI can warn where a profile has opted out of it.
    public var guaranteesJapaneseImeKeys: Bool { keyboardLayout == .japanese }
}

public struct EffectiveProfileResolver: Sendable {
    public init() {}

    /// How many jump hosts a chain may have. A longer one is almost
    /// certainly a mistake; it is cut there rather than looped on.
    public static let maximumJumpHosts = 8

    /// `proxies` are the saved ones the profile's `proxyID` names. A
    /// reference to a proxy that is gone (deleteProxy clears them, so only a
    /// hand-edited store has one) connects directly. `profiles` are where an
    /// SSH profile's jump host is looked up; one that is gone, not SSH, or
    /// already in the chain ends the chain there.
    public func resolve(
        profile: ConnectionProfile,
        globalSettings: GlobalSettings,
        proxies: [ProxyServer] = [],
        profiles: [ConnectionProfile] = []
    ) -> EffectiveConnectionConfiguration {
        let proxy = profile.proxyID.flatMap { id in proxies.first { $0.id == id } }
        let rdp: RDPConfiguration
        switch profile.configuration {
        case .rdp(let configuration):
            rdp = configuration
        case .ssh(let ssh):
            var chain: [EffectiveConnectionConfiguration] = []
            var seen: Set<ProfileID> = [profile.id]
            var next = ssh.jumpProfileID
            var first: (profile: ConnectionProfile, ssh: SSHConfiguration)?
            while let id = next, !seen.contains(id), chain.count < Self.maximumJumpHosts,
                  let jump = profiles.first(where: { $0.id == id }), case .ssh(let jumpSSH) = jump.configuration {
                seen.insert(id)
                chain.insert(resolve(profile: jump, ssh: jumpSSH, globalSettings: globalSettings, proxy: nil), at: 0)
                first = (jump, jumpSSH)
                next = jumpSSH.jumpProfileID
            }
            // Only the hop this device connects to goes through a proxy, its
            // own: the rest are reached through it.
            if let first {
                chain[0] = resolve(
                    profile: first.profile, ssh: first.ssh, globalSettings: globalSettings,
                    proxy: first.profile.proxyID.flatMap { id in proxies.first { $0.id == id } })
            }
            return resolve(profile: profile, ssh: ssh, globalSettings: globalSettings,
                           proxy: chain.isEmpty ? proxy : nil, jumpHosts: chain)
        }
        return EffectiveConnectionConfiguration(
            profileID: profile.id,
            displayName: profile.displayName,
            endpoint: profile.endpoint,
            account: profile.account,
            resolutionPolicy: rdp.resolutionPolicy.resolved(default: globalSettings.resolutionPolicy),
            initialScale: rdp.initialScale.resolved(default: globalSettings.initialScale),
            displayQuality: rdp.displayQuality.resolved(default: globalSettings.displayQuality),
            keyboardLayout: rdp.keyboardLayout.resolved(default: globalSettings.keyboardLayout),
            audioPlayback: rdp.audioPlayback.resolved(default: globalSettings.audioPlayback),
            clipboardPolicy: rdp.clipboardPolicy.resolved(default: globalSettings.clipboardPolicy),
            scrollDirection: rdp.scrollDirection.resolved(default: globalSettings.scrollDirection),
            reconnectPolicy: rdp.reconnectPolicy.resolved(default: globalSettings.reconnectPolicy),
            securityPolicy: rdp.securityPolicy,
            gateway: rdp.gateway,
            sharedFolder: rdp.sharedFolder,
            remoteApp: rdp.remoteApp,
            redirectsMicrophone: rdp.redirectsMicrophone,
            prefersH264: rdp.prefersH264,
            remotePlatform: rdp.remotePlatform,
            streamQuality: rdp.preferredStreamQuality,
            proxy: proxy
        )
    }
}

extension EffectiveProfileResolver {
    fileprivate func resolve(
        profile: ConnectionProfile,
        ssh: SSHConfiguration,
        globalSettings: GlobalSettings,
        proxy: ProxyServer?,
        jumpHosts: [EffectiveConnectionConfiguration] = []
    ) -> EffectiveConnectionConfiguration {
        let terminal = globalSettings.terminal
        let settings = EffectiveSSHSettings(
            authentication: ssh.authentication,
            startupCommand: ssh.effectiveStartupCommand,
            terminalType: ssh.effectiveTerminalType,
            fontSize: min(max(ssh.fontSize.resolved(default: terminal.fontSize), TerminalDefaults.fontSizeRange.lowerBound),
                          TerminalDefaults.fontSizeRange.upperBound),
            theme: ssh.theme.resolved(default: terminal.theme),
            optionAsMeta: ssh.optionAsMeta.resolved(default: terminal.optionAsMeta),
            cursorStyle: ssh.cursorStyle.resolved(default: terminal.cursorStyle),
            scrollbackLines: min(max(terminal.scrollbackLines, TerminalDefaults.scrollbackRange.lowerBound),
                                 TerminalDefaults.scrollbackRange.upperBound),
            keepAliveSeconds: max(0, ssh.keepAliveSeconds.resolved(default: terminal.keepAliveSeconds)),
            exitBehavior: ssh.exitBehavior.resolved(default: terminal.exitBehavior),
            portForwards: ssh.portForwards ?? [],
            tmux: ssh.tmux ?? SSHTmuxSettings(),
            jumpHosts: jumpHosts
        )
        // The RDP fields take the global defaults: nothing reads them for an
        // SSH connection, and a real value is safer than a sentinel.
        return EffectiveConnectionConfiguration(
            profileID: profile.id,
            displayName: profile.displayName,
            endpoint: profile.endpoint,
            account: profile.account,
            resolutionPolicy: globalSettings.resolutionPolicy,
            initialScale: globalSettings.initialScale,
            displayQuality: globalSettings.displayQuality,
            keyboardLayout: globalSettings.keyboardLayout,
            audioPlayback: false,
            clipboardPolicy: ssh.clipboardPolicy.resolved(default: globalSettings.clipboardPolicy),
            scrollDirection: globalSettings.scrollDirection,
            reconnectPolicy: ssh.reconnectPolicy.resolved(default: globalSettings.reconnectPolicy),
            securityPolicy: .secureAutomatic,
            ssh: settings,
            proxy: proxy
        )
    }
}

/// Zoom, pan, the live scroll inversion and a local audio mute are not part of
/// the handshake, so they live here and may change during a session. Changing
/// one never writes back to the profile unless the user explicitly saves it as
/// that connection's default.
public struct SessionRuntimeState: Hashable, Sendable {
    public var scale: InitialScale
    public var zoom: Double
    public var scrollDirection: ScrollDirection
    public var isLocallyMuted: Bool
    /// Starts as the connection's setting; the session menu changes it for
    /// this session only.
    public var resolution: ResolutionPolicy

    public init(
        scale: InitialScale = .fit,
        zoom: Double = 1.0,
        scrollDirection: ScrollDirection = .normal,
        isLocallyMuted: Bool = false,
        resolution: ResolutionPolicy = .adaptive
    ) {
        self.scale = scale
        self.zoom = zoom
        self.scrollDirection = scrollDirection
        self.isLocallyMuted = isLocallyMuted
        self.resolution = resolution
    }

    public init(from configuration: EffectiveConnectionConfiguration) {
        self.init(
            scale: configuration.initialScale,
            zoom: 1.0,
            scrollDirection: configuration.scrollDirection,
            isLocallyMuted: false,
            resolution: configuration.resolutionPolicy
        )
    }
}
