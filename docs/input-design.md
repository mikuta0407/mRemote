# 入力設計

## 1. 目的

入力層は、Apple platform のイベントを「どのセッションへ送るか」「RDP では何を意味するか」から分離する。特に次を保証する。

- 物理キーボードは iPadOS IME を通さず、キーの down/up として送る。
- 英数/かなを Windows の無変換/変換として送る。
- UIKit と GameController の重複を 1 回の物理操作へ正規化する。
- フォーカスが外れたとき、リモートにキーやボタンを押下状態で残さない。
- マウス座標とスクロール方向を、拡大/回転を含め一貫して変換する。
- 終盤に追加するソフトウェアキーボードを別経路として収容する。

## 2. KeyProbe の実証結果

### 2.1 確認済み

検証資産:

- `work/getiPadKey/KeyProbe/KeyProbeViewController.swift`
- `work/getiPadKey/KeyProbe/GCKeyboardMonitor.swift`
- `work/getiPadKey/KeyProbe/ProbeTargets.swift`
- `work/getiPadKey/README.md`
- 実機結果 `work/KeyProbe_ScrShot.jpeg`

実機画像から確認できる事実は次のとおり。

| 物理キー | HID usage | UIKit | GCKeyboard | key-up の画像上の証拠 |
|---|---:|---|---|---|
| 英数 | LANG2 `0x91` | 検出 | 検出 | 未確定（verdict は検出を示すが最終イベント表示はかな） |
| かな | LANG1 `0x90` | 検出 | 検出 | `pressesEnded` と `pressed=false` を確認 |

かなの実測では `characters` に物理キーの意味として利用できない値も表示されている。したがって `characters`/`charactersIgnoringModifiers` から英数/かなを判定せず、raw HID usage を物理キーの識別子とする。Windows 側の意味は effective keyboard layout と組み合わせて決める。

### 2.2 未検証で残る事項

- 英数の key-down/key-up 対称性
- `call super = OFF` 時の iPadOS 入力ソース UI の挙動
- 長押し、サーバー側キーリピート、N キーロールオーバー
- Apple JIS、iPad 用 Magic Keyboard、市販 USB/Bluetooth 109 キーボード間の差
- Full Keyboard Access、修飾キー入れ替え、Stage Manager の影響
- キーボード切断/再接続、スリープ復帰時の event ordering

これらは実装を止めず、入力スパイクと正式な実機マトリクスで確定する。

## 3. 正規化イベント

Apple API の型を RDP adapter へ渡さず、まずプラットフォーム非依存イベントへ変換する。

```swift
struct HardwareKeyEvent: Sendable {
    enum Action: Sendable { case down, up, cancel }
    enum Source: Sendable { case uiKit, gameController, virtualKey }

    let usage: UInt16
    let action: Action
    let source: Source
    let monotonicTime: ContinuousClock.Instant
}

enum NormalizedInputEvent: Sendable {
    case hardwareKey(HardwareKeyEvent)
    case pointer(PointerEvent)
    case committedText(String)
    case releaseAll
}

// RDPProtocol 内だけで生成する
enum RDPInputEvent: Sendable {
    case scanCode(RemoteScanCode, action: KeyAction)
    case pointer(RDPPointerEvent)
    case unicode(UInt16, action: KeyAction)
}
```

文字 (`committedText`) と物理キー (`hardwareKey`) を同じ経路に混ぜない。英数/かな、修飾キー、ショートカットは必ず hardware key 経路を使い、`RDPProtocol` の mapper が scan code 化する。

## 4. 物理キーボードの取得

### 4.1 UIKit 主経路

`RemoteInputViewController` または描画用 `UIView` を first responder にし、次を override する。

- `pressesBegan(_:with:)` → down
- `pressesChanged(_:with:)` → digital key の remote transition には使わず、repeat と誤認しない。診断/将来の analog press だけに保持
- `pressesEnded(_:with:)` → up
- `pressesCancelled(_:with:)` → cancel/up

KeyProbe は未知の Objective-C enum 値を Swift enum として load する trap を避けるため KVC で raw 値を読んでおり、`UIKey.keyCode.rawValue` の直接利用はまだ実証されていない。製品では公開 `UIKey.keyCode` を Objective-C 上で `NSInteger` へ変換する小さな adapter を初期採用し、文字列 KVC を常用しない。Phase 0 で Swift 直接読出しも比較し、安全性を確認できた場合だけ単純化する。

