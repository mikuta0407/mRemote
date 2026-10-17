import SwiftUI
import AppleAdapters
import SessionCore

/// The SSH half of the connection form (docs/ssh-design.md 8.1). The RDP
/// sections are not shown for an SSH profile, and none of these for RDP.
struct SSHProfileSections: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: ProfileEditorModel
    @State private var keys: [SSHKeyMetadata] = []

    var body: some View {
        Section {
            TextField("ユーザー名", text: $model.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("profile-ssh-username-field")
            Picker("鍵", selection: $model.sshKeyID) {
                Text("使わない").tag(SSHKeyID?.none)
                ForEach(keys) { key in
                    Text(key.name).tag(SSHKeyID?.some(key.id))
                }
            }
            .accessibilityIdentifier("profile-ssh-key-picker")
            NavigationLink("鍵を管理…") {
                SSHKeysView(onChange: reloadKeys)
            }
            Toggle("パスワードでのサインイン", isOn: $model.sshAllowsPassword)
            if model.sshAllowsPassword {
                SecureField("パスワード（任意）", text: $model.password)
            }
            Toggle("サーバーの質問に答えてサインイン", isOn: $model.sshAllowsKeyboardInteractive)
            if model.showsNoSignInMethodWarning {
                Label("サインインの方法がありません。鍵を選ぶか、パスワードかサーバーの質問を許可してください。",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("サインイン")
        } footer: {
            Text("鍵、サーバーの質問（ワンタイムパスワードなど）、パスワードの順に試します。ユーザー名が空なら接続するときに聞きます。パスワードと鍵は Keychain にのみ保存されます。")
        }

        Section {
            InheritablePicker(
                title: String(localized: "文字の大きさ"),
                selection: $model.terminalFontSize,
                options: [10, 11, 12, 13, 14, 15, 16, 18, 20, 24],
                label: { String(format: "%.0f pt", $0) }
            )
            InheritablePicker(
                title: String(localized: "配色"),
                selection: $model.terminalTheme,
                options: TerminalTheme.allCases,
                label: Formatting.terminalThemeLabel
            )
            InheritablePicker(
                title: String(localized: "Option キー"),
                selection: $model.optionAsMeta,
                options: [true, false],
                label: { $0 ? String(localized: "Meta（Esc を前置）") : String(localized: "文字の入力") }
            )
            TextField("接続後に実行するコマンド", text: $model.startupCommand, prompt: Text(verbatim: "tmux new -A -s main"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("profile-ssh-startup-field")
        } header: {
            Text("端末")
        } footer: {
            Text("iPhone/iPad をしばらく閉じると接続は切れ、シェルも終わります。tmux や screen を起動しておくと、つなぎ直したときに作業の続きから始められます。")
        }

        Section {
            InheritablePicker(
                title: String(localized: "自動で再接続"),
                selection: $model.sshReconnectPolicy,
                options: ReconnectPolicy.allCases,
                label: { $0 == .automatic ? String(localized: "する") : String(localized: "しない") }
            )
            InheritablePicker(
                title: String(localized: "シェルが終了したら"),
                selection: $model.shellExitBehavior,
                options: ShellExitBehavior.allCases,
                label: Formatting.shellExitLabel
            )
            InheritablePicker(
                title: String(localized: "接続の確認（keepalive）"),
                selection: $model.keepAliveSeconds,
                options: [0, 15, 30, 60, 120],
                label: { $0 == 0 ? String(localized: "しない") : String(localized: "\($0) 秒ごと") }
            )
            InheritablePicker(
                title: String(localized: "クリップボード"),
                selection: $model.clipboardPolicy,
                options: ClipboardPolicy.allCases,
                label: Formatting.clipboardLabel
            )
            TextField("TERM", text: $model.terminalType, prompt: Text(verbatim: SSHConfiguration.defaultTerminalType))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("詳細")
        } footer: {
            Text("再接続すると新しいシェルが始まります。クリップボードは、端末への貼り付け（送信）と端末からのコピー（受信）を許可するかどうかです。")
        }

        SSHPortForwardSection(forwards: $model.portForwards)
            .onAppear(perform: reloadKeys)
    }

    private func reloadKeys() {
        keys = (try? environment.sshKeys.allKeys()) ?? []
        if let selected = model.sshKeyID, !keys.contains(where: { $0.id == selected }) {
            model.sshKeyID = nil
        }
    }
}

/// Local port forwards (`ssh -L`), e.g. RDP to a machine behind the SSH
/// server: 13389 → 10.0.0.5:3389, then an RDP profile for localhost:13389.
struct SSHPortForwardSection: View {
    @Binding var forwards: [SSHPortForward]

    var body: some View {
        Section {
            ForEach($forwards) { $forward in
                HStack(spacing: 6) {
                    TextField("ローカル", value: $forward.localPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 80)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("転送先ホスト", text: $forward.remoteHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(verbatim: ":")
                    TextField("ポート", value: $forward.remotePort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 70)
                }
                .font(.system(.body, design: .monospaced))
            }
            .onDelete { forwards.remove(atOffsets: $0) }
            Button("転送を追加") {
                forwards.append(SSHPortForward(localPort: 13389, remoteHost: "localhost", remotePort: 3389))
            }
            .accessibilityIdentifier("profile-ssh-add-forward")
        } header: {
            Text("ポート転送")
        } footer: {
            Text("接続している間、この端末の localhost:ローカルポート への接続を、SSH サーバーから見た転送先へつなぎます。SSH サーバーの奥にある PC へ RDP するときは、RDP の接続先を localhost とそのポートにします。")
        }
    }
}
