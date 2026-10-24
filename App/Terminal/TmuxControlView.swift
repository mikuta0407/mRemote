import SwiftUI
import UIKit
import CoreText
import SessionCore
import SSHProtocol

/// tmux control mode on screen (docs/ssh-design.md section 16.5): a bar of
/// tmux's windows, and the selected one's panes where tmux places them, cell
/// for cell. The app's own tabs and panes step aside meanwhile.
struct TmuxControlView: View {
    let model: SessionWorkspaceModel
    let client: TmuxControlClient
    let terminal: any TerminalSession
    let settings: EffectiveSSHSettings
    let isInputEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            TmuxWindowBar(client: client)
            if let window = client.selectedWindow {
                TmuxPaneLayout(
                    layout: window.layout,
                    activePane: window.activePane,
                    views: views(for: window),
                    cell: TmuxCell.size(fontSize: CGFloat(settings.fontSize))
                ) { columns, rows in
                    client.setClientSize(columns: columns, rows: rows)
                }
            } else {
                // Attached, the windows still on their way.
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }

    private func views(for window: TmuxControlClient.Window) -> [Int: SessionTerminalView] {
        var views: [Int: SessionTerminalView] = [:]
        for (pane, _) in window.layout.panes {
            guard let channel = client.panes[pane] else { continue }
            let view = model.tmuxPaneViews[pane] ?? SessionTerminalView(session: terminal, channel: channel, settings: settings)
            model.tmuxPaneViews[pane] = view
            let isActive = pane == window.activePane
            TerminalViewConfiguration(
                isInputEnabled: isInputEnabled,
                clipboardPolicy: model.clipboardPolicy,
                isFocused: isActive,
                accessibilityID: isActive ? "tmux-pane-active" : "tmux-pane",
                onSendRefused: { model.terminalSendRefused() },
                onPasteNeedsConfirmation: { text, proceed in model.confirmPaste(text, proceed: proceed) },
                onOpenLink: { url in model.pendingLink = url },
                onFocus: { client.selectPane(pane) },
                onKeyboardMisplaced: { model.tmuxPaneViews[client.selectedWindow?.activePane ?? -1]?.restoreFirstResponder() }
            ).apply(to: view)
            views[pane] = view
        }
        return views
    }
}

/// The size of a character cell, as SwiftTerm works it out for a font: tmux
/// places panes in cells, and each pane's view must be exactly its cells.
@MainActor
enum TmuxCell {
    static func size(fontSize: CGFloat, scale: CGFloat = UIScreen.main.scale) -> CGSize {
        let font = SessionTerminalView.font(size: fontSize)
        let ctFont = font as CTFont
        let height = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(1, (width * scale).rounded() / scale),
                      height: max(1, ceil(height * scale) / scale))
    }
}

/// tmux's windows, and what can be done with them.
struct TmuxWindowBar: View {
    let client: TmuxControlClient

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(Color(white: 0.6))
                .padding(.leading, 8)
                .accessibilityLabel("tmux \(client.sessionName)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(client.windows.enumerated()), id: \.element.id) { index, window in
                        let selected = window.id == client.selectedWindowID
                        Button {
                            client.selectWindow(window.id)
                        } label: {
                            Text("\(index + 1): \(window.name)")
                                .lineLimit(1)
                                .font(.footnote)
                                .frame(maxWidth: 180)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.white : Color(white: 0.7))
                        .background(selected ? Color(white: 0.28) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityIdentifier("tmux-window-\(index)")
                    }
                }
            }
            Menu {
                Button { client.newWindow() } label: { Label("新しいウィンドウ", systemImage: "plus.square.on.square") }
                    .accessibilityIdentifier("tmux-new-window")
                Button { client.split(.horizontal) } label: { Label("左右に分割", systemImage: "rectangle.split.2x1") }
                    .accessibilityIdentifier("tmux-split-horizontal")
                Button { client.split(.vertical) } label: { Label("上下に分割", systemImage: "rectangle.split.1x2") }
                    .accessibilityIdentifier("tmux-split-vertical")
                Button(role: .destructive) { client.closePane() } label: { Label("このペインを閉じる", systemImage: "xmark.square") }
                    .accessibilityIdentifier("tmux-close-pane")
                if let window = client.selectedWindowID {
                    Button(role: .destructive) { client.closeWindow(window) } label: { Label("このウィンドウを閉じる", systemImage: "xmark.rectangle") }
                }
                Divider()
                Button { client.detach() } label: { Label("tmux から切り離す", systemImage: "eject") }
                    .accessibilityIdentifier("tmux-detach")
            } label: {
                Image(systemName: "plus").frame(width: 34, height: 30)
            }
            .accessibilityLabel("tmux のウィンドウとペイン")
            .accessibilityIdentifier("tmux-menu")
            .padding(.trailing, 4)
        }
        .frame(height: 34)
        .background(Color(white: 0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tmux-window-bar")
    }
}

