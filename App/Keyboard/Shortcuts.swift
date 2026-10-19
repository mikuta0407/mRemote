import SwiftUI
import InputCore

/// Whether the laptop deck carries a row of the user's shortcuts.
enum DeckShortcutStrip {
    static let storageKey = "laptop-deck-shortcut-strip"
    static let height: CGFloat = 34
}

/// The user's shortcuts as a row of buttons along the top of the laptop
/// deck, dark like the keys below.
struct ShortcutStrip: View {
    let shortcuts: [KeyShortcut]
    let isEnabled: Bool
    let send: (KeyShortcut) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shortcuts) { shortcut in
                    Button {
                        send(shortcut)
                    } label: {
                        Text(shortcut.displayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: DeckShortcutStrip.height - 8)
                            .background(Color(white: 0.24), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(shortcut.keysDescription)
                    .accessibilityIdentifier("deck-shortcut-\(shortcut.keysDescription)")
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: DeckShortcutStrip.height)
        .background(Color.black)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityIdentifier("deck-shortcut-strip")
    }
}

/// Settings > ショートカット, also reached from the session menu: the list,
/// in the order the bars show it.
struct ShortcutListEditor: View {
    @AppStorage(KeyShortcutList.storageKey) private var list = KeyShortcutList.standard
    @AppStorage(DeckShortcutStrip.storageKey) private var showsDeckStrip = true
    @State private var editing: KeyShortcut?

    var body: some View {
        Form {
            Section {
                ForEach(list.shortcuts) { shortcut in
                    Button {
                        editing = shortcut
                    } label: {
                        LabeledContent(shortcut.displayTitle) {
                            if shortcut.displayTitle != shortcut.keysDescription {
                                Text(shortcut.keysDescription)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("shortcut-row-\(shortcut.keysDescription)")
                }
                .onDelete { list.shortcuts.remove(atOffsets: $0) }
                .onMove { list.shortcuts.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    editing = KeyShortcut(modifiers: [.control], usage: ShortcutKey.letters[0].usage)
                } label: {
                    Label("ショートカットを追加", systemImage: "plus")
                }
                .accessibilityIdentifier("shortcut-add")
            } footer: {
                Text("iOS のキーボードの上のキーバーと、フル PC キーボードの上の列に、この順で並びます。1 回のタップで修飾キーごと送ります。")
            }

            let unused = KeyShortcut.suggestions.filter { suggestion in
                !list.shortcuts.contains { $0.modifiers == suggestion.modifiers && $0.usage == suggestion.usage }
            }
            if !unused.isEmpty {
                Section("よく使うもの") {
                    ForEach(unused) { suggestion in
                        Button {
                            list.shortcuts.append(KeyShortcut(modifiers: suggestion.modifiers, usage: suggestion.usage))
                        } label: {
                            Label(suggestion.keysDescription, systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("shortcut-suggestion-\(suggestion.keysDescription)")
                    }
                }
            }

            Section {
                Toggle("フル PC キーボードにも並べる", isOn: $showsDeckStrip)
                    .accessibilityIdentifier("shortcut-deck-strip-toggle")
                Button("最初の状態に戻す", role: .destructive) {
                    list = .standard
                }
            }
        }
        .navigationTitle("ショートカット")
        .keepsNavigationBarOnScroll()
        .toolbar { EditButton() }
        .sheet(item: $editing) { shortcut in
            NavigationStack {
                ShortcutEditor(shortcut: shortcut, isNew: !list.shortcuts.contains { $0.id == shortcut.id }) { saved in
                    if let index = list.shortcuts.firstIndex(where: { $0.id == saved.id }) {
                        list.shortcuts[index] = saved
                    } else {
                        list.shortcuts.append(saved)
                    }
                }
            }
        }
    }
}

/// One shortcut: an optional name, the modifiers and the key.
struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var shortcut: KeyShortcut
    let isNew: Bool
    let save: (KeyShortcut) -> Void

    var body: some View {
        Form {
            Section {
                TextField("名前（省略するとキーの組み合わせ）", text: $shortcut.title)
                    .accessibilityIdentifier("shortcut-title-field")
            }
            Section("修飾キー") {
                ForEach(VirtualModifier.allCases.sorted { $0.displayOrder < $1.displayOrder }, id: \.self) { modifier in
                    Toggle(modifier.displayName, isOn: Binding(
                        get: { shortcut.modifiers.contains(modifier) },
                        set: { isOn in
                            if isOn {
                                shortcut.modifiers.insert(modifier)
                            } else {
                                shortcut.modifiers.remove(modifier)
                            }
                        }
                    ))
                    .accessibilityIdentifier("shortcut-modifier-\(modifier.rawValue)")
                }
            }
            Section {
                Picker("キー", selection: $shortcut.usage) {
                    ForEach(ShortcutKey.all) { key in
                        Text(key.name).tag(key.usage)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("shortcut-key-picker")
            } footer: {
                Text("送るのはキーの位置です。記号キーは接続先のキーボード配列によって入る文字が変わります。")
            }
            Section {
                LabeledContent("送る内容", value: shortcut.keysDescription)
            }
        }
        .navigationTitle(isNew ? String(localized: "ショートカットを追加") : String(localized: "ショートカットを編集"))
        .keepsNavigationBarOnScroll()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save(shortcut)
                    dismiss()
                }
                .accessibilityIdentifier("shortcut-save")
            }
        }
    }
}
