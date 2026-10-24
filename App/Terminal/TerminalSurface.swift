import SwiftUI
import UIKit
import ObjectiveC
import SwiftTerm
import SessionCore
import SSHProtocol

/// The terminal a session's shell draws into (docs/ssh-design.md 8.2).
///
/// SwiftTerm does the emulation and owns text input - including the IME's
/// marked text, which a terminal wants, unlike the RDP surface. This wraps
/// it with what the app adds: output drained from the session's buffer on the
/// main thread in time slices, keystrokes to the session's input sink, the
/// PTY size sent on resize, and paste checked before it can run commands.
struct TerminalSurface: UIViewRepresentable {
    let session: any TerminalSession
    let settings: EffectiveSSHSettings
    let isInputEnabled: Bool
    var clipboardPolicy: ClipboardPolicy = .bidirectional
    /// The session's terminal from an earlier appearance. Reused, so the
    /// screen, scrollback and the modes the remote program set survive a
    /// trip to the list and back.
    var existing: SessionTerminalView?
    var onSendRefused: () -> Void = {}
    var onPasteNeedsConfirmation: (String, @escaping () -> Void) -> Void = { _, proceed in proceed() }
    var onOpenLink: (URL) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    /// Gives the workspace a way to reach the view (menu commands, focus).
    var onReady: (SessionTerminalView) -> Void = { _ in }

    func makeUIView(context: Context) -> SessionTerminalView {
        let view = existing ?? SessionTerminalView(session: session, settings: settings)
        apply(to: view)
        onReady(view)
        return view
    }

    func updateUIView(_ view: SessionTerminalView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: SessionTerminalView) {
        view.isInputEnabled = isInputEnabled
        view.clipboardPolicy = clipboardPolicy
        view.onSendRefused = onSendRefused
        view.onPasteNeedsConfirmation = onPasteNeedsConfirmation
        view.onOpenLink = onOpenLink
        view.onTitle = onTitle
    }

    // No dismantleUIView: the view outlives this appearance. The workspace
    // detaches it when the session closes.
}