/// A tmux window's panes at tmux's own places, in cells; the cell left
/// between neighbours is tmux's border. Reports how many cells fit, which
/// becomes the client's size.
struct TmuxPaneLayout: UIViewRepresentable {
    let layout: TmuxLayout
    let activePane: Int?
    let views: [Int: SessionTerminalView]
    let cell: CGSize
    let onFit: (Int, Int) -> Void

    func makeUIView(context: Context) -> TmuxPaneContainerView { TmuxPaneContainerView() }

    func updateUIView(_ container: TmuxPaneContainerView, context: Context) {
        container.update(layout: layout, activePane: activePane, views: views, cell: cell, onFit: onFit)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TmuxPaneContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class TmuxPaneContainerView: UIView {
    private var layout: TmuxLayout?
    private var activePane: Int?
    private var views: [Int: SessionTerminalView] = [:]
    private var cell = CGSize(width: 8, height: 16)
    private var onFit: (Int, Int) -> Void = { _, _ in }
    private let activeRing = UIView()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = UIColor(white: 0.18, alpha: 1)
        activeRing.isUserInteractionEnabled = false
        activeRing.layer.borderWidth = 1
        activeRing.layer.borderColor = UIColor.tintColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(layout: TmuxLayout, activePane: Int?, views: [Int: SessionTerminalView], cell: CGSize,
                onFit: @escaping (Int, Int) -> Void) {
        self.layout = layout
        self.activePane = activePane
        self.views = views
        self.cell = cell
        self.onFit = onFit
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, let layout, bounds.width > 0 else { return }
        onFit(Int(bounds.width / cell.width), Int(bounds.height / cell.height))
        var placed = Set<ObjectIdentifier>()
        var activeFrame: CGRect?
        for (pane, frame) in layout.panes {
            guard let view = views[pane] else { continue }
            if view.superview !== self {
                let hadKeyboard = view.isFirstResponder
                insertSubview(view, at: 0)
                if hadKeyboard, !view.isFirstResponder { view.restoreFirstResponder() }
            }
            // A hair over the cells: SwiftTerm takes whole cells that fit.
            let rect = CGRect(x: CGFloat(frame.x) * cell.width, y: CGFloat(frame.y) * cell.height,
                              width: CGFloat(frame.width) * cell.width + 0.25,
                              height: CGFloat(frame.height) * cell.height + 0.25)
            view.frame = rect
            placed.insert(ObjectIdentifier(view))
            if pane == activePane { activeFrame = rect }
        }
        for view in subviews where view is SessionTerminalView && !placed.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        if layout.panes.count > 1, let activeFrame {
            if activeRing.superview == nil { addSubview(activeRing) }
            bringSubviewToFront(activeRing)
            activeRing.frame = activeFrame.insetBy(dx: -1, dy: -1)
        } else {
            activeRing.removeFromSuperview()
        }
    }
}
