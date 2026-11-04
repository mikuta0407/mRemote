import SwiftUI
import UniformTypeIdentifiers
import AppleAdapters
import SessionCore
import SSHProtocol

/// `~/.ssh/config` in and out (SSHConfigProfiles): read into a plan the user
/// looks over before anything is saved, and written from every SSH
/// connection.
extension AppEnvironment {
    func sshConfigPlan(from url: URL) -> SSHConfigProfiles.Plan? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            importFailure = String(localized: "\(url.lastPathComponent) を読めませんでした。")
            return nil
        }
        return sshConfigPlan(text: text, name: url.lastPathComponent)
    }

    func sshConfigPlan(text: String, name: String) -> SSHConfigProfiles.Plan? {
        let file = SSHConfigFile(parsing: text)
        guard !file.hosts.isEmpty else {
            importFailure = String(localized: "\(name) に Host の設定がありませんでした。")
            return nil
        }
        let keys = ((try? sshKeys.allKeys()) ?? []).map { SSHConfigProfiles.StoredKey(id: $0.id, name: $0.name) }
        return SSHConfigProfiles.plan(file, existing: profiles, keys: keys)
    }

    /// Saves the chosen items. One that goes through a jump host left out,
    /// and not already saved, goes direct instead.
    func importSSHConfig(_ items: [SSHConfigProfiles.Item]) async {
        let saved = Set(profiles.map(\.id)).union(items.map(\.id))
        for item in items {
            var profile = item.profile
            if case .ssh(var ssh) = profile.configuration, let jump = ssh.jumpProfileID, !saved.contains(jump) {
                ssh.jumpProfileID = nil
                profile.configuration = .ssh(ssh)
            }
            await save(profile, password: nil)
        }
    }

    var sshConfigExport: String {
        let names = Dictionary(((try? sshKeys.allKeys()) ?? []).map { ($0.id, $0.name) }) { first, _ in first }
        return SSHConfigProfiles.file(for: profiles, all: profiles, keyNames: names).text
    }
}

/// The exported file, for the share sheet and Files.
struct SSHConfigDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// What reading an ssh config would add or change, to choose from.
struct SSHConfigImportView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let plan: SSHConfigProfiles.Plan
    @State private var chosen: Set<ProfileID>

    init(plan: SSHConfigProfiles.Plan) {
        self.plan = plan
        _chosen = State(initialValue: Set(plan.items.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(plan.items) { item in
                        Toggle(isOn: binding(for: item.id)) {
                            row(item)
                        }
                        .accessibilityIdentifier("ssh-config-item-\(item.alias)")
                    }
                } footer: {
                    Text("同じ名前の SSH 接続先は、ファイルにある項目（ホスト名、ポート、ユーザー、鍵、踏み台、keepalive）だけを書き換えます。")
                }
                if plan.items.contains(where: { $0.missingKey != nil }) {
                    Section {
                        Text("IdentityFile の鍵は、同じ名前で保存した鍵に結び付けます。見つからない鍵は、設定 > SSH 鍵 で取り込んでから、接続先の編集で選んでください。")
                    }
                }
                if !plan.unread.isEmpty {
                    Section("読み込まなかった設定") {
                        Text(plan.unread.joined(separator: ", "))
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .navigationTitle("ssh config から読み込む")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("読み込む") {
                        let items = plan.items.filter { chosen.contains($0.id) }
                        Task { await environment.importSSHConfig(items) }
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("ssh-config-import-confirm")
                }
            }
        }
    }

    private func row(_ item: SSHConfigProfiles.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.alias).font(.headline)
                Text(item.replacesExisting ? "上書き" : "新規")
                    .font(.caption)
                    .foregroundStyle(item.replacesExisting ? .orange : .secondary)
            }
            let endpoint = item.profile.endpoint
            let user = item.profile.account.username.map { "\($0)@" } ?? ""
            Text(verbatim: "\(user)\(endpoint.host):\(endpoint.port)")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            if let jump = item.profile.configuration.ssh?.jumpProfileID,
               let name = plan.items.first(where: { $0.id == jump })?.alias
                ?? environment.profiles.first(where: { $0.id == jump })?.displayName {
                Text("踏み台: \(name)").font(.footnote).foregroundStyle(.secondary)
            }
            if let missing = item.missingKey {
                Label("鍵「\(missing)」が見つかりません", systemImage: "key.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func binding(for id: ProfileID) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(id) },
            set: { if $0 { chosen.insert(id) } else { chosen.remove(id) } }
        )
    }
}
