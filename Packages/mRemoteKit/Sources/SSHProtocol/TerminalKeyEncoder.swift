import Foundation

/// A key the app sends itself - from the terminal key bar, the Mac menu or a
/// hardware key the terminal view leaves to the app - rather than text the
/// IME committed.
public enum TerminalKey: Hashable, Sendable {
    case character(Character)
    case enter
    case tab
    case backspace
    case escape
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    /// F1...F12.
    case function(Int)
}

public struct TerminalModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = TerminalModifiers(rawValue: 1 << 0)
    /// Option/Alt as Meta: ESC before the key.
    public static let meta = TerminalModifiers(rawValue: 1 << 1)
    public static let control = TerminalModifiers(rawValue: 1 << 2)
}

/// Keys to the bytes an xterm sends, so a shell, vim or tmux on the other end
/// reads them as it would from any terminal (docs/ssh-design.md 8.3).
public enum TerminalKeyEncoder {
    /// `applicationCursor` is DECCKM, which full-screen programs turn on: the
    /// arrows then send SS3 (ESC O A) instead of CSI (ESC [ A).
    public static func bytes(
        for key: TerminalKey,
        modifiers: TerminalModifiers = [],
        applicationCursor: Bool = false
    ) -> [UInt8] {
        // xterm's modifier parameter: 1 + shift + 2·alt + 4·ctrl.
        let parameter = 1 + (modifiers.contains(.shift) ? 1 : 0)
            + (modifiers.contains(.meta) ? 2 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
        let modified = parameter > 1

        func cursor(_ final: Character) -> [UInt8] {
            if modified { return csi("1;\(parameter)\(final)") }
            return applicationCursor ? esc("O\(final)") : csi("\(final)")
        }
        func tilde(_ code: Int) -> [UInt8] {
            modified ? csi("\(code);\(parameter)~") : csi("\(code)~")
        }

        switch key {
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .function(let n):
            switch n {
            case 1...4:
                let final = Character(UnicodeScalar(UInt8(ascii: "P") + UInt8(n - 1)))
                return modified ? csi("1;\(parameter)\(final)") : esc("O\(final)")
            case 5: return tilde(15)
            case 6...10: return tilde(11 + n)   // 17...21
            case 11, 12: return tilde(12 + n)   // 23, 24
            default: return []
            }
        case .enter:
            return withMeta(modifiers, [0x0D])
        case .tab:
            return modifiers.contains(.shift) ? csi("Z") : withMeta(modifiers, [0x09])
        case .backspace:
            return withMeta(modifiers, [modifiers.contains(.control) ? 0x08 : 0x7F])
        case .escape:
            return withMeta(modifiers, [0x1B])
        case .character(let character):
            if modifiers.contains(.control), let control = controlByte(for: character) {
                return withMeta(modifiers, [control])
            }
            return withMeta(modifiers, Array(String(character).utf8))
        }
    }

    /// Ctrl plus a key, as a terminal has always sent it. Nil where Ctrl has
    /// no ASCII meaning; the character is then sent unchanged.
    public static func controlByte(for character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return ascii - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return ascii - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "7"), UInt8(ascii: "/"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    /// Pasted text, wrapped in the bracketed-paste markers when the program
    /// asked for them (DECSET 2004), so a shell does not run each line as it
    /// arrives. The markers inside the text are removed: a paste must not be
    /// able to end itself early and smuggle in keystrokes.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        // Terminals send CR for Enter; a pasted LF would not run a line in a
        // shell without bracketed paste, and CRLF would run it twice.
        var normalised = text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        guard bracketed else { return Array(normalised.utf8) }
        // Until none is left: removing one can join the text around it into
        // another ("ESC[20" + "ESC[201~" + "1~").
        while normalised.contains("\u{1B}[200~") || normalised.contains("\u{1B}[201~") {
            normalised = normalised.replacingOccurrences(of: "\u{1B}[200~", with: "")
                .replacingOccurrences(of: "\u{1B}[201~", with: "")
        }
        return csi("200~") + Array(normalised.utf8) + csi("201~")
    }

    /// True when pasting `text` without bracketed paste would run commands:
    /// it has a line break. The UI confirms first (docs/ssh-design.md 8.3).
    public static func pasteNeedsConfirmation(_ text: String, bracketed: Bool) -> Bool {
        !bracketed && text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
    }

    private static func esc(_ rest: String) -> [UInt8] { [0x1B] + Array(rest.utf8) }
    private static func csi(_ rest: String) -> [UInt8] { [0x1B, UInt8(ascii: "[")] + Array(rest.utf8) }
    private static func withMeta(_ modifiers: TerminalModifiers, _ bytes: [UInt8]) -> [UInt8] {
        modifiers.contains(.meta) ? [0x1B] + bytes : bytes
    }
}