物理入力用 responder は `UIKeyInput`/`UITextInput` に適合させない。これによりソフトウェアキーボードと marked text を出さず、iPadOS IME を文字入力経路として利用しない。

RDP へ転送すると判定した press はアプリが消費し、その `pressesBegan/Changed/Ended/Cancelled` から `super` を呼ばない。未対応キーまたはローカル UI 用の操作だけを responder chain へ渡す。KeyProbe の実機画像は `call super = ON` であり、この規則によって iPadOS の入力ソース切替 UI まで抑止できることはまだ実証されていないため、`call super = OFF` 相当の製品 harness で必須確認する。GCKeyboard は観測経路であり、それ単体で OS の既定動作を抑止しない。

### 4.2 GameController フォールバック

`GCKeyboard.coalesced.keyboardInput.keyChangedHandler` から `GCKeyCode.rawValue` と `pressed` を受ける。接続/切断通知を監視し、アプリが active の間は focus にかかわらず `PhysicalKeyboardState` の押下 boolean だけを更新する。remote 送信用の調停器へ渡すのは RDP surface が focused かつ input gate が開いている場合だけとする。

GCKeyboard は UIKit に届かないキーの補完と互換性診断に使う。画面上のメニューや別セッションへ入力が漏れないよう、グローバル handler から RemoteSession を直接呼ばない。

### 4.3 システム予約キー

`UIKeyCommand.wantsPriorityOverSystemBehavior` は利用可能なコマンドに使えるが key-up を取得できず、raw keyboard 転送の代替にはしない。Home、App 切替、Spotlight 等、iPadOS が予約する全操作を横取りできるとは仮定しない。取れない組み合わせは画面内の Ctrl/Alt/Win、Alt+Tab、リモートのセキュリティ画面操作等で代替する。secure attention は raw Ctrl+Alt+Delete の scan code 送信で足りる（2026-10-07、Windows 11 でキーバーの Ctrl → Alt → Del からセキュリティ画面が出ることを確認）。Ctrl+Alt+End は mstsc が手元で Ctrl+Alt+Delete に置き換えるショートカットで、サーバーへ送っても効かない。

## 5. 二経路の調停と押下状態

UIKit と GCKeyboard には共通 event ID がなく、GC event には UIKit と比較可能な発生 timestamp もない。したがって press ごとの動的 merge、時間窓による重複除去、遅延フォールバックは行わない。

`KeyboardSourcePolicy` は usage ごとに送信元を一つだけ固定する。

| Policy | 用途 |
|---|---|
| `uiKit` | 標準の既定。UIKit の down/up だけを remote へ送る |
| `gameController` | UIKit 不達、GC の down/up が安定すると実機 matrix で確認した静的 allow-list のみ |
| `unsupported` | どちらにも安定した down/up がなく送信しない。UI 代替を使う |

英数/かなは UIKit down の到達が確認済みなので暫定 `uiKit` 候補とするが、英数を含む各キーの down/up 対称性の反復試験（既定 10 回）に合格した後だけ policy を固定する。英数の UIKit up が欠落し GC が安定していれば、その usage 全体を `gameController` に切り替える。二経路を一つの press cycle 内で混ぜない。

source policy は対応 OS と検証済みキーボード種別/接続方式を含む compatibility table に束縛する。機器を識別できない場合は対応 matrix 全体で安全な共通 policy を使い、動的推測しない。変更は全物理キーが neutral の focus epoch 境界でだけ行う。選択外 source は物理状態と診断集計にだけ使う。遅延した GC down、source 切替中の保持キー、旧 focus で始まった orphan up/repeat は remote へ送らない。

選択 source 内では `usage -> remotePressed` を保持し、最初の down と対応する up/cancel を各一回送る。観測された重複 down は送らない。

長押しの repeat は client 側で生成する。当初は Windows 側 repeat を第一候補としたが、Phase 0 の実機確認で成立しないことが判明した。RDP に server 側 auto-repeat は存在せず、Windows の typematic は物理キーボードの driver 層が作るもので terminal server 経由で注入された scan code には適用されない。iPadOS からも repeat は届かない（`pressesBegan`/`pressesEnded` は物理遷移のみ、`pressesChanged` は analog force、`GCKeyboard.keyChangedHandler` は状態変化のみ）。したがって `KeyRepeatScheduler` が initial delay の後 interval ごとに **down だけ** を再送し、up は物理解放に束縛したまま各 press 一回に保つ。bridge 側の `mr_input_command_queue` は repeat された down に release reservation を追加しないため、teardown が解放すべき状態は増えない。

