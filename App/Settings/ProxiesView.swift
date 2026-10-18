import SwiftUI
import SessionCore

/// The saved proxies (SOCKS5) connections pick from. One proxy serves any
/// number of connections, RDP or SSH; editing it changes all of them.
struct ProxiesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editing: ProxyServer?
    @State private var pendingDeletion: ProxyServer?

    var body: some View {
        List {
            if environment.proxies.isEmpty {
                Text("プロキシはまだありません。")
                    .foregroundStyle(.secondary)
            }
            ForEach(environment.proxies) { proxy in
                Button {
                    editing = proxy
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proxy.displayName).font(.headline)
                        Text(verbatim: "SOCKS5 · \(proxy.address)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let count = environment.profileCount(usingProxy: proxy.id)
                        if count > 0 {
                            Text("\(count) 件の接続先で使用中")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .swipeActions {
                    Button("削除", role: .destructive) { pendingDeletion = proxy }
                }
                .contextMenu {
                    Button("編集", systemImage: "pencil") { editing = proxy }
                    Button("削除", systemImage: "trash", role: .destructive) { pendingDeletion = proxy }
                }
                .accessibilityIdentifier("proxy-row")
            }
        }
        .navigationTitle("プロキシ")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("追加", systemImage: "plus") {
                    editing = ProxyServer(host: "")
                }
                .accessibilityIdentifier("proxy-add")
            }
        }
        .sheet(item: $editing) { proxy in
            ProxyEditorView(proxy: proxy) { saved in
                Task { await environment.saveProxy(saved) }
            }
        }
        .alert("プロキシを削除しますか？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { proxy in
            Button("削除", role: .destructive) {
                Task { await environment.deleteProxy(proxy) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { proxy in
            let count = environment.profileCount(usingProxy: proxy.id)
            if count > 0 {
                Text("\(count) 件の接続先がこのプロキシを使っています。削除すると、それらはプロキシを使わずに直接接続します。")
            } else {
                Text("どの接続先も使っていません。")
            }
        }
    }
}

/// Adds or edits one proxy.
struct ProxyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let original: ProxyServer
    let onSave: (ProxyServer) -> Void

    @State private var name: String
    @State private var host: String
    @State private var portText: String

    init(proxy: ProxyServer, onSave: @escaping (ProxyServer) -> Void) {
        original = proxy
        self.onSave = onSave
        _name = State(initialValue: proxy.name)
        _host = State(initialValue: proxy.host)
        _portText = State(initialValue: proxy.host.isEmpty && proxy.port == proxy.kind.defaultPort
            ? "" : String(proxy.port))
    }

    private var trimmedHost: String {
        // A bracketed IPv6 literal is stored bare, as the bridges take it.
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private var port: UInt16? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return original.kind.defaultPort }
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    private var isValid: Bool {
        !trimmedHost.isEmpty && trimmedHost.utf8.count <= 253 && port != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前（任意）", text: $name)
                        .accessibilityIdentifier("proxy-name-field")
                    TextField("ホスト", text: $host, prompt: Text(verbatim: "proxy.example.com"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("proxy-host-field")
                    TextField("ポート", text: $portText, prompt: Text(verbatim: String(original.kind.defaultPort)))
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("proxy-port-field")
                    LabeledContent("種類", value: "SOCKS5")
                } footer: {
                    Text("接続先の名前はプロキシが解決します。プロキシの先でしか引けない名前でも接続できます。ユーザー名とパスワードが必要なプロキシにはまだ対応していません。")
                }
            }
            .navigationTitle(original.host.isEmpty ? "プロキシを追加" : "プロキシを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let port else { return }
                        var proxy = original
                        proxy.name = name.trimmingCharacters(in: .whitespaces)
                        proxy.host = trimmedHost
                        proxy.port = port
                        onSave(proxy)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier("proxy-save")
                }
            }
        }
    }
}
