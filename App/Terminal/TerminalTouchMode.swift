import Foundation

/// What a touch on a terminal does: one setting for every terminal, kept
/// across sessions and launches like the desktop's touch mode, since it is
/// about the user's hands rather than the host. The Mac has a real mouse and
/// a scroll wheel, so there it is always `.mouse`.
enum TerminalTouchMode: String, CaseIterable {
    /// Taps and drags go to the remote program as mouse clicks and drags when
    /// it asks for the mouse (tmux, vim, htop); otherwise a drag scrolls the
    /// local scrollback. SwiftTerm's own behaviour.
    case mouse
    /// A vertical drag is a scroll wheel: wheel events to a program that
    /// asks for the mouse, ↑/↓ to a full-screen one that does not (less,
    /// man), the local scrollback otherwise. Taps still click.
    case wheel
    /// Nothing goes to the remote program: a drag scrolls the local
    /// scrollback, a tap only places the menu.
    case scrollback

    static let storageKey = "terminalTouchMode"

    static var current: TerminalTouchMode {
        get {
            guard !Platform.isMac else { return .mouse }
            return UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .mouse
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            NotificationCenter.default.post(name: .terminalTouchModeChanged, object: nil)
        }
    }

    var title: String {
        switch self {
        case .mouse: String(localized: "マウスクリック")
        case .wheel: String(localized: "マウスホイールでスクロール")
        case .scrollback: String(localized: "バッファをスクロール")
        }
    }

    var hint: String {
        switch self {
        case .mouse:
            String(localized: "マウスに対応したプログラム（tmux、vim など）には、タップをクリック、なぞるとドラッグとして送ります。それ以外では、なぞるとこの端末のスクロールバックを動かします。")
        case .wheel:
            String(localized: "上下になぞると、マウスに対応したプログラムにはホイール、less などの全画面のプログラムには ↑↓ キーを送ります。それ以外ではスクロールバックを動かします。タップはクリックです。")
        case .scrollback:
            String(localized: "リモートには何も送りません。なぞるとこの端末のスクロールバックを動かします。長押しで文字を選択できます。")
        }
    }

    /// For the key bar's button, which shows the mode it is in.
    var symbol: String {
        switch self {
        case .mouse: "cursorarrow.click"
        case .wheel: "computermouse"
        case .scrollback: "scroll"
        }
    }

    var next: TerminalTouchMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// How far a drag goes for one wheel step sent to a program that asks for
/// the mouse, in `.wheel` mode. tmux and most programs move several lines
/// per step, so a step per row of drag already runs ahead of the finger.
enum TerminalWheelSpeed: String, CaseIterable {
    case slow
    case standard
    case fast
    case fastest

    static let storageKey = "terminalWheelSpeed"

    static var current: TerminalWheelSpeed {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .standard
    }

    /// Rows of drag per wheel step.
    var rowsPerStep: CGFloat {
        switch self {
        case .slow: 2
        case .standard: 1
        case .fast: 0.5
        case .fastest: 0.25
        }
    }

    var title: String {
        switch self {
        case .slow: String(localized: "ゆっくり")
        case .standard: String(localized: "標準")
        case .fast: String(localized: "速い")
        case .fastest: String(localized: "とても速い")
        }
    }
}

extension Notification.Name {
    static let terminalTouchModeChanged = Notification.Name("mRemote.terminalTouchModeChanged")
}