repeat 対象は最後に down した repeat 適格 usage 一つとし、その解放時にまだ保持されている usage があれば typematic と同様に再開する。modifier、lock key、および LANG1/LANG2 を含む日本語入力モードキーは対象外とする（変換/無変換の repeat は文字入力ではなく host IME の候補操作になり、英数/かなの「1 press = 1 組」契約とも矛盾するため）。initial delay と interval は client 設定とする。iPadOS は system のキーリピート設定をアプリへ公開しないため、端末設定の反映はできない。repeat の停止条件は gate 閉、`releaseAll`、quarantine、source policy 適用、generation 不一致、remote 未押下のいずれかで、pending fire は発火時に毎回再検証する。

同じ usage を持つ二つのキーボードを同時に押すケースは `GCKeyboard.coalesced` では個体識別できないため対象外とする。

`releaseAll` の発火条件:

- `pressesCancelled`
- RDP surface の resign first responder
- フローティングメニュー表示
- セッション切替
- scene inactive/background
- 物理キーボード切断
- network disconnect/セッション終了

マウスボタンと仮想修飾キーにも同じ原則を適用する。

`PhysicalKeyboardState`（端末で観測中）と session ごとの `RemotePressedState`（remote へ down 済み）を分ける。`releaseAll` は remote state と input generation を即時 clear し、その時点で物理的に押されていた usage を `quarantine` に移す。session が writable なら up events を lossless queue へ best effort で投入するが、network ACK は待たない。

メニュー/別 focus 中も GC の up または keyboard disconnect で quarantine を解除し、focus 復帰後も quarantined usage の orphan repeat/up は送らない。GC が利用できず非 focused 中の up を観測できない場合は、その usage の次の完全な down/up cycle を送らずに neutral を再確立する安全側の挙動とし、必要なら「すべてのキーを離してください」を表示する。セッション切替は旧 queue への順序付き barrier または短い timeout までで進める。切断済みの場合は remote up を送れないため、remote state の破棄と新 generation への隔離を成功条件とする。

## 6. HID usage から RDP scan code への変換

RDP の keyboard PDU は USB HID usage をそのまま受け取らない。`KeyboardLayoutMapper` で PC/AT Set 1 scan code と extended/release flag に変換する。

日本語キーの mapping 候補:

| iPad/キーボード側 | HID usage | Windows の意味 | Set 1 scan code |
|---|---:|---|---:|
| 英数 | LANG2 `0x91` | 無変換 / `VK_NONCONVERT` | `0x7B` |
| かな | LANG1 `0x90` | 変換 / `VK_CONVERT` | `0x79` |
| 変換（PC JIS） | Intl4 `0x8A` | 変換 / `VK_CONVERT` | `0x79` |
| 無変換（PC JIS） | Intl5 `0x8B` | 無変換 / `VK_NONCONVERT` | `0x7B` |
| かな/カナ（PC JIS） | Intl2 `0x88` | かな / `VK_KANA` | `0x70` |
| 半角/全角 | LANG5 `0x94` | 漢字/半角全角 | `0x29` |
| ろ/_ | Intl1 `0x87` | JIS ろ | `0x73` |
| ¥/\ | Intl3 `0x89` | JIS ¥ | `0x7D` |

先頭 2 行の英数/かなは本アプリの必須意味変換である。スクリーンショットでは Intl1（ろ）と Intl3（¥）のアプリ到達も確認済みだが、Intl2/4/5 と LANG3/4/5 は未検出である。また、いずれも remote scan code/IME 動作までは未検証である。PC JIS 実機と Windows 側 `KeyEcho` で候補 mapping を確定してから対応表を固定する。

Phase 0 harness の `RDPScanCodeMapper` は、上表の日本語キーに加えて HID usage page 0x07 の標準キー（英字/数字/記号、F1–F24、編集・矢印キー、テンキー、左右修飾キー）を PC/AT Set 1 へ変換する。Pause だけは EXTENDED1 の 2 code 連続であり単一 code の `mr_rdp_key_event` で表現できないため、意図的に未対応（送信前に drop）とする。

scan code/flag は magic number を送信箇所へ散らさず、FreeRDP の定数または型付きの生成テーブルに集約する。通常キー、右 Ctrl/Alt、Insert/Delete、矢印等の extended/extended1/release flag も unit test の対象にする。

