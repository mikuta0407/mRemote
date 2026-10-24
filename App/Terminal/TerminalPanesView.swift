import SwiftUI
import SessionCore

/// An SSH session's terminals on screen (docs/ssh-design.md section 16): a
/// bar of tabs - this host's, and the other SSH sessions' - over the tab on
/// screen, split into panes. On a narrow screen a tab shows one pane at a
/// time, chosen in the bar.
struct TerminalPanesView: View {
    let model: SessionWorkspaceModel
    let terminal: any TerminalSession
    let settings: EffectiveSSHSettings
    let isInputEnabled: Bool
    @Environment(AppEnvironment.self) private var environment

    /// Below this a tab shows its focused pane only. UI tests lower it with
    /// `-mremote-terminal-split-width`, to see splits on a phone.
    static var splitWidth: CGFloat {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "mremote-terminal-split-width")
        if override > 0 { return override }
        #endif
        return 600
    }

    var body: some View {
        GeometryReader { proxy in
            let showsSplits = proxy.size.width >= Self.splitWidth
            VStack(spacing: 0) {
                if showsBar(showsSplits: showsSplits) {
                    TerminalTabBar(model: model, showsPaneChips: !showsSplits)
                }
                if let tab = model.terminalTabs.selected {
                    let root = showsSplits ? tab.root : .leaf(tab.focused)
                    TerminalPaneLayout(
                        root: root,
                        focused: tab.focused,
                        showsFocus: showsSplits && tab.root.leaves.count > 1,
                        views: views(for: root.leaves, focused: tab.focused)
                    ) { ratio, split in
                        model.setTerminalSplitRatio(ratio, of: split)
                    }
                }
            }
        }
    }

    /// Only when there is more than one thing to choose from: a single
    /// shell keeps the whole screen.
    private func showsBar(showsSplits: Bool) -> Bool {
        model.terminalTabs.tabs.count > 1
            || (!showsSplits && (model.terminalTabs.selected?.root.leaves.count ?? 0) > 1)
            || environment.runningSessions.contains { $0.id != model.id && $0.terminal != nil }
    }

    /// Each terminal's view, made the first time it is shown and kept by the
    /// workspace, told what it is now.
    private func views(for ids: [TerminalID], focused: TerminalID) -> [TerminalID: SessionTerminalView] {
        var views: [TerminalID: SessionTerminalView] = [:]
        for id in ids {
            guard let channel = model.terminalChannels[id] else { continue }
            let view = model.terminalViews[id] ?? SessionTerminalView(session: terminal, channel: channel, settings: settings)
            model.terminalViews[id] = view
            TerminalViewConfiguration(
                isInputEnabled: isInputEnabled,
                clipboardPolicy: model.clipboardPolicy,
                isFocused: id == focused,
                accessibilityID: id == focused ? "terminal-surface" : "terminal-pane",
                onSendRefused: { model.terminalSendRefused() },
                onPasteNeedsConfirmation: { text, proceed in model.confirmPaste(text, proceed: proceed) },
                onOpenLink: { url in model.pendingLink = url },
                onTitle: { title in model.terminalTitles[id] = title },
                onFocus: { model.focusTerminal(id) },
                onCommand: { command in Task { await model.perform(command, from: id) } },
                onKeyboardMisplaced: { model.terminalView?.restoreFirstResponder() }
            ).apply(to: view)
            views[id] = view
        }
        return views
    }
}