final class SessionTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
    private let session: any TerminalSession
    private let settings: EffectiveSSHSettings
    /// User input: keys, the key bar, paste. The terminal's own replies to
    /// the remote program's queries are sent regardless.
    var isInputEnabled = true
    var clipboardPolicy: ClipboardPolicy = .bidirectional
    var onSendRefused: () -> Void = {}
    var onPasteNeedsConfirmation: (String, @escaping () -> Void) -> Void = { _, proceed in proceed() }
    var onOpenLink: (URL) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }

    private var draining = false
    /// True while output is fed in: what SwiftTerm sends then is a reply
    /// (DSR, DA), not user input.
    private var feeding = false
    private var detached = false
    private var resizeTask: Task<Void, Never>?
    private var fontSize: CGFloat
    /// The IME's text being composed, drawn over the cursor: SwiftTerm keeps
    /// it to itself until it is committed.
    private let compositionLabel = UILabel()

    /// One slice of output per run loop turn, so a `cat` of a large file
    /// cannot freeze the UI (docs/ssh-design.md 6.3).
    private static let drainBudget: TimeInterval = 0.008
    private static let drainChunk = 64 * 1024
    private static let resizeDebounce = Duration.milliseconds(150)

    init(session: any TerminalSession, settings: EffectiveSSHSettings) {
        self.session = session
        self.settings = settings
        self.fontSize = CGFloat(settings.fontSize)
        let options = TerminalOptions(
            termName: settings.terminalType,
            cursorStyle: Self.cursorStyle(settings.cursorStyle),
            scrollback: settings.scrollbackLines)
        super.init(frame: .zero, font: Self.font(size: CGFloat(settings.fontSize)), options: options)
        terminalDelegate = self
        optionAsMetaKey = settings.optionAsMeta
        #if !targetEnvironment(macCatalyst)
        inputAccessoryView = TerminalKeyBar(terminal: self)
        #endif
        applyTheme()
        Self.installCompositionHooks
        compositionLabel.isHidden = true
        compositionLabel.numberOfLines = 0
        compositionLabel.isAccessibilityElement = false
        compositionLabel.accessibilityIdentifier = "terminal-composition"
        addSubview(compositionLabel)
        session.terminalOutput.setReadableHandler { [weak self] in
            DispatchQueue.main.async { self?.drain() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    #if DEBUG
    /// What the terminal holds, for UI tests against a live host.
    override var accessibilityValue: String? {
        get { String(String(decoding: getTerminal().getBufferAsData(), as: UTF8.self).suffix(4000)) }
        set {}
    }
    #endif

    /// The session closed. Stops output and SwiftTerm's display link, which
    /// holds the view and would otherwise keep it alive.
    func detach() {
        detached = true
        session.terminalOutput.setReadableHandler(nil)
        resizeTask?.cancel()
        updateUiClosed()
    }

    // MARK: Output

    private func drain() {
        guard !draining, !detached else { return }
        draining = true
        defer { draining = false }
        let started = Date()
        while Date().timeIntervalSince(started) < Self.drainBudget {
            let bytes = session.terminalOutput.drain(maximum: Self.drainChunk)
            if bytes.isEmpty { return }
            feeding = true
            feed(byteArray: bytes[...])
            feeding = false
        }
        // Over budget with output left: come back on the next turn.
        if !session.terminalOutput.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }

    // MARK: Appearance

    static func font(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func cursorStyle(_ style: TerminalCursorStyle) -> CursorStyle {
        switch style {
        case .block: return .steadyBlock
        case .underline: return .steadyUnderline
        case .bar: return .steadyBar
        }
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, CGFloat(TerminalDefaults.fontSizeRange.lowerBound)),
                       CGFloat(TerminalDefaults.fontSizeRange.upperBound))
        font = Self.font(size: fontSize)
    }

    func adjustFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }
    func resetFontSize() { setFontSize(CGFloat(settings.fontSize)) }

    /// The local scrollback only, as Terminal.app's "Clear Scrollback"
    /// does: ED 3. RIS would also reset the remote program's modes.
    func clearLocalScrollback() {
        clearScrollback()
    }

    /// ⌘= as well as the menu's ⌘+, which needs Shift on a US layout:
    /// Terminal.app takes both. No title, so it adds no menu item.
    override var keyCommands: [UIKeyCommand]? {
        let bigger = UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(makeFontBigger))
        bigger.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [bigger]
    }

    @objc private func makeFontBigger() { adjustFontSize(by: 1) }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if settings.theme == .system,
           traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
            applyTheme()
        }
    }

    private func applyTheme() {
        let dark: Bool
        switch settings.theme {
        case .system: dark = traitCollection.userInterfaceStyle == .dark
        case .light: dark = false
        case .dark, .solarizedDark: dark = true
        }
        if settings.theme == .solarizedDark {
            nativeBackgroundColor = UIColor(red: 0, green: 0x2B / 255, blue: 0x36 / 255, alpha: 1)
            nativeForegroundColor = UIColor(red: 0x83 / 255, green: 0x94 / 255, blue: 0x96 / 255, alpha: 1)
            installColors(Self.solarized)
        } else {
            nativeBackgroundColor = dark ? .black : .white
            nativeForegroundColor = dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        }
        backgroundColor = nativeBackgroundColor
        keyboardAppearance = dark ? .dark : .light
    }

    private static let solarized: [SwiftTerm.Color] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ].map { rgb in
        SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257,
                        green: UInt16((rgb >> 8) & 0xFF) * 257,
                        blue: UInt16(rgb & 0xFF) * 257)
    }

    // MARK: Input

    /// Keys from the menu or a key bar outside the terminal's own.
    func sendKey(_ key: TerminalKey, modifiers: TerminalModifiers = []) {
        let bytes = TerminalKeyEncoder.bytes(
            for: key, modifiers: modifiers, applicationCursor: getTerminal().applicationCursor)
        sendToSession(bytes[...])
    }

    /// A key from the key bar: with the sticky Ctrl/Alt, which it clears,
    /// unless `modifiers` says otherwise. PgUp/PgDn without a modifier act
    /// as the hardware keys do in SwiftTerm: the local scrollback on the
    /// normal screen, the remote program when it runs full-screen.
    func pressKey(_ key: TerminalKey, modifiers: TerminalModifiers? = nil) {
        let modifiers = modifiers ?? takeStickyModifiers()
        if modifiers.isEmpty, !getTerminal().applicationCursor {
            switch key {
            case .pageUp: pageUp(); return
            case .pageDown: pageDown(); return
            default: break
            }
        }
        sendKey(key, modifiers: modifiers)
    }

    func takeStickyModifiers() -> TerminalModifiers {
        var modifiers: TerminalModifiers = []
        if controlModifier { modifiers.insert(.control) }
        if metaModifier { modifiers.insert(.meta) }
        controlModifier = false
        metaModifier = false
        return modifiers
    }

    @discardableResult
    private func sendToSession(_ data: ArraySlice<UInt8>, fromUser: Bool = true) -> Bool {
        guard isInputEnabled || !fromUser else { return false }
        if !session.terminalInput.send(Array(data)) {
            onSendRefused()
            return false
        }
        return true
    }

    /// docs/ssh-design.md 8.3: a multi-line paste into a program that did not
    /// ask for bracketed paste would run each line; confirm first.
    override func paste(_ sender: Any?) {
        guard clipboardPolicy.allowsSend,
              let text = UIPasteboard.general.string, !text.isEmpty else { return }
        pasteText(text)
    }

    /// The profile's clipboard policy covers copying out of the terminal.
    override func copy(_ sender: Any?) {
        guard clipboardPolicy.allowsReceive else { return }
        super.copy(sender)
    }

    private static let maximumPasteBytes = 512 * 1024

    func pasteText(_ text: String) {
        guard clipboardPolicy.allowsSend else { return }
        let bracketed = getTerminal().bracketedPasteMode
        let send = { [weak self] in
            guard let self else { return }
            // In chunks: a large paste must not fill the input queue at once.
            let bytes = TerminalKeyEncoder.paste(text, bracketed: bracketed)
            // Half the bridge's input queue (1 MiB): more is refused whole
            // rather than cut off partway.
            guard bytes.count <= Self.maximumPasteBytes else {
                self.onSendRefused()
                return
            }
            var offset = 0
            // Stops at the first refusal: a paste with a hole in it is worse
            // than a short one. The closing bracket still goes, or the shell
            // would take everything typed after as pasted.
            while offset < bytes.count {
                let end = min(offset + 4096, bytes.count)
                guard self.sendToSession(bytes[offset..<end]) else {
                    if bracketed, offset > 0 {
                        _ = self.session.terminalInput.send(Array("\u{1B}[201~".utf8))
                    }
                    return
                }
                offset = end
            }
        }
        if TerminalKeyEncoder.pasteNeedsConfirmation(text, bracketed: bracketed) {
            onPasteNeedsConfirmation(text, send)
        } else {
            send()
        }
    }

    // MARK: Composition

    /// SwiftTerm's `setMarkedText` and `unmarkText` are public but not
    /// open, so they cannot be overridden: this subclass gets its own
    /// implementations at run time, which call SwiftTerm's and then redraw
    /// the composition.
    private static let installCompositionHooks: Void = {
        let setMarked = #selector(UITextInput.setMarkedText(_:selectedRange:))
        if let method = class_getInstanceMethod(TerminalView.self, setMarked) {
            typealias Original = @convention(c) (AnyObject, Selector, NSString?, NSRange) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let hook: @convention(block) (SessionTerminalView, NSString?, NSRange) -> Void = { view, text, range in
                original(view, setMarked, text, range)
                view.updateComposition()
            }
            class_addMethod(SessionTerminalView.self, setMarked,
                            imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        }
        let unmark = #selector(UITextInput.unmarkText)
        if let method = class_getInstanceMethod(TerminalView.self, unmark) {
            typealias Original = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let hook: @convention(block) (SessionTerminalView) -> Void = { view in
                original(view, unmark)
                view.updateComposition()
            }
            class_addMethod(SessionTerminalView.self, unmark,
                            imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        }
    }()

    override func insertText(_ text: String) {
        super.insertText(text)
        updateComposition()
    }

    override func deleteBackward() {
        super.deleteBackward()
        updateComposition()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateComposition()
        return resigned
    }

    /// Shows the marked text where it will be typed, underlined, with the
    /// clause being converted underlined thicker, as a Mac's terminal does.
    private func updateComposition() {
        guard let marked = markedTextRange, let text = self.text(in: marked), !text.isEmpty, isFirstResponder else {
            compositionLabel.isHidden = true
            return
        }
        let font = Self.font(size: fontSize)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .backgroundColor: nativeBackgroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        if let selected = selectedTextRange, !selected.isEmpty {
            let start = offset(from: marked.start, to: selected.start)
            let length = offset(from: selected.start, to: selected.end)
            let range = NSRange(location: start, length: length)
            if range.location >= 0, NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
            }
        }
        compositionLabel.attributedText = attributed
        compositionLabel.backgroundColor = nativeBackgroundColor
        // SwiftTerm's caret is the one place that knows the cursor's cell.
        let caret = subviews.first { String(describing: type(of: $0)) == "CaretView" }?.frame
            ?? CGRect(x: 0, y: contentOffset.y, width: 0, height: font.lineHeight)
        let width = bounds.width
        let size = compositionLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // On the cursor's line; moved left when it would run off the edge,
        // and wrapped from the left when it is wider than the screen.
        let x = max(0, min(caret.minX, width - size.width))
        compositionLabel.frame = CGRect(x: x, y: caret.minY, width: min(size.width, width), height: size.height)
        bringSubviewToFront(compositionLabel)
        compositionLabel.isHidden = false
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendToSession(data, fromUser: !feeding)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let size = TerminalSize(
            columns: newCols, rows: newRows,
            pixelWidth: Int(bounds.width * contentScaleFactor),
            pixelHeight: Int(bounds.height * contentScaleFactor))
        resizeTask?.cancel()
        resizeTask = Task { [session] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled else { return }
            await session.resizeTerminal(size)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) { onTitle(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Only web links, and the workspace asks before opening one.
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        onOpenLink(url)
    }

    /// OSC 52: a remote program writing the local clipboard. Off
    /// (docs/ssh-design.md section 11).
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