接続時の既定は Windows Japanese layout `0x00000411`、Japanese keyboard type `7` とする。接続 profile で「日本語 106/109」「US」「自動」を選べる余地を残すが、英数/かな→無変換/変換の保証対象は日本語 profile とする。US/自動を選んだ場合はこの保証外であることを接続設定に表示し、誤った意味変換を自動適用しない。

`0x7B`/`0x79` が Windows で `VK_NONCONVERT`/`VK_CONVERT` として届くことと、Microsoft IME がそれらを IME OFF/ON に割り当てていることは別条件である。前者をクライアントの必須受入条件、後者を host 側 IME 設定を含む end-to-end 確認とし、必要な Windows 設定をヘルプに記載する。

既定の修飾キー mapping:

| iPad キー | Windows へ送るキー |
|---|---|
| Control | Control |
| Option | Alt |
| Command | Windows |
| Shift | Shift |

iPadOS 側の修飾キー入れ替え設定が raw usage に与える影響を実測し、必要なら「物理キー優先」「iPadOS の割当優先」を後続設定にする。

## 7. first responder と UI 操作

- セッション表示完了時とフローティングメニューを閉じた時に RDP surface が `becomeFirstResponder()` する。
- メニューを開く直前に `releaseAll` し、メニュー操作中は hardware event の送信 gate を閉じる。
- 接続先一覧へ戻ると接続は維持しても入力 focus は解除する。
- セッション切替では、旧 session の local state clear と queue barrier（または timeout）後に `focusedSessionID` を更新する。
- ソフトキーボード表示中は専用 input proxy だけが first responder になり、物理用 responder と同時に文字を生成しない。

## 8. マウス/トラックパッド

### 8.1 取得経路

iPadOS の indirect pointer event を主経路とする。実装時に `UIApplicationSupportsIndirectInputEvents` を有効化して実機検証する。

Apple API は OS/version と device により hover、button、scroll の配送先が異なるため、下表は確定 API 契約ではなく候補である。Phase 0 で `UIEvent.buttonMask`、`UIPress`/touch、scroll event の down/up/drag/cancel 順序を実機記録し、左右ボタンを lossless に取得できる一経路を ADR で固定する。成立しない端末では `GCMouse` を含む単一フォールバック経路を選び、複数 API のイベントを時刻だけで merge しない。

| 操作 | Apple 側候補 | 正規化結果 |
|---|---|---|
| hover/move | `UIHoverGestureRecognizer` | absolute pointer move |
| 左/右押下と drag | button mask を扱う custom gesture/touch handling | button down/move/up |
| scroll | continuous/discrete scroll gesture | vertical/horizontal wheel delta |
| 接続状態補助 | 必要に応じて `GCMouse` | device status/relative delta |

UIKit と GCMouse の move/button を同時に送らない。GCMouse は UIKit で取得できないハードウェアのフォールバックとして PoC 後に限定する。

### 8.2 座標

描画と同じ `ViewportTransform` の逆変換を使う。

```text
view point (pt)
  → content inset / safe area を除去
  → pan/zoom/letterbox transform の逆変換
  → remote framebuffer pixel
  → [0 ... width-1], [0 ... height-1] へ clamp
```

RDP へは remote desktop の absolute pixel 座標を送る。描画側と別々の式を実装しない。

content は常に中央に置いてから pan する。pan はどの軸もはみ出し分の範囲内で、拡大しても desktop の外（地の黒）は出ない。下端が覆われている間（`occludedBottom`、ソフトウェアキーボード）は、desktop の下端がその上に来るまで上へ動かせる。

### 8.3 ボタン

- 左、右の down/up を個別に保持し、drag 中も state を維持する。
- focus 喪失時は押下中の全ボタンへ up を送る。
- primary/secondary の入れ替えは初期要件外だが、mapping table で後から追加可能にする。
- Ctrl+click を右クリックへ変える補助は、物理右クリックと競合しないオプションとして後続検討する。

### 8.4 スクロール

continuous delta は accumulator に足し、FreeRDP/RDP の wheel 表現可能単位へ量子化する。閾値未満の端数は次回へ持ち越し、速いスクロールは 1 event の上限に収めて複数送信する。縦と横は別 accumulator を使う。

```text
effectiveDelta = deviceDelta × sensitivity × (isReversed ? -1 : 1)
```

