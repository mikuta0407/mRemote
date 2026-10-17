import Foundation
import SessionCore

enum Formatting {
    static func endpoint(_ endpoint: RemoteEndpoint) -> String {
        endpoint.port == 3389 ? endpoint.host : "\(endpoint.host):\(endpoint.port)"
    }

    static func subtitle(for profile: ConnectionProfile) -> String {
        if profile.protocolKind == .ssh {
            let host = profile.endpoint.port == SSHConfiguration.defaultPort
                ? profile.endpoint.host : "\(profile.endpoint.host):\(profile.endpoint.port)"
            let user = profile.account.username.map { $0.isEmpty ? "" : "\($0)@" } ?? ""
            return "SSH ・ \(user)\(host)"
        }
        guard let username = profile.account.username, !username.isEmpty else {
            return endpoint(profile.endpoint)
        }
        if let domain = profile.account.domain, !domain.isEmpty {
            return "\(domain)\\\(username) @ \(endpoint(profile.endpoint))"
        }
        return "\(username) @ \(endpoint(profile.endpoint))"
    }

    /// "1920×1080（16:9）", or 自動 for following the screen.
    static func resolutionLabel(_ policy: ResolutionPolicy) -> String {
        switch policy {
        case .adaptive:
            return String(localized: "自動（画面に合わせる）")
        case let .fixed(width, height):
            let ratio = Double(width) / Double(max(height, 1))
            let named = [("4:3", 4.0 / 3), ("5:4", 5.0 / 4), ("16:9", 16.0 / 9), ("16:10", 16.0 / 10)]
                .first { abs($0.1 - ratio) < 0.01 }?.0
            return named.map { "\(width)×\(height)（\($0)）" } ?? "\(width)×\(height)"
        }
    }

