import SwiftUI
import UIKit
import ObjectiveC
import SwiftTerm
import SessionCore
import SSHProtocol

/// tmux control mode, as a terminal's output carries it.
enum TmuxControlEvent {
    case began
    case line(String)
    case ended
}

/// What the workspace tells a terminal's view on each update: whether it
/// takes input, what its pane is, and where its requests go.
struct TerminalViewConfiguration {
    var isInputEnabled: Bool
    var clipboardPolicy: ClipboardPolicy = .bidirectional
    /// Its pane types: it takes the keyboard from the terminal that has it.
    var isFocused = true
    var accessibilityID = "terminal-surface"
    var onSendRefused: () -> Void = {}
    var onPasteNeedsConfirmation: (String, @escaping () -> Void) -> Void = { _, proceed in proceed() }
    var onOpenLink: (URL) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    /// A touch chose this terminal: its pane types now.
    var onFocus: () -> Void = {}
    var onCommand: (TerminalLayoutCommand) -> Void = { _ in }
    /// The keyboard came to a pane that does not type: give it to the one
    /// that does.
    var onKeyboardMisplaced: () -> Void = {}
    var onControlMode: (TmuxControlEvent) -> Void = { _ in }

    func apply(to view: SessionTerminalView) {
        view.accessibilityIdentifier = accessibilityID
        view.isInputEnabled = isInputEnabled
        view.clipboardPolicy = clipboardPolicy
        view.onSendRefused = onSendRefused
        view.onPasteNeedsConfirmation = onPasteNeedsConfirmation
        view.onOpenLink = onOpenLink
        view.onTitle = onTitle
        view.onFocus = onFocus
        view.onCommand = onCommand
        view.onKeyboardMisplaced = onKeyboardMisplaced
        view.onControlMode = onControlMode
        view.isFocusedPane = isFocused
        // Focus moved here by a shortcut or the bar: the keyboard follows,
        // if a terminal had it.
        if isFocused, !view.isFirstResponder, SessionTerminalView.keyboardOwner != nil,
           SessionTerminalView.keyboardOwner !== view {
            DispatchQueue.main.async { view.restoreFirstResponder() }
        }
    }
}

/// A tab's terminals on screen (docs/ssh-design.md 8.2 and 16): their views
/// laid out by the tab's pane tree, with a divider to drag between each
/// pair, in one UIKit view.
///
/// One view for the whole tab rather than a SwiftUI view per pane: a
/// terminal's view outlives any layout (it is the terminal's state), and
/// SwiftUI would at times hold it in two places at once, or size a pane by
/// the terminal's last size instead of the space it has.
struct TerminalPaneLayout: UIViewRepresentable {
    /// What is on screen: the tab's tree, or its focused pane alone.
    let root: PaneNode
    let focused: TerminalID
    /// More than one pane: the one that types is outlined.
    let showsFocus: Bool
    /// The view for each terminal in `root`, configured for this update.
    let views: [TerminalID: SessionTerminalView]
    let setRatio: (Double, UUID) -> Void

    func makeUIView(context: Context) -> PaneContainerView {
        PaneContainerView()
    }

