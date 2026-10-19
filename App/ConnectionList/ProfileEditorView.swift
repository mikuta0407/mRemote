import SwiftUI
import UniformTypeIdentifiers
import SessionCore

struct ProfileEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ProfileEditorModel
    @State private var isPickingFolder = false

    var body: some View {
        NavigationStack {
            Form {
                if model.isImport {
                    Section {
                        Label("ファイルまたはリンクの内容を入れました。確認して保存してください。", systemImage: "square.and.arrow.down")
                        if !model.unsupportedImportSettings.isEmpty {
                            Label(
                                String(localized: "この設定には対応していないため使いません: \(model.unsupportedImportSettings.joined(separator: ", "))"),
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("profile-import-note")
                }
                if model.canChangeProtocol {
                    Section {
                        Picker("種類", selection: $model.protocolKind) {
                            Text(verbatim: "RDP").tag(ProtocolKind.rdp)
                            Text(verbatim: "SSH").tag(ProtocolKind.ssh)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("profile-protocol-picker")
                    }
                }
                Section(String(localized: "profile-editor.section.computer", defaultValue: "接続先")) {
                    TextField("名前", text: $model.displayName)
                        .accessibilityIdentifier("profile-name-field")
                    TextField("ホスト名または IP", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("profile-host-field")
                    LabeledContent("ポート") {
                        TextField("ポート", text: $model.portText, prompt: Text(verbatim: String(model.defaultPort)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("profile-port-field")
                    }
                }

                proxySection

                Section {
                    TextField("グループ（任意）", text: $model.group)
                        .accessibilityIdentifier("profile-group-field")
                    Toggle("お気に入り", isOn: $model.isFavorite)
                        .accessibilityIdentifier("profile-favorite-toggle")
                }

                if model.protocolKind == .ssh {
                    SSHProfileSections(model: model)
                } else {
                Section("資格情報") {
                    TextField("ユーザー名", text: $model.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ドメイン（任意）", text: $model.domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("パスワード", text: $model.password)
                    Text("パスワードは Keychain にのみ保存され、接続設定のファイルやログには残りません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    InheritablePicker(
                        title: String(localized: "解像度"),
                        selection: $model.resolutionPolicy,
                        options: [.adaptive] + ResolutionPolicy.presets,
                        label: Formatting.resolutionLabel
                    )
                    .accessibilityIdentifier("profile-resolution-picker")
                } header: {
                    Text("画面")
                } footer: {
                    Text("接続中でもセッションメニューから変えられます。")
                }

                Section("キーボード") {
                    InheritablePicker(
                        title: String(localized: "レイアウト"),
                        selection: $model.keyboardLayout,
                        options: KeyboardLayoutPreference.allCases,
                        label: keyboardLabel
                    )
                    if model.showsJapaneseKeyWarning {
                        Label(
                            String(localized: "英数→無変換、かな→変換の変換が保証されるのは日本語レイアウトのみです。"),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                    }
                }

                Section("セキュリティ") {
                    Picker("接続方式", selection: Binding(
                        get: { model.securityPolicy },
                        set: { model.choose($0) }
                    )) {
                        ForEach(SecurityPolicy.allCases, id: \.self) { policy in
                            Text(securityLabel(policy)).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("profile-security-picker")
                    .alert("レガシー RDP セキュリティを許可しますか？", isPresented: Binding(
                        get: { model.isConfirmingLegacySecurity },
                        set: { if !$0 { model.declineLegacySecurity() } }
                    )) {
                        Button("許可する", role: .destructive) { model.confirmLegacySecurity() }
                        Button("キャンセル", role: .cancel) { model.declineLegacySecurity() }
                    } message: {
                        Text("この接続先だけ、TLS/NLA を使えないサーバーへ古い RDP セキュリティで接続できるようにします。暗号は弱く、サーバーが本物かどうかの確認もできません。信頼できるネットワーク上の、自分が管理するマシンにだけ使ってください。")
                    }
                    if model.showsLegacySecurityWarning {
                        Label(
                            String(localized: "レガシー RDP セキュリティは暗号強度が低く、資格情報の保護も弱くなります。"),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                    }
                }

                gatewaySection
                Section {
                    Picker("接続先", selection: $model.remotePlatform) {
                        Text("Windows / 標準の RDP").tag(RemotePlatform.standard)
                        Text("macOS（macos-rdp-server）").tag(RemotePlatform.macOS)
                    }
                    .accessibilityIdentifier("profile-platform-picker")
                    if model.remotePlatform == .macOS {
                        Picker("画質", selection: $model.streamQuality) {
                            ForEach(StreamQuality.allCases, id: \.self) { quality in
                                Text(StreamQualityLabel.text(quality)).tag(quality)
                            }
                        }
                        .accessibilityIdentifier("profile-stream-quality-picker")
                    }
                } header: {
                    Text("接続先の種類")
                } footer: {
                    if model.remotePlatform == .macOS {
                        Text("Mac 同士の拡張を使います。⌘ は ⌘ のまま、Fn や左右の修飾キー、トラックパッドの滑らかなスクロールもそのまま届きます。拡張に対応しないサーバーには通常の RDP で接続します。")
                    } else {
                        Text("macos-rdp-server を動かす Mac に接続するときは「macOS」を選ぶと、Mac のキー操作とスクロールがそのまま届きます。")
                    }
                }
                Section {
                    Toggle("マイクを使う", isOn: $model.redirectsMicrophone)
                        .accessibilityIdentifier("profile-microphone-toggle")
                    Toggle("H.264 で画面を受け取る", isOn: $model.usesH264)
                        .accessibilityIdentifier("profile-h264-toggle")
                } header: {
                    Text("音声と画質")
                } footer: {
                    Text("マイクは Windows 側のアプリが使うときだけ録音します。H.264 は動きの多い画面で通信量が減ります（端末のハードウェアで復号します）。")
                }
                Section {
                    TextField("プログラム（例 ||notepad）", text: $model.remoteProgram)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("profile-remote-program-field")
                    if !model.remoteProgram.trimmingCharacters(in: .whitespaces).isEmpty {
                        TextField("引数（任意）", text: $model.remoteArguments)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("RemoteApp")
                } footer: {
                    Text("空欄ならデスクトップ全体に接続します。指定すると、そのプログラムのウィンドウだけを表示します（サーバー側で RemoteApp を許可しておく必要があります）。RemoteApp では H.264 を使いません。")
                }
                sharedFolderSection

                Section("チャネル") {
                    InheritablePicker(
                        title: String(localized: "音声再生"),
                        selection: $model.audioPlayback,
                        options: [true, false],
                        label: { $0 ? String(localized: "有効") : String(localized: "無効") }
                    )
                    InheritablePicker(
                        title: String(localized: "クリップボード"),
                        selection: $model.clipboardPolicy,
                        options: ClipboardPolicy.allCases,
                        label: clipboardLabel
                    )
                    InheritablePicker(
                        title: String(localized: "スクロール方向"),
                        selection: $model.scrollDirection,
                        options: ScrollDirection.allCases,
                        label: { $0 == .normal ? String(localized: "通常") : String(localized: "反転") }
                    )
                }
                }
                wakeSection
            }
            .navigationTitle(model.title)
            .keepsNavigationBarOnScroll()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("profile-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let profile = model.makeProfile() else { return }
                        let password = model.password
                        let gatewayPassword = model.usesGateway && !model.gatewayUsesComputerCredentials
                            ? model.gatewayPassword : nil
                        Task {
                            await environment.save(profile, password: password, gatewayPassword: gatewayPassword)
                        }
                        dismiss()
                    }
                    .disabled(!model.isValid)
                    .accessibilityIdentifier("profile-save-button")
                }
            }
        }
    }

    private var proxySection: some View {
        Section {
            Picker("プロキシ", selection: $model.proxyID) {
                Text("使わない").tag(ProxyID?.none)
                ForEach(environment.proxies) { proxy in
                    Text(proxy.displayName).tag(ProxyID?.some(proxy.id))
                }
            }
            .accessibilityIdentifier("profile-proxy-picker")
            .onChange(of: environment.proxies) { _, proxies in
                // Deleted on the management screen meanwhile.
                if let selected = model.proxyID, !proxies.contains(where: { $0.id == selected }) {
                    model.proxyID = nil
                }
            }
            NavigationLink("プロキシを管理…") { ProxiesView() }
                .accessibilityIdentifier("profile-manage-proxies")
        } footer: {
            Text("SOCKS5 プロキシを経由して接続します。接続先の名前はプロキシが解決します。保存したプロキシはほかの接続先からも選べます。")
        }
    }

    @ViewBuilder
    private var wakeSection: some View {
        Section {
            Toggle("Wake-on-LAN", isOn: $model.wakesOnLAN)
                .accessibilityIdentifier("profile-wake-toggle")
            if model.wakesOnLAN {
                TextField("MAC アドレス（例 AA:BB:CC:DD:EE:FF）", text: $model.macAddress)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("profile-mac-field")
                TextField("送信先", text: $model.wakeTarget)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                TextField("ポート", text: $model.wakePortText)
                    .keyboardType(.numberPad)
                Toggle("接続するときに起動する", isOn: $model.wakesBeforeConnecting)
                if !model.macAddress.isEmpty, MagicPacket.macBytes(model.macAddress) == nil {
                    Label("MAC アドレスは 16 進 12 桁で入力してください。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("起動")
        } footer: {
            if model.wakesOnLAN {
                Text("スリープ中の PC を起こしてから接続します（最大 2 分待ちます）。送信先は通常 255.255.255.255 のままで、外から起こすときはルーターなどの転送先を指定します。一覧で接続先を右にスワイプしても起動できます。")
            }
        }
    }

    @ViewBuilder
    private var gatewaySection: some View {
        Section {
            Toggle("RD ゲートウェイを使う", isOn: $model.usesGateway)
                .accessibilityIdentifier("profile-gateway-toggle")
            if model.usesGateway {
                TextField("ゲートウェイのホスト名", text: $model.gatewayHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("profile-gateway-host-field")
                TextField("ポート", text: $model.gatewayPortText)
                    .keyboardType(.numberPad)
                Toggle("接続先と同じユーザーでサインイン", isOn: $model.gatewayUsesComputerCredentials)
                if !model.gatewayUsesComputerCredentials {
                    TextField("ゲートウェイのユーザー名", text: $model.gatewayUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ドメイン（任意）", text: $model.gatewayDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("ゲートウェイのパスワード", text: $model.gatewayPassword)
                }
                Toggle("ローカルのアドレスにはゲートウェイを使わない", isOn: $model.gatewayBypassesLocal)
            }
        } header: {
            Text("RD ゲートウェイ")
        } footer: {
            if model.usesGateway {
                Text("HTTPS（つながらなければ RPC）でゲートウェイを経由します。ゲートウェイの証明書も、接続先と同じように確認します。")
            }
        }
    }

    @ViewBuilder
    private var sharedFolderSection: some View {
        Section {
            Picker("共有するフォルダ", selection: Binding(
                get: { folderTag },
                set: { tag in
                    switch tag {
                    case "app": model.sharedFolder = .appDocuments
                    case "pick": isPickingFolder = true
                    default: model.sharedFolder = .none
                    }
                }
            )) {
                Text("共有しない").tag("none")
                Text("このアプリのフォルダ").tag("app")
                if case let .picked(_, name) = model.sharedFolder {
                    Text(name).tag("picked")
                }
                Text("フォルダを選ぶ…").tag("pick")
            }
            .accessibilityIdentifier("profile-shared-folder-picker")
            if model.sharedFolder != .none {
                TextField("ドライブ名", text: $model.driveName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("フォルダの共有")
        } footer: {
            Text(model.sharedFolder == .appDocuments
                 ? String(localized: "ファイル App の「このiPhone内 › mRemote」が、Windows のエクスプローラーにドライブとして見えます。")
                 : String(localized: "選んだフォルダが、Windows のエクスプローラーにドライブとして見えます。接続中は Windows から読み書きできます。"))
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            else { return }
            model.sharedFolder = .picked(bookmark: bookmark, name: url.lastPathComponent)
            if model.driveName == "mRemote" || model.driveName.isEmpty {
                model.driveName = SharedFolder.sanitizedDriveName(url.lastPathComponent)
            }
        }
    }

    private var folderTag: String {
        switch model.sharedFolder {
        case .none: return "none"
        case .appDocuments: return "app"
        case .picked: return "picked"
        }
    }

    private func keyboardLabel(_ value: KeyboardLayoutPreference) -> String {
        switch value {
        case .japanese: return String(localized: "日本語 106/109")
        case .us: return "US"
        case .automatic: return String(localized: "自動")
        }
    }

    private func clipboardLabel(_ value: ClipboardPolicy) -> String {
        switch value {
        case .disabled: return String(localized: "無効")
        case .bidirectional: return String(localized: "双方向")
        case .sendOnly: return String(localized: "送信のみ")
        case .receiveOnly: return String(localized: "受信のみ")
        }
    }

    private func securityLabel(_ value: SecurityPolicy) -> String {
        switch value {
        case .secureAutomatic: return String(localized: "自動（安全な方式のみ）")
        case .nlaRequired: return String(localized: "NLA 必須")
        case .tlsRequired: return String(localized: "TLS 必須")
        case .legacyExplicit: return String(localized: "レガシー RDP セキュリティ")
        }
    }
}

/// One control for every setting that can either inherit the global default or
/// override it, so `inherit` looks the same everywhere it appears.
struct InheritablePicker<Value: Hashable & Sendable & Codable>: View {
    let title: String
    @Binding var selection: Inheritable<Value>
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(title, selection: Binding(
            get: { Choice(selection) },
            set: { selection = $0.inheritable }
        )) {
            Text("全体設定に従う").tag(Choice<Value>.inherit)
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(Choice.explicit(option))
            }
        }
    }

    private enum Choice<Wrapped: Hashable & Sendable & Codable>: Hashable {
        case inherit
        case explicit(Wrapped)

        init(_ value: Inheritable<Wrapped>) {
            switch value {
            case .inherit: self = .inherit
            case .explicit(let wrapped): self = .explicit(wrapped)
            }
        }

        var inheritable: Inheritable<Wrapped> {
            switch self {
            case .inherit: return .inherit
            case .explicit(let wrapped): return .explicit(wrapped)
            }
        }
    }
}
