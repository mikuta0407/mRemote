import SwiftUI
import SessionCore

/// The questions a connection can stop on - a password or a certificate, and
/// for SSH a host key, the server's own prompts or a key's passphrase. They
/// share a sheet because they share a rule: the connection is blocked until
/// the user answers, and dismissing without answering has to mean cancel
/// rather than "later".
struct SessionChallengeSheet: View {
    let challenge: SessionChallenge
    let defaultUsername: String?
    let defaultDomain: String?
    let onCredential: (String, String?, String, Bool) -> Void
    let onTrust: (Bool) -> Void
    var onKeyboardInteractive: ([String]) -> Void = { _ in }
    var onPassphrase: (String, Bool) -> Void = { _, _ in }
    /// SSH has no domain.
    var asksForDomain = true
    let onCancel: () -> Void

    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var savePassword = true
    @State private var answers: [String] = []

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル", role: .cancel) { onCancel() }
                            .accessibilityIdentifier("challenge-cancel")
                    }
                }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch challenge {
        case .credential(let credential):
            credentialForm(credential)
        case .certificate(let certificate):
            certificateReview(certificate)
        case .hostKey(let hostKey):
            hostKeyReview(hostKey)
        case .keyboardInteractive(let prompts):
            keyboardInteractiveForm(prompts)
        case .keyPassphrase(let passphrase):
            passphraseForm(passphrase)
        }
    }

    // MARK: - Credentials

    private func credentialForm(_ challenge: CredentialChallenge) -> some View {
        Form {
            if challenge.storedCredentialWasRejected {
                Section {
                    Label(
                        String(localized: "保存済みのパスワードが拒否されました。もう一度入力してください。"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section("\(challenge.host) にサインイン") {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("challenge-username")
                if asksForDomain {
                    TextField("ドメイン（任意）", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("challenge-domain")
                }
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("challenge-password")
                Toggle("このデバイスに保存", isOn: $savePassword)
                    .accessibilityIdentifier("challenge-save-password")
            }
            Section {
                Button("接続") {
                    onCredential(
                        username,
                        domain.isEmpty ? nil : domain,
                        password,
                        savePassword
                    )
                }
                .disabled(username.isEmpty || password.isEmpty)
                .accessibilityIdentifier("challenge-connect")
            } footer: {
                Text("パスワードは Keychain にのみ保存され、接続設定ファイルには書き込まれません。")
            }
        }
        .navigationTitle("資格情報が必要です")
        .onAppear {
            username = challenge.username ?? defaultUsername ?? ""
            domain = challenge.domain ?? defaultDomain ?? ""
        }
    }

    // MARK: - SSH

    /// docs/ssh-design.md 7.1. A changed key gets its own wording and its own
    /// buttons: it is not a first connection.
    private func hostKeyReview(_ challenge: HostKeyChallenge) -> some View {
        Form {
            Section {
                if case .changed = challenge.disposition {
                    Label(String(localized: "ホスト鍵が以前と変わっています"), systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                    Text("""
                    この接続先には以前に信頼したホスト鍵があり、今回はそれと異なる鍵が提示されました。\
                    サーバーを入れ直した場合にも起こりますが、通信が傍受されている場合にも同じことが起こります。\
                    心当たりがなければ接続せず、サーバー側で鍵を確認してください。
                    """)
                    .font(.callout)
                } else {
                    Label(String(localized: "初めて接続するサーバーです"), systemImage: "key.horizontal")
                        .foregroundStyle(.orange)
                    Text("下のフィンガープリントが接続先のサーバーのものであることを、別の手段で確認してください。")
                        .font(.callout)
                }
            }
            Section("ホスト鍵") {
                LabeledContent(String(localized: "challenge.computer", defaultValue: "接続先"), value: "\(challenge.host):\(challenge.port)")
                LabeledContent("種類", value: challenge.keyType)
                VStack(alignment: .leading, spacing: 4) {
                    Text("フィンガープリント")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(challenge.fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("host-key-fingerprint")
                }
                if case .changed(let previousType, let previous) = challenge.disposition {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("以前に信頼した鍵（\(previousType)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(previous)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                Button(challenge.disposition.isIdentityChange
                    ? String(localized: "変更を承知のうえで今回のみ接続")
                    : String(localized: "今回のみ信頼")) {
                    onTrust(false)
                }
                .accessibilityIdentifier("host-key-trust-once")
                Button(challenge.disposition.isIdentityChange
                    ? String(localized: "新しい鍵に置き換えて保存")
                    : String(localized: "この接続先で常に信頼")) {
                    onTrust(true)
                }
                .accessibilityIdentifier("host-key-trust-always")
            } footer: {
                Text("サーバーで確かめるには: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub（Mac は /etc/ssh/ の同名ファイル）")
            }
        }
        .navigationTitle("ホスト鍵の確認")
    }

    private func keyboardInteractiveForm(_ challenge: KeyboardInteractiveChallenge) -> some View {
        Form {
            if !challenge.instruction.isEmpty || !challenge.name.isEmpty {
                Section {
                    if !challenge.name.isEmpty { Text(challenge.name).font(.headline) }
                    if !challenge.instruction.isEmpty { Text(challenge.instruction).font(.callout) }
                }
            }
            Section("\(challenge.host) にサインイン") {
                ForEach(Array(challenge.prompts.enumerated()), id: \.offset) { index, prompt in
                    let binding = Binding(
                        get: { index < answers.count ? answers[index] : "" },
                        set: { if index < answers.count { answers[index] = $0 } })
                    if prompt.echo {
                        TextField(prompt.text, text: binding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(prompt.text, text: binding)
                            .textContentType(.oneTimeCode)
                    }
                }
            }
            Section {
                Button(challenge.prompts.isEmpty ? String(localized: "続ける") : String(localized: "送信")) {
                    onKeyboardInteractive(answers)
                }
                .accessibilityIdentifier("challenge-kbd-submit")
            } footer: {
                Text("サーバーが尋ねている内容です。ここで入力したものは保存しません。")
            }
        }
        .navigationTitle("サーバーからの確認")
        .onAppear { answers = Array(repeating: "", count: challenge.prompts.count) }
    }

    private func passphraseForm(_ challenge: KeyPassphraseChallenge) -> some View {
        Form {
            if challenge.previousWasRejected {
                Section {
                    Label(String(localized: "パスフレーズが違うか、サーバーがこの鍵を受け付けませんでした。"),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section(challenge.keyName.isEmpty
                ? String(localized: "鍵のパスフレーズ")
                : String(localized: "「\(challenge.keyName)」のパスフレーズ")) {
                SecureField("パスフレーズ", text: $password)
                    .accessibilityIdentifier("challenge-passphrase")
                Toggle("このデバイスに保存", isOn: $savePassword)
            }
            Section {
                Button("接続") { onPassphrase(password, savePassword) }
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("challenge-connect")
            } footer: {
                Text("保存すると Keychain に入り、次からは聞かれません。サインインに成功したときだけ保存します。")
            }
        }
        .navigationTitle("鍵のパスフレーズ")
    }

    // MARK: - Certificates

    private func certificateReview(_ challenge: CertificateChallenge) -> some View {
        Form {
            Section {
                Label(headline(for: challenge.disposition), systemImage: symbol(for: challenge))
                    .foregroundStyle(challenge.disposition.isIdentityChange ? .red : .orange)
                Text(explanation(for: challenge))
                    .font(.callout)
            }

            Section("証明書") {
                LabeledContent(String(localized: "challenge.computer", defaultValue: "接続先"), value: "\(challenge.host):\(challenge.port)")
                LabeledContent("発行先", value: challenge.subject)
                LabeledContent("発行者", value: challenge.issuer)
                LabeledContent("有効期間", value: validity(for: challenge))
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256 フィンガープリント")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(grouped(challenge.leafSHA256))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("certificate-fingerprint")
                }
                if case .fingerprintChanged(let previous) = challenge.disposition {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("以前に承認したフィンガープリント")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(grouped(previous))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if challenge.disposition.allowsUserApproval {
                Section {
                    Button(challenge.disposition.isIdentityChange
                        ? String(localized: "変更を承知のうえで今回のみ接続")
                        : String(localized: "今回のみ信頼")) {
                        onTrust(false)
                    }
                    .accessibilityIdentifier("certificate-trust-once")

                    Button(challenge.disposition.isIdentityChange
                        ? String(localized: "新しい証明書に置き換えて保存")
                        : String(localized: "この接続先で常に信頼")) {
                        onTrust(true)
                    }
                    .accessibilityIdentifier("certificate-trust-always")
                } footer: {
                    Text("承認は \(challenge.host):\(challenge.port) とこのフィンガープリントの組み合わせにだけ適用されます。")
                }
            } else {
                Section {
                    Text("この証明書は承認できません。接続を中止してください。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("サーバー証明書の確認")
    }

    private func symbol(for challenge: CertificateChallenge) -> String {
        challenge.disposition.isIdentityChange
            ? "exclamationmark.shield.fill"
            : "lock.trianglebadge.exclamationmark"
    }

    private func headline(for disposition: CertificateDisposition) -> String {
        switch disposition {
        case .untrustedRoot:
            return String(localized: "システムが信頼していない証明書です")
        case .serverPurposeUnmet:
            return String(localized: "iOS のサーバー証明書要件を満たしていません")
        case .hostnameUnverifiable:
            return String(localized: "ホスト名を検証できていません")
        case .rejected(let reason):
            return reason
        case .fingerprintChanged:
            return String(localized: "以前と異なる証明書が提示されました")
        }
    }

    private func explanation(for challenge: CertificateChallenge) -> String {
        switch challenge.disposition {
        case .untrustedRoot:
            return String(localized: """
            自己署名または独自 CA の証明書です。チェーンと有効期間は確認済みですが、\
            この証明書を保証する第三者はいません。下のフィンガープリントが接続先の\
            サーバーのものであることを、別の手段で確認してください。
            """)
        case .serverPurposeUnmet:
            return String(localized: """
            チェーンと有効期間は確認済みですが、iOS がサーバー証明書に求める要件を\
            満たしていません。Windows のリモートデスクトップが既定で作る証明書は\
            この状態になることがあります。識別の根拠はフィンガープリントだけです。
            """)
        case .hostnameUnverifiable:
            return String(localized: """
            接続先を IP アドレスで指定したため、証明書のホスト名は検証されていません。\
            Windows の自己署名証明書はコンピューター名しか持たないため、IP 指定では\
            照合が成立しません。識別の根拠はフィンガープリントだけです。
            """)
        case .rejected(let reason):
            return String(localized: "\(reason) 承認しても安全にはならないため、接続は中止されます。")
        case .fingerprintChanged:
            return String(localized: """
            この接続先には以前に承認した証明書があり、今回はそれと異なる証明書が\
            提示されました。サーバーの証明書を更新した場合にも起こりますが、通信が\
            傍受されている場合にも同じことが起こります。心当たりがなければ承認せず、\
            サーバー側で証明書を確認してください。
            """)
        }
    }

    private func validity(for challenge: CertificateChallenge) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        guard challenge.notBefore != .distantPast, challenge.notAfter != .distantFuture else {
            return String(localized: "読み取れません")
        }
        return "\(formatter.string(from: challenge.notBefore)) 〜 \(formatter.string(from: challenge.notAfter))"
    }

    /// A 64 character hex string is unreadable in one run, and reading it is
    /// the entire security value of this sheet.
    private func grouped(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 2).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: min(2, fingerprint.count - offset))
            return String(fingerprint[start..<end])
        }.joined(separator: ":")
    }
}
