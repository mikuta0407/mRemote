import Foundation
import Observation
import SessionCore
import SSHProtocol

/// A tmux control mode client (docs/ssh-design.md section 16.5): tmux's
/// windows as tabs and its panes as panes, each pane a terminal of its own
/// fed from %output and typing through send-keys.
///
/// It runs over the shell that ran `tmux -CC`: the lines come from that
/// terminal's output (`TmuxControlStream`), and commands go back as lines
/// on its input.
@MainActor
@Observable
final class TmuxControlClient {
    struct Window: Identifiable, Equatable {
        let id: Int
        var name: String
        var layout: TmuxLayout
        var activePane: Int?
    }

    private(set) var windows: [Window] = []
    private(set) var selectedWindowID: Int?
    /// The session's name, for the tab bar.
    private(set) var sessionName = ""
    /// Each pane's terminal, its output from %output.
    @ObservationIgnored private(set) var panes: [Int: TerminalChannel] = [:]
    /// The terminal that ran `tmux -CC`: hidden while control mode lasts.
    let controlTerminal: TerminalID

    var selectedWindow: Window? { windows.first { $0.id == selectedWindowID } }

    @ObservationIgnored private let writeLine: (String) -> Bool
    /// Replies awaited, in the order the commands went out.
    @ObservationIgnored private var replies: [(([String], Bool) -> Void)?] = []
    /// The reply being read: whether it is one of ours, and its lines.
    @ObservationIgnored private var reading: (ours: Bool, lines: [String])?
    /// Panes whose history is being fetched: their output waits behind it.
    @ObservationIgnored private var held: [Int: [UInt8]] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var clientSize: (columns: Int, rows: Int)?

    /// Lines of history fetched for a pane new to this client.
    static let history = 2000

    init(controlTerminal: TerminalID, writeLine: @escaping (String) -> Bool) {
        self.controlTerminal = controlTerminal
        self.writeLine = writeLine
    }

    // MARK: Commands

    /// Sends a command; `reply` gets its lines and whether it succeeded.
    func command(_ line: String, reply: (([String], Bool) -> Void)? = nil) {
        guard writeLine(line) else { return }
        replies.append(reply)
    }

    func setClientSize(columns: Int, rows: Int) {
        guard clientSize?.columns != columns || clientSize?.rows != rows else { return }
        clientSize = (columns, rows)
        if started { command(TmuxControlCommands.clientSize(columns: columns, rows: rows)) }
    }

    func sendKeys(pane: Int, _ bytes: [UInt8]) {
        for line in TmuxControlCommands.sendKeys(pane: pane, bytes) { command(line) }
    }

    func selectWindow(_ id: Int) {
        selectedWindowID = id
        command("select-window -t @\(id)")
    }

    func selectPane(_ pane: Int) {
        if let index = windows.firstIndex(where: { $0.layout.panes.contains { $0.id == pane } }) {
            windows[index].activePane = pane
        }
        command("select-pane -t %\(pane)")
    }

    func newWindow() { command("new-window") }
    func split(_ axis: PaneAxis) {
        guard let pane = selectedWindow?.activePane else { return }
        command("split-window \(axis == .horizontal ? "-h" : "-v") -t %\(pane)")
    }
    func closePane() {
        guard let pane = selectedWindow?.activePane else { return }
        command("kill-pane -t %\(pane)")
    }
    func closeWindow(_ id: Int) { command("kill-window -t @\(id)") }
    /// Leaves tmux running, as ⌃B d does.
    func detach() { command("detach-client") }

    // MARK: Lines from tmux

