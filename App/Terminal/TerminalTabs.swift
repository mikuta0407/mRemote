import Foundation
import SessionCore

/// Which way a split divides its space.
enum PaneAxis: Hashable {
    /// Side by side, the divider upright.
    case horizontal
    /// One above the other.
    case vertical
}

/// A tab's terminals: one, or a split of two smaller trees.
indirect enum PaneNode: Hashable {
    case leaf(TerminalID)
    case split(PaneSplit)

    /// Left to right, top to bottom.
    var leaves: [TerminalID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let split): return split.first.leaves + split.second.leaves
        }
    }

    func contains(_ id: TerminalID) -> Bool { leaves.contains(id) }

    /// `id`'s pane divided: it keeps the first half, `new` takes the second.
    func splitting(_ id: TerminalID, axis: PaneAxis, with new: TerminalID) -> PaneNode {
        switch self {
        case .leaf(let leaf) where leaf == id:
            return .split(PaneSplit(axis: axis, ratio: 0.5, first: self, second: .leaf(new)))
        case .leaf:
            return self
        case .split(var split):
            split.first = split.first.splitting(id, axis: axis, with: new)
            split.second = split.second.splitting(id, axis: axis, with: new)
            return .split(split)
        }
    }

    /// Without `id`'s pane: its sibling takes the split's place. Nil when it
    /// was the only one.
    func removing(_ id: TerminalID) -> PaneNode? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(var split):
            guard let first = split.first.removing(id) else { return split.second }
            guard let second = split.second.removing(id) else { return split.first }
            split.first = first
            split.second = second
            return .split(split)
        }
    }

    func settingRatio(_ ratio: Double, of splitID: UUID) -> PaneNode {
        guard case .split(var split) = self else { return self }
        if split.id == splitID {
            split.ratio = min(max(ratio, PaneSplit.ratioRange.lowerBound), PaneSplit.ratioRange.upperBound)
        } else {
            split.first = split.first.settingRatio(ratio, of: splitID)
            split.second = split.second.settingRatio(ratio, of: splitID)
        }
        return .split(split)
    }
}

struct PaneSplit: Hashable, Identifiable {
    let id: UUID
    var axis: PaneAxis
    /// The first pane's share.
    var ratio: Double
    var first: PaneNode
    var second: PaneNode

    /// Neither pane is squeezed to nothing.
    static let ratioRange = 0.15...0.85

    init(id: UUID = UUID(), axis: PaneAxis, ratio: Double, first: PaneNode, second: PaneNode) {
        self.id = id
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

struct TerminalTab: Hashable, Identifiable {
    let id: UUID
    var root: PaneNode
    /// The pane that types: the one last touched.
    var focused: TerminalID

    init(id: UUID = UUID(), terminal: TerminalID) {
        self.id = id
        self.root = .leaf(terminal)
        self.focused = terminal
    }
}

/// A session's terminals as the user arranged them (docs/ssh-design.md
/// section 16): tabs, each a tree of panes, one tab shown.
struct TerminalTabsState: Hashable {
    private(set) var tabs: [TerminalTab] = []
    private(set) var selectedID: UUID?

    var selected: TerminalTab? { tabs.first { $0.id == selectedID } }
    /// The terminal that types, in the tab on screen.
    var focusedTerminal: TerminalID? { selected?.focused }
    var allTerminals: [TerminalID] { tabs.flatMap(\.root.leaves) }

    func tab(containing id: TerminalID) -> TerminalTab? {
        tabs.first { $0.root.contains(id) }
    }

    /// A new tab after the selected one, and on screen.
    mutating func addTab(_ terminal: TerminalID) {
        let tab = TerminalTab(terminal: terminal)
        if let index = tabs.firstIndex(where: { $0.id == selectedID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
    }

    /// The focused pane of the tab on screen, divided; the new one types.
    mutating func split(axis: PaneAxis, with terminal: TerminalID) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else {
            addTab(terminal)
            return
        }
        tabs[index].root = tabs[index].root.splitting(tabs[index].focused, axis: axis, with: terminal)
        tabs[index].focused = terminal
    }

    /// A pane gone, its shell closed or ended. A tab left empty goes too, and
    /// its neighbour is shown. Returns false when it was not here.
    @discardableResult
    mutating func remove(_ terminal: TerminalID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.root.contains(terminal) }) else { return false }
        if let root = tabs[index].root.removing(terminal) {
            let leaves = tabs[index].root.leaves
            tabs[index].root = root
            if tabs[index].focused == terminal {
                // The pane before it, as closing a split in a terminal app.
                let position = leaves.firstIndex(of: terminal) ?? 0
                let remaining = root.leaves
                tabs[index].focused = remaining[max(0, min(position - 1, remaining.count - 1))]
            }
        } else {
            let wasSelected = tabs[index].id == selectedID
            tabs.remove(at: index)
            if wasSelected {
                selectedID = tabs.isEmpty ? nil : tabs[max(0, min(index - 1, tabs.count - 1))].id
            }
        }
        return true
    }

    mutating func select(_ tabID: UUID) {
        if tabs.contains(where: { $0.id == tabID }) { selectedID = tabID }
    }

    /// The pane, and its tab on screen.
    mutating func focus(_ terminal: TerminalID) {
        guard let index = tabs.firstIndex(where: { $0.root.contains(terminal) }) else { return }
        tabs[index].focused = terminal
        selectedID = tabs[index].id
    }

    /// The next or previous tab, wrapping round.
    mutating func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        selectedID = tabs[((index + offset) % tabs.count + tabs.count) % tabs.count].id
    }

    /// The next or previous pane in the tab on screen, wrapping round.
    mutating func focusPane(offset: Int) {
        guard let tab = selected else { return }
        let leaves = tab.root.leaves
        guard let index = leaves.firstIndex(of: tab.focused) else { return }
        focus(leaves[((index + offset) % leaves.count + leaves.count) % leaves.count])
    }

    mutating func setRatio(_ ratio: Double, of splitID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[index].root = tabs[index].root.settingRatio(ratio, of: splitID)
    }
}

/// What a terminal's keyboard shortcuts ask of its tabs and panes.
enum TerminalLayoutCommand: CaseIterable {
    case newTab, splitHorizontal, splitVertical, closePane
    case nextTab, previousTab, nextPane, previousPane
}
