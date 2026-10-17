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

/// A session that runs a terminal (docs/ssh-design.md section 6.2). Like
/// `DesktopSession`, its high-rate traffic bypasses the actor.
public protocol TerminalSession: RemoteSession {
    /// The shell's output, read by the terminal view.
    nonisolated var terminalOutput: TerminalOutputBuffer { get }
    nonisolated var terminalInput: any TerminalInputSink { get }
    /// Tells the server the terminal's new size. Debounced by the caller.
    func resizeTerminal(_ size: TerminalSize) async
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
