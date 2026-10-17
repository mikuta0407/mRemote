import Foundation
import Observation
import SessionCore

/// The editable form behind the add/edit sheet.
///
/// It is a model rather than `@State` in the view so the validation rules have
/// one home and can be tested without presenting anything.
@MainActor
@Observable
final class ProfileEditorModel: Identifiable {
    enum Mode {
        case create
        case edit(ConnectionProfile)
        /// A new profile filled in from a `.rdp` file or an `rdp://` link,
        /// with the settings it named that this app does not carry out.
        case importing(ConnectionProfile, unsupported: [String])
    }

    nonisolated let id = UUID()

    /// RDP or SSH. Chosen when the profile is created; an existing profile
    /// keeps its protocol (its settings would not carry over).
    var protocolKind: ProtocolKind = .rdp {
        didSet {
            // A port left at the old protocol's default follows the new one.
            if portText == String(oldValue.defaultPort) { portText = "" }
        }
    }
    var canChangeProtocol: Bool { existing == nil && !isImport }

    // SSH (docs/ssh-design.md 8.1).
    var sshKeyID: SSHKeyID?
    var sshAllowsKeyboardInteractive = true
    var sshAllowsPassword = true
    var startupCommand = ""
    var terminalType = ""
    var terminalFontSize: Inheritable<Double> = .inherit
    var terminalTheme: Inheritable<TerminalTheme> = .inherit
    var optionAsMeta: Inheritable<Bool> = .inherit
    var keepAliveSeconds: Inheritable<Int> = .inherit
    var shellExitBehavior: Inheritable<ShellExitBehavior> = .inherit
    var sshReconnectPolicy: Inheritable<ReconnectPolicy> = .explicit(.disabled)
    var portForwards: [SSHPortForward] = []

    var displayName: String
    var host: String
    var portText: String
    var username: String
    var domain: String
    var password: String
    var keyboardLayout: Inheritable<KeyboardLayoutPreference>
    var securityPolicy: SecurityPolicy
    var audioPlayback: Inheritable<Bool>
    var clipboardPolicy: Inheritable<ClipboardPolicy>
    var scrollDirection: Inheritable<ScrollDirection>
    var resolutionPolicy: Inheritable<ResolutionPolicy>

    // RD Gateway.
    var usesGateway = false
    var gatewayHost = ""
    var gatewayPortText = String(RDPGatewayConfiguration.defaultPort)
    var gatewayUsesComputerCredentials = true
    var gatewayUsername = ""
    var gatewayDomain = ""
    var gatewayPassword = ""
    var gatewayBypassesLocal = false

    // The folder shared as a drive.
    enum SharedFolderChoice: Hashable {
        case none
        case appDocuments
        case picked(bookmark: Data, name: String)
    }
    var sharedFolder: SharedFolderChoice = .none

    var group = ""
    var isFavorite = false
    var redirectsMicrophone = false
    var usesH264 = true
    var remotePlatform = RemotePlatform.standard
    var streamQuality = StreamQuality.automatic
    var remoteProgram = ""
    var remoteArguments = ""
    var wakesOnLAN = false
    var macAddress = ""
    var wakeTarget = WakeOnLANConfiguration.defaultTarget
    var wakePortText = String(WakeOnLANConfiguration.defaultPort)
    var wakesBeforeConnecting = true
    var driveName = "mRemote"

    private let existing: ConnectionProfile?
    /// What a new profile is built on: an import's settings beyond the form.
    private let base: RDPConfiguration?
    /// Shown above the form for an import.
    let unsupportedImportSettings: [String]
    let isImport: Bool