    func handle(_ line: String) {
        let notification = TmuxNotification(line)
        if var current = reading {
            switch notification {
            case .end(_, let ours), .error(_, let ours):
                reading = nil
                if ours, !replies.isEmpty {
                    let reply = replies.removeFirst()
                    if case .end = notification { reply?(current.lines, true) } else { reply?(current.lines, false) }
                }
            default:
                current.lines.append(line)
                reading = current
            }
            return
        }
        switch notification {
        case .begin(_, let ours):
            reading = (ours, [])
        case let .output(pane, bytes):
            if held[pane] != nil {
                held[pane]?.append(contentsOf: bytes)
            } else {
                panes[pane]?.output.append(bytes)
            }
        case .sessionChanged(_, let name):
            sessionName = name
            // Attached: what is there, at the size there is room for.
            if !started {
                started = true
                if let size = clientSize {
                    command(TmuxControlCommands.clientSize(columns: size.columns, rows: size.rows))
                }
            }
            refreshWindows()
        case .windowAdd, .windowClose, .sessionWindowChanged:
            refreshWindows()
        case let .windowRenamed(window, name):
            if let index = windows.firstIndex(where: { $0.id == window }) { windows[index].name = name }
        case let .layoutChange(window, layout):
            guard let parsed = TmuxLayout(layout), let index = windows.firstIndex(where: { $0.id == window }) else {
                refreshWindows()
                return
            }
            windows[index].layout = parsed
            adoptPanes()
        case let .windowPaneChanged(window, pane):
            if let index = windows.firstIndex(where: { $0.id == window }) { windows[index].activePane = pane }
        default:
            break
        }
    }

    /// Every window again, as tmux has them now.
    private func refreshWindows() {
        command(TmuxControlCommands.listWindows) { [weak self] lines, ok in
            guard let self, ok else { return }
            let listed = TmuxControlCommands.parseWindows(lines)
            self.windows = listed.map { window in
                let previous = self.windows.first { $0.id == window.id }
                return Window(id: window.id, name: window.name, layout: window.layout,
                              activePane: previous?.activePane ?? window.layout.panes.first?.id)
            }
            if let active = listed.first(where: \.isActive) {
                self.selectedWindowID = active.id
            } else if !self.windows.contains(where: { $0.id == self.selectedWindowID }) {
                self.selectedWindowID = self.windows.first?.id
            }
            self.adoptPanes()
            for window in listed where window.isActive {
                self.command("display-message -p -t @\(window.id) '#{pane_id}'") { [weak self] lines, ok in
                    guard let self, ok, let line = lines.first, line.first == "%", let pane = Int(line.dropFirst()),
                          let index = self.windows.firstIndex(where: { $0.id == window.id }) else { return }
                    self.windows[index].activePane = pane
                }
            }
        }
    }

    /// A terminal for each pane new to this client, filled with its history
    /// first; and none for panes that are gone.
    private func adoptPanes() {
        let current = Set(windows.flatMap { $0.layout.panes.map(\.id) })
        for pane in panes.keys where !current.contains(pane) {
            panes[pane] = nil
            held[pane] = nil
        }
        for pane in current where panes[pane] == nil {
            let input = TmuxPaneInput(pane: pane) { [weak self] pane, bytes in
                self?.sendKeys(pane: pane, bytes)
            }
            panes[pane] = TerminalChannel(input: input)
            held[pane] = []
            command(TmuxControlCommands.capture(pane: pane, history: Self.history)) { [weak self] lines, ok in
                guard let self, let channel = self.panes[pane] else { return }
                if ok {
                    // The last line is where the cursor row is; its end is
                    // put back by the cursor's place below.
                    let text = lines.joined(separator: "\r\n")
                    channel.output.append(Array(text.utf8))
                }
                self.command(TmuxControlCommands.cursor(pane: pane)) { [weak self] lines, ok in
                    guard let self, let channel = self.panes[pane] else { return }
                    let place = (lines.first ?? "").split(separator: " ").compactMap { Int($0) }
                    if ok, place.count == 2 {
                        // On the pane's screen, the last rows of what was
                        // printed.
                        channel.output.append(Array("\u{1B}[\(place[1] + 1);\(place[0] + 1)H".utf8))
                    }
                    let waiting = self.held.removeValue(forKey: pane) ?? []
                    if !waiting.isEmpty { channel.output.append(waiting) }
                }
            }
        }
    }
}

/// A tmux pane's keys: to tmux as send-keys, through its client.
final class TmuxPaneInput: TerminalInputSink, @unchecked Sendable {
    let pane: Int
    private let deliver: @MainActor (Int, [UInt8]) -> Void

    init(pane: Int, deliver: @escaping @MainActor (Int, [UInt8]) -> Void) {
        self.pane = pane
        self.deliver = deliver
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        // The terminal views type on the main thread.
        MainActor.assumeIsolated { deliver(pane, bytes) }
        return true
    }
}
