import Foundation
import Observation
import InputCore
import SessionCore

/// The software keyboard of one session (docs/input-design.md section 10).
///
/// The text proxy reports what iPadOS committed and the key bar reports
/// taps; this turns both into host input through `SoftwareKeyboardComposer`,
/// whose chords are complete in themselves, so closing the keyboard has
/// nothing to release on the host - only the local latches.
@MainActor
@Observable
final class SoftwareKeyboardController {
    private(set) var isVisible = false
    private(set) var mode: SoftwareKeyboardMode
    /// Local IME composition not yet committed. Shown in the bar, never sent.
    var markedText: String?
    /// docs/input-design.md section 10.2: a character a Windows app does not
    /// take as a Unicode key event can go by clipboard paste instead, with
    /// the user's say-so. Armed, the next committed text - a confirmed
    /// composition, an emoji - is pasted rather than typed. One shot.
    private(set) var pastesNextCommit = false
    private var composer: SoftwareKeyboardComposer

    @ObservationIgnored weak var proxy: SoftwareKeyboardProxy?
    @ObservationIgnored private let send: (SoftwareKeyboardOutput) -> Void
    @ObservationIgnored private let canSend: () -> Bool
    /// Nil when the profile does not allow sending the clipboard; the bar
    /// then offers no paste.
    @ObservationIgnored private let paste: ((String) -> Void)?
    /// A Mac host: the bar names its keys as a Mac's (⌘ ⌥ ⌃, 英数/かな).
    /// Set later when the host turns out to be a Mac.
    var isMacHost: Bool

    init(
        mode: SoftwareKeyboardMode,
        layout: KeyboardLayoutPreference,
        canSend: @escaping () -> Bool,
        paste: ((String) -> Void)? = nil,
        isMacHost: Bool = false,
        send: @escaping (SoftwareKeyboardOutput) -> Void
    ) {
        self.isMacHost = isMacHost
        self.mode = mode
        self.composer = SoftwareKeyboardComposer(mode: mode, layout: layout)
        self.canSend = canSend
        self.paste = paste
        self.send = send
    }

    var hasMarkedText: Bool { !(markedText ?? "").isEmpty }

    func latch(_ modifier: VirtualModifier) -> VirtualModifierState.Latch {
        composer.modifiers.latch(modifier)
    }

    func show() {
        isVisible = true
    }

    /// docs/ui-flow.md section 9: closing releases every virtual modifier
    /// and gives the keyboard back to the physical surface.
    func hide() {
        pastesNextCommit = false
        cancelComposition()
        composer.releaseModifiers()
        isVisible = false
    }

    /// The proxy lost first responder. Through `hide()` this is already
    /// done; otherwise the system put the keyboard away.
    func proxyDidResign() {
        guard isVisible else { return }
        hide()
    }

    /// Refused while composing: the marked text has to be committed or
    /// cancelled first, or it would be typed under the wrong mode.
    func setMode(_ newMode: SoftwareKeyboardMode) {
        guard !hasMarkedText, newMode != mode else { return }
        composer.releaseModifiers()
        mode = newMode
        composer.mode = newMode
        proxy?.applyMode(newMode)
    }

    var canPaste: Bool { paste != nil }

    func togglePasteNextCommit() {
        guard canPaste else { return }
        pastesNextCommit.toggle()
    }

    func commit(_ text: String) {
        if pastesNextCommit, let paste {
            pastesNextCommit = false
            // Modifiers latched for this text do not apply to a paste.
            composer.releaseModifiers()
            guard canSend() else { return }
            paste(text)
            return
        }
        deliver(composer.commit(text))
    }

    func press(_ key: ExtendedKey) {
        // Esc first cancels a composition; only without one is it the
        // remote's Escape.
        if key == .escape, hasMarkedText {
            cancelComposition()
            return
        }
        guard !hasMarkedText else { return }
        deliver(composer.press(key))
    }

    /// A shortcut is its own chord: the latched modifiers neither apply to
    /// it nor are spent by it.
    func send(_ shortcut: KeyShortcut) {
        guard !hasMarkedText else { return }
        deliver(shortcut.inputs.map(SoftwareKeyboardOutput.key))
    }

    func tapModifier(_ modifier: VirtualModifier) {
        guard !hasMarkedText else { return }
        composer.tapModifier(modifier)
    }

    func confirmComposition() {
        proxy?.confirmComposition()
    }

    func cancelComposition() {
        proxy?.cancelComposition()
        markedText = nil
    }

    private func deliver(_ outputs: [SoftwareKeyboardOutput]) {
        guard canSend() else { return }
        outputs.forEach(send)
    }
}