    static func lastConnected(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .idle: return String(localized: "待機中")
        case .connecting: return String(localized: "接続中")
        case .awaitingUser: return String(localized: "確認待ち")
        case .connected: return String(localized: "接続済み")
        case .reconnecting: return String(localized: "再接続中")
        case .disconnecting: return String(localized: "切断中")
        case .disconnected: return String(localized: "切断済み")
        case .failed: return String(localized: "エラー")
        }
    }

    /// A stream bit rate: "1.5 Mbps", "800 kbps".
    static func bitrate(_ kbps: Int) -> String {
        kbps >= 1_000
            ? String(format: "%.1f Mbps", Double(kbps) / 1_000)
            : "\(kbps) kbps"
    }

    static func terminalThemeLabel(_ theme: TerminalTheme) -> String {
        switch theme {
        case .system: return String(localized: "システムに合わせる")
        case .light: return String(localized: "ライト")
        case .dark: return String(localized: "ダーク")
        case .solarizedDark: return "Solarized Dark"
        }
    }

    static func shellExitLabel(_ behavior: ShellExitBehavior) -> String {
        switch behavior {
        case .keepScreen: return String(localized: "画面を残す")
        case .closeSession: return String(localized: "セッションを閉じる")
        }
    }

    static func clipboardLabel(_ value: ClipboardPolicy) -> String {
        switch value {
        case .disabled: return String(localized: "無効")
        case .bidirectional: return String(localized: "双方向")
        case .sendOnly: return String(localized: "送信のみ")
        case .receiveOnly: return String(localized: "受信のみ")
        }
    }

    static func transportLabel(_ security: TransportSecurity) -> String {
        switch security {
        case .nla: return "NLA（TLS）"
        case .tls: return "TLS"
        case .legacyRDP: return String(localized: "古い RDP セキュリティ")
        }
    }

    static func endReasonLabel(_ reason: RemoteEndReason) -> String {
        switch reason {
        case .anotherConnection:
            return String(localized: "別の接続が同じユーザーでサインインし、このセッションを引き継ぎました。取り返さないよう、自動では再接続しません。")
        case .disconnectedOnServer:
            return String(localized: "サーバー側でこのセッションが切断されました。別の端末が同じユーザーで接続した場合もこうなります。取り返さないよう、自動では再接続しません。")
        case .signedOut:
            return String(localized: "サーバー側でサインアウトされました。")
        case .idleTimeout:
            return String(localized: "操作がなかったため、サーバーが切断しました。")
        case .signInTimeout:
            return String(localized: "サインインに時間がかかりすぎたため、サーバーが切断しました。")
        case .shellExited(let status):
            if let status, status != 0 {
                return String(localized: "シェルが終了しました（終了コード \(status)）。")
            }
            return String(localized: "シェルが終了しました。")
        }
    }

    /// What went wrong and what to try, in that order. Technical detail
    /// from the backend stays in English and goes last, for reports.
    static func errorLabel(_ error: RemoteSessionError, protocolKind: ProtocolKind) -> String {
        guard protocolKind == .ssh else { return errorLabel(error) }
        switch error {
        case .connectionRefused:
            return String(localized: "接続を拒否されました。ポート番号と、リモート側で SSH サーバー（Mac なら「リモートログイン」）が有効になっているかを確認してください。")
        case .connectionTimedOut:
            return String(localized: "応答がないまま時間切れになりました。リモートの電源とネットワーク、ファイアウォールで SSH（通常 22）が許可されているかを確認してください。")
        case .securityNegotiationFailed:
            return String(localized: "サーバーと共通の暗号方式がありません。サーバーが古い方式（SHA-1、DSA、CBC など）しか受け付けていない可能性があります。サーバーの OpenSSH を更新してください。")
        case .authenticationFailed:
            return String(localized: "サインインできませんでした。ユーザー名と、鍵・パスワードを確認してください。鍵を使う場合は、公開鍵がサーバーの ~/.ssh/authorized_keys に登録されている必要があります。")
        default:
            return errorLabel(error)
        }
    }

    static func errorLabel(_ error: RemoteSessionError) -> String {
        switch error {
        case .nameResolutionFailed:
            return String(localized: "ホスト名が見つかりません。ホスト名のつづりを確認するか、IP アドレスで指定してください。")
        case .networkUnreachable:
            return String(localized: "ネットワークに到達できません。iPhone/iPad のネットワーク接続と、VPN が必要な接続先ならその接続を確認してください。")
        case .connectionRefused:
            return String(localized: "接続を拒否されました。ポート番号と、リモート側でリモートデスクトップが有効になっているかを確認してください。")
        case .connectionTimedOut:
            return String(localized: "応答がないまま時間切れになりました。リモートの電源とネットワーク、ファイアウォールで RDP（通常 3389）が許可されているかを確認してください。")
        case .securityNegotiationFailed:
            return String(localized: "サーバーと共通のセキュリティ方式がありません。サーバーが TLS/NLA を許可せず古い RDP セキュリティのみを受け付けている可能性があります。必要なら接続設定の「接続方式」で明示的に許可できます。")
        case .tlsHandshakeFailed:
            return String(localized: "暗号化した通信を始められませんでした。接続設定の「接続方式」がサーバーの設定と合っているか確認してください。")
        case .authenticationFailed:
            return String(localized: "認証に失敗しました。ユーザー名・パスワード・ドメインを確認してください。Microsoft アカウントはメールアドレスをユーザー名にします。")
        case .accountRestricted:
            return String(localized: "このアカウントはリモート接続を許可されていません。リモート側で「リモートデスクトップ ユーザー」に加えるか、管理者に確認してください。")
        case .certificateRejected:
            return String(localized: "サーバー証明書を信頼しなかったため中止しました。接続し直すと、もう一度確認できます。")
        case .hostKeyRejected:
            return String(localized: "ホスト鍵を信頼しなかったため中止しました。接続し直すと、もう一度確認できます。")
        case .userCancelled:
            return String(localized: "接続を中止しました。")
        case .protocolFailure(let detail):
            return String(localized: "サーバーとの通信が想定外の形で終わりました。もう一度接続してください。続く場合は、この詳細を添えて報告してください。（\(detail)）")
        case .resourceUnavailable:
            return String(localized: "メモリなどが足りず接続を始められませんでした。ほかのセッションを閉じてからもう一度試してください。")
        case .internalFailure(let detail):
            return String(localized: "アプリ内部のエラーです。もう一度接続してください。続く場合は、この詳細を添えて報告してください。（\(detail)）")
        }
    }
}
