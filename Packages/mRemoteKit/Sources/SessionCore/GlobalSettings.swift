import Foundation

/// docs/input-design.md section 10: the two software keyboard modes.
public enum SoftwareKeyboardMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// iPadOS converts; only committed text is sent, as Unicode. The host
    /// IME should be off.
    case localIME
    /// An ASCII keyboard whose keys become scan codes, so the host IME does
    /// the converting.
    case hostIME
}

/// The values every `inherit` resolves against. Defaults live here and in the
/// schema migration, never spread across the settings screens.
public struct GlobalSettings: Hashable, Sendable, Codable {
    public var resolutionPolicy: ResolutionPolicy
    public var initialScale: InitialScale
    public var displayQuality: DisplayQuality
    public var keyboardLayout: KeyboardLayoutPreference
    public var audioPlayback: Bool
    public var clipboardPolicy: ClipboardPolicy
    public var scrollDirection: ScrollDirection
    public var reconnectPolicy: ReconnectPolicy
    /// Schema v2. Where the software keyboard starts; switchable per session.
    public var softwareKeyboardMode: SoftwareKeyboardMode
    /// Schema v3. What SSH profiles inherit.
    public var terminal: TerminalDefaults

    public init(
        resolutionPolicy: ResolutionPolicy = .adaptive,
        initialScale: InitialScale = .fit,
        displayQuality: DisplayQuality = .automatic,
        keyboardLayout: KeyboardLayoutPreference = .japanese,
        audioPlayback: Bool = true,
        clipboardPolicy: ClipboardPolicy = .bidirectional,
        scrollDirection: ScrollDirection = .normal,
        reconnectPolicy: ReconnectPolicy = .automatic,
        softwareKeyboardMode: SoftwareKeyboardMode = .localIME,
        terminal: TerminalDefaults = .default
    ) {
        self.resolutionPolicy = resolutionPolicy
        self.initialScale = initialScale
        self.displayQuality = displayQuality
        self.keyboardLayout = keyboardLayout
        self.audioPlayback = audioPlayback
        self.clipboardPolicy = clipboardPolicy
        self.scrollDirection = scrollDirection
        self.reconnectPolicy = reconnectPolicy
        self.softwareKeyboardMode = softwareKeyboardMode
        self.terminal = terminal
    }

    public static let `default` = GlobalSettings()
}