    func updateUIView(_ container: PaneContainerView, context: Context) {
        container.update(root: root, focused: focused, showsFocus: showsFocus, views: views, setRatio: setRatio)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PaneContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class PaneContainerView: UIView {
    private var root: PaneNode?
    private var focusedTerminal: TerminalID?
    private var showsFocus = false
    private var views: [TerminalID: SessionTerminalView] = [:]
    private var setRatio: (Double, UUID) -> Void = { _, _ in }
    private var dividers: [UUID: PaneDividerView] = [:]
    private let focusRing = UIView()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        focusRing.isUserInteractionEnabled = false
        focusRing.layer.borderWidth = 2
        focusRing.layer.borderColor = UIColor.tintColor.cgColor
        focusRing.isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(root: PaneNode, focused: TerminalID, showsFocus: Bool,
                views: [TerminalID: SessionTerminalView], setRatio: @escaping (Double, UUID) -> Void) {
        self.root = root
        self.focusedTerminal = focused
        self.showsFocus = showsFocus
        self.views = views
        self.setRatio = setRatio
        setNeedsLayout()
    }

    /// Back on screen (another session's workspace may have held the
    /// views meanwhile): take them again.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, let root else { return }
        var placed = Set<ObjectIdentifier>()
        var usedDividers = Set<UUID>()
        var focusFrame: CGRect?
        func place(_ node: PaneNode, in rect: CGRect) {
            switch node {
            case .leaf(let id):
                guard let view = views[id] else { return }
                if view.superview !== self {
                    let hadKeyboard = view.isFirstResponder
                    insertSubview(view, at: 0)
                    if hadKeyboard, !view.isFirstResponder { view.restoreFirstResponder() }
                }
                view.frame = rect
                placed.insert(ObjectIdentifier(view))
                if id == focusedTerminal { focusFrame = rect }
            case .split(let split):
                let horizontal = split.axis == .horizontal
                let thickness = PaneDividerView.thickness
                let length = horizontal ? rect.width : rect.height
                let first = ((length - thickness) * split.ratio).rounded()
                let firstRect: CGRect
                let dividerRect: CGRect
                let secondRect: CGRect
                if horizontal {
                    firstRect = CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height)
                    dividerRect = CGRect(x: rect.minX + first, y: rect.minY, width: thickness, height: rect.height)
                    secondRect = CGRect(x: dividerRect.maxX, y: rect.minY, width: max(0, rect.maxX - dividerRect.maxX), height: rect.height)
                } else {
                    firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first)
                    dividerRect = CGRect(x: rect.minX, y: rect.minY + first, width: rect.width, height: thickness)
                    secondRect = CGRect(x: rect.minX, y: dividerRect.maxY, width: rect.width, height: max(0, rect.maxY - dividerRect.maxY))
                }
                let divider: PaneDividerView
                if let existing = dividers[split.id] {
                    divider = existing
                } else {
                    divider = PaneDividerView()
                    dividers[split.id] = divider
                    addSubview(divider)
                }
                let splitID = split.id
                divider.configure(axis: split.axis, splitRect: rect) { [weak self] ratio in
                    self?.setRatio(ratio, splitID)
                }
                divider.frame = dividerRect
                usedDividers.insert(split.id)
                place(split.first, in: firstRect)
                place(split.second, in: secondRect)
            }
        }
        place(root, in: bounds)
        // Panes that left this tab, or a tab no longer shown.
        for view in subviews where view is SessionTerminalView && !placed.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        for (id, divider) in dividers where !usedDividers.contains(id) {
            divider.removeFromSuperview()
            dividers[id] = nil
        }
        if showsFocus, let focusFrame {
            if focusRing.superview == nil { addSubview(focusRing) }
            bringSubviewToFront(focusRing)
            focusRing.frame = focusFrame
        } else {
            focusRing.removeFromSuperview()
        }
    }
}

/// The line between two panes; dragged, it moves.
final class PaneDividerView: UIView {
    static let thickness: CGFloat = 6
    private var axis = PaneAxis.horizontal
    /// The split it divides, in its container.
    private var splitRect = CGRect.zero
    private var onRatio: (Double) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.3, alpha: 1)
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal-pane-divider"
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(axis: PaneAxis, splitRect: CGRect, onRatio: @escaping (Double) -> Void) {
        self.axis = axis
        self.splitRect = splitRect
        self.onRatio = onRatio
        accessibilityLabel = axis == .horizontal ? String(localized: "左右の仕切り") : String(localized: "上下の仕切り")
    }

    /// Easier to catch than it is thick.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: axis == .horizontal ? -8 : 0, dy: axis == .vertical ? -8 : 0).contains(point)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        let point = gesture.location(in: container)
        let thickness = Self.thickness
        let ratio = axis == .horizontal
            ? (point.x - splitRect.minX - thickness / 2) / max(1, splitRect.width - thickness)
            : (point.y - splitRect.minY - thickness / 2) / max(1, splitRect.height - thickness)
        onRatio(Double(ratio))
    }
}

