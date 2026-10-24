import Foundation
import os
import SessionCore

/// What the bridge reports, copied out of its callbacks.
enum SSHNativeEvent: Sendable {
    case state(mr_ssh_state, failure: UInt32, detail: Int32)
    case hostKey(challengeID: UInt64, keyType: String, blob: Data)
    case signIn(challengeID: UInt64, offered: UInt32, attempt: UInt32, rejected: UInt32)
    case keyboardInteractive(challengeID: UInt64, name: String, instruction: String, prompts: [KeyboardInteractivePrompt])
    case forward(index: Int, error: Int32)
    /// A channel opened, ended (detail: its exit status, or -1) or was
    /// refused (detail: the libssh2 error).
    case channel(id: UInt32, state: mr_ssh_channel_state, detail: Int32)
    /// The run thread has returned and the handle is destroyed. Always last.
    case finished
}

/// Serialises calls into one `mr_ssh_session` and makes `destroy` wait for
/// the calls already inside it - the same job `RDPNativeCallGate` does, for
/// the same reason (bridge/ssh/include/mremote/ssh_bridge.h: raw-pointer
/// lifetime stays with the caller).
final class SSHNativeCallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var session: OpaquePointer?
    private var callsInFlight = 0
    private var stopRequested = false

    func install(_ session: OpaquePointer) {
        condition.lock()
        self.session = session
        let mustStop = stopRequested
        condition.unlock()
        if mustStop { requestStop() }
    }

    func requestStop() {
        condition.lock()
        stopRequested = true
        condition.unlock()
        _ = call { mr_ssh_session_request_stop($0) }
    }

    @discardableResult
    func call(_ body: (OpaquePointer) -> mr_ssh_status) -> mr_ssh_status? {
        condition.lock()
        guard let session else {
            condition.unlock()
            return nil
        }
        callsInFlight += 1
        condition.unlock()
        let status = body(session)
        condition.lock()
        callsInFlight -= 1
        condition.broadcast()
        condition.unlock()
        return status
    }

    /// Closes the gate, waits for the calls in flight, then frees. Called on
    /// the run thread once `mr_ssh_session_run` has returned, which the
    /// bridge allows.
    func destroy() {
        condition.lock()
        let session = self.session
        self.session = nil
        while callsInFlight > 0 { condition.wait() }
        condition.unlock()
        if let session { _ = mr_ssh_session_destroy(session) }
    }
}

/// The connection parameters for one attempt.
struct SSHNativeConnection: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let terminalType: String
    let size: TerminalSize
    let keepAliveSeconds: Int
    var forwards: [SSHPortForward] = []
    /// A SOCKS5 proxy the connection goes through.
    var proxy: (host: String, port: UInt16)?
    /// No shell once signed in: the caller opens one, after a command.
    var deferShell = false
}

/// Where a channel's output goes: a terminal's buffer, or a command's
/// collected output.
private enum SSHOutputSink {
    case terminal(TerminalOutputBuffer)
    case command(SSHCommandOutput)
}

/// A command's output, kept up to a limit: it is read whole, not streamed.
final class SSHCommandOutput: @unchecked Sendable {
    static let limit = 256 * 1024
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func append(_ buffer: UnsafeRawBufferPointer) {
        lock.withLock {
            let room = Self.limit - bytes.count
            if room > 0 { bytes.append(contentsOf: buffer.prefix(room)) }
        }
    }

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

/// Owns the C session: creates it, runs it on a thread of its own, and turns
/// its callbacks into one ordered event stream for the session actor. Output
/// goes straight into each channel's terminal buffer instead, on the data
/// plane.
final class SSHNativeSession: @unchecked Sendable {
    let events: AsyncStream<SSHNativeEvent>
    fileprivate let continuation: AsyncStream<SSHNativeEvent>.Continuation
    let gate = SSHNativeCallGate()
    private let label: String
    private let startLock = NSLock()
    private var didStart = false
    /// Channel by channel, where output goes. Output for a channel not here
    /// yet is refused, which pauses it until `route` resumes it.
    private let routeLock = NSLock()
    private var routes: [UInt32: SSHOutputSink] = [:]

