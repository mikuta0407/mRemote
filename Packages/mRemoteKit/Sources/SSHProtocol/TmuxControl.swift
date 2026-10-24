import Foundation

// tmux control mode (`tmux -CC`), as iTerm2 speaks it (docs/ssh-design.md
// section 16.5). tmux then writes no screen: it says what happens in lines -
// a pane's output, a window added, a layout changed - inside a DCS that
// starts with ESC P 1000 p and ends with ESC \ after %exit. Commands go back
// as lines, and each gets its reply between %begin and %end (or %error).

/// Splits a shell's output into what the terminal shows and control mode's
/// lines. Fed in chunks as they arrive; a marker split across two chunks is
/// still found.
public struct TmuxControlStream {
    public enum Piece: Equatable {
        /// For the terminal, as before control mode or after it.
        case terminal([UInt8])
        /// Control mode began: tmux -CC is attached.
        case began
        /// One line of control mode, without its line ending.
        case line(String)
        /// Control mode ended: tmux detached or exited.
        case ended
    }

    private static let start: [UInt8] = Array("\u{1B}P1000p".utf8)
    private static let terminator: [UInt8] = [0x1B, 0x5C]  // ESC \

    public private(set) var inControlMode = false
    /// Bytes held back: the start of a marker, or a line not yet ended.
    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Piece] {
        var input = pending + bytes
        pending = []
        var pieces: [Piece] = []
        while !input.isEmpty {
            if inControlMode {
                // A line at a time; ESC \ at a line's start ends the mode.
                if input.starts(with: Self.terminator) {
                    inControlMode = false
                    pieces.append(.ended)
                    input.removeFirst(Self.terminator.count)
                    continue
                }
                if input == [0x1B] {
                    pending = input
                    break
                }
                guard let newline = input.firstIndex(of: 0x0A) else {
                    pending = input
                    break
                }
                var line = Array(input[..<newline])
                if line.last == 0x0D { line.removeLast() }
                input.removeFirst(newline + 1)
                pieces.append(.line(String(decoding: line, as: UTF8.self)))
            } else {
                if let index = Self.find(Self.start, in: input) {
                    if index > 0 { pieces.append(.terminal(Array(input[..<index]))) }
                    input.removeFirst(index + Self.start.count)
                    inControlMode = true
                    pieces.append(.began)
                    continue
                }
                // Keep back what could be the marker's beginning.
                let keep = Self.partialSuffix(of: input)
                if input.count > keep { pieces.append(.terminal(Array(input[..<(input.count - keep)]))) }
                pending = Array(input.suffix(keep))
                break
            }
        }
        return pieces
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var index = 0
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    /// The longest end of `bytes` that begins the start marker.
    private static func partialSuffix(of bytes: [UInt8]) -> Int {
        for length in stride(from: min(start.count - 1, bytes.count), through: 1, by: -1)
        where Array(bytes.suffix(length)) == Array(start.prefix(length)) {
            return length
        }
        return 0
    }
}

/// One line of control mode.
public enum TmuxNotification: Equatable {
    /// A reply's start and end. `fromClient` is tmux's flag for a command
    /// this client sent; the reply to the attach itself has it clear.
    case begin(command: Int, fromClient: Bool)
    case end(command: Int, fromClient: Bool)
    case error(command: Int, fromClient: Bool)
    /// A pane's output, unescaped.
    case output(pane: Int, bytes: [UInt8])
    case windowAdd(window: Int)
    case windowClose(window: Int)
    case windowRenamed(window: Int, name: String)
    case layoutChange(window: Int, layout: String)
    case windowPaneChanged(window: Int, pane: Int)
    case sessionChanged(session: Int, name: String)
    case sessionWindowChanged(session: Int, window: Int)
    case exit(reason: String?)
    /// A reply's own line, or a notification this client does not act on.
    case other(String)

