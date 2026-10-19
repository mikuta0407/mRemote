import SwiftUI

/// What the app cannot do on iPadOS/iOS and what to do instead. The source
/// text is docs/help-limitations.md; change both together.
struct HelpView: View {
    var body: some View {
        List {
            Section {
                Text("iPad の Command キーは Windows キーとして送るため、Windows キーを含むショートカットの一部が届きません。キーバーの修飾キーは 1 回押すと次の 1 キーだけ、2 回押すと固定、3 回目で解除です。")
                row("Command+Tab", String(localized: "App 切り替えに使われます。Win+Tab はキーバーの Win を押してから Tab。"))
                row("Command+Space", String(localized: "Spotlight に使われます。Win+Space はキーバーの Win を押してから Space。"))
                row("Command+H", String(localized: "ホーム画面に使われます。Win+H はキーバーの Win を押してから H。"))
                row(String(localized: "Globe（地球儀）キー"), String(localized: "iPadOS のショートカットに使われ、Windows へは送りません。"))
                row("Control+Space", String(localized: "iPadOS の入力切替に設定されていると届きません。キーバーの Ctrl を押してから Space。"))
                row("Caps Lock", String(localized: "iPadOS の「ハードウェアキーボード」設定で Caps Lock による入力切替がオンだと、英字入力の切替に使われます。"))
                row("Ctrl+Alt+Del", String(localized: "キーバーで Ctrl と Alt を押してから Del を押すと、Windows のセキュリティ画面（ロック、サインアウト、タスク マネージャーなど）が出ます。"))
            } header: {
                Text("iPadOS が先に使うキー")
            }

            Section {
                Text("別のアプリに切り替える、ホーム画面に戻る、画面をロックすると、押していたキーとボタンは離され、音声は止まります。")
                Text("しばらくすると OS が接続を閉じることがあります。戻ったときに切断されていたら「再接続」を押してください。RDP の切断はサインアウトではないので、同じデスクトップに戻ります。")
                Text("入力と音声は、表に出ているセッションだけに届きます。")
            } header: {
                Text("バックグラウンドに移ったとき")
            }

            Section {
                Text("英数は無変換、かなは変換として送ります。")
                Text("Windows の「設定 > 時刻と言語 > 言語と地域」で日本語の「言語のオプション」を開き、Microsoft IME の「キーボード オプション > キーとタッチのカスタマイズ」で「キーの割り当て」をオンにし、無変換キーを「IME-オフ」、変換キーを「IME-オン」にします。サインインし直すと効きます。")
            } header: {
                Text("英数/かなで Windows の IME を切り替える")
            }
        }
        .navigationTitle("ヘルプ")
        .keepsNavigationBarOnScroll()
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("help-screen")
    }

    private func row(_ key: String, _ text: String) -> some View {
        // One Text, so it wraps and grows as one piece and is read as one.
        Text("\(Text(key).bold())\n\(Text(text).foregroundStyle(.secondary))")
            .accessibilityIdentifier("help-row")
    }
}
