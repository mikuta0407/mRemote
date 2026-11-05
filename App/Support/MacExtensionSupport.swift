import Darwin
import Foundation
import Network
import SessionCore

/// Whether the device is on a network to be careful with: cellular, a
/// personal hotspot, or Low Data Mode. Automatic stream quality follows it.
final class NetworkConstraint: @unchecked Sendable {
    static let shared = NetworkConstraint()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var constrained = false
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.isExpensive || path.isConstrained)
        }
        monitor.start(queue: DispatchQueue(label: "net.mikuta0407.mRemote.network-constraint"))
    }

    var isConstrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return constrained
    }

    /// Yields the new value each time it changes.
    func changes() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            observers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.observers[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func update(_ value: Bool) {
        lock.lock()
        guard value != constrained else {
            lock.unlock()
            return
        }
        constrained = value
        let targets = Array(observers.values)
        lock.unlock()
        targets.forEach { $0.yield(value) }
    }
}

/// The physical keyboard type a Mac server should type as (macOS's 40 ANSI,
/// 41 ISO, 42 JIS, or the precise type number), so its own input source maps
/// the keys as this keyboard is labelled.
enum MacKeyboardType {
    static func current(fallback layout: KeyboardLayoutPreference) -> UInt32 {
        #if targetEnvironment(macCatalyst)
        // HIToolbox's LMGetKbdType, the type of the keyboard last typed on.
        // Catalyst cannot import Carbon, but AppKit has it loaded.
        typealias GetKbdType = @convention(c) () -> UInt8
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LMGetKbdType") {
            let type = unsafeBitCast(symbol, to: GetKbdType.self)()
            if type != 0 { return UInt32(type) }
        }
        #endif
        switch layout {
        case .japanese: return UInt32(MRX_KEYBOARD_TYPE_JIS)
        case .us: return UInt32(MRX_KEYBOARD_TYPE_ANSI)
        case .automatic: return UInt32(MRX_KEYBOARD_TYPE_UNKNOWN)
        }
    }
}