    init(mode: Mode, password: String? = nil) {
        switch mode {
        case .create:
            existing = nil
            base = nil
            unsupportedImportSettings = []
            isImport = false
            displayName = ""
            host = ""
            portText = ""
            username = ""
            domain = ""
            keyboardLayout = .inherit
            securityPolicy = .secureAutomatic
            audioPlayback = .inherit
            clipboardPolicy = .inherit
            scrollDirection = .inherit
            resolutionPolicy = .inherit
        case .edit(let profile), .importing(let profile, _):
            if case .importing(_, let unsupported) = mode {
                existing = nil
                unsupportedImportSettings = unsupported
                isImport = true
            } else {
                existing = profile
                unsupportedImportSettings = []
                isImport = false
            }
            base = profile.configuration.rdp
            protocolKind = profile.protocolKind
            displayName = profile.displayName
            host = profile.endpoint.host
            portText = profile.endpoint.port == profile.protocolKind.defaultPort ? "" : String(profile.endpoint.port)
            username = profile.account.username ?? ""
            domain = profile.account.domain ?? ""
            let rdp = profile.configuration.rdp ?? RDPConfiguration()
            group = profile.group ?? ""
            isFavorite = profile.isFavorite
            redirectsMicrophone = rdp.redirectsMicrophone
            usesH264 = rdp.prefersH264
            remotePlatform = rdp.remotePlatform
            streamQuality = rdp.preferredStreamQuality
            remoteProgram = rdp.remoteApp?.program ?? ""
            remoteArguments = rdp.remoteApp?.arguments ?? ""
            if let wake = profile.wakeOnLAN {
                wakesOnLAN = true
                macAddress = wake.macAddress
                wakeTarget = wake.targetAddress
                wakePortText = String(wake.port)
                wakesBeforeConnecting = wake.wakesBeforeConnecting
            }
            keyboardLayout = rdp.keyboardLayout
            securityPolicy = rdp.securityPolicy
            audioPlayback = rdp.audioPlayback
            clipboardPolicy = rdp.clipboardPolicy
            scrollDirection = rdp.scrollDirection
            resolutionPolicy = rdp.resolutionPolicy
            if let gateway = rdp.gateway {
                usesGateway = true
                gatewayHost = gateway.host
                gatewayPortText = String(gateway.port)
                gatewayUsesComputerCredentials = gateway.usesComputerCredentials
                gatewayUsername = gateway.account.username ?? ""
                gatewayDomain = gateway.account.domain ?? ""
                gatewayBypassesLocal = gateway.bypassesLocalAddresses
            }
            if let ssh = profile.configuration.ssh {
                sshKeyID = ssh.authentication.keyID
                sshAllowsKeyboardInteractive = ssh.authentication.allowsKeyboardInteractive
                sshAllowsPassword = ssh.authentication.allowsPassword
                startupCommand = ssh.startupCommand ?? ""
                terminalType = ssh.terminalType ?? ""
                terminalFontSize = ssh.fontSize
                terminalTheme = ssh.theme
                optionAsMeta = ssh.optionAsMeta
                keepAliveSeconds = ssh.keepAliveSeconds
                shellExitBehavior = ssh.exitBehavior
                clipboardPolicy = ssh.clipboardPolicy
                sshReconnectPolicy = ssh.reconnectPolicy
                portForwards = ssh.portForwards ?? []
            }
            if let folder = rdp.sharedFolder {
                switch folder.location {
                case .appDocuments: sharedFolder = .appDocuments
                case let .bookmark(data, name): sharedFolder = .picked(bookmark: data, name: name)
                }
                driveName = folder.driveName
            }
        }
        self.password = password ?? ""
    }

    var isEditing: Bool { existing != nil }

    var title: String {
        isEditing ? String(localized: "接続先を編集")
            : isImport ? String(localized: "接続先を読み込む") : String(localized: "接続先を追加")
    }

    /// What an empty port field means: 3389, or 22 for SSH.
    var defaultPort: UInt16 { protocolKind.defaultPort }

    /// Nil only for something that is not a port; an empty field is the
    /// protocol's default.
    var port: UInt16? { Self.parsePort(portText, default: defaultPort) }