反転は正規化の最後に一度だけ適用する。「ナチュラルスクロール」を OS が既に変換した可能性を推測して二重反転しない。接続別上書きがなければグローバル設定を用いる。

## 9. タッチ操作

要件の中心はマウスだが、iPhone やポインターのない iPad でも操作できるよう、画面へのタッチの扱いを三方式から選べる（セッションメニュー「画面のタッチ」、全セッション共通、既定は直接タッチ）。いずれもマウスと同じ `PointerInputRouter` を通る。マウス・トラックパッドの入力は方式に関係なくリモートポインターを動かす。

| 方式 | 1 本指 | 2 本指 | ローカル表示 |
|---|---|---|---|
| 直接タッチ（`DirectTouchGestureTracker`）。RDPEI が開いている接続先（Windows、GNOME）では 1 本指をタッチとして送る（下記） | tap: その位置で左 click。0.5 秒以内・24pt 以内の 2 回目の tap は 1 回目と同じ位置を押し、double click として届く。長押し 0.5 秒: 右 click。なぞる: 押した位置から左ドラッグ | 移動: スクロール。tap: 右 click | pinch で zoom。zoom 中は pinch したまま動かすと viewport 移動 |
| トラックパッド（`TrackpadGestureTracker`） | なぞる: 相対移動。tap: 左 click（2 回目のタッチを 0.35 秒待ってから送る）。tap の直後にもう一度触れて動かす、または押さえてから動かす: ドラッグ。2 回 tap: double click | 移動: スクロール。tap: 右 click | 同上。ポインターが端に寄ると表示が追従 |
| 表示の移動だけ | viewport 移動。double tap: Fit/100% 切替 | — | pinch で zoom |

以前あった 4 番目の方式「Windows のタッチとして送る」（すべての指を contact として送り、pinch も Windows に渡す）は、直接タッチがタッチ対応の接続先へ 1 本指をタッチとして送るようになって違いが 2 本指だけになったため、2026-10-09 に廃止した。保存済みの設定は直接タッチとして読む。

直接タッチで接続先が RDPEI を開いているとき（`DesktopInputSink.acceptsTouch`。Windows、GNOME Remote Desktop）は、1 本指を Windows App のタッチモードと同じくタッチ（contact）として送り、tap・長押しの右 click・パンや選択は接続先が決める。方式は最初の指が触れたときに決める。最初の指は 0.1 秒（`touchHoldBack`）送らずに待ち、その間に 2 本目が触れたらタッチは一度も送らずに上表のマウス操作にする。待つ間に指が離れた（tap）・動いた（パン）ときは、触れた位置の down からすぐ送る。0.1 秒より後の 2 本目は、送ったタッチを cancel してマウス操作に引き継ぐ。Windows（少なくとも Edge）は down 直後の cancel を tap として扱うため、待たずに送ると 2 本指 tap の下でリンクが開いた。2 本指（スクロール、tap で右 click、pinch zoom）はどの接続先でも同じになる。2 本指スクロールは最初の指の位置へポインターを移してからホイールを送る（ホイールはポインターの下のウィンドウに届き、タッチはポインターを動かさないため）。Mac（macos-rdp-server は RDPEI を持たない）や RDPEI が開く前のログイン画面では、上表のマウス操作になる。

トラックパッドの tap の click を 0.35 秒待つのは、tap の直後のドラッグをボタンの押下だけにするため。0.25 秒では、落ち着いて 2 回目に触れると間に合わなかった。click をすぐ送ると、続く押下が Windows では double click になり、ファイルをドラッグしようとして開いてしまう。

pinch が成立すると UIKit が touch を cancel するため、途中のドラッグはボタンを離して終わり、click は送らない。折りたたみ端末で手元デッキをキーボードのみにしたときは、選択に関係なくトラックパッド方式になる。

タッチと Apple Pencil は bridge ABI 4 の `mr_rdp_session_send_touch` / `send_pen` で送る。キーと同じ有界キューを通り、down は対応する up/cancel の空きを予約する。入力の門が閉じるとき（メニュー、フォーカス喪失、方式の切替）は、置いている指をすべて cancel、ペンを up にしてから閉じる。RDPEI がまだ無いとき（ログイン画面など）は FreeRDP がタッチを左ボタンに置き換える。cancel は FreeRDP の `freerdp_client_handle_touch` を使わず、RDPEI の `TouchCancel`（UP|CANCELED）で送る。前者は UPDATE|CANCELED を送り、RDPEI クライアントはその contact を以後のフレームでも押したまま送り続け、FreeRDP 側の contact 表（10 枠）も UP でしか空かないため。

