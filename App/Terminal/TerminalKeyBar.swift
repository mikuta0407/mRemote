import UIKit
import SwiftTerm
import SSHProtocol

/// The keys above the software keyboard (docs/ssh-design.md 8.3), in place
/// of SwiftTerm's own bar, which fits what the width allows and has no
/// Home/End/PgUp/PgDn. One row that scrolls sideways; hiding the keyboard
/// stays pinned at the trailing end.
///
/// Ctrl and Alt are SwiftTerm's sticky modifiers, so they also apply to the
/// next key typed on the software keyboard, and SwiftTerm clears them.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    private weak var terminal: SessionTerminalView?
    private let scrollView = KeyScrollView()
    private var keyButtons: [UIButton] = []
    private lazy var hideButton = key(nil, symbol: "keyboard.chevron.compact.down",
                                      label: String(localized: "キーボードを閉じる")) { _ = $0.resignFirstResponder() }
    private var controlButton: UIButton?
    private var metaButton: UIButton?
    private var touchButton: UIButton?

    private var repeatDelay: Timer?
    private var repeatTimer: Timer?
    private var didRepeat = false

    private static let height: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 44 : 50
    private static let repeatAfter: TimeInterval = 0.45
    private static let repeatEvery: TimeInterval = 0.08

    init(terminal: SessionTerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        buildUI()
        for name in [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(modifierReset), name: name, object: terminal)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func modifierReset(_ notification: Notification) {
        refreshModifiers()
    }

    /// A hold the touch never finished (the keyboard went away under it)
    /// must not keep repeating.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endHold() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    var enableInputClicksWhenVisible: Bool { true }

    // MARK: Layout

    private func buildUI() {
        keyButtons.append(key("Esc") { $0.pressKey(.escape) })
        let control = toggle("Ctrl", label: String(localized: "Control")) { $0.controlModifier.toggle() }
        controlButton = control
        keyButtons.append(control)
        let meta = toggle("Alt", label: String(localized: "Alt")) { $0.metaModifier.toggle() }
        metaButton = meta
        keyButtons.append(meta)
        keyButtons.append(key("Tab") { $0.pressKey(.tab) })
        keyButtons.append(repeating(symbol: "arrow.left", label: String(localized: "左"), .left))
        keyButtons.append(repeating(symbol: "arrow.down", label: String(localized: "下"), .down))
        keyButtons.append(repeating(symbol: "arrow.up", label: String(localized: "上"), .up))
        keyButtons.append(repeating(symbol: "arrow.right", label: String(localized: "右"), .right))
        keyButtons.append(repeating(title: "PgUp", .pageUp))
        keyButtons.append(repeating(title: "PgDn", .pageDown))
        keyButtons.append(key("Home") { $0.pressKey(.home) })
        keyButtons.append(key("End") { $0.pressKey(.end) })
        keyButtons.append(repeating(title: "Del", .delete))
        for text in ["~", "|", "/", "-", "\\", "`"] {
            keyButtons.append(key(text) { $0.insertText(text) })
        }
        for n in 1...12 {
            keyButtons.append(key("F\(n)") { $0.pressKey(.function(n)) })
        }
        let touch = toggle(nil, symbol: "hand.draw", label: String(localized: "タッチで選択")) { terminal in
            terminal.allowMouseReporting.toggle()
        }
        touchButton = touch
        keyButtons.append(touch)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        keyButtons.forEach(scrollView.addSubview)
        addSubview(scrollView)
        addSubview(hideButton)
        refreshModifiers()
    }

    /// By hand rather than a stack view in the scroll view: each key as wide
    /// as its label, and the row as wide as its keys.
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 6
        let keyHeight = bounds.height - inset * 2
        let hideWidth: CGFloat = 52
        hideButton.frame = CGRect(
            x: bounds.width - safeAreaInsets.right - inset - hideWidth, y: inset,
            width: hideWidth, height: keyHeight)
        scrollView.frame = CGRect(x: 0, y: 0, width: hideButton.frame.minX - inset, height: bounds.height)
        var x = safeAreaInsets.left + inset
        for button in keyButtons {
            let fit = button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: keyHeight))
            let width = max(44, ceil(fit.width))
            button.frame = CGRect(x: x, y: inset, width: width, height: keyHeight)
            x += width + inset
        }
        scrollView.contentSize = CGSize(width: x, height: bounds.height)
    }

    private func refreshModifiers() {
        guard let terminal else { return }
        controlButton?.isSelected = terminal.controlModifier
        metaButton?.isSelected = terminal.metaModifier
        touchButton?.isSelected = !terminal.allowMouseReporting
    }

    // MARK: Keys

    private func button(_ title: String?, symbol: String?, label: String?) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        if let symbol {
            config.image = UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 15)
            return attributes
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        config.background.cornerRadius = 6
        let button = UIButton(configuration: config)
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            let on = button.isSelected
            config?.baseBackgroundColor = on ? button.tintColor : Self.keyColor
            config?.baseForegroundColor = on ? .white : .label
            button.configuration = config
        }
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0
        button.layer.shadowOpacity = 0.3
        if let label { button.accessibilityLabel = label }
        button.accessibilityIdentifier = "terminal-key-\(title ?? symbol ?? "")"
        return button
    }

    /// The software keyboard's own key color.
    private static let keyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    }

    private func key(_ title: String?, symbol: String? = nil, label: String? = nil,
                     _ action: @escaping (SessionTerminalView) -> Void) -> UIButton {
        let button = button(title, symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in
            guard let terminal = self?.terminal else { return }
            UIDevice.current.playInputClick()
            action(terminal)
        }, for: .touchUpInside)
        return button
    }

    private func toggle(_ title: String?, symbol: String? = nil, label: String,
                        _ action: @escaping (SessionTerminalView) -> Void) -> UIButton {
        let button = button(title, symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in
            guard let self, let terminal else { return }
            UIDevice.current.playInputClick()
            action(terminal)
            refreshModifiers()
        }, for: .touchUpInside)
        return button
    }

    private func repeating(title: String? = nil, symbol: String? = nil, label: String? = nil,
                           _ key: TerminalKey) -> UIButton {
        let button = button(title, symbol: symbol, label: label)
        // One press on release, so a swipe to scroll the bar sends nothing;
        // held, it repeats like a hardware key.
        button.addAction(UIAction { [weak self] _ in self?.beginHold(key) }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let repeated = didRepeat
            endHold()
            if !repeated { press(key) }
        }, for: .touchUpInside)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel, .touchDragExit] {
            button.addAction(UIAction { [weak self] _ in self?.endHold() }, for: event)
        }
        return button
    }

    private func press(_ key: TerminalKey) {
        UIDevice.current.playInputClick()
        terminal?.pressKey(key)
    }

    private func beginHold(_ key: TerminalKey) {
        endHold()
        repeatDelay = Timer.scheduledTimer(withTimeInterval: Self.repeatAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeating(key) }
        }
    }

    private func startRepeating(_ key: TerminalKey) {
        didRepeat = true
        // Ctrl or Alt held for the whole repeat, not just the first.
        let modifiers = terminal?.takeStickyModifiers() ?? []
        UIDevice.current.playInputClick()
        terminal?.pressKey(key, modifiers: modifiers)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminal?.pressKey(key, modifiers: modifiers) }
        }
    }

    private func endHold() {
        repeatDelay?.invalidate()
        repeatTimer?.invalidate()
        repeatDelay = nil
        repeatTimer = nil
        didRepeat = false
    }
}

/// A drag that starts on a key scrolls the bar instead of being swallowed by
/// the button.
private final class KeyScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}