    public init(_ line: String) {
        let words = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        func id(_ word: String, _ sigil: Character) -> Int? {
            word.first == sigil ? Int(word.dropFirst()) : nil
        }
        func rest(after count: Int) -> String {
            line.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
                .dropFirst(count).first.map(String.init) ?? ""
        }
        switch words.first {
        case "%begin" where words.count >= 3, "%end" where words.count >= 3, "%error" where words.count >= 3:
            guard let number = Int(words[2]) else { self = .other(line); return }
            let fromClient = words.count > 3 && words[3] == "1"
            switch words[0] {
            case "%begin": self = .begin(command: number, fromClient: fromClient)
            case "%end": self = .end(command: number, fromClient: fromClient)
            default: self = .error(command: number, fromClient: fromClient)
            }
        case "%output" where words.count >= 2:
            guard let pane = id(words[1], "%") else { self = .other(line); return }
            self = .output(pane: pane, bytes: TmuxNotification.unescape(rest(after: 2)))
        case "%window-add" where words.count >= 2:
            self = id(words[1], "@").map { .windowAdd(window: $0) } ?? .other(line)
        case "%window-close" where words.count >= 2, "%unlinked-window-close" where words.count >= 2:
            self = id(words[1], "@").map { .windowClose(window: $0) } ?? .other(line)
        case "%window-renamed" where words.count >= 2:
            self = id(words[1], "@").map { .windowRenamed(window: $0, name: rest(after: 2)) } ?? .other(line)
        case "%layout-change" where words.count >= 3:
            self = id(words[1], "@").map { .layoutChange(window: $0, layout: words[2]) } ?? .other(line)
        case "%window-pane-changed" where words.count >= 3:
            if let window = id(words[1], "@"), let pane = id(words[2], "%") {
                self = .windowPaneChanged(window: window, pane: pane)
            } else {
                self = .other(line)
            }
        case "%session-changed" where words.count >= 2:
            self = id(words[1], "$").map { .sessionChanged(session: $0, name: rest(after: 2)) } ?? .other(line)
        case "%session-window-changed" where words.count >= 3:
            if let session = id(words[1], "$"), let window = id(words[2], "@") {
                self = .sessionWindowChanged(session: session, window: window)
            } else {
                self = .other(line)
            }
        case "%exit":
            let reason = rest(after: 1)
            self = .exit(reason: reason.isEmpty ? nil : reason)
        default:
            self = .other(line)
        }
    }

    /// %output's data: control characters and the backslash come as \ooo.
    public static func unescape(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 3 < bytes.count {
                let digits = bytes[(index + 1)...(index + 3)]
                if digits.allSatisfy({ (0x30...0x37).contains($0) }) {
                    let value = digits.reduce(0) { $0 * 8 + Int($1 - 0x30) }
                    out.append(UInt8(truncatingIfNeeded: value))
                    index += 4
                    continue
                }
            }
            out.append(bytes[index])
            index += 1
        }
        return out
    }
}