Apple Pencil は方式に関係なくペンとして送る（iPad、「Apple Pencil をペンとして送る」、既定オン）。筆圧は force / maximumPossibleForce、傾きは altitude と azimuth から X/Y の度数、回転は iPadOS 17.5 以降の roll。ペンのボタン（barrel/eraser）は Apple Pencil に無いので送らない。ペン先が画面から浮いているあいだ（`UIHoverGestureRecognizer` の `zOffset` が 0 より大きい）は、位置と傾きを接触なしのホバーとして送る。

## 10. ソフトウェアキーボード（終盤実装）

入力層は初期から三モードを区別する。

### 10.1 `hardwareRaw`

物理キーの HID-to-scan-code 経路。ソフトウェアキーボード設定にかかわらず常にホスト側入力として扱う。

### 10.2 `softwareLocalIME`

専用 `UITextInput` proxy で iPadOS の marked text をローカル表示し、確定した文字列だけを RDP Unicode keyboard event として送る。未確定文字は送らない。Backspace、改行、絵文字、結合文字をテストし、送信単位は Swift の `Character` ではなくプロトコルが必要とする UTF-16 code unit を adapter 内で扱う。surrogate pair や対象 Windows app によって Unicode event が成立しない文字は、ユーザー確認付き clipboard paste を fallback とする。

このモードでは Windows 側 IME が OFF であることが望ましい。クライアントがホスト IME 状態を確実に検出できるとは仮定せず、モード説明を表示する。

### 10.3 `softwareRemoteIME`

ローカル入力 proxy は ASCII capable、autocorrection/spell checking/smart punctuation 無効とし、入力された ASCII を keyboard layout に基づく scan code の down/up へ変換する。ASCII capable 指定だけで日本語 IME を確実に抑止できるかは初期 `UITextInput` PoC で実機確認する。

画面内の拡張キーバーは両ソフトキーボードモードで表示し、次を提供する。

- Esc、Tab、Ctrl、Alt、Shift、Win
- 矢印、Delete/Backspace
- 変換、無変換
- リモートのセキュリティ画面等、検証済みの定型操作

仮想修飾キーは「次の 1 key のみ」と「lock」を視覚的に区別し、モード切替/メニュー/切断時に必ず解放する。

local IME mode で marked text がある間は、`確定` と `キャンセル` を表示する。文字以外の remote modifier/chord を押した場合は暗黙送信せず、先に確定またはキャンセルを選ばせる。Esc はまず composition のキャンセルに使い、未変換文字がないときだけ remote Esc とする。

### 10.4 ポインターへの追従

ソフトウェアキーボードが画面下に出ている間、`RemoteDesktopView` はキーボードが覆う高さを `ViewportTransform.occludedBottom` に渡し、リモートのポインター（トラックパッドで動かした位置、またはタッチで置いた位置）がキーボードの上 24pt 以内に見えるまで desktop を持ち上げる。トラックパッドで動かすとそのまま追いかけ、キーボードを閉じると元に戻る。iPhone 向け Windows App と同じ動き。セッションメニューの「キーボード表示中はポインターに合わせて画面を動かす」（既定オン、端末に保存）で切れる。iPad のフローティング/分割キーボードは帯状に覆わないので対象外。

### 10.5 モード切替

marked text がある最中に切り替える場合は確定またはキャンセルしてから responder を交換する。交換中は入力 gate を閉じ、旧 responder の遅延 callback を generation ID で破棄する。

## 11. 入力診断

グローバル設定に明示的な「入力診断」を用意する。ただし HID usage/scan code の時系列は文字列がなくても入力本文を再構成できるため、Release build で通常の printable key を event 単位に記録しない。

- 常時取得可能: event/drop/stale/duplicate の集計数、focused session、first responder、device connect 状態、`releaseAll` の理由
- 明示 opt-in の時限診断: 英数/かな等の非文字 allow-list に限った source、usage、down/up/cancel、mapping 結果
- 開発 build 限定: 実機入力スパイク用の全 usage trace。画面上に記録中表示を出し、memory 上だけに保持する

KeyProbe の全キー記録機能は研究用であり製品版へそのまま移植しない。診断ログはパスワード、`characters`、printable key sequence を記録せず、既定では永続化しない。

## 12. Mac（Mac Catalyst）

