import Foundation
import SessionCore

/// The shell commands that find tmux on a host and go into its sessions
/// (docs/ssh-design.md section 16.4).
public enum TmuxCommands {
    /// Where tmux tends to live when a non-interactive shell's PATH lacks
    /// it: Homebrew on Apple silicon and Intel, MacPorts, a user's own.
    private static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/.local/bin"

    /// Run without a terminal, as `ssh host command`. Exit 127: no tmux.
    /// Exit 1 and nothing printed: tmux, but no server or no sessions.
    public static let listSessions =
        "PATH=\"$PATH:\(extraPath)\"; command -v tmux >/dev/null 2>&1 || exit 127; " +
        "tmux list-sessions -F '#{session_windows} #{session_attached} #{session_activity} #{session_name}' 2>/dev/null"

    /// `list-sessions`' lines, most recently used first. Lines that do not
    /// parse are left out. The name comes last, as the rest of the line: it
    /// may hold spaces, and tmux's formats write no tab.
    public static func parseSessions(_ output: String) -> [TmuxSessionInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> TmuxSessionInfo? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[3].isEmpty,
                  let windows = Int(fields[0]), let attached = Int(fields[1]) else { return nil }
            let activity = TimeInterval(fields[2]).map { Date(timeIntervalSince1970: $0) }
            return TmuxSessionInfo(name: String(fields[3]), windows: windows, attachedClients: attached, lastActivity: activity)
        }
        .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// What to type into the shell for a choice; nil for none. `-d` is not
    /// passed: other clients stay attached, as tmux does by default.
    public static func command(for choice: TmuxChoice) -> String? {
        switch choice {
        case let .attach(name, controlMode):
            // "=" matches the name exactly, not as a prefix.
            return "\(tmux(controlMode)) attach-session -t \(quote("=" + name))"
        case let .new(name, controlMode):
            guard let name, !name.isEmpty else { return "\(tmux(controlMode)) new-session" }
            return "\(tmux(controlMode)) new-session -A -s \(quote(name))"
        case .none:
            return nil
        }
    }

    private static func tmux(_ controlMode: Bool) -> String {
        // The PATH the listing used, for a shell whose own lacks tmux.
        "PATH=\"$PATH:\(extraPath)\" tmux" + (controlMode ? " -CC" : "")
    }

    /// One shell word, whatever the name holds.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
