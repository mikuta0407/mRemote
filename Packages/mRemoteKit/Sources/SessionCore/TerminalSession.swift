import Foundation

/// A terminal's size in character cells, plus the pixels they cover (sent to
/// the server for programs that draw images; zero when unknown).
public struct TerminalSize: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public static let range = 1...4096

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = min(max(columns, Self.range.lowerBound), Self.range.upperBound)
        self.rows = min(max(rows, Self.range.lowerBound), Self.range.upperBound)
        self.pixelWidth = max(0, min(pixelWidth, Int(UInt16.max)))
        self.pixelHeight = max(0, min(pixelHeight, Int(UInt16.max)))
    }

    public static let standard = TerminalSize(columns: 80, rows: 24)
}

/// Where keystrokes and pastes go, on the data plane like `DesktopInputSink`:
/// synchronous, ordered, bounded.
public protocol TerminalInputSink: AnyObject, Sendable {
    /// Queues bytes for the shell. False when the queue is full (the network
    /// is not keeping up) or the session is not connected; nothing of `bytes`
    /// was taken then.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool
}

public typealias TerminalID = UUID

/// One terminal of a session: a shell, for a tab or a pane. The same object
/// across reconnects: its output and input are retargeted to each attempt's
/// shell, so the view that shows it keeps its screen.
public final class TerminalChannel: Identifiable, Sendable {
    public let id: TerminalID
    /// The shell's output, read by the terminal view.
    public let output: TerminalOutputBuffer
    public let input: any TerminalInputSink

    public init(id: TerminalID = TerminalID(), output: TerminalOutputBuffer = TerminalOutputBuffer(), input: any TerminalInputSink) {
        self.id = id
        self.output = output
        self.input = input
    }
}

/// What a command run without a terminal printed, stdout and stderr merged.
public struct TerminalCommandResult: Hashable, Sendable {
    public let output: String
    /// Nil when the server sent none.
    public let exitStatus: Int32?

    public init(output: String, exitStatus: Int32?) {
        self.output = output
        self.exitStatus = exitStatus
    }
}

/// A session that runs terminals (docs/ssh-design.md sections 6.2 and 16).
/// Like `DesktopSession`, its high-rate traffic bypasses the actor.
public protocol TerminalSession: RemoteSession {
    /// The first shell: there from the start, and opened again on reconnect.
    nonisolated var primaryTerminal: TerminalChannel { get }
    /// Another shell on the same connection, for a tab or a pane. Nil when
    /// the session is not connected or has no room for more. Like the
    /// primary one it comes back, as a new shell, after a reconnect.
    func openTerminal(size: TerminalSize) async -> TerminalChannel?
    /// Tells the server a terminal's new size. Debounced by the caller.
    func resizeTerminal(_ id: TerminalID, to size: TerminalSize) async
    /// Closes a terminal's shell, as a closed tab. Closing the last one ends
    /// the session. `terminalEnded` follows.
    func closeTerminal(_ id: TerminalID) async
    /// Runs a command on the connection without a terminal, as `ssh host
    /// command`. Nil when it could not run (not connected, refused).
    func runCommand(_ command: String) async -> TerminalCommandResult?
}

extension TerminalSession {
    public nonisolated var terminalOutput: TerminalOutputBuffer { primaryTerminal.output }
    public nonisolated var terminalInput: any TerminalInputSink { primaryTerminal.input }

    public func resizeTerminal(_ size: TerminalSize) async {
        await resizeTerminal(primaryTerminal.id, to: size)
    }
}

/// The shell's output on its way to the screen: a bounded byte queue between
/// the session's worker and the main actor.
///
/// Unlike a desktop frame, no byte may be dropped - the terminal's state is
/// the sum of everything it was fed. So instead of coalescing, a full buffer
/// pushes back: `append` takes what fits, the worker stops reading the
/// channel, and the server stops once the SSH window is used up. Draining
/// calls `onSpaceAvailable` so the worker reads again.
public final class TerminalOutputBuffer: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage: [UInt8]
    private var head = 0
    private var count = 0
    private var readerNotified = false
    private var writerWaiting = false
    private var onReadable: (@Sendable () -> Void)?
    private var onSpaceAvailable: (@Sendable () -> Void)?
    /// Bytes appended in total; for tests and diagnostics.
    public private(set) var totalAppended: UInt64 = 0

    public init(capacity: Int = 1 << 20) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    /// Called once per batch of new output, not per append: the reader drains
    /// everything there is, and the next append after that notifies again.
    public func setReadableHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        onReadable = handler
        let notify = handler != nil && count > 0 && !readerNotified
        if notify { readerNotified = true }
        lock.unlock()
        if notify { handler?() }
    }

    public func setSpaceAvailableHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        onSpaceAvailable = handler
        lock.unlock()
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    /// The worker side. Returns how many bytes were taken; fewer than offered
    /// means the buffer is full, and `onSpaceAvailable` will fire.
    @discardableResult
    public func append(_ bytes: UnsafeRawBufferPointer) -> Int {
        lock.lock()
        let free = capacity - count
        let taken = min(free, bytes.count)
        if taken > 0 {
            var tail = (head + count) % capacity
            var offset = 0
            while offset < taken {
                let run = min(taken - offset, capacity - tail)
                storage.withUnsafeMutableBytes { destination in
                    destination.baseAddress!.advanced(by: tail)
                        .copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: run)
                }
                offset += run
                tail = (tail + run) % capacity
            }
            count += taken
            totalAppended += UInt64(taken)
        }
        if taken < bytes.count { writerWaiting = true }
        let notify = taken > 0 && !readerNotified && onReadable != nil
        if notify { readerNotified = true }
        let handler = notify ? onReadable : nil
        lock.unlock()
        handler?()
        return taken
    }

    public func append(_ bytes: [UInt8]) -> Int {
        bytes.withUnsafeBytes { append($0) }
    }

    /// The reader side: up to `maximum` bytes, oldest first. Once the buffer
    /// is empty the next append notifies again; until then the reader is
    /// expected to come back for the rest by itself (check `isEmpty`).
    public func drain(maximum: Int = .max) -> [UInt8] {
        lock.lock()
        let n = min(maximum, count)
        var out = [UInt8](repeating: 0, count: n)
        var offset = 0
        while offset < n {
            let run = min(n - offset, capacity - head)
            out.withUnsafeMutableBytes { destination in
                storage.withUnsafeBytes { source in
                    destination.baseAddress!.advanced(by: offset)
                        .copyMemory(from: source.baseAddress!.advanced(by: head), byteCount: run)
                }
            }
            offset += run
            head = (head + run) % capacity
        }
        count -= n
        if count == 0 {
            head = 0
            readerNotified = false
        }
        let wake = n > 0 && writerWaiting
        if wake { writerWaiting = false }
        let handler = wake ? onSpaceAvailable : nil
        lock.unlock()
        handler?()
        return out
    }

    /// Drops everything, e.g. when the session reconnects into a new shell.
    public func reset() {
        lock.lock()
        head = 0
        count = 0
        readerNotified = false
        let wake = writerWaiting
        writerWaiting = false
        let handler = wake ? onSpaceAvailable : nil
        lock.unlock()
        handler?()
    }
}