    private static func parsePort(_ text: String, default fallback: UInt16) -> UInt16? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return fallback }
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    var gatewayPort: UInt16? {
        Self.parsePort(gatewayPortText, default: RDPGatewayConfiguration.defaultPort)
    }

    var trimmedGatewayHost: String { gatewayHost.trimmingCharacters(in: .whitespaces) }

    var isWakeValid: Bool {
        !wakesOnLAN || (MagicPacket.macBytes(macAddress) != nil && UInt16(wakePortText) != nil
            && !wakeTarget.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var isValid: Bool {
        guard !trimmedHost.isEmpty, port != nil, isWakeValid else { return false }
        switch protocolKind {
        case .rdp:
            return !usesGateway || (!trimmedGatewayHost.isEmpty && gatewayPort != nil)
        case .ssh:
            return portForwards.allSatisfy { $0.localPort > 0 && $0.remotePort > 0 && !$0.remoteHost.isEmpty }
        }
    }

    /// An SSH profile with no key and both typed methods turned off could
    /// never sign in.
    var showsNoSignInMethodWarning: Bool {
        protocolKind == .ssh && sshKeyID == nil && !sshAllowsPassword && !sshAllowsKeyboardInteractive
    }

    /// The Eisu/Kana promise only holds for the Japanese layout, so the form
    /// says where it does not rather than silently mapping the keys anyway.
    var showsJapaneseKeyWarning: Bool {
        if case .explicit(let layout) = keyboardLayout, layout != .japanese { return true }
        return false
    }

    var showsLegacySecurityWarning: Bool { securityPolicy == .legacyExplicit }

    /// docs/data-and-security.md section 4: legacy RDP Security only by
    /// explicit consent. Choosing it in the picker only asks; the policy
    /// changes when the user confirms.
    var isConfirmingLegacySecurity = false

    func choose(_ policy: SecurityPolicy) {
        if policy == .legacyExplicit, securityPolicy != .legacyExplicit {
            isConfirmingLegacySecurity = true
        } else {
            securityPolicy = policy
        }
    }

    func confirmLegacySecurity() {
        isConfirmingLegacySecurity = false
        securityPolicy = .legacyExplicit
    }

    func declineLegacySecurity() {
        isConfirmingLegacySecurity = false
    }

    /// A name is optional in the form; falling back to the host is friendlier
    /// than refusing to save.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? trimmedHost : trimmed
    }

    private func makeSSHConfiguration() -> SSHConfiguration {
        var ssh = existing?.configuration.ssh ?? SSHConfiguration()
        ssh.authentication = SSHAuthentication(
            keyID: sshKeyID,
            allowsKeyboardInteractive: sshAllowsKeyboardInteractive,
            allowsPassword: sshAllowsPassword)
        let command = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        ssh.startupCommand = command.isEmpty ? nil : command
        let term = terminalType.trimmingCharacters(in: .whitespaces)
        ssh.terminalType = term.isEmpty ? nil : term
        ssh.fontSize = terminalFontSize
        ssh.theme = terminalTheme
        ssh.optionAsMeta = optionAsMeta
        ssh.keepAliveSeconds = keepAliveSeconds
        ssh.exitBehavior = shellExitBehavior
        ssh.clipboardPolicy = clipboardPolicy
        ssh.reconnectPolicy = sshReconnectPolicy
        ssh.portForwards = portForwards.isEmpty ? nil : portForwards
        return ssh
    }

    func makeProfile(now: Date = Date()) -> ConnectionProfile? {
        guard let port else { return nil }
        if protocolKind == .ssh {
            var profile = existing ?? ConnectionProfile(
                displayName: resolvedDisplayName,
                endpoint: RemoteEndpoint(host: trimmedHost, port: port),
                createdAt: now,
                updatedAt: now
            )
            profile.displayName = resolvedDisplayName
            profile.endpoint = RemoteEndpoint(host: trimmedHost, port: port)
            let user = username.trimmingCharacters(in: .whitespaces)
            profile.account.username = user.isEmpty ? nil : user
            profile.account.domain = nil
            profile.configuration = .ssh(makeSSHConfiguration())
            applyCommon(to: &profile, now: now)
            return profile
        }
        // Built on what was there, so a field the form does not show is
        // kept rather than reset to inherit.
        var configuration = existing?.configuration.rdp ?? base ?? RDPConfiguration()
        configuration.keyboardLayout = keyboardLayout
        configuration.audioPlayback = audioPlayback
        configuration.clipboardPolicy = clipboardPolicy
        configuration.scrollDirection = scrollDirection
        configuration.resolutionPolicy = resolutionPolicy
        configuration.securityPolicy = securityPolicy
        if usesGateway, let gatewayPort {
            var gateway = configuration.gateway ?? RDPGatewayConfiguration(host: trimmedGatewayHost)
            gateway.host = trimmedGatewayHost
            gateway.port = gatewayPort
            gateway.usesComputerCredentials = gatewayUsesComputerCredentials
            gateway.account.username = gatewayUsername.isEmpty ? nil : gatewayUsername
            gateway.account.domain = gatewayDomain.isEmpty ? nil : gatewayDomain
            gateway.bypassesLocalAddresses = gatewayBypassesLocal
            configuration.gateway = gateway
        } else {
            configuration.gateway = nil
        }
        configuration.microphone = redirectsMicrophone ? true : nil
        configuration.usesH264 = usesH264 ? nil : false
        configuration.platform = remotePlatform == .standard ? nil : remotePlatform
        configuration.streamQuality = remotePlatform == .macOS && streamQuality != .automatic
            ? streamQuality : nil
        let program = remoteProgram.trimmingCharacters(in: .whitespaces)
        configuration.remoteApp = program.isEmpty
            ? nil
            : RemoteAppConfiguration(program: program, arguments: remoteArguments.trimmingCharacters(in: .whitespaces))
        switch sharedFolder {
        case .none:
            configuration.sharedFolder = nil
        case .appDocuments:
            configuration.sharedFolder = SharedFolder(location: .appDocuments, driveName: driveName)
        case let .picked(bookmark, name):
            configuration.sharedFolder = SharedFolder(
                location: .bookmark(bookmark, displayName: name),
                driveName: driveName
            )
        }
        var profile = existing ?? ConnectionProfile(
            displayName: resolvedDisplayName,
            endpoint: RemoteEndpoint(host: trimmedHost, port: port),
            createdAt: now,
            updatedAt: now
        )
        profile.displayName = resolvedDisplayName
        profile.endpoint = RemoteEndpoint(host: trimmedHost, port: port)
        profile.account.username = username.isEmpty ? nil : username
        profile.account.domain = domain.isEmpty ? nil : domain
        profile.configuration = .rdp(configuration)
        applyCommon(to: &profile, now: now)
        return profile
    }

    /// What RDP and SSH profiles share past the endpoint and account.
    private func applyCommon(to profile: inout ConnectionProfile, now: Date) {
        profile.group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : group
        profile.isFavorite = isFavorite
        profile.wakeOnLAN = wakesOnLAN
            ? WakeOnLANConfiguration(
                macAddress: macAddress.trimmingCharacters(in: .whitespaces),
                targetAddress: wakeTarget.trimmingCharacters(in: .whitespaces),
                port: UInt16(wakePortText) ?? WakeOnLANConfiguration.defaultPort,
                wakesBeforeConnecting: wakesBeforeConnecting
            )
            : nil
        profile.updatedAt = now
    }
}
