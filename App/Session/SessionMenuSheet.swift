import SwiftUI
import UIKit
import InputCore
import SessionCore

/// The floating button's menu (docs/ui-flow.md section 6.1).
///
/// Opening it closes the input gate - `SessionWorkspaceModel.acceptsInput` -
/// so whatever was held is released before the sheet appears, and closing it
/// gives the keyboard back to the surface.
struct SessionMenuSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SessionWorkspaceModel
    @State private var confirmingDisconnect = false
    @AppStorage(LaptopDeckArrangement.storageKey)
    private var deckArrangement = LaptopDeckArrangement.keyboardAboveTrackpad
    @AppStorage(TouchPointerMode.storageKey) private var touchMode = TouchPointerMode.direct
    @AppStorage(LaptopDeckPreference.storageKey) private var deckPreference = LaptopDeckPreference.automatic

    private var touchModeHint: String {
        switch touchMode {
        case .direct:
            String(localized: "タッチに対応した接続先（Windows など）には、1 本指をタッチとして送ります（タップ、長押しで右クリック、なぞるとスクロールや選択）。それ以外ではタップでクリック、長押しで右クリック、なぞるとドラッグ。どの接続先でも、2 本指でスクロール、2 本指タップで右クリック、ピンチで拡大（拡大中はピンチしたまま動かすと表示が動きます）。")
        case .trackpad:
            String(localized: "なぞるとポインターが動きます。タップでクリック、2 本指タップで右クリック、2 本指でスクロール。タップしてすぐもう一度触れて動かすか、押さえてから動かすとドラッグ。")
        case .viewport:
            String(localized: "タッチは Windows へ送りません。1 本指で表示を動かし、ピンチで拡大、ダブルタップで全体表示と 100% を切り替えます。")
        }
    }
    @AppStorage(CapsLockRole.storageKey) private var capsLockRole = CapsLockRole.capsLock
    @AppStorage(LaptopKeyboardPlatform.storageKey) private var deckPlatform = LaptopKeyboardPlatform.windows
    @AppStorage(RemoteScalePreference.storageKey)
    private var scalePreference = RemoteScalePreference.automatic
    @AppStorage(FoldResolutionPolicy.storageKey)
    private var foldPolicy = FoldResolutionPolicy.resizeToFit
    @AppStorage(LaptopDeckArrangement.trackpadButtonsStorageKey) private var showsTrackpadButtons = true
    @AppStorage(LaptopDeckArrangement.macTrackpadButtonsStorageKey) private var showsMacTrackpadButtons = false
    @AppStorage(DesktopSafeAreaPolicy.storageKey)
    private var safeAreaPolicy = DesktopSafeAreaPolicy.avoid
    @AppStorage(LaptopDeckPlacement.storageKey) private var deckPlacement = LaptopDeckPlacement.docked
    @AppStorage(KeyboardPointerFollowing.storageKey) private var followsPointerAboveKeyboard = true
    @AppStorage(MacSwipeGestureMode.storageKey) private var swipeGestureMode = MacSwipeGestureMode.shortcuts
    @AppStorage(MacPinchGestures.storageKey) private var sendsPinchToMac = true
    @AppStorage(LaptopDeckArrangement.splitInLandscapeStorageKey) private var splitsDeckInLandscape = false
    @AppStorage(LaptopDeckPreference.foldedLandscapeStorageKey) private var showsDeckFoldedInLandscape = false
    @AppStorage(FloatingButtonsIdleStyle.storageKey) private var buttonsIdleStyle = FloatingButtonsIdleStyle.dim
    @AppStorage(KeyShortcutList.storageKey) private var shortcuts = KeyShortcutList.standard
    @AppStorage(ExternalDisplayMode.storageKey) private var externalMode = ExternalDisplayMode.desktop
    @AppStorage(PencilInput.storageKey) private var sendsPencilAsPen = true
    @State private var isPickingFilesToSend = false

    private var swipeGestureHint: String {
        switch swipeGestureMode {
        case .shortcuts:
            String(localized: "左右でデスクトップを切り替え（⌃← / ⌃→）、上で Mission Control（⌃↑）、下でアプリ Exposé（⌃↓）。Mac 側でこのショートカットが有効になっている必要があります")
        case .followFingers:
            String(localized: "Mac のトラックパッドと同じように、指に合わせて画面が動きます。macOS の非公開の仕組みを使うため、macOS のバージョンによっては動きません")
        case .off:
            String(localized: "3本指・4本指は2本指と同じくスクロールになります")
        }
    }

    private var canFloatDeck: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || model.deviceHasHinge
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(model.displayName).font(.headline)
                        Spacer()
                        SessionStateBadge(state: model.state, statusText: model.statusText)
                    }
                    if let security = model.transportSecurity {
                        LabeledContent("通信の保護", value: Formatting.transportLabel(security))
                            .accessibilityIdentifier("session-transport-security")
                    }
                    // docs/data-and-security.md section 4: the audit display.
                    // Strong when the server actually chose legacy security,
                    // a note when it was only allowed.
                    if model.isUsingLegacySecurity {
                        Label(
                            String(localized: "この接続は古い RDP セキュリティで通信しています。暗号は弱く、サーバーの確認もできません。"),
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("session-legacy-security")
                    } else if model.allowsLegacySecurity {
                        Label(
                            model.transportSecurity == nil
                                ? String(localized: "古い RDP セキュリティを許可した接続先です。")
                                : String(localized: "古い RDP セキュリティを許可した接続先ですが、この接続では使われていません。"),
                            systemImage: "shield.lefthalf.filled"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("session-legacy-security")
                    }
                }

                macExtensionsSection

                Section {
                    Button {
                        model.returnToList()
                    } label: {
                        Label("接続先一覧へ戻る（接続を維持）", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("session-return-to-list")

                    if model.canRetry || model.state == .disconnected {
                        Button {
                            dismiss()
                            Task { await model.reconnect() }
                        } label: {
                            Label("再接続", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("session-reconnect")
                    }

                    Button(role: .destructive) {
                        confirmingDisconnect = true
                    } label: {
                        Label("このセッションを切断", systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("session-disconnect")
                }
                if environment.runningSessions.count > 1 {
                    Section("セッションを切り替える") {
                        ForEach(environment.runningSessions) { session in
                            Button {
                                environment.switchTo(session)
                            } label: {
                                HStack {
                                    SessionThumbnailView(image: session.thumbnail)
                                    Image(systemName: session.id == model.id
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(session.id == model.id ? Color.accentColor : .secondary)
                                    Text(session.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    SessionStateBadge(state: session.state, statusText: session.statusText)
                                }
                            }
                            .disabled(session.id == model.id)
                            .accessibilityIdentifier("switch-to-\(session.displayName)")
                        }
                    }
                }

                if model.terminal != nil {
                    terminalSection
                } else {
                Section {
                    Button {
                        model.showSoftwareKeyboard()
                    } label: {
                        Label("キーボード / 拡張キー", systemImage: "keyboard")
                    }
                    .disabled(!model.state.acceptsInput)
                    .accessibilityIdentifier("session-show-keyboard")
                    // The deck is not only for a foldable: any device can put
                    // a PC keyboard and a trackpad on the lower half.
                    Button {
                        deckPreference = deckPreference == .always ? .never : .always
                        dismiss()
                    } label: {
                        if deckPreference == .always {
                            Label("フル PC キーボードを隠す", systemImage: "keyboard.chevron.compact.down")
                        } else {
                            Label("フル PC キーボードを表示", systemImage: "keyboard.chevron.compact.down")
                        }
                    }
                    .accessibilityIdentifier("session-toggle-laptop-deck")
                }

                Section("ショートカット") {
                    ForEach(shortcuts.shortcuts) { shortcut in
                        Button {
                            Task { await model.sendFromMenu(shortcut) }
                        } label: {
                            LabeledContent {
                                if shortcut.displayTitle != shortcut.keysDescription {
                                    Text(shortcut.keysDescription)
                                }
                            } label: {
                                Label(shortcut.displayTitle, systemImage: "command")
                            }
                        }
                        .disabled(!model.state.acceptsInput)
                        .accessibilityIdentifier("menu-shortcut-\(shortcut.keysDescription)")
                    }
                    NavigationLink {
                        ShortcutListEditor()
                    } label: {
                        Label("ショートカットを編集", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("session-edit-shortcuts")
                }

                Section("表示") {
                    Picker("表示倍率", selection: Binding(
                        get: { model.runtime.scale },
                        set: { model.setScaleMode($0) }
                    )) {
                        Text("画面に合わせる").tag(InitialScale.fit)
                        Text("100%").tag(InitialScale.oneToOne)
                    }
                    .accessibilityIdentifier("session-scale-picker")
                    // Windows' own Scale, sent with the display layout: what
                    // makes text on a phone-sized desktop readable.
                    Picker("Windows の拡大率", selection: $scalePreference) {
                        Text("自動（端末に合わせる）").tag(RemoteScalePreference.automatic)
                        ForEach(RemoteDisplayScale.choices, id: \.self) { percent in
                            Text("\(percent)%").tag(RemoteScalePreference.fixed(percent))
                        }
                    }
                    .accessibilityIdentifier("session-remote-scale-picker")
                    Picker("フル PC キーボード表示中の解像度", selection: $foldPolicy) {
                        Text("画面に合わせて変える").tag(FoldResolutionPolicy.resizeToFit)
                        Text("変えずに縮小表示").tag(FoldResolutionPolicy.keepAndScale)
                        Text("表示中の大きさで固定").tag(FoldResolutionPolicy.lockToDeck)
                    }
                    .accessibilityIdentifier("session-fold-resolution-picker")
                    if foldPolicy == .lockToDeck {
                        Text("フル PC キーボードを隠しても、表示中と同じ解像度のまま大きく表示します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // For this session; the connection's own setting is the
                    // one it starts from next time.
                    Picker("解像度", selection: Binding(
                        get: { model.runtime.resolution },
                        set: { model.setResolution($0) }
                    )) {
                        ForEach([ResolutionPolicy.adaptive] + ResolutionPolicy.presets, id: \.self) { policy in
                            Text(Formatting.resolutionLabel(policy)).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("session-resolution-picker")
                    if !model.supportsDynamicResolution, model.state == .connected {
                        Text("このサーバーは接続中の解像度変更に対応していません。接続先の設定で指定すると、次の接続から反映されます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("画面の端まで使う", isOn: Binding(
                        get: { safeAreaPolicy == .fullScreen },
                        set: { safeAreaPolicy = $0 ? .fullScreen : .avoid }
                    ))
                    .accessibilityIdentifier("session-full-screen-toggle")
                    Text(safeAreaPolicy == .fullScreen
                         ? String(localized: "Dynamic Island や画面の角の下にもデスクトップを表示します。")
                         : String(localized: "Dynamic Island、画面の角、ホームインジケータを避けて表示します。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("外部ディスプレイ", selection: $externalMode) {
                        Text("この画面と同じ（ミラーリング）").tag(ExternalDisplayMode.mirror)
                        Text("デスクトップを表示").tag(ExternalDisplayMode.desktop)
                        Text("デュアルモニター（この画面とつなげる）").tag(ExternalDisplayMode.extend)
                    }
                    .accessibilityIdentifier("session-external-display-mode")
                    Text(ExternalDisplayCoordinator.shared.screen == nil
                         ? String(localized: "モニターをつなぐと、そちらにデスクトップを表示し、この画面はキーボードとトラックパッドになります。")
                         : externalMode == .mirror
                            ? String(localized: "モニターにはこの画面がそのまま映ります。")
                            : externalMode == .extend
                                ? String(localized: "この画面を左、モニターを右にした 2 画面のデスクトップです。ポインターはトラックパッドやマウスで画面をまたいで動かせます。")
                                : String(localized: "モニターにデスクトップを表示しています。この画面はキーボードとトラックパッドです。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // The keyboard and menu buttons, after a few seconds alone.
                    Picker("操作しないときのボタン", selection: $buttonsIdleStyle) {
                        Text("薄くする").tag(FloatingButtonsIdleStyle.dim)
                        Text("ほとんど見えなくする").tag(FloatingButtonsIdleStyle.faint)
                        Text("画面の端に寄せる").tag(FloatingButtonsIdleStyle.tuck)
                    }
                    .accessibilityIdentifier("session-buttons-idle-style")
                    if buttonsIdleStyle == .tuck {
                        Text("端に少しだけ残ったボタンをタップすると元に戻ります。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let size = model.desktopSizeText {
                        LabeledContent(
                            String(localized: "リモート解像度"),
                            value: model.supportsDynamicResolution ? String(localized: "\(size)（可変）") : size
                        )
                    }
                }

                Section("入力") {
                    // Kept across sessions and launches, like the deck's
                    // arrangement: it is about the user's hands, not the host.
                    Picker("画面のタッチ", selection: $touchMode) {
                        Text("タッチした場所を操作").tag(TouchPointerMode.direct)
                        Text("トラックパッドとして使う").tag(TouchPointerMode.trackpad)
                        Text("表示の移動だけ").tag(TouchPointerMode.viewport)
                    }
                    .accessibilityIdentifier("session-touch-mode-picker")
                    Text(touchModeHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Toggle("Apple Pencil をペンとして送る", isOn: $sendsPencilAsPen)
                            .accessibilityIdentifier("session-pencil-toggle")
                    }
                    // Kept across sessions and launches, like the touch mode.
                    Toggle("キーボード表示中はポインターに合わせて画面を動かす", isOn: $followsPointerAboveKeyboard)
                        .accessibilityIdentifier("session-follow-pointer-toggle")
                    // Live rather than a profile edit: which way a trackpad
                    // should scroll a remote desktop is settled by trying it.
                    Picker("スクロール方向", selection: Binding(
                        get: { model.runtime.scrollDirection },
                        set: { model.setScrollDirection($0) }
                    )) {
                        Text("標準").tag(ScrollDirection.normal)
                        Text("反転").tag(ScrollDirection.reversed)
                    }
                    .accessibilityIdentifier("session-scroll-picker")
                    // On the iPhone and iPad only: the Mac app has the Mac's
                    // own trackpad.
                    if model.isMacHost, !Platform.isMac {
                        Picker("3・4本指のスワイプ", selection: $swipeGestureMode) {
                            Text("ショートカットを送る").tag(MacSwipeGestureMode.shortcuts)
                            Text("指に合わせて動かす（実験的）").tag(MacSwipeGestureMode.followFingers)
                            Text("使わない").tag(MacSwipeGestureMode.off)
                        }
                        .accessibilityIdentifier("session-swipe-gesture-picker")
                        Text(swipeGestureHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle("ピンチ・回転・2本指ダブルタップを Mac に送る", isOn: $sendsPinchToMac)
                            .accessibilityIdentifier("session-pinch-to-mac-toggle")
                    }
                    // 自動 is the foldable's laptop posture; the other two
                    // let any device use the deck, or a folded one do without.
                    Picker("フル PC キーボード", selection: $deckPreference) {
                        Text("折りたたみ端末を折り曲げたとき").tag(LaptopDeckPreference.automatic)
                        Text("常に表示").tag(LaptopDeckPreference.always)
                        Text("表示しない").tag(LaptopDeckPreference.never)
                    }
                    .accessibilityIdentifier("session-laptop-deck-picker")
                    if canFloatDeck {
                        Picker("フル PC キーボードの位置", selection: $deckPlacement) {
                            Text("画面の下").tag(LaptopDeckPlacement.docked)
                            Text("フローティング").tag(LaptopDeckPlacement.floating)
                        }
                        .disabled(deckPreference == .never)
                        .accessibilityIdentifier("session-laptop-deck-placement")
                    }
                    Text(canFloatDeck && deckPlacement == .floating
                         ? String(localized: "上のバーで移動、バー右端のつまみで大きさを変えられます。折りたたみ端末を折り曲げているときはヒンジの下に固定します。")
                         : String(localized: "上端のつまみを上下にドラッグすると高さを変えられます。ダブルタップで元の高さに戻ります。折りたたみ端末を折り曲げているときはヒンジの位置に固定します。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("フル PC キーボードの大きさを元に戻す") {
                        DeckLayout.resetSizes()
                    }
                    .accessibilityIdentifier("session-laptop-deck-reset")
                    if canFloatDeck {
                        // Thumbs on a wide screen: the halves at the sides,
                        // the trackpad between them.
                        Toggle("横向きでは左右に分ける", isOn: $splitsDeckInLandscape)
                            .disabled(deckPreference == .never)
                            .accessibilityIdentifier("session-laptop-split-toggle")
                    }
                    if model.deviceHasHinge {
                        // The system decides which way the screen turns; this
                        // only decides whether folding sideways means a deck.
                        Toggle("横向きで折り曲げたときもフル PC キーボードを出す", isOn: $showsDeckFoldedInLandscape)
                            .disabled(deckPreference != .automatic)
                            .accessibilityIdentifier("session-folded-landscape-toggle")
                        Text(showsDeckFoldedInLandscape
                             ? String(localized: "本のように横向きで少し折ったときも、フル PC キーボードを画面の下に出します（左右分割の設定に従います）。")
                             : String(localized: "フル PC キーボードが出るのは、縦向き（ラップトップの形）で折り曲げたときだけです。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Kept across sessions and launches: how the deck is laid
                    // out is a matter of the user's hands, not of the host.
                    Picker("手元側の配置", selection: $deckArrangement) {
                        Text("キーボード / トラックパッド").tag(LaptopDeckArrangement.keyboardAboveTrackpad)
                        Text("トラックパッド / キーボード").tag(LaptopDeckArrangement.trackpadAboveKeyboard)
                        Text("キーボードのみ（画面を触って操作）").tag(LaptopDeckArrangement.keyboardOnly)
                    }
                    .disabled(deckPreference == .never)
                    .accessibilityIdentifier("session-laptop-deck-arrangement")
                    // Only the picture and a few keys change: Command is sent
                    // as Win and Option as Alt either way.
                    Picker("キーボードの見た目", selection: $deckPlatform) {
                        ForEach(LaptopKeyboardPlatform.allCases, id: \.self) { platform in
                            Text(platform.title).tag(platform)
                        }
                    }
                    .disabled(deckPreference == .never)
                    .accessibilityIdentifier("session-laptop-platform")
                    .onChange(of: deckPlatform) { _, platform in
                        // A Mac-only role does not carry over to a PC's keys.
                        if !CapsLockRole.roles(on: platform).contains(capsLockRole) {
                            capsLockRole = .capsLock
                        }
                    }
                    Picker("Caps キー", selection: $capsLockRole) {
                        ForEach(CapsLockRole.roles(on: deckPlatform), id: \.self) { role in
                            Text(role.title(on: deckPlatform)).tag(role)
                        }
                    }
                    .disabled(deckPreference == .never)
                    .accessibilityIdentifier("session-laptop-caps-role")
                    // Without buttons: tap to click, two-finger tap for the
                    // right button, tap then touch and move to drag. The
                    // Mac's keyboard keeps its own setting, off at first.
                    Toggle(
                        "トラックパッドのクリックボタン",
                        isOn: model.isMacHost || deckPlatform == .mac ? $showsMacTrackpadButtons : $showsTrackpadButtons
                    )
                        .disabled(deckPreference == .never || !deckArrangement.hasTrackpad)
                        .accessibilityIdentifier("session-laptop-trackpad-buttons")
                }

                if model.clipboardPolicy != .disabled {
                    clipboardSection
                        .fileImporter(isPresented: $isPickingFilesToSend, allowedContentTypes: [.item],
                                      allowsMultipleSelection: true) { result in
                            guard case .success(let urls) = result else { return }
                            Task { await model.sendFilesToRemote(urls) }
                        }
                }

                Section("音声") {
                    Toggle("この端末で再生", isOn: Binding(
                        get: { !model.isAudioMuted },
                        set: { model.setLocallyMuted(!$0) }
                    ))
                    .disabled(!model.configuration.audioPlayback)
                    .accessibilityIdentifier("session-audio-toggle")
                    if !model.configuration.audioPlayback {
                        Text("この接続では音声が無効です（接続設定で変更できます）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                }
            }
            .navigationTitle("セッション")
            .keepsNavigationBarOnScroll()
            // The display channel opens after the session is connected, so
            // what the server supports is read again when there is a menu to
            // show it in.
            .task { await model.refresh() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("session-menu-close")
                }
            }
            .confirmationDialog(
                String(localized: "\(model.displayName) を切断しますか？"),
                isPresented: $confirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button("切断", role: .destructive) {
                    Task { await model.disconnect() }
                }
                .accessibilityIdentifier("session-disconnect-confirm")
            }
        }
        .accessibilityIdentifier("session-menu")
    }
}

extension SessionMenuSheet {
    /// An SSH session's own commands (docs/ssh-design.md 8.2): the desktop's
    /// keyboard, display and audio settings mean nothing to a terminal.
    var terminalSection: some View {
        Group {
            Section {
                Button {
                    dismiss()
                    model.toggleTerminalKeyboard()
                } label: {
                    Label("キーボード", systemImage: "keyboard")
                }
                .disabled(!model.state.acceptsInput)
                Button {
                    dismiss()
                    model.pasteIntoTerminal()
                } label: {
                    Label("貼り付け", systemImage: "doc.on.clipboard")
                }
                .disabled(!model.state.acceptsInput || !model.clipboardPolicy.allowsSend)
                .accessibilityIdentifier("session-terminal-paste")
            }
            Section("表示") {
                HStack {
                    Text("文字の大きさ")
                    Spacer()
                    Button { model.terminalView?.adjustFontSize(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("小さく")
                    Button("標準") { model.terminalView?.resetFontSize() }
                        .buttonStyle(.bordered)
                    Button { model.terminalView?.adjustFontSize(by: 1) } label: { Image(systemName: "textformat.size.larger") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("大きく")
                }
                Button {
                    model.terminalView?.clearLocalScrollback()
                } label: {
                    Label("スクロールバックを消去", systemImage: "eraser")
                }
            }
        }
    }

    /// A Mac server's extensions: what is in use, and the stream quality,
    /// which can change mid-session (say, moving from Wi-Fi to cellular).
    @ViewBuilder
    var macExtensionsSection: some View {
        if let mac = model.macExtensions {
            Section {
                LabeledContent("サーバー", value: mac.serverName)
                if let fps = mac.framesPerSecond, let kbps = mac.bitrateKbps {
                    LabeledContent("映像", value: "\(fps) fps・\(Formatting.bitrate(kbps))"
                        + ((mac.scalePercent ?? 100) >= 200 ? "・Retina" : ""))
                        .accessibilityIdentifier("session-mac-stream")
                }
                if let ascii = mac.isASCIICapable {
                    LabeledContent("入力ソース", value: ascii
                        ? String(localized: "英字")
                        : String(localized: "日本語などの入力モード"))
                }
                if mac.features.contains(.streamConfig) {
                    Picker("画質", selection: Binding(
                        get: { mac.quality },
                        set: { quality in Task { await model.setStreamQuality(quality) } }
                    )) {
                        ForEach(StreamQuality.allCases, id: \.self) { quality in
                            Text(StreamQualityLabel.text(quality)).tag(quality)
                        }
                    }
                    .accessibilityIdentifier("session-stream-quality")
                }
            } header: {
                Text("Mac 拡張")
            } footer: {
                Text("キー（⌘・Fn・左右の修飾キー）、ポインタ、スクロールを Mac のまま送っています。")
            }
        }
    }

    /// docs/ui-flow.md section 6.2. Both directions start from a tap here;
    /// nothing reads or writes the pasteboard on its own.
    @ViewBuilder
    var clipboardSection: some View {
        Section {
            if let format = model.microphoneFormat {
                Label(String(localized: "マイクを使用中（\(format.sampleRate / 1000) kHz）"), systemImage: "mic.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("session-microphone-in-use")
            }
            if model.clipboardPolicy.allowsSend {
                // PasteButton hands over the pasteboard without the system
                // "allow paste" prompt, because the tap itself is the consent.
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    Task { @MainActor in await model.pasteToRemote(text) }
                }
                .disabled(!model.canSendClipboard)
                .accessibilityIdentifier("clipboard-paste-to-remote")
                // An image from this device's clipboard, pasted as an image.
                PasteButton(supportedContentTypes: [.image]) { providers in
                    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else { return }
                    _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                        guard let image = object as? UIImage else { return }
                        Task { @MainActor in await model.pasteImageToRemote(image) }
                    }
                }
                .disabled(!model.canSendClipboard)
                .accessibilityIdentifier("clipboard-paste-image-to-remote")
                Button {
                    isPickingFilesToSend = true
                } label: {
                    Label("ファイルを貼り付けで送る…", systemImage: "doc.badge.arrow.up")
                }
                .disabled(!model.canSendClipboard)
                .accessibilityIdentifier("clipboard-send-files")
            }
            if model.clipboardPolicy.allowsReceive {
                Button {
                    Task {
                        if let text = await model.copyRemoteToDevice() {
                            UIPasteboard.general.string = text
                        }
                    }
                } label: {
                    Label("リモートのテキストを端末へコピー", systemImage: "doc.on.clipboard")
                }
                .disabled(!model.canReceiveClipboard)
                .accessibilityIdentifier("clipboard-copy-to-device")
                Button {
                    Task {
                        if let image = await model.copyRemoteImageToDevice() {
                            UIPasteboard.general.image = image
                        }
                    }
                } label: {
                    Label("リモートの画像を端末へコピー", systemImage: "photo.on.rectangle")
                }
                .disabled(!model.canReceiveClipboardMedia || !model.remoteHasImage)
                .accessibilityIdentifier("clipboard-copy-image-to-device")
                Button {
                    Task { await model.saveRemoteFilesToDevice() }
                } label: {
                    Label("リモートでコピーしたファイルを保存", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!model.canReceiveClipboardMedia || !model.remoteHasFiles)
                .accessibilityIdentifier("clipboard-save-files")
            }
        } header: {
            Text("クリップボード")
        } footer: {
            if Platform.isMac {
                // The Mac mirrors text and images by itself; the buttons
                // above remain for files and for pasting by hand.
                Text("Mac とリモートのクリップボードは自動で同期します（テキストと画像）。ファイルはここから送受信します")
            } else if model.remoteHasText || model.remoteHasImage || model.remoteHasFiles {
                Text(model.remoteHasFiles ? String(localized: "リモートにファイルがあります")
                     : model.remoteHasImage ? String(localized: "リモートに画像があります")
                     : String(localized: "リモートにテキストがあります"))
            } else if model.clipboardPolicy.allowsReceive {
                Text("リモートでテキストをコピーすると、ここから端末へコピーできます")
            }
        }
    }
}

/// State with an icon as well as a colour, so it is not carried by colour
/// alone (docs/ui-flow.md section 10).
struct SessionStateBadge: View {
    let state: SessionState
    let statusText: String

    var body: some View {
        Label(statusText, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch state {
        case .connected: return "checkmark.circle"
        case .connecting, .reconnecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .awaitingUser: return "person.crop.circle.badge.questionmark"
        case .failed: return "exclamationmark.triangle"
        case .idle, .disconnected: return "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .awaitingUser: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
