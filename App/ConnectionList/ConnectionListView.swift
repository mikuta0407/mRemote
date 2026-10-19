import SwiftUI
import UniformTypeIdentifiers
import SessionCore

struct ConnectionListView: View {
    @Environment(AppEnvironment.self) private var environment
    /// One presentation state for both sheets. Two `.sheet` modifiers on the
    /// same view do not both work in SwiftUI -- the later one wins -- so the
    /// route is modelled once and presented once.
    @State private var route: Route?
    @State private var isImportingFile = false
    @State private var searchText = ""
    @Environment(\.openWindow) private var openWindow

    private enum Route: Identifiable {
        case editor(ProfileEditorModel)
        case settings

        var id: String {
            switch self {
            case .editor(let model): return "editor-\(model.id)"
            case .settings: return "settings"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let failure = environment.loadFailure {
                    ContentUnavailableView {
                        Label("接続先を読み込めません", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    }
                } else if environment.profiles.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("接続先")
            .keepsNavigationBarOnScroll()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        route = .settings
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImportingFile = true
                    } label: {
                        Label(".rdp ファイルから読み込む", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("import-profile-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        route = .editor(ProfileEditorModel(mode: .create))
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-profile-button")
                }
            }
        }
        // iPad shows a centred form sheet, iPhone a large sheet; the adaptive
        // presentation is what SwiftUI does by default for `.sheet`, so the
        // only thing worth stating is the detent for the compact case.
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [UTType(filenameExtension: "rdp") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await environment.open(url) }
        }
        .onChange(of: environment.pendingImport?.id, initial: true) { _, _ in
            guard let model = environment.pendingImport else { return }
            environment.pendingImport = nil
            route = .editor(model)
        }
        .alert(
            environment.listMessage ?? "",
            isPresented: Binding(
                get: { environment.listMessage != nil },
                set: { if !$0 { environment.listMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .alert(
            "読み込めませんでした",
            isPresented: Binding(
                get: { environment.importFailure != nil },
                set: { if !$0 { environment.importFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.importFailure ?? "")
        }
        .sheet(item: $route) { route in
            switch route {
            case .editor(let model):
                ProfileEditorView(model: model)
                    .presentationDetents([.large])
                    .macSheetSize()
            case .settings:
                SettingsView()
                    .macSheetSize()
            }
        }
        // The Mac's menu bar: 設定… (⌘,) and 新しい接続先… (⌘N).
        .onChange(of: environment.listRequest, initial: true) { _, request in
            guard let request else { return }
            environment.listRequest = nil
            switch request {
            case .settings: route = .settings
            case .newConnection: route = .editor(ProfileEditorModel(mode: .create))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("接続先がありません", systemImage: "desktopcomputer")
        } description: {
            Text("右上の + から Windows の接続先を追加します。")
        } actions: {
            Button("接続先を追加") {
                route = .editor(ProfileEditorModel(mode: .create))
            }
            .accessibilityIdentifier("empty-add-profile-button")
        }
        .accessibilityIdentifier("empty-state")
    }

    /// Favourites first, then each group in name order, then the rest;
    /// filtered by the search text on name, host and group.
    private var profileSections: [(title: String?, profiles: [ConnectionProfile])] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = environment.profiles.filter { profile in
            query.isEmpty
                || profile.displayName.localizedCaseInsensitiveContains(query)
                || profile.endpoint.host.localizedCaseInsensitiveContains(query)
                || (profile.groupName?.localizedCaseInsensitiveContains(query) ?? false)
        }
        var sections: [(title: String?, profiles: [ConnectionProfile])] = []
        let favourites = matching.filter(\.isFavorite)
        if !favourites.isEmpty {
            sections.append((String(localized: "お気に入り"), favourites))
        }
        let others = matching.filter { !$0.isFavorite }
        let groups = Set(others.compactMap(\.groupName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for group in groups {
            sections.append((group, others.filter { $0.groupName == group }))
        }
        let ungrouped = others.filter { $0.groupName == nil }
        if !ungrouped.isEmpty {
            sections.append((sections.isEmpty ? nil : String(localized: "その他"), ungrouped))
        }
        return sections
    }

    private var list: some View {
        List {
            if !environment.runningSessions.isEmpty, searchText.isEmpty {
                Section("実行中") {
                    ForEach(environment.runningSessions) { session in
                        Button {
                            environment.present(session)
                        } label: {
                            HStack(spacing: 12) {
                                SessionThumbnailView(image: session.thumbnail)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayName).font(.headline)
                                        .foregroundStyle(.primary)
                                    SessionStateBadge(
                                        state: session.state,
                                        statusText: session.statusText
                                    )
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("running-session-\(session.displayName)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await session.disconnect() }
                            } label: {
                                Label(session.state.isActive ? String(localized: "切断") : String(localized: "閉じる"),
                                      systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            ForEach(Array(profileSections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section.profiles) { profile in
                        profileRow(profile)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("名前・ホスト・グループで検索"))
        .accessibilityIdentifier("profile-list")
    }

    @ViewBuilder
    private func profileRow(_ profile: ConnectionProfile) -> some View {
        Button {
            // docs/ui-flow.md section 7: an ordinary tap returns to the
            // profile's running session; only the explicit action below
            // opens a second one.
            if let running = environment.runningSession(for: profile) {
                environment.present(running)
            } else {
                Task { await environment.connect(to: profile) }
            }
        } label: {
            ConnectionRow(profile: profile, isWaking: environment.wakingProfileID == profile.id)
        }
        .disabled(environment.wakingProfileID == profile.id)
        .accessibilityIdentifier("profile-row-\(profile.displayName)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await environment.delete(profile) }
            } label: {
                Label("削除", systemImage: "trash")
            }
            Button {
                route = .editor(ProfileEditorModel(
                    mode: .edit(profile),
                    password: environment.storedPassword(for: profile)
                ))
            } label: {
                Label("編集", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await environment.setFavorite(!profile.isFavorite, for: profile) }
            } label: {
                Label(profile.isFavorite ? String(localized: "お気に入りから外す") : String(localized: "お気に入り"),
                      systemImage: profile.isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
            if profile.wakeOnLAN != nil {
                Button {
                    Task { await environment.wake(profile) }
                } label: {
                    Label("起動", systemImage: "power")
                }
                .tint(.green)
            }
        }
        .contextMenu {
            // On the Mac every connection is already a window of its own, so
            // neither of these is offered there.
            if !Platform.isMac {
                Button("新しいセッションで接続") {
                    Task { await environment.connect(to: profile) }
                }
                .accessibilityIdentifier("connect-new-session")
            }
            if UIApplication.shared.supportsMultipleScenes, !Platform.isMac {
                Button("新しいウィンドウで接続") {
                    openWindow(value: profile.id.rawValue)
                }
                .accessibilityIdentifier("connect-new-window")
            }
            if profile.wakeOnLAN != nil {
                Button("起動（Wake-on-LAN）") {
                    Task { await environment.wake(profile) }
                }
            }
            Button(profile.isFavorite ? String(localized: "お気に入りから外す") : String(localized: "お気に入りに追加")) {
                Task { await environment.setFavorite(!profile.isFavorite, for: profile) }
            }
            Button("編集") {
                route = .editor(ProfileEditorModel(
                    mode: .edit(profile),
                    password: environment.storedPassword(for: profile)
                ))
            }
            Button("複製") {
                Task { await environment.duplicate(profile) }
            }
            Button("削除", role: .destructive) {
                Task { await environment.delete(profile) }
            }
        }
    }
}

/// The desktop as last seen, small; a placeholder until there is one.
struct SessionThumbnailView: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "display")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemFill))
            }
        }
        .frame(width: 80, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.quaternary))
        .accessibilityHidden(true)
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile
    var isWaking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if profile.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("お気に入り")
                }
                Text(profile.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            if isWaking {
                Label("起動を待っています…", systemImage: "power")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            Text(Formatting.subtitle(for: profile))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let last = Formatting.lastConnected(profile.lastConnectedAt) {
                Text("最終接続 \(last)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