Mac 版は同じアプリを Mac Catalyst で動かす。入力の正規化（HID usage → scan code、調停、quarantine、リピート）は iPad と共通で、Mac で違うのは取得経路だけである。

### 12.1 キーボード

Mac Catalyst では `pressesBegan` に届かないキーが 2 種類ある（2026-10-08、macOS 26 VM で確認）。

- 英数/かな: UIKit は `UIEvent type 4` を受け取るが、どのウインドウにも配送しない（`Sending UIEvent type: 4 … to windows: 0`）。
- メニュー項目のキー（⌘W、⌘C、⌘N など）: `pressesBegan` より先にメニューの動作になる。⌘W ではセッションのウインドウが閉じた。

このため Mac では、セッション面が key window の first responder で入力 gate が開いている間、AppKit の local event monitor（`NSEvent addLocalMonitorForEventsMatchingMask:`、Catalyst から AppKit は import できないので名前で引く）で `keyDown`/`keyUp`/`flagsChanged` を取り、仮想キーコード（`kVK_*`）を HID usage に直して `.uiKit` 経路として調停へ渡し、イベントは消費する（`MacKeyboardCapture`、表は `InputCore.MacVirtualKey`）。メニューにも UIKit にも届かないので、同じキーが二重に届くことはない。

- 修飾キーは `flagsChanged` の左右別 device bit で押下/解放を判定する。device bit の無いソフトウェア生成イベントは device 非依存の flag で判定する。
- Caps Lock は状態変化ごとに 1 回の押下として送る。
- AppKit のオートリピートは捨て、iPad と同じくアプリ側のリピートを使う。
- Mac に残すショートカット: ⌘Q、⌘H、⌘M、⌘\`、⌃⌘F。それ以外の ⌘ は Windows キーとの組み合わせとしてリモートへ送る（⌘W は Win+W）。⌘Tab、⌘Space など OS が先に取るものはアプリに届かない。
- 対応: Command → Windows、Option → Alt、Control → Control、かな（`kVK_JIS_Kana`）→ LANG1 → 変換（`0x79`）、英数（`kVK_JIS_Eisu`）→ LANG2 → 無変換（`0x7B`）、¥ → `0x7D`、ろ → `0x73`。

確認（2026-10-08、tart の macOS 26 VM から UTM 上の Windows 11、`KeyEcho`）: 英数/かな/¥/ろ、⌘W、⌘R（Win+R）、⌥F4（Alt+F4）、F1、矢印、前方削除が上表どおり届いた。ただし VM では tart の VNC が英数/かなを VM に送らないため、この 2 キーは `CGEventPost` した仮想キーコードでの確認であり、実機 JIS キーボードでは未確認。

### 12.2 マウス

左ボタン、移動、スクロールは iPad と同じ indirect pointer 経路で届く。右ボタンと中ボタンは UIKit がタッチとして渡さない（副ボタンはコンテキストメニュー要求になる）ので、同じ AppKit monitor で `rightMouseDown/Up`、`otherMouseDown/Up` を取り、セッション面が hover で追っている位置で押下/解放を送る。ポインタがセッション面の外にあるクリックは Mac に任せる。

### 12.3 メニューとクリップボード

セッションの上に浮かぶメニューボタン（⋯）は Mac では出さず、メニューバーの「セッション」に置く（前面のセッションウインドウのセッションが対象。セッションのメニュー…、ショートカットを送る、解像度、画質、再接続、切断）。キーはリモートへ行くので、項目にショートカットは付けない。

クリップボードは、セッションのウインドウが前面にある間だけ双方向に追従する（`isWindowInFront`。Mac では別のアプリが前面でも scene は `.active` のままなので、ウインドウが key でアプリが active かで判定する: `WindowKeyReader`）。

- 別のアプリが前面の間に Mac でコピーしたものは送らず、戻ったときに送る。
- 別のアプリが前面の間にリモートがコピーを知らせてきたら、戻ったときに Mac 側がその間に何もコピーしていなければ取り込む。Mac 側でコピーしていればそちらが新しいので、Mac のものを送る。
- リモートの内容を取りに行っている間に Mac でコピーされたら（pasteboard の change count が動いたら）、取ってきた内容で上書きしない（2026-10-17。以前は前面でなくても取り込み、別アプリでのコピーが上書きされることがあった）。


## 13. Mac サーバー（macos-rdp-server, MACRDPX）

接続先の種類を「macOS（macos-rdp-server）」にした接続は、静的仮想チャンネル `MACRDPX`（Mac RDP eXtensions、`external/macrdpx`）を要求する（ブリッジ ABI 6、`MR_RDP_CHANNEL_FLAG_MACRDPX`）。サーバーが HELLO に応じるまでは通常の RDP 入力のまま。応じた後は合意した機能の入力だけをチャンネルで送り、同じ入力を二重には送らない。サーバーがチャンネルを知らなければ何も起きない（Windows/標準接続ではチャンネル自体を要求しない）。

- キー: Mac 版は AppKit の monitor が取ったキーを、仮想キーコードと `NSEvent.modifierFlags`（左右の device bit 込み）のまま `KEY` で送る。調停・アプリ側リピート・scan code 変換は通らず、AppKit のオートリピートを `REPEAT` 付きで送る。⌘ は ⌘、Fn（`kVK_Function`）と Caps Lock も flags-changed として届く。Mac に残すショートカット（⌘Q、⌘H、⌘M、⌘\`、⌃⌘F）は 12.1 と同じ。セッション面がキーボードを得たとき `MODIFIERS` で修飾状態を合わせ、失ったとき `MODIFIERS(0)` でサーバー側の押下をすべて離す。iPad は HID usage を同じ位置の Mac キー（`mrx_keycode_for_hid_usage`）にし、修飾状態は `mrx_modifier_tracker` で作る。
- キーボード種別: 接続時に `KEYBOARD_INFO` で送る（Mac は `LMGetKbdType`、iPad はプロファイルの配列: 日本語→JIS、US→ANSI）。
- ポインタ: 移動・ボタンもキーと同じチャンネル・同じ順序付きキューで送る（`POINTER`）。修飾フラグと、クライアントで数えたクリック回数（0.5 秒・6 px 以内の同じボタン）を付ける。
- スクロール: Mac 版は AppKit の scrollWheel monitor から `scrollingDelta`、`hasPreciseScrollingDeltas`、phase、momentumPhase をそのまま `SCROLL` で送り、UIKit の pan には渡さない（ポインタがセッション面の上にあるときだけ）。iPad の pan/ホイールは RDP の回転量を行単位の `SCROLL` に直す。ブリッジのキューは同じ phase の継続イベントを加算してまとめる。
- 画質: プロファイルの「画質」（自動/高/標準/低 = 60fps 20Mbps / 30fps 8Mbps / 15fps 1.5Mbps）を `STREAM_CONFIG` で求める。自動は `NWPathMonitor` の expensive/constrained（モバイル回線、Low Data Mode）で低、それ以外で高。セッションメニューで変えられ、サーバーの `STREAM_STATUS`（fps、bit rate、Retina か）と `INPUT_SOURCE`（英字か入力モードか）を表示する。
- 確認（2026-10-08、tart の macOS 26 VM 2 台、Mac 版 mRemote → macos-rdp-server）: ⌃C、⌘K（Terminal の画面消去）、位置どおりの文字、かな→日本語入力（「かか」と候補表示）、トラックパッド相当の pixel スクロール（phase と慣性付き）、画質の切り替え（60fps 20Mbps → 15fps 1.5Mbps）、Retina（2048x1298 px を 1024x649 pt の HiDPI 仮想ディスプレイで）。同じサーバーに「Windows / 標準」の接続で入ると MACRDPX は使われず、scan code 経路（⌘ は Windows キー扱い）で届く。
- iPad/iPhone（2026-10-09、シミュレータ → localhost 転送 → macos-rdp-server の VM）: iPad Air 13 (M4) で縦向き 2048x2692 px（HiDPI）、iPhone 17 Pro で 1206x2334 px の Retina デスクトップ。Mac 接続ではデッキが Mac 配列（⌘ ⌥、英数/かな）とショートカット列（⌘Tab、⌘Space、⌃↑、⌥⌘Esc、⌃⌘Q）になり、iPhone の拡張キーバーは ⌃⌥⇧⌘・英数/かな と表記する。デッキの e/c/h/o（kVK 14/8/4/31）、⌘K（左⌘ device bit 付き）、英数（kVK 102）、iPhone のバーの ⌘←が Mac キーとして届いた。PC 配列の 無変換/変換（International5/4）も英数/かなとして送る。
- 同じ iPad から Windows（標準接続）へは従来どおり scan code 経路で、デッキも Windows 配列のまま。DISP リサイズと 変換（IME オン）を確認した。

