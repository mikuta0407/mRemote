import Foundation

/// When to try again after a connection dropped, if at all.
///
/// docs/architecture.md section 10: reconnection follows the configured
/// policy, is never attempted for a failure that needs the user (a refused
/// password retried automatically is how an account gets locked), and only
/// applies to a session that had actually connected - a first attempt that
/// fails is reported, not retried behind the user's back.
public struct ReconnectSchedule: Hashable, Sendable {
    public let delays: [Duration]
    /// How long a reconnected session has to stay up before a later drop is
    /// counted from the first attempt again. A server that lets the client
    /// in and then turns it away - one that checks the password only once
    /// the session is set up - would otherwise be retried forever, each try
    /// counted as the first.
    public let heldAfter: Duration

    public init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)], heldAfter: Duration = .seconds(10)) {
        self.delays = delays
        self.heldAfter = heldAfter
    }

    public var maximumAttempts: Int { delays.count }

    /// The number of the next attempt, after `previous` of them: the first
    /// again only if the session connected and stayed up long enough.
    public func attempt(following previous: Int, connectedFor: Duration?) -> Int {
        if let connectedFor, connectedFor >= heldAfter { return 1 }
        return previous + 1
    }

    /// The wait before attempt number `attempt` (1-based), or nil to stop.
    public func delay(
        beforeAttempt attempt: Int,
        after error: RemoteSessionError?,
        policy: ReconnectPolicy,
        hadConnected: Bool
    ) -> Duration? {
        guard policy == .automatic,
              hadConnected,
              let error, error.isRetriable,
              attempt >= 1, attempt <= delays.count else {
            return nil
        }
        return delays[attempt - 1]
    }
}