/// A window's layout, as `window_layout` and %layout-change give it:
/// `b25d,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`. Sizes and places are in
/// cells; a pane's place leaves a cell between it and its neighbour for
/// tmux's border.
public indirect enum TmuxLayout: Equatable {
    case pane(id: Int, frame: TmuxCellRect)
    /// Side by side (`{}`) or one above the other (`[]`).
    case split(sideBySide: Bool, frame: TmuxCellRect, children: [TmuxLayout])

    public var frame: TmuxCellRect {
        switch self {
        case let .pane(_, frame), let .split(_, frame, _): return frame
        }
    }

    public var panes: [(id: Int, frame: TmuxCellRect)] {
        switch self {
        case let .pane(id, frame): return [(id, frame)]
        case let .split(_, _, children): return children.flatMap(\.panes)
        }
    }

    /// Nil when it does not parse.
    public init?(_ text: String) {
        var scanner = Array(text.utf8)[...]
        // The checksum: four hex digits and a comma.
        if scanner.count > 5, scanner[scanner.startIndex + 4] == UInt8(ascii: ",") {
            scanner = scanner.dropFirst(5)
        }
        guard let layout = Self.parse(&scanner), scanner.isEmpty else { return nil }
        self = layout
    }

    private static func number(_ scanner: inout ArraySlice<UInt8>) -> Int? {
        var value = 0
        var digits = 0
        while let byte = scanner.first, (0x30...0x39).contains(byte) {
            value = value * 10 + Int(byte - 0x30)
            digits += 1
            scanner = scanner.dropFirst()
        }
        return digits > 0 ? value : nil
    }

    private static func expect(_ byte: Character, _ scanner: inout ArraySlice<UInt8>) -> Bool {
        guard scanner.first == UInt8(ascii: byte.unicodeScalars.first!) else { return false }
        scanner = scanner.dropFirst()
        return true
    }

    private static func parse(_ scanner: inout ArraySlice<UInt8>) -> TmuxLayout? {
        guard let width = number(&scanner), expect("x", &scanner), let height = number(&scanner),
              expect(",", &scanner), let x = number(&scanner), expect(",", &scanner), let y = number(&scanner)
        else { return nil }
        let frame = TmuxCellRect(x: x, y: y, width: width, height: height)
        switch scanner.first {
        case UInt8(ascii: ","):
            scanner = scanner.dropFirst()
            guard let id = number(&scanner) else { return nil }
            return .pane(id: id, frame: frame)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let sideBySide = scanner.first == UInt8(ascii: "{")
            let close = UInt8(ascii: sideBySide ? "}" : "]")
            scanner = scanner.dropFirst()
            var children: [TmuxLayout] = []
            while true {
                guard let child = parse(&scanner) else { return nil }
                children.append(child)
                if scanner.first == UInt8(ascii: ",") {
                    scanner = scanner.dropFirst()
                } else if scanner.first == close {
                    scanner = scanner.dropFirst()
                    break
                } else {
                    return nil
                }
            }
            return .split(sideBySide: sideBySide, frame: frame, children: children)
        default:
            return nil
        }
    }
}

public struct TmuxCellRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The commands this client sends.
public enum TmuxControlCommands {
    /// Keys for a pane, as bytes in hex: nothing in them can be taken for
    /// tmux syntax. Split so no line grows long.
    public static func sendKeys(pane: Int, _ bytes: [UInt8], chunk: Int = 256) -> [String] {
        stride(from: 0, to: bytes.count, by: chunk).map { start in
            let hex = bytes[start..<min(start + chunk, bytes.count)].map { String(format: "%02x", $0) }
            return "send-keys -t %\(pane) -H " + hex.joined(separator: " ")
        }
    }

    /// The client's size: tmux lays its windows out to fit.
    public static func clientSize(columns: Int, rows: Int) -> String {
        "refresh-client -C \(max(1, columns))x\(max(1, rows))"
    }

    /// Every window of the session, a line each: id, active (1/0), layout,
    /// name last as it may hold spaces.
    public static let listWindows = "list-windows -F '#{window_id} #{window_active} #{window_layout} #{window_name}'"

    /// What a pane shows, with colours, joined lines and history, for one
    /// that is new to this client.
    public static func capture(pane: Int, history: Int) -> String {
        "capture-pane -p -e -J -t %\(pane) -S -\(max(0, history))"
    }

    /// Where a pane's cursor is: "x y".
    public static func cursor(pane: Int) -> String {
        "display-message -p -t %\(pane) '#{cursor_x} #{cursor_y}'"
    }

    public struct Window: Equatable {
        public let id: Int
        public let isActive: Bool
        public let layout: TmuxLayout
        public let name: String
    }

    public static func parseWindows(_ lines: [String]) -> [Window] {
        lines.compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[0].first == "@", let id = Int(fields[0].dropFirst()),
                  let layout = TmuxLayout(String(fields[2])) else { return nil }
            return Window(id: id, isActive: fields[1] == "1", layout: layout,
                          name: fields.count > 3 ? String(fields[3]) : "")
        }
    }
}
