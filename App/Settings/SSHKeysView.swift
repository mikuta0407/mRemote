import SwiftUI
import UniformTypeIdentifiers
import AppleAdapters
import SessionCore
import SSHProtocol

/// The private keys SSH profiles sign in with (docs/ssh-design.md 7.2):
/// generate one here, or bring one from a file or the clipboard. Only the
/// public half ever leaves the device.
struct SSHKeysView: View {
    @Environment(AppEnvironment.self) private var environment
    var onChange: () -> Void = {}

    @State private var keys: [SSHKeyMetadata] = []
    @State private var isImportingFile = false
    @State private var isPasting = false
    @State private var pastedKey = ""
    @State private var message: String?
    @State private var keyPendingDeletion: SSHKeyMetadata?
    @State private var renaming: SSHKeyMetadata?
    @State private var newName = ""

    var body: some View {
        List {
            if keys.isEmpty {
                Text("鍵はまだありません。作成するか、読み込んでください。")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(key.name).font(.headline)
                        if key.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("パスフレーズ付き")
                        }
                    }
                    Text(key.keyType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(key.fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .contextMenu {
                    Button("公開鍵をコピー", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = key.publicKey
                        message = String(localized: "公開鍵をコピーしました。サーバーの ~/.ssh/authorized_keys に追加してください。")
                    }
                    ShareLink(item: key.publicKey) {
                        Label("公開鍵を共有", systemImage: "square.and.arrow.up")
                    }
                    Button("名前を変更", systemImage: "pencil") {
                        newName = key.name
                        renaming = key
                    }
                    Button("削除", systemImage: "trash", role: .destructive) {
                        keyPendingDeletion = key
                    }
                }
                .swipeActions {
                    Button("削除", role: .destructive) { keyPendingDeletion = key }
                    Button("コピー") {
                        UIPasteboard.general.string = key.publicKey
                        message = String(localized: "公開鍵をコピーしました。サーバーの ~/.ssh/authorized_keys に追加してください。")
                    }
                    .tint(.blue)
                }
                .accessibilityIdentifier("ssh-key-row")
            }
        }
        .navigationTitle("SSH の鍵")
        .keepsNavigationBarOnScroll()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("新しい鍵を作成（Ed25519）", systemImage: "key") { generate() }
                        .accessibilityIdentifier("ssh-key-generate")
                    Button("ファイルから読み込む", systemImage: "doc") { isImportingFile = true }
                    Button("貼り付けて読み込む", systemImage: "doc.on.clipboard") {
                        pastedKey = UIPasteboard.general.string ?? ""
                        isPasting = true
                    }
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .accessibilityIdentifier("ssh-key-add")
            }
        }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.data, .text, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                message = String(localized: "ファイルを読めませんでした。")
                return
            }
            importKey(data, name: url.deletingPathExtension().lastPathComponent)
        }
        .sheet(isPresented: $isPasting) {
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $pastedKey)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("-----BEGIN OPENSSH PRIVATE KEY----- から始まる秘密鍵を貼り付けてください。")
                    }
                }
                .navigationTitle("秘密鍵を貼り付け")
                .keepsNavigationBarOnScroll()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { isPasting = false; pastedKey = "" }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("読み込む") {
                            importKey(Data(pastedKey.utf8), name: String(localized: "貼り付けた鍵"))
                            pastedKey = ""
                            isPasting = false
                        }
                        .disabled(pastedKey.isEmpty)
                    }
                }
            }
        }
        .alert("鍵を削除しますか？", isPresented: Binding(
            get: { keyPendingDeletion != nil },
            set: { if !$0 { keyPendingDeletion = nil } }
        ), presenting: keyPendingDeletion) { key in
            Button("削除", role: .destructive) { delete(key) }
            Button("キャンセル", role: .cancel) {}
        } message: { key in
            Text(deletionMessage(for: key))
        }
        .alert("名前を変更", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { key in
            TextField("名前", text: $newName)
            Button("変更") {
                try? environment.sshKeys.rename(key.id, to: newName.trimmingCharacters(in: .whitespaces))
                reload()
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func reload() {
        keys = (try? environment.sshKeys.allKeys()) ?? []
        onChange()
    }

    private func generate() {
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
        let key = OpenSSHKey.generateEd25519(comment: "mRemote@\(device)")
        store(key, name: String(localized: "mRemote の鍵"))
        UIPasteboard.general.string = key.publicKeyLine
        message = String(localized: "鍵を作成し、公開鍵をコピーしました。サーバーの ~/.ssh/authorized_keys に追加してください。")
    }

    private func importKey(_ data: Data, name: String) {
        do {
            let key = try OpenSSHKey(parsing: data)
            store(key, name: key.comment.isEmpty ? name : key.comment)
        } catch OpenSSHKey.ParseError.legacyEncryptedPEM {
            message = String(localized: "古い形式で暗号化された鍵です。Mac などで ssh-keygen -p -f <ファイル> を実行して OpenSSH 形式に書き直してから読み込んでください。")
        } catch OpenSSHKey.ParseError.unsupportedKeyType(let type) {
            message = String(localized: "この種類の鍵（\(type)）には対応していません。Ed25519、ECDSA、RSA の鍵を使ってください。")
        } catch {
            message = String(localized: "秘密鍵として読めませんでした。公開鍵（.pub）ではなく秘密鍵のファイルを選んでください。")
        }
    }

    private func store(_ key: OpenSSHKey, name: String) {
        let metadata = SSHKeyMetadata(
            name: name, keyType: key.keyType, publicKey: key.publicKeyLine,
            fingerprint: key.fingerprint, isEncrypted: key.isEncrypted)
        do {
            try environment.sshKeys.store(metadata, privateKey: key.privateKeyFile)
        } catch {
            message = String(localized: "鍵を保存できませんでした（\(String(describing: error))）。")
        }
        reload()
    }

    private func usingProfiles(_ key: SSHKeyMetadata) -> [String] {
        environment.profiles.filter { $0.configuration.ssh?.authentication.keyID == key.id }.map(\.displayName)
    }

    private func deletionMessage(for key: SSHKeyMetadata) -> String {
        let users = usingProfiles(key)
        if users.isEmpty { return String(localized: "「\(key.name)」をこのデバイスから削除します。元に戻せません。") }
        return String(localized: "「\(key.name)」を使っている接続先があります: \(users.joined(separator: "、"))。削除すると、これらは鍵でサインインできなくなります。")
    }

    private func delete(_ key: SSHKeyMetadata) {
        try? environment.sshKeys.delete(key.id)
        reload()
    }
}

/// The host keys the user trusted (docs/ssh-design.md 7.1). Removing one
/// makes the next connection ask again.
struct KnownHostsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var hosts: [KnownHost] = []

    var body: some View {
        List {
            if hosts.isEmpty {
                Text("まだありません。SSH で接続し、ホスト鍵を「常に信頼」するとここに並びます。")
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts, id: \.endpointKey) { host in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(host.host):\(host.port)").font(.headline)
                    Text(host.keyType).font(.caption).foregroundStyle(.secondary)
                    Text(host.fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    try? environment.knownHosts.remove(host: hosts[index].host, port: hosts[index].port)
                }
                reload()
            }
        }
        .navigationTitle("既知のホスト鍵")
        .keepsNavigationBarOnScroll()
        .onAppear(perform: reload)
    }

    private func reload() {
        hosts = (try? environment.knownHosts.allHosts()) ?? []
    }
}
