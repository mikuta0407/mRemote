import Foundation

public enum SessionControlEvent: Sendable {
    case stateChanged(SessionState, generation: SessionGeneration)
    case userActionRequired(SessionChallenge)
    case error(RemoteSessionError)
    /// The remote clipboard changed. Carries whether it now holds text; the
    /// text itself is never part of an event.
    case clipboardChanged(hasRemoteText: Bool)
    /// The server opened the microphone in this format, or closed it (nil).
    case microphone(MicrophoneFormat?)
    /// The server ended the session on purpose. Not an error, and not a
    /// reason to reconnect: reconnecting after another connection took the
    /// session over takes it back, and the two then fight over it.
    case endedByServer(RemoteEndReason)
    /// What protects the connection, as the server selected it. Sent once,
    /// when the session connects.
    case transportSecurity(TransportSecurity)
    /// A Mac server took up the Mac extensions, or what it reports about
    /// them changed (stream rate, input source).
    case macExtensions(MacExtensionStatus)
}

public enum TransportSecurity: Hashable, Sendable {
    /// Network Level Authentication: CredSSP over TLS.
    case nla
    /// TLS, with the server's own sign-in.
    case tls
    /// The legacy RDP Security Layer: weak encryption, no server identity.
    case legacyRDP
}

/// Why the server ended a session, in terms the UI can explain.
public enum RemoteEndReason: Hashable, Sendable {
    /// Another connection - possibly another device, possibly this app's
    /// own other session - signed in as the same user and took it over.
    case anotherConnection
    /// Disconnected on the server. Windows 11 also reports a takeover by a
    /// connection as the same user this way, not as `anotherConnection`.
    case disconnectedOnServer
    /// Signed out, by the user or an administrator.
    case signedOut
    case idleTimeout
    case signInTimeout
    /// SSH: the shell ended by itself (`exit`, logout). The status is the
    /// shell's exit status, when the server sent one.
    case shellExited(status: Int32?)
}

public enum SessionVisibility: Hashable, Sendable {
    /// Presented and focused: input, audio and full presentation rate.
    case focused
    /// Connected but off screen. The connection and its channels keep running;
    /// presentation and transient decode buffers are reduced.
    case background
}

/// The protocol-independent part of a session: lifecycle, state and
/// challenges. A future SSH session implements exactly this much; desktop
/// frames, scan codes, audio and clipboard live in the capability protocols
/// below so that a terminal never has to model them.
public protocol RemoteSession: Actor {
    nonisolated var id: SessionID { get }
    nonisolated var profileID: ProfileID? { get }

    /// One stream per session. Ordered and finite-buffered: state and pending
    /// challenges stay authoritative on the session itself, so a consumer that
    /// misses events can always re-read rather than reconstruct.
    func controlEvents() -> AsyncStream<SessionControlEvent>

    var state: SessionState { get }
    var generation: SessionGeneration { get }
    /// The unanswered challenge, if any. State and the pending challenge are
    /// authoritative on the session and re-readable at any time, so a consumer
    /// that started late or dropped an event recovers by reading rather than
    /// by reconstructing what it missed.
    var pendingChallenge: SessionChallenge? { get }

    func connect() async throws
    func disconnect(reason: DisconnectReason) async
    func respond(to challengeID: ChallengeID, with response: ChallengeResponse) async throws
    func setVisibility(_ visibility: SessionVisibility) async
}

/// Raised when a challenge is answered twice, or answered after the attempt it
/// belonged to has ended.
public struct StaleChallengeError: Error, Hashable, Sendable {
    public let challengeID: ChallengeID

    public init(challengeID: ChallengeID) {
        self.challengeID = challengeID
    }
}