    init(label: String) {
        self.label = label
        var continuation: AsyncStream<SSHNativeEvent>.Continuation!
        // Unbounded: lifecycle events, bounded in number by the handshake.
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    func start(_ connection: SSHNativeConnection) {
        startLock.lock()
        precondition(!didStart, "a native session runs at most once")
        didStart = true
        startLock.unlock()

        let gate = gate
        let context = Unmanaged.passRetained(self)
        let thread = Thread { [continuation] in
            defer {
                context.release()
                continuation.yield(.finished)
                continuation.finish()
            }
            var session: OpaquePointer?
            // The forwards' host names as C strings for the duration of
            // create, which copies them.
            let hosts = connection.forwards.map { strdup($0.remoteHost) }
            defer { hosts.forEach { free($0) } }
            var forwards = zip(connection.forwards, hosts).map { forward, host in
                mr_ssh_forward(local_port: forward.localPort, remote_host: UnsafePointer(host), remote_port: forward.remotePort)
            }
            let proxyHost = connection.proxy.flatMap { strdup($0.host) }
            defer { free(proxyHost) }
            let status = connection.host.withCString { host in
                connection.username.withCString { user in
                    connection.terminalType.withCString { term in
                        var config = mr_ssh_config()
                        config.struct_size = UInt32(MemoryLayout<mr_ssh_config>.size)
                        config.host = host
                        config.port = connection.port
                        config.username = user
                        config.term = term
                        config.columns = UInt16(connection.size.columns)
                        config.rows = UInt16(connection.size.rows)
                        config.pixel_width = UInt16(connection.size.pixelWidth)
                        config.pixel_height = UInt16(connection.size.pixelHeight)
                        config.keepalive_seconds = UInt32(max(0, connection.keepAliveSeconds))
                        config.defer_shell = connection.deferShell ? 1 : 0
                        if let proxy = connection.proxy, let proxyHost {
                            config.proxy_type = mr_ssh_proxy_type(MR_SSH_PROXY_SOCKS5)
                            config.proxy_host = UnsafePointer(proxyHost)
                            config.proxy_port = proxy.port
                        }
                        var callbacks = mr_ssh_callbacks(
                            on_state: sshOnState,
                            on_host_key: sshOnHostKey,
                            on_auth_request: sshOnAuthRequest,
                            on_keyboard_interactive: sshOnKeyboardInteractive,
                            on_output: nil,
                            on_forward: sshOnForward,
                            on_channel_output: sshOnChannelOutput,
                            on_channel_state: sshOnChannelState
                        )
                        return forwards.withUnsafeMutableBufferPointer { buffer in
                            config.forwards = UnsafePointer(buffer.baseAddress)
                            config.forward_count = buffer.count
                            return mr_ssh_session_create(&config, &callbacks, context.toOpaque(), &session)
                        }
                    }
                }
            }
            guard status == MR_SSH_STATUS_OK, let session else {
                continuation.yield(.state(mr_ssh_state(MR_SSH_STATE_FAILED), failure: 12, detail: status))
                return
            }
            gate.install(session)
            _ = mr_ssh_session_run(session)
            gate.destroy()
        }
        thread.name = label
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func requestStop() { gate.requestStop() }

    /// An answer the bridge refused (too long, the wrong number of answers)
    /// would leave its run thread waiting with nothing on screen to answer;
    /// end the attempt instead. A stale one is already over.
    private func checkAnswer(_ status: mr_ssh_status?) {
        guard let status, status != mr_ssh_status(MR_SSH_STATUS_OK),
              status != mr_ssh_status(MR_SSH_ERROR_STALE_CHALLENGE) else { return }
        sshLog.error("the bridge refused an answer: \(status, privacy: .public)")
        gate.requestStop()
    }

    func answerHostKey(_ challengeID: UInt64, accept: Bool) {
        checkAnswer(gate.call {
            mr_ssh_session_answer_host_key($0, challengeID,
                                           mr_ssh_host_key_decision(accept ? MR_SSH_HOST_KEY_ACCEPT : MR_SSH_HOST_KEY_REJECT))
        })
    }

    /// `method` 0 abandons the sign-in.
    func answerSignIn(_ challengeID: UInt64, method: UInt32, secret: [UInt8] = [], passphrase: [UInt8] = []) {
        var secret = secret
        var passphrase = passphrase
        defer {
            // The bridge copied them; ours are wiped.
            secret.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
            passphrase.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        }
        checkAnswer(gate.call { session in
            secret.withUnsafeBufferPointer { secretBuffer in
                passphrase.withUnsafeBufferPointer { passphraseBuffer in
                    var answer = mr_ssh_auth_answer(
                        method: method,
                        secret: secretBuffer.baseAddress,
                        secret_length: secretBuffer.count,
                        passphrase: passphraseBuffer.isEmpty ? nil : passphraseBuffer.baseAddress,
                        passphrase_length: passphraseBuffer.count
                    )
                    return mr_ssh_session_answer_auth(session, challengeID, &answer)
                }
            }
        })
    }

    func answerKeyboardInteractive(_ challengeID: UInt64, answers: [String]) {
        var copies = answers.map { Array($0.utf8) }
        defer {
            for index in copies.indices {
                copies[index].withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
            }
        }
        let lengths = copies.map(\.count)
        checkAnswer(gate.call { session in
            // Pointers into each copy for the duration of the call.
            func withPointers(_ index: Int, _ collected: [UnsafePointer<UInt8>?], _ body: ([UnsafePointer<UInt8>?]) -> mr_ssh_status) -> mr_ssh_status {
                if index == copies.count { return body(collected) }
                return copies[index].withUnsafeBufferPointer { withPointers(index + 1, collected + [$0.baseAddress], body) }
            }
            return withPointers(0, []) { pointers in
                pointers.withUnsafeBufferPointer { pointerBuffer in
                    lengths.withUnsafeBufferPointer { lengthBuffer in
                        mr_ssh_session_answer_keyboard_interactive(
                            session, challengeID, pointerBuffer.baseAddress, lengthBuffer.baseAddress, copies.count)
                    }
                }
            }
        })
    }

    func cancelChallenge(_ challengeID: UInt64) {
        gate.call { mr_ssh_session_cancel_challenge($0, challengeID) }
    }

    // MARK: Channels

    /// Sends a terminal's output to `buffer`: the first shell (channel 0) or
    /// one `openShell` made. Output it refused meanwhile is read again.
    func route(_ channel: UInt32, to buffer: TerminalOutputBuffer) {
        routeLock.withLock { routes[channel] = .terminal(buffer) }
        // The buffer made room: read again. Held weakly through the gate,
        // which is a no-op once the session is gone.
        let gate = gate
        buffer.setSpaceAvailableHandler { _ = gate.call { mr_ssh_channel_resume_output($0, channel) } }
        gate.call { mr_ssh_channel_resume_output($0, channel) }
    }

    func unroute(_ channel: UInt32) {
        _ = routeLock.withLock { routes.removeValue(forKey: channel) }
    }

    /// A new shell on the connection, its output to `buffer`. Nil when the
    /// bridge has no room or the session is gone.
    func openShell(size: TerminalSize, output buffer: TerminalOutputBuffer) -> UInt32? {
        guard let id = open(kind: MR_SSH_CHANNEL_SHELL, command: nil, size: size, sink: .terminal(buffer)) else {
            return nil
        }
        let gate = gate
        buffer.setSpaceAvailableHandler { _ = gate.call { mr_ssh_channel_resume_output($0, id) } }
        return id
    }

    /// A command without a terminal; what it prints collects in `output`.
    func openCommand(_ command: String, output: SSHCommandOutput) -> UInt32? {
        open(kind: MR_SSH_CHANNEL_EXEC, command: command, size: .standard, sink: .command(output))
    }

    /// The route is in place before the run thread can deliver anything: it
    /// waits for `routeLock`, which the open holds.
    private func open(kind: Int, command: String?, size: TerminalSize, sink: SSHOutputSink) -> UInt32? {
        routeLock.lock()
        defer { routeLock.unlock() }
        var id: UInt32 = 0
        let status = gate.call { session in
            func call(_ command: UnsafePointer<CChar>?) -> mr_ssh_status {
                var config = mr_ssh_channel_config()
                config.struct_size = UInt32(MemoryLayout<mr_ssh_channel_config>.size)
                config.kind = mr_ssh_channel_kind(kind)
                config.command = command
                config.columns = UInt16(size.columns)
                config.rows = UInt16(size.rows)
                config.pixel_width = UInt16(size.pixelWidth)
                config.pixel_height = UInt16(size.pixelHeight)
                return mr_ssh_session_open_channel(session, &config, &id)
            }
            guard let command else { return call(nil) }
            return command.withCString { call($0) }
        }
        guard status == mr_ssh_status(MR_SSH_STATUS_OK), id != 0 else { return nil }
        routes[id] = sink
        return id
    }

    /// False when the queue is full, or the channel or the session is gone.
    func write(_ channel: UInt32, _ bytes: [UInt8]) -> Bool {
        let status = gate.call { session in
            bytes.withUnsafeBufferPointer { mr_ssh_channel_write(session, channel, $0.baseAddress, $0.count) }
        }
        return status == mr_ssh_status(MR_SSH_STATUS_OK)
    }

    func resize(_ channel: UInt32, _ size: TerminalSize) {
        gate.call {
            mr_ssh_channel_resize($0, channel, UInt16(size.columns), UInt16(size.rows),
                                  UInt16(size.pixelWidth), UInt16(size.pixelHeight))
        }
    }

    func close(_ channel: UInt32) {
        gate.call { mr_ssh_channel_close($0, channel) }
    }

    /// The run thread: a channel's output, to where it is routed.
    fileprivate func deliver(_ channel: UInt32, _ bytes: UnsafeRawBufferPointer) -> Int {
        let sink = routeLock.withLock { routes[channel] }
        switch sink {
        case .terminal(let buffer): return buffer.append(bytes)
        case .command(let output):
            output.append(bytes)
            return bytes.count
        case nil: return 0
        }
    }
}

// MARK: - C callbacks (run thread)

private func native(_ context: UnsafeMutableRawPointer?) -> SSHNativeSession {
    Unmanaged<SSHNativeSession>.fromOpaque(context!).takeUnretainedValue()
}

private func text(_ bytes: UnsafePointer<UInt8>?, _ length: Int) -> String {
    guard let bytes, length > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
}

private func sshOnState(_ context: UnsafeMutableRawPointer?, _ state: mr_ssh_state, _ failure: mr_ssh_failure, _ detail: Int32) {
    native(context).continuation.yield(.state(state, failure: failure, detail: detail))
}

private func sshOnHostKey(_ context: UnsafeMutableRawPointer?, _ challengeID: UInt64, _ key: UnsafePointer<mr_ssh_host_key>?) {
    guard let key = key?.pointee else { return }
    let blob = Data(bytes: key.blob, count: key.blob_length)
    let type = key.type_name.map { String(cString: $0) } ?? "unknown"
    native(context).continuation.yield(.hostKey(challengeID: challengeID, keyType: type, blob: blob))
}

private func sshOnAuthRequest(_ context: UnsafeMutableRawPointer?, _ challengeID: UInt64, _ request: UnsafePointer<mr_ssh_auth_request>?) {
    guard let request = request?.pointee else { return }
    native(context).continuation.yield(.signIn(
        challengeID: challengeID, offered: request.offered, attempt: request.attempt, rejected: request.rejected))
}

private func sshOnKeyboardInteractive(_ context: UnsafeMutableRawPointer?, _ challengeID: UInt64, _ request: UnsafePointer<mr_ssh_kbd_request>?) {
    guard let request = request?.pointee else { return }
    var prompts: [KeyboardInteractivePrompt] = []
    for index in 0..<request.prompt_count {
        let prompt = request.prompts[index]
        prompts.append(KeyboardInteractivePrompt(text: text(prompt.text, prompt.length), echo: prompt.echo != 0))
    }
    native(context).continuation.yield(.keyboardInteractive(
        challengeID: challengeID,
        name: text(request.name, request.name_length),
        instruction: text(request.instruction, request.instruction_length),
        prompts: prompts))
}

private func sshOnForward(_ context: UnsafeMutableRawPointer?, _ index: Int, _ error: Int32) {
    native(context).continuation.yield(.forward(index: index, error: error))
}

private func sshOnChannelOutput(_ context: UnsafeMutableRawPointer?, _ channel: UInt32, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Int {
    guard let bytes, length > 0 else { return 0 }
    return native(context).deliver(channel, UnsafeRawBufferPointer(start: bytes, count: length))
}

private func sshOnChannelState(_ context: UnsafeMutableRawPointer?, _ channel: UInt32, _ state: mr_ssh_channel_state, _ detail: Int32) {
    let session = native(context)
    if state != mr_ssh_channel_state(MR_SSH_CHANNEL_OPEN) {
        // Ended: nothing more comes for it. A command's output stays with
        // whoever waits for it.
        session.unroute(channel)
    }
    session.continuation.yield(.channel(id: channel, state: state, detail: detail))
}