final class SessionTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
    private let session: any TerminalSession
    let channel: TerminalChannel
    private let settings: EffectiveSSHSettings
    /// User input: keys, the key bar, paste. The terminal's own replies to
    /// the remote program's queries are sent regardless.
    var isInputEnabled = true
    var clipboardPolicy: ClipboardPolicy = .bidirectional
    var onSendRefused: () -> Void = {}
    var onPasteNeedsConfirmation: (String, @escaping () -> Void) -> Void = { _, proceed in proceed() }
    var onOpenLink: (URL) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    var onFocus: () -> Void = {}
    var onCommand: (TerminalLayoutCommand) -> Void = { _ in }
    var onKeyboardMisplaced: () -> Void = {}
    /// tmux control mode began in this terminal, sent a line, or ended.
    var onControlMode: (TmuxControlEvent) -> Void = { _ in }
    /// Finds control mode in the output (docs/ssh-design.md 16.5).
    private var controlStream = TmuxControlStream()
    /// Its pane is the one that types.
    var isFocusedPane = true
    /// The terminal with the keyboard, if any.
    static weak var keyboardOwner: SessionTerminalView?

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

    init(session: any TerminalSession, channel: TerminalChannel, settings: EffectiveSSHSettings) {
        self.session = session
        self.channel = channel
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
        channel.output.setReadableHandler { [weak self] in
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
        channel.output.setReadableHandler(nil)
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
            let bytes = channel.output.drain(maximum: Self.drainChunk)
            if bytes.isEmpty { return }
            feeding = true
            for piece in controlStream.feed(bytes) {
                switch piece {
                case .terminal(let shown): feed(byteArray: shown[...])
                case .began: onControlMode(.began)
                case .line(let line): onControlMode(.line(line))
                case .ended: onControlMode(.ended)
                }
            }
            feeding = false
        }
        // Over budget with output left: come back on the next turn.
        if !channel.output.isEmpty {
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
        return (super.keyCommands ?? []) + [bigger] + Self.layoutKeyCommands
    }

    @objc private func makeFontBigger() { adjustFontSize(by: 1) }

    /// Tabs and panes, as Terminal.app and iTerm2 have them.
    private static let layoutKeyCommands: [UIKeyCommand] = [
        UIKeyCommand(title: String(localized: "新しいタブ"), action: #selector(layoutNewTab), input: "t", modifierFlags: .command),
        UIKeyCommand(title: String(localized: "左右に分割"), action: #selector(layoutSplitHorizontal), input: "d", modifierFlags: .command),
        UIKeyCommand(title: String(localized: "上下に分割"), action: #selector(layoutSplitVertical), input: "d", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: String(localized: "ペインを閉じる"), action: #selector(layoutClosePane), input: "w", modifierFlags: .command),
        UIKeyCommand(title: String(localized: "次のタブ"), action: #selector(layoutNextTab), input: "]", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: String(localized: "前のタブ"), action: #selector(layoutPreviousTab), input: "[", modifierFlags: [.command, .shift]),
        UIKeyCommand(title: String(localized: "次のペイン"), action: #selector(layoutNextPane), input: "]", modifierFlags: .command),
        UIKeyCommand(title: String(localized: "前のペイン"), action: #selector(layoutPreviousPane), input: "[", modifierFlags: .command),
    ].map { command in
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func layoutNewTab() { onCommand(.newTab) }
    @objc private func layoutSplitHorizontal() { onCommand(.splitHorizontal) }
    @objc private func layoutSplitVertical() { onCommand(.splitVertical) }
    @objc private func layoutClosePane() { onCommand(.closePane) }
    @objc private func layoutNextTab() { onCommand(.nextTab) }
    @objc private func layoutPreviousTab() { onCommand(.previousTab) }
    @objc private func layoutNextPane() { onCommand(.nextPane) }
    @objc private func layoutPreviousPane() { onCommand(.previousPane) }

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
        if !channel.input.send(Array(data)) {
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
                        _ = self.channel.input.send(Array("\u{1B}[201~".utf8))
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
        if resigned, Self.keyboardOwner === self { Self.keyboardOwner = nil }
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

    /// The size it has now, in cells, as the shell was told.
    var terminalSize: TerminalSize {
        let terminal = getTerminal()
        return TerminalSize(
            columns: terminal.cols, rows: terminal.rows,
            pixelWidth: Int(bounds.width * contentScaleFactor),
            pixelHeight: Int(bounds.height * contentScaleFactor))
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            Self.keyboardOwner = self
            // UIKit gives the keyboard back to whoever had it when a sheet
            // closes: if that is not the pane that types now, it goes on.
            if !isFocusedPane, !restoring {
                DispatchQueue.main.async { [weak self] in self?.onKeyboardMisplaced() }
            }
        }
        return became
    }

    /// A touch chooses the pane, whatever the gesture turns out to be.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFocusedPane {
            isFocusedPane = true
            onFocus()
        }
        super.touchesBegan(touches, with: event)
    }

    private var restoring = false

    /// The keyboard back after a move between holders: not the user
    /// choosing this pane, so focus stays where it is.
    func restoreFirstResponder() {
        restoring = true
        becomeFirstResponder()
        restoring = false
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let size = TerminalSize(
            columns: newCols, rows: newRows,
            pixelWidth: Int(bounds.width * contentScaleFactor),
            pixelHeight: Int(bounds.height * contentScaleFactor))
        resizeTask?.cancel()
        resizeTask = Task { [session, id = channel.id] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled else { return }
            await session.resizeTerminal(id, to: size)
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
