import Foundation
import OSLog
import SessionCore

/// One category per boundary, so a trace can be filtered to the layer being
/// investigated instead of reading as one interleaved stream.
public enum LogCategory: String, Sendable, CaseIterable {
    case app
    case profiles
    case session
    case trust
    case input
    case rendering
    case audio
    case clipboard
}

public enum AppLog {
    public static let subsystem = "net.mikuta0407.mRemote"

    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}

/// Redaction helpers for values that must never appear in a log.
///
/// A connection target implies who the user works for, so a full host name is
/// as unwelcome in a diagnostic as a password. These produce something stable
/// enough to correlate two lines without naming anything.
public enum Redaction {
    /// The port stays readable because it is useful and carries no identity;
    /// the host becomes a short stable digest.
    public static func endpoint(host: String, port: UInt16) -> String {
        "host#\(digest(host)):\(port)"
    }

    public static func username(_ username: String?) -> String {
        guard let username, !username.isEmpty else { return "user#none" }
        return "user#\(digest(username))"
    }

    /// Fingerprints are not secret and are the whole point of a trust log
    /// line, but a full one is unreadable in a trace, so keep the head.
    public static func fingerprint(_ sha256: String) -> String {
        String(sha256.prefix(16))
    }

    /// Text payloads are never logged, only measured.
    public static func textPayload(_ text: String) -> String {
        "text(chars=\(text.count))"
    }

    private static func digest(_ value: String) -> String {
        // Not a cryptographic commitment: it only has to be stable within a
        // run and useless outside it.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(value.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
