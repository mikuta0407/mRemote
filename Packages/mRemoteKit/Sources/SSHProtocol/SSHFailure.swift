import Foundation
import CryptoKit
import SessionCore

/// The bridge's failure codes (`mr_ssh_failure` in bridge/ssh), mirrored so
/// they can be mapped and tested without the bridge.
public enum SSHBridgeFailure: UInt32, Sendable, CaseIterable {
    case none = 0
    case nameResolution = 1
    case refused = 2
    case unreachable = 3
    case timeout = 4
    case negotiation = 5
    case hostKeyRejected = 6
    case authentication = 7
    case channel = 8
    case `protocol` = 9
    case disconnected = 10
    case cancelled = 11
    case `internal` = 12
    case proxyUnreachable = 13
    case proxy = 14

    /// docs/ssh-design.md section 10.
    public func sessionError(detail: Int32) -> RemoteSessionError? {
        switch self {
        case .none: return nil
        case .nameResolution: return .nameResolutionFailed
        case .refused: return .connectionRefused
        case .unreachable: return .networkUnreachable
        case .timeout: return .connectionTimedOut
        case .negotiation: return .securityNegotiationFailed
        case .hostKeyRejected: return .hostKeyRejected
        case .authentication: return .authenticationFailed
        case .channel: return .protocolFailure(detail: "ssh channel \(detail)")
        case .protocol: return .protocolFailure(detail: "ssh \(detail)")
        case .disconnected: return .networkUnreachable
        case .cancelled: return .userCancelled
        case .internal: return .internalFailure(detail: "ssh \(detail)")
        case .proxyUnreachable: return .proxyUnreachable
        case .proxy: return .proxyRefused
        }
    }
}

public enum HostKeyFingerprint {
    /// OpenSSH's form: "SHA256:" and the unpadded base64 of the blob's
    /// SHA-256, as `ssh-keygen -lf` and `ssh` itself print it.
    public static func sha256(of blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
    }
}