/// The tabs: this host's first, then the other SSH sessions', each named
/// after its host. A plus menu opens a tab or a pane here, or a tab on
/// another host.
struct TerminalTabBar: View {
    let model: SessionWorkspaceModel
    /// On a narrow screen: the tab on screen's panes, to switch between.
    let showsPaneChips: Bool
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.terminalTabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(tab, index: index)
                    }
                    ForEach(otherSessions, id: \.id) { other in
                        ForEach(Array(other.terminalTabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            otherTabButton(other, tab: tab, index: index)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            if showsPaneChips, let tab = model.terminalTabs.selected, tab.root.leaves.count > 1 {
                paneChips(tab)
            }
            addMenu
        }
        .frame(height: 34)
        .background(Color(white: 0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-tab-bar")
    }

    private var otherSessions: [SessionWorkspaceModel] {
        environment.runningSessions.filter { $0.id != model.id && $0.terminal != nil }
    }

    private func title(of tab: TerminalTab, in session: SessionWorkspaceModel, index: Int) -> String {
        let shell = session.terminalTitles[tab.focused].flatMap { $0.isEmpty ? nil : $0 }
        let panes = tab.root.leaves.count > 1 ? " ▦\(tab.root.leaves.count)" : ""
        return (shell ?? "\(session.displayName) \(index + 1)") + panes
    }

    private func tabButton(_ tab: TerminalTab, index: Int) -> some View {
        let selected = tab.id == model.terminalTabs.selected?.id
        return HStack(spacing: 4) {
            Button {
                model.selectTerminalTab(tab.id)
            } label: {
                Text(title(of: tab, in: model, index: index))
                    .lineLimit(1)
                    .font(.footnote)
                    .frame(maxWidth: 180)
            }
            .accessibilityIdentifier("terminal-tab-\(index)")
            if selected {
                Button {
                    Task { await model.closeTerminalTab(tab.id) }
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .accessibilityLabel("タブを閉じる")
                .accessibilityIdentifier("terminal-tab-close")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Color(white: 0.7))
        .background(selected ? Color(white: 0.28) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Another host's tab: shows that session, on that tab.
    private func otherTabButton(_ other: SessionWorkspaceModel, tab: TerminalTab, index: Int) -> some View {
        Button {
            other.selectTerminalTab(tab.id)
            environment.switchTo(other)
        } label: {
            Label(title(of: tab, in: other, index: index), systemImage: "server.rack")
                .lineLimit(1)
                .font(.footnote)
                .frame(maxWidth: 200)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(Color(white: 0.6))
        .accessibilityIdentifier("terminal-other-tab-\(other.displayName)-\(index)")
    }

    private func paneChips(_ tab: TerminalTab) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(tab.root.leaves.enumerated()), id: \.element) { index, id in
                Button("\(index + 1)") { model.focusTerminal(id) }
                    .font(.footnote.monospacedDigit())
                    .frame(width: 26, height: 24)
                    .foregroundStyle(id == tab.focused ? Color.white : Color(white: 0.6))
                    .background(id == tab.focused ? Color.accentColor.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("ペイン \(index + 1)")
                    .accessibilityIdentifier("terminal-pane-chip-\(index)")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            TerminalLayoutMenuItems(model: model)
        } label: {
            Image(systemName: "plus")
                .frame(width: 34, height: 30)
        }
        .accessibilityLabel("タブとペイン")
        .accessibilityIdentifier("terminal-tab-add")
        .padding(.trailing, 4)
    }
}

/// New tabs and panes: the bar's plus menu and the session menu share these.
struct TerminalLayoutMenuItems: View {
    let model: SessionWorkspaceModel
    /// Before each action: the session menu closes itself.
    var before: () -> Void = {}
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button {
            before()
            Task { await model.openTerminalTab() }
        } label: {
            Label("新しいタブ（\(model.displayName)）", systemImage: "plus.square.on.square")
        }
        .accessibilityIdentifier("terminal-new-tab")
        Button {
            before()
            Task { await model.splitTerminal(.horizontal) }
        } label: {
            Label("左右に分割", systemImage: "rectangle.split.2x1")
        }
        .accessibilityIdentifier("terminal-split-horizontal")
        Button {
            before()
            Task { await model.splitTerminal(.vertical) }
        } label: {
            Label("上下に分割", systemImage: "rectangle.split.1x2")
        }
        .accessibilityIdentifier("terminal-split-vertical")
        if (model.terminalTabs.selected?.root.leaves.count ?? 0) > 1, let focused = model.terminalTabs.focusedTerminal {
            Button(role: .destructive) {
                before()
            Task { await model.closeTerminal(focused) }
            } label: {
                Label("このペインを閉じる", systemImage: "xmark.square")
            }
            .accessibilityIdentifier("terminal-close-pane")
        }
        let hosts = environment.profiles.filter { $0.protocolKind == .ssh }
        if !hosts.isEmpty {
            Menu {
                ForEach(hosts, id: \.id) { profile in
                    Button(profile.displayName) {
                        before()
                        Task { await environment.openTerminalTab(on: profile, from: model) }
                    }
                    .accessibilityIdentifier("terminal-new-tab-host-\(profile.displayName)")
                }
            } label: {
                Label("別のホストで新しいタブ", systemImage: "server.rack")
            }
            .accessibilityIdentifier("terminal-new-tab-other-host")
        }
    }
}
