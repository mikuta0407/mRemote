import SwiftUI
import SessionCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var settings = GlobalSettings.default
    @AppStorage(DesktopSafeAreaPolicy.storageKey)
    private var safeAreaPolicy = DesktopSafeAreaPolicy.avoid

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("キーボードレイアウト", selection: $settings.keyboardLayout) {
                        Text("日本語 106/109").tag(KeyboardLayoutPreference.japanese)
                        Text("US").tag(KeyboardLayoutPreference.us)
                        Text("自動").tag(KeyboardLayoutPreference.automatic)
                    }
                } header: {
                    Text("キーボード")
                } footer: {
                    Text("英数→無変換、かな→変換の変換が保証されるのは日本語レイアウトのみです。接続先ごとに上書きできます。")
                }

                Section {
                    Picker("解像度", selection: $settings.resolutionPolicy) {
                        ForEach([ResolutionPolicy.adaptive] + ResolutionPolicy.presets, id: \.self) { policy in
                            Text(Formatting.resolutionLabel(policy)).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("settings-resolution-picker")
                    Picker("初期倍率", selection: $settings.initialScale) {
                        Text("画面に合わせる").tag(InitialScale.fit)
                        Text("100%").tag(InitialScale.oneToOne)
                    }
                    // A matter of the device in hand, so it is kept on the
                    // device rather than with the other settings.
                    Toggle("画面の端まで使う", isOn: Binding(
                        get: { safeAreaPolicy == .fullScreen },
                        set: { safeAreaPolicy = $0 ? .fullScreen : .avoid }
                    ))
                    .accessibilityIdentifier("settings-full-screen-toggle")
                } header: {
                    Text("表示")
                } footer: {
                    Text("自動は画面の大きさに合わせて解像度を変えます（サーバーが対応している場合）。「画面の端まで使う」をオフにすると、Dynamic Island や画面の角を避けて表示します。")
                }

                Section("入力") {
                    Picker("スクロール方向", selection: $settings.scrollDirection) {
                        Text("通常").tag(ScrollDirection.normal)
                        Text("反転").tag(ScrollDirection.reversed)
                    }
                    NavigationLink("ショートカット") {
                        ShortcutListEditor()
                    }
                    .accessibilityIdentifier("settings-shortcuts")
                }

                Section {
                    Picker("初期モード", selection: $settings.softwareKeyboardMode) {
                        Text("手元IME").tag(SoftwareKeyboardMode.localIME)
                        Text("ホストIME").tag(SoftwareKeyboardMode.hostIME)
                    }
                    .accessibilityIdentifier("settings-software-keyboard-mode")
                } header: {
                    Text("ソフトウェアキーボード")
                } footer: {
                    Text("手元IME は iPad で変換して確定した文字だけを送ります（Windows 側の IME はオフにしてください）。ホストIME は英数キーボードの打鍵をそのまま送り、Windows 側の IME で変換します。セッション中にキーバーで切り替えられます。")
                }

                Section {
                    Toggle("音声を再生", isOn: $settings.audioPlayback)
                    Picker("クリップボード", selection: $settings.clipboardPolicy) {
                        Text("無効").tag(ClipboardPolicy.disabled)
                        Text("双方向").tag(ClipboardPolicy.bidirectional)
                        Text("送信のみ").tag(ClipboardPolicy.sendOnly)
                        Text("受信のみ").tag(ClipboardPolicy.receiveOnly)
                    }
                } header: {
                    Text("チャネル")
                } footer: {
                    Text("双方向は転送を許可する方向の設定です。クリップボードを常時監視するものではなく、転送はコピー/貼り付け操作を起点にします。")
                }

                Section("接続") {
                    Picker("自動再接続", selection: $settings.reconnectPolicy) {
                        Text("しない").tag(ReconnectPolicy.disabled)
                        Text("する").tag(ReconnectPolicy.automatic)
                    }
                }

                Section {
                    Picker("文字の大きさ", selection: $settings.terminal.fontSize) {
                        ForEach([10.0, 11, 12, 13, 14, 15, 16, 18, 20, 24], id: \.self) { size in
                            Text(String(format: "%.0f pt", size)).tag(size)
                        }
                    }
                    Picker("配色", selection: $settings.terminal.theme) {
                        ForEach(TerminalTheme.allCases, id: \.self) { theme in
                            Text(Formatting.terminalThemeLabel(theme)).tag(theme)
                        }
                    }
                    Toggle("Option キーを Meta として送る", isOn: $settings.terminal.optionAsMeta)
                    Picker("シェルが終了したら", selection: $settings.terminal.exitBehavior) {
                        ForEach(ShellExitBehavior.allCases, id: \.self) { behavior in
                            Text(Formatting.shellExitLabel(behavior)).tag(behavior)
                        }
                    }
                    NavigationLink("SSH の鍵") { SSHKeysView() }
                        .accessibilityIdentifier("settings-ssh-keys")
                    NavigationLink("既知のホスト鍵") { KnownHostsView() }
                        .accessibilityIdentifier("settings-known-hosts")
                } header: {
                    Text("SSH")
                } footer: {
                    Text("SSH の接続先が「全体設定に従う」ときに使う値です。")
                }

                Section("診断") {
                    NavigationLink("入力診断") {
                        InputDiagnosticsView()
                    }
                    .accessibilityIdentifier("input-diagnostics-link")
                }

                Section("ヘルプ") {
                    NavigationLink("送れないキーとバックグラウンド") {
                        HelpView()
                    }
                    .accessibilityIdentifier("help-link")
                }

                Section {
                    NavigationLink("ライセンス") {
                        LicensesView()
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        let updated = settings
                        Task { await environment.updateGlobalSettings(updated) }
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-done-button")
                }
            }
            .onAppear { settings = environment.globalSettings }
        }
        .accessibilityIdentifier("settings-screen")
    }
}
