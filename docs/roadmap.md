# 実装ロードマップ

## 1. 進め方

最も不確実な FreeRDP の iOS build、Japanese scan code、描画/音声 bridge、複数セッションのメモリを先に実機で潰す。UI を作り込んだ後に native core の制約が判明しない順序にする。

検証の規模は [`README.md`](README.md) の「開発体制と試験スケール」に従う。個人開発なので、
反復回数と端末マトリクスは現実的な水準に落とし、そのぶん自動テストと記録に寄せる。

2026-10-07 時点の方針: 実機・Windows での確認を後回しにして Phase 6 まで実装を先行した。
各 phase の「実装状況」表の **未実施** が、実機/Windows 環境で消化する残りである。

期間ではなく exit criteria で phase を区切る。各 phase で未完の native resource、入力押下状態、秘密データが残らない teardown test を加える。Phase 0 の `GO` は個人基準で native core を採用する判断であり、製品/互換性/リリースの承認ではない。

## 2. Phase 0 — Go/No-Go スパイク

### 成果物

- 固定 commit の FreeRDP/WinPR を生成する再現可能な build script
- device `arm64` と Simulator 向け静的 XCFramework
- opaque handle を使う最小 C bridge
- 1 枚の UIKit/Metal RDP surface を持つ技術 harness
- Windows 側 scan code 観測用 `KeyEcho`
- host/local IME mode を切り替える最小 `UITextInput` proxy harness
- 端末機種、OS build、キーボード機種/接続方式、iPadOS 関連設定を記録した入力基準環境
- dependency license 一覧/SBOM の原型

### Core Gate（最初の実機 run）

1. device arm64 の bridge を含む harness を実機で起動できる。
2. NLA/TLS で実 Windows へ接続し、leaf/chain DER を `SecTrust` + SSL hostname policy で判定して challenge を扱える。
3. 英数→`0x7B`、かな→`0x79` の各 down/up が Windows 側で無変換/変換として認識される（数回の実機確認で足りる。KeyEcho による 10 cycle の機械判定は Phase 3 で行う）。
4. 対象 press で `super.presses*` を呼ばず、iPadOS IME/入力ソース UI を起動しない (`KEY-IME-02`)。
5. 接続停止・破棄後に callback/wait が残らず、再接続して crash/hang しない。

### 結果（2026-09-05: GO）

基準構成（iPad mini 第 7 世代 + Apple Magic Keyboard JIS + Windows 11 一台）で Core Gate の
7 行すべてが実機で PASS した。判定と繰り越し事項は [`phase0/README.md`](../phase0/README.md)
に記録してある。

### Gate

- FreeRDP を安全に停止/破棄できない、DER を authoritative trust 判定へ渡せない、必須 Japanese key event を送れない、または `KEY-IME-02` を満たせない場合は、その版/方式を採用しない。
- 合格後は個人基準で native core を採用し、Phase 1/2 へ進む。版変更、bridge 修正、代替 RDP core 評価が必要な場合だけ Core Gate を再実施する。
- pointer、4K、channel/audio、複数 session、archive/SBOM、多端末 matrix は実装済みの先行資産として残し、それぞれ Phase 3〜7 または対応機能の実装時に検証する。

## 3. Phase 1 — アプリ基盤と接続先

### 実装

- module/target 構成、DI、OSLog category（`Packages/mRemoteKit/` の SwiftPM package: `SessionCore` / `Persistence` / `AppleAdapters`）
- `ConnectionProfile`、RDP payload、global settings、migration
- Keychain credential repository、trust repository
- 接続先一覧、空状態、追加/編集/複製/削除 sheet
- `RemoteSession` interface、SessionManager actor、FakeRemoteSession
- Settings と dependency licenses 画面

### Exit criteria（2026-09-05: 達成）

- fake session で一覧→接続→全画面→一覧復帰→切断の UI test が通る。→ `AppUITests/ConnectionFlowUITests`
- password が profile store/log へ保存されない。→ Keychain 保存と、document へ混入しないことの test
- schema v1 と migration test の土台がある。→ `SchemaMigrator` と `SchemaMigratorTests`
- SSH session factory を将来登録できる依存方向になっている。→ `SessionFactoryRegistry`

### この phase で意図的に残したもの

- ライセンス画面は静的リスト。`ThirdParty/` の notice からの生成は Phase 7
- String Catalog への文言分離、VoiceOver/Dynamic Type の確認は Phase 7
- session workspace のリモート描画は placeholder。実描画は Phase 2

## 4. Phase 2 — 単一 RDP セッション

### 実装

- FreeRDP bridge の connect/cancel/disconnect/error mapping
- NLA/TLS、credential challenge、certificate UI
- software framebuffer→Metal dirty-region 描画
- Fit/100%、pinch、pan、回転。DISP 対応時の動的解像度、非対応時の local scaling/再接続
- connection status/retry
- scene inactive privacy cover と lifecycle 処理
- Phase 0 harness の `ServerTrustEvaluator` を `RDPProtocol` へ移設

### Exit criteria

- 対象 Windows へ接続し、30 分操作して crash/leak/UI hang がない。
- 接続全段階をキャンセル可能で、20 回の connect/disconnect test に耐える。
- 証明書を無言で受理せず、fingerprint 変更を検出する。
- （Phase 0 からの繰り越し）bridge の sanitizer stress を実施する。

### 実装状況

| 項目 | 状態 |
|---|---|
| bridge connect/cancel/disconnect、error mapping | 実装済み。`RDPErrorMapper` が bridge status と FreeRDP error code を `RemoteSessionError` へ写像する |
| NLA/TLS、credential challenge、certificate UI | 実装済み。`SessionChallengeSheet` |
| software framebuffer→Metal dirty-region 描画 | 実装済み。`LatestDesktopFrameStore` と `RemoteDesktopView` |
| Fit/100%、pinch、pan、回転、DISP 動的解像度 | 実装済み。`ViewportTransform` |
| scene inactive privacy cover と lifecycle | 実装済み |
| ポインター入力（hover/左右 button/drag/wheel） | 実装済み。Phase 3 から前倒し。`InputCore` の `PointerInputRouter` |
| キーボード入力（UIKit `presses*`、英数/かな、client 側 key repeat） | 実装済み。Phase 3 から前倒し。`InputCore` の `KeyboardInputRouter` と `RDPProtocol` の `RDPScanCodeMapper` |
| 接続全段階のキャンセル、20 回 connect/disconnect | 自動試験済み。`AppTests/RDPRemoteSessionTests` |
| 証明書の無言受理なし、fingerprint 変更検出 | 自動試験済み。`CertificateReviewPolicyTests` |
| 実 Windows への 30 分操作 | **未実施**。実機試験が必要 |
| bridge の sanitizer stress | 実施済み（2026-09-05）。下記 |

### bridge sanitizer stress の記録（2026-09-05）

Phase 0 から繰り越した項目。`unavailable`/mock backend の contract test 一式を
Address+UndefinedBehavior と Thread の両 sanitizer で実行し、いずれも clean。

| 構成 | 結果 |
|---|---|
| `-DMR_BRIDGE_SANITIZER=address` | 5/5 pass |
| `-DMR_BRIDGE_SANITIZER=thread` | 5/5 pass |
| `-DMR_BRIDGE_SANITIZER=address -DMR_BRIDGE_CERTIFICATE_TESTS=ON` | 6/6 pass（PEM parser 込み） |

実行環境: macOS 26.0 (arm64)、Apple clang（Xcode 27.0 / 27A5194q）、CMake 4.4.3。

この繰り越しのために `contract_tests.c` へ `concurrent stop and call stress` を追加した。
既存の drain test は順序を 1 回ずつ確認するもので、sanitizer が探すべき競合
（challenge wait とその wake の間に入る stop、run が return する最中に届く send、
既に消えた challenge への response）は再現しない。新テストは run と並行して別 thread から
25 反復 × 64 回の send/respond/cancel/stop を撃つ。destroy は両 thread の join 後にだけ呼ぶ。
これは Swift 側 `RDPNativeCallGate` が提供する外部 gate と同じ契約である。

再現手順は [`bridge/README.md`](../bridge/README.md) にある。

### この phase で意図的に残したもの

- ポインターとキーボードの**送信経路**は Phase 3 の範囲だったが、実機で何も試せなく
  なるため前倒しした。`InputCore`（`PointerInputRouter`/`KeyboardInputRouter`/
  `ScrollWheelAccumulator`/key repeat）と `RDPProtocol` の `RDPScanCodeMapper` が
  ここで入る。source は UIKit の `presses*` と indirect pointer だけで、`GCKeyboard`、
  `GCMouse`、usage ごとの source policy、`KeyboardEventArbiter` は Phase 3 のまま。
  KeyEcho による英数/かな 10 cycle の機械判定も Phase 3 のままである。
- **remote cursor の形状**は送れない。C ABI に pointer/cursor callback が無く、追加には
  ABI 変更と XCFramework の再生成が要る。ポインター自体が Phase 3 の担当なので、cursor
  shape の transport はそこで ABI 追加として設計する。現状はサーバー側描画に依存する。
- 自動再接続 (`ReconnectPolicy.automatic`) は設定値としては存在するが、再接続の実行は
  Phase 4 の scene restoration と同じ policy で扱う。

## 5. Phase 3 — 物理入力とポインター

### 実装

- GCKeyboard/GCMouse 経路、usage ごとの静的 source policy、`KeyboardEventArbiter`
- Phase 0 harness の `InputRouter` を `InputCore` へ移設（harness は入力回帰の治具として残す）
- `releaseAll` の source 横断 quarantine（Phase 2 は UIKit 単一 source ぶんのみ）
- Japanese layout/type negotiation（Phase 2 は scan code 送信のみ）
- focused-session input gate（Phase 2 は単一セッションの scene/state gate のみ）
- scroll 反転の global override（Phase 2 はセッション中の切り替えのみ）
- remote cursor shape の C ABI 追加（pointer callback）と描画
- redacted input diagnostics

Phase 2 で前倒し済み: `RemoteInputView` の first responder と UIKit keyboard capture、
`RDPScanCodeMapper`（HID-to-Set-1）、`ScrollWheelAccumulator`、hover/左右 button/drag/
縦横 wheel、`ViewportTransform`、client 側 key repeat。

### Exit criteria

- KEY-EISU-01/KEY-KANA-01 の各 10 回が実機/Windows で合格する。
- local IME の候補/文字が混入せず、focus/lifecycle 操作で押下残りがない。
- 手元の Apple JIS キーボードと利用可能なポインターで合格する。PC JIS と他のポインターは入手できた時点で追加検証とし、未検証であることを文書に残す。

### 実装状況（2026-10-07、シミュレータ確認まで）

実機確認を後回しにして Phase 6 まで先に進める方針になったため、ここでの「済み」は
実装と自動試験、シミュレータでの起動確認までを指す。

| 項目 | 状態 |
|---|---|
| GCKeyboard 経路と usage ごとの静的 source policy | 実装済み。`HardwareKeyboardMonitor` が `GCKeyboard.coalesced` を観測し、`InputCore` の `KeyboardEventArbiter` が usage ごとに一つの source だけを remote へ通す。基準 policy は全 usage が UIKit（Phase 0 の実機結果） |
| `releaseAll` の source 横断 quarantine | 実装済み。解放時に物理的に押されていた usage を隔離し、その押下の up/再 down を送らない。gate を開くときは `GCKeyboard` の `isPressed` で隔離を照合し直す |
| Japanese layout/type negotiation | 実装済み。bridge ABI 2 の `keyboard_profile`。日本語は 0x411/type 7、US は 0x409/type 4、自動は FreeRDP 既定のまま |
| focused-session input gate | 実装済み。`SessionManager` の focus を `AppEnvironment.focusedSessionID` に写し、focus 外の surface は gate が閉じる |
| scroll 反転の global override | 既存の `Inheritable<ScrollDirection>`（グローバル既定 + 接続先ごとの上書き）とセッション中の切替で満たしている |
| remote cursor shape | 実装済み。bridge の pointer class が BGRA へ変換し、surface はリモート倍率で描いたレイヤーをローカルポインタに追従させ、システムポインタを隠す。サーバーからの位置ワープは iPadOS が許さないため無視する |
| redacted input diagnostics | 実装済み。設定 > 入力診断。常時の集計と、非文字キー限定・メモリのみ・10 分で自動停止する記録 |
| GCMouse | 採用しない。Phase 0 で UIKit の indirect pointer が左右ボタン・ドラッグ・ホイールを取れており、二経路を混ぜない原則（入力設計 8.1）に従う |
| KEY-EISU-01/KEY-KANA-01 各 10 回（KeyEcho） | Windows 側は確認済み（2026-10-07、Windows 11 VM）: 無変換/変換（英数/かなと同じ scan code 0x7B/0x79）を各 10 回、`analyze-keyecho.sh` で pass（VK_NONCONVERT/VK_CONVERT、repeat/mismatch/押下残り 0）。物理の英数/かなキーは DeviceHub・シミュレータがアプリへ渡さない（Shift は届くがアプリの入力診断に 0 件）ため **実機で未実施** |
| 押下残りの実機確認（focus/lifecycle） | **未実施**。自動試験（`KeyboardEventArbiterTests`）のみ。物理キーボードを使う実機試験 |

## 6. Phase 4 — 複数セッション

### 実装

- session ごとの FreeRDP instance/worker/frame store
- 実行中 section、session switcher、状態 badge
- focused session の atomic switch と stale generation 排除
- 非表示 session の presentation 縮退、memory warning policy
- reconnect と scene restoration policy

### Exit criteria

- 2×1080p session を必須として 30 分接続し、切替、入力分離、個別切断が成立する。3 session は基準端末で目標測定する。
- 1 session の network stall/error が他 session/UI を止めない。
- memory baseline に基づく supported session guidance を決める。

### 実装状況（2026-10-07、シミュレータ確認まで）

| 項目 | 状態 |
|---|---|
| session ごとの FreeRDP instance/worker/frame store | Phase 2 の構造のまま成立（セッションごとに `RDPRemoteSession` と専用 worker）。上限は `SessionManager.sessionLimit = 3` |
| 実行中 section、session switcher、状態 badge | 実装済み。一覧の「実行中」、フローティングボタンのメニュー sheet の切替一覧、`SessionStateBadge`（色だけに頼らずアイコン付き） |
| focused session の atomic switch と stale generation 排除 | 実装済み。`AppEnvironment.switchTo` で focus を移し、旧 surface は gate 閉で押下を解放、新 surface は `.id` で作り直す。generation は Phase 2 から session が保持 |
| 非表示 session の presentation 縮退 | 実装済み。frame store が最後の全面フレームを保持し、戻ったときに即描画（従来は次の更新まで黒） |
| memory warning policy | 実装済み。非 focus セッションの保持フレームだけを捨て、接続は切らない |
| reconnect と scene restoration policy | 実装済み。接続済みだったセッションが再試行可能なエラーで落ちたら 1/2/4 秒で最大 3 回（`ReconnectSchedule`）。前景復帰時にも判定。認証失敗等は再試行しない。あわせて状態機械に `connected → failed` を追加した（従来は通信断後も `connected` のまま残っていた） |
| 通常 tap は既存セッションへ戻る／明示操作だけが多重接続 | 実装済み。一覧の context menu「新しいセッションで接続」 |
| 2×1080p で 30 分、切替・入力分離・個別切断 | 自動試験（`MultiSessionTests`）に加え、実ホスト 2 台（Windows 11 VM と実機 Windows）で切替・入力分離・個別切断を確認（2026-10-07、iPhone Duo シミュレータ）: B 表示中の Win/Esc は VM に 0 件、A に切り替えての Win/Esc は VM に 1 組だけ、B を切断しても A は接続済みで入力も届く。**実機 30 分は未実施** |
| network stall が他 session/UI を止めない | 確認済み（2026-10-07、シミュレータ）: VM のネットワークを止めている間も実機 Windows のセッションと UI は応答した（スタートメニュー、セッションメニュー）。VM のセッションは失敗→自動再接続を使い切り、戻った後にバナーの「再接続」で接続済みに戻った |
| memory baseline と supported session guidance | **未実施**。実機計測が必要 |

## 7. Phase 5 — 音声・クリップボード

### 実装

- iOS `RDPSND_DEVICE_PLUGIN`、PCM-only negotiation、session 別 SPSC ring、共通 AVAudioEngine、route/interruption
- focused session だけを再生する audio policy
- `cliprdr` の format-list/request/response、NUL 終端 UTF-16LE `CF_UNICODETEXT`、UIPasteboard adapter
- clipboard direction、user-initiated paste/copy、loop/size protection

### Exit criteria

- 44.1/48 kHz の test tone が安定再生され、route/interruption 後に復帰する。
- session 切替で音声が混ざらない。
- ASCII/日本語/絵文字を双方向に copy でき、許可 UI を過剰に出さない。
- clipboard/audio 本文が log/disk に残らない。

### 実装状況（2026-10-07、シミュレータ確認まで）

| 項目 | 状態 |
|---|---|
| iOS `RDPSND_DEVICE_PLUGIN`、PCM-only negotiation | 実装済み。bridge 独自の `mremote` サブシステム（addin provider で登録）が 16-bit PCM 1〜2ch だけを受け、`mr_rdpsnd` の focus gate を通す。Wave Confirm は FreeRDP core が送る |
| session 別 SPSC ring、共通 AVAudioEngine | 実装済み。`mr_pcm_ring`（C、lock-free）をセッションごとに持ち、`AudioCoordinator` が focus 中のセッションの ring だけを `AVAudioSourceNode` で再生する。render callback は lock・確保・actor hop をしない |
| route/interruption | 実装済み。interruption 終了と `AVAudioEngineConfigurationChange` で再構築。background で停止 |
| focused session だけを再生 | 実装済み。bridge 側で非 focus の PCM を捨て、切替時は新 ring の backlog を破棄 |
| `cliprdr` の format-list/request/response | 実装済み（bridge ABI 2）。ローカル→リモートは offer、リモート→ローカルは request。MS-RDPECLIP どおり capability の後に空の format list を送るようにした |
| NUL 終端 UTF-16LE `CF_UNICODETEXT` | 実装済み。`ClipboardTextCodec`（CRLF 変換、埋め込み NUL 拒否、受信は最初の NUL まで、不正サロゲートは U+FFFD） |
| clipboard direction、user-initiated paste/copy | 実装済み。メニューの `PasteButton`（OS の貼り付け許可ダイアログを出さない）と「端末へコピー」。貼り付け chord（Ctrl+V）はこの操作のときだけ送る |
| loop/size protection | 実装済み。4 MiB 上限、10 秒タイムアウト、受信直後の同一テキストは再 offer しない |
| 44.1/48 kHz test tone、route 変更後の復帰 | test tone は確認済み（2026-10-07）: 44.1/48 kHz の 1.5 s tone を RDP セッション内で再生し、44100 Hz x2 の node で再生、ring overflow は最初の 1 packet（node 構築前）のみ。DeviceHub の出力切替（System ↔ MacBook スピーカー）中も再生継続。iOS 側の route change（AVAudioEngine の再構築）はシミュレータで発生しないため **実機で未実施**。耳での確認も未実施 |
| ASCII/日本語/絵文字の双方向 copy | 確認済み（2026-10-07、Windows 11 VM）: ASCII、日本語、絵文字（肌色修飾・国旗・𠮷 のサロゲートペア）の 3 種を端末→Windows、Windows→端末の両方向で完全一致 |

## 8. Phase 6 — ソフトウェアキーボード

この phase は後半だが、`InputMode` の経路分離と小さな `UITextInput` 技術検証は Phase 0〜3 で済ませる。

### 実装

1. 拡張キーバー: Esc、Tab、Ctrl、Alt、Shift、Win、矢印、Delete、変換、無変換
2. host IME mode: ASCII を scan code 化、virtual modifier の one-shot/lock
3. local IME mode: marked text 表示、確定文字だけを Unicode event で送信。不成立文字は明示 clipboard paste
4. mode/global default/profile override、session 中の切替
5. software keyboard の回転、予測変換、絵文字、削除、composition edge case

### Exit criteria

- local IME mode で未確定文字が host へ漏れず、確定文字が一度だけ届く。
- host IME mode で変換/無変換と Ctrl 等が正しい down/up になる。
- mode 切替、keyboard close、session 切替で marked text/modifier が残らない。

### 実装状況（2026-10-07、シミュレータ確認まで）

| 項目 | 状態 |
|---|---|
| 拡張キーバー | 実装済み。Esc/Tab/Ctrl/Alt/Shift/Win/無変換/変換/矢印/Home/End/PgUp/PgDn/Del。システムキーボードの accessory view |
| host IME mode | 実装済み。ASCII キーボードの打鍵を、接続時の配列（日本語 106/109 か US）に合わせたキー位置で送る（`ASCIIKeystrokeMapper`） |
| virtual modifier の one-shot/lock | 実装済み。タップで 1 キー限定 → 固定 → オフ。表示は塗りと鍵アイコンで区別し色だけに頼らない。修飾キーは各キーの前後で down/up するため、リモートに押下状態が残らない |
| local IME mode | 実装済み。隠した `UITextView` を proxy にし、iPadOS の marked text をそのまま使う。未確定文字はキーバー上に表示するだけで送らず、確定した文字を UTF-16 単位の Unicode イベントで送る（bridge ABI 2）。Enter はキーとして送る |
| marked text 中の制約 | 実装済み。確定/キャンセルを表示し、修飾キー・拡張キー・モード切替を無効化。Esc は未確定文字のキャンセルに使う |
| mode/global default、session 中の切替 | 実装済み。設定の初期モード（スキーマ v2、v1 からの移行付き）とキーバーの切替 |
| keyboard close / session 切替で modifier を解放 | 実装済み |
| 送れない文字の明示 clipboard paste | 実装済み。キーバーの 📋 で次の確定文字（確定した未確定文字、または絵文字）を 1 回だけ貼り付けで送る。リモートのクリップボードを上書きすると表示し、接続先がクリップボード送信を許すときだけ出す。キーボードを閉じると解除。Unicode イベントが効かないかはクライアントから判別できないため、自動ではなく利用者が選ぶ |
| Windows 側で一度だけ届くこと、host IME での変換/無変換 | 確認済み（2026-10-07、iPad シミュレータ + Windows 11 VM）: 手元 IME で ASCII/日本語/絵文字が一度だけ届く。marked text 中は Windows に 0 イベント（KeyEcho）、確定で「かな」が一度だけ、キャンセルでは何も届かない。ホスト IME で 変換→aiu→Enter→無変換→abc が「あいうabc」 |

### 追加: 折りたたみ端末のラップトップ姿勢（2026-10-07、シミュレータ確認まで）

iPhone Duo（Xcode 27.1 beta のシミュレータ）向け。仕様は docs/ui-flow.md 9.1。

調査で分かったこと:

- iOS 27.1 の `UIHingeInteraction` / SwiftUI `onHingeChange` は状態（closed / partiallyOpen / fullyOpen）と角度だけを返し、**ヒンジの画面上の位置は取れない**。
- Duo の内側ディスプレイは 669×951pt、カバーは 466×678pt で内側の半分に相当する。縦持ちで長辺を横切って中央で折れるため、「縦長 + partiallyOpen」をラップトップ姿勢とし、中央で分割する。
- シミュレータのヒンジ操作は DeviceHub.app の UI のみ（端末表示の横にある Closed / Partially Open / Open ボタン）。`simctl` / `devicectl` には無い。シミュレータの初期向きは横（ヒンジが縦に入る本の向き）なので、ラップトップ姿勢は Controls > Rotate Left で縦にしてから試す。
- `UIHingeInteraction` は Xcode 27.0 の SDK に無いため `#if canImport(UIKit, _version: 9127.0.85)` で分岐。27.0 でもビルドは通り、ヒンジは常に「なし」になる。

| 項目 | 状態 |
|---|---|
| ヒンジ検出と上下分割 | 実装済み（`HingePostureReader`、`SessionWorkspaceView`）。surface は分割時も再生成しない |
| PC 配列キーボード（JIS / US） | 実装済み（`LaptopKeyboardLayout`、`LaptopKeyboardComposer`）。キー位置を HID usage で送る。押している間 down、リピート、修飾キーは同時押しとタップでの one-shot/lock の両方 |
| トラックパッド | 実装済み（`RelativePointerMotion`）。相対移動と加速、タップで左、2 本指タップで右、2 本指スクロール、左右ボタン、ズーム時の追従、トラックパッド移動時のカーソル描画 |
| 解放 | 実装済み。gate が閉じたとき、デッキが消えたときにキーとボタンをすべて解放 |
| メニューの表示切替 | 実装済み。折り曲げたとき / 常に表示 / 表示しない（セッション単位、保存しない） |
| 手元側の配置 | 実装済み。キーボード / トラックパッド、トラックパッド / キーボード、キーボードのみ（上側の画面をトラックパッドとして使う）。`@AppStorage` に保存。長押しドラッグを追加。3 配置の表示と、キーボードのみでの画面トラックパッド（カーソル位置でクリック）を Windows 11 で確認 |
| テスト | 単体テスト（配列幅、scan code の有無、合成、相対移動）と UI テスト（常に表示でデッキが出る）が通過 |
| 実際に折り曲げたときの自動切替 | 確認済み（2026-10-07、シミュレータ）。縦向き + Partially Open で自動表示、Open で全画面に戻り、横向き + Partially Open では出ない |
| 実ホストでのキー・ポインター | 確認済み（2026-10-07、Windows 11 Pro ARM64 VM、シミュレータ）。Win+R、英字と Shift の one-shot、Ctrl+N、半/全 → ローマ字 → 変換 → 確定、トラックパッドの移動・カーソル描画・タップで左クリック・右ボタン・長押しドラッグ、キーボードのみでの画面トラックパッド（カーソル位置でクリック）。2 本指タップとスクロールは XCUITest で合成できず **未確認** |

| Mac 配列（JIS / US） | セッションメニューの「キーボードの見た目」で Windows / Mac を選べる（全セッション共通の設定、既定は Windows）。`LaptopKeyboardPlatform.mac` は Magic Keyboard（テンキー無し）相当の配列。⌘ は GUI（Win）、⌥ は Alt、英数/かな は LANG2/LANG1 として送るので、Windows ホストでも Mac の手癖で使える。fn は送れる usage が無いため置かず、前方削除を最上段に置く。矢印は逆 T 字。左下の Caps キーは「Caps キー」で役割を変えられ、Mac では macOS の「修飾キー」設定と同じ 6 つ（Caps Lock / Control / Option / Command / Escape / アクションなし）、Windows では Caps Lock / Ctrl。Mac だけの役割を選んだまま Windows に戻すと Caps Lock に戻す |

接続方式（2026-10-07）: プロファイルの「接続方式」は以前から UI と警告だけがあり、接続には反映されていなかった（bridge が NLA 固定、PostConnect も HYBRID 以外を拒否）。bridge ABI 3 の `security_policy` で反映し、自動=NLA+TLS、NLA 必須、TLS 必須、レガシー=NLA+TLS+RDP。レガシーは選ぶと確認ダイアログを出し、許可した場合だけ設定され、接続時のトーストとセッションメニューに監査表示を出す。RDP Security Layer のみを受け付ける実機 Windows（X.224 で SSL_NOT_ALLOWED_BY_SERVER）に、許可後に接続できることを確認。TLS 失敗の文言にこの原因と設定場所を足した。

実ホスト接続で見つけて直したもの（Phase 2 からの不具合）:

- 証明書を保存済みの承認やシステム信頼で受け入れると、セッションが `awaitingUser` のまま `connected` に進めず、画面は出るのに入力がすべて止まっていた。バックエンドの「証明書確認中」を `awaitingUser` に写していたのが原因で、実際にユーザーへ尋ねたときだけ `awaitingUser` にした。
- 動的解像度の要求が一度も届いていなかった。surface は接続中にサイズを報告し、その時点の要求は捨てられ、以後は同じサイズとして送り直されなかった。セッションが希望サイズを覚えて接続後と disp チャネル確立後に送り、ログオン中に送った要求は Windows に無視されるため、実フレームのサイズが一致するまで 2 秒ごとに最大 4 回送り直す。
- デッキが入力不可でも不透明に見えていた（初期状態の見た目を設定していなかった）。

実ホストでの確認手順: `AppUITests/LiveRDPUITests.swift`（ホストと資格情報を環境変数で渡したときだけ動き、接続を保持してコマンドファイルの操作を実行する）。

次にやること:

- 未確認（2026-10-07 時点、3-1〜3-3 の作業で残ったもの）:
  - iPadOS 予約ショートカットの表（[help-limitations.md](help-limitations.md) 1 節とアプリ内ヘルプ）は iPadOS の既定割当から書いたもの。実機 iPad と物理キーボードで各組み合わせがアプリに届くかを記録する（KEY-RESERVED-01）。iPadOS 設定（Caps Lock での入力切替、Control+Space、修飾キーの入れ替え）による差も含める。
  - （2026-10-07 確認、ヘルプを訂正）キーバーの Ctrl → Alt → Del で Windows 11 VM にセキュリティ画面が出る（LogonUI がセッション 1 に起動）。当初ヘルプに書いた Ctrl+Alt+End は mstsc が手元で置き換えるショートカットで、mRemote から送っても何も起きなかった。
  - （2026-10-07 確認済み）最大の文字サイズ（AccessibilityXXXL、iPhone Duo シミュレータ）で、ヘルプ画面の行は大きくなって折り返し、見切れない。監査の「一部未対応」は誤検出と判断してよい。手元キーボードのキー表示はキーの大きさで止まり、見切れない。
- （2026-10-07 対応）画面のタッチを「タッチした場所を操作」（既定）／「トラックパッドとして使う」／「表示の移動だけ」から選べるようにした（docs/input-design.md 9 章）。従来はポインターのない iPad・iPhone でクリックする手段がなかった。直接タッチの tap で GNOME のログイン画面のユーザーを選べることを確認（iPad シミュレータ）。長押し・ドラッグ・2 本指は単体試験（`DirectTouchGestureTrackerTests`）のみ。
- （2026-10-07 確認、GNOME Remote Desktop 50.2 / Ubuntu 26.04、iPad シミュレータ）システムモード（GDM リモートログイン）へ接続。自己署名証明書（CN=GNOME）は「iOS の要件外」の警告付きで承認でき、NLA、1 段目のサーバーリダイレクト（GDM のログイン画面へ）、ホスト IME でのキー入力が通った。ログイン後の 2 段目の引き渡しは、当初ホスト側の handover 不具合で成立しなかったが、ホスト修正後（同日 23:03）はユーザーセッションまで到達した。直接タッチのクリック（通知を閉じる）と音声の受信（44.1 kHz x2 の node 構築）を確認。2 段目のリダイレクト後に解像度と拡大率が送り直されず、ユーザーセッションが 1920x1080 のまま縮小表示される不具合を見つけて直した（disp チャネルが開き直すたびにレイアウトを送る）。続けて GTK の入力記録ウィンドウで確認した（同日 23:10〜23:27、iPad シミュレータ）。ホスト IME の英数字・JIS 記号、拡張キーバーと手元キーボードの 無変換/変換/半全/かな/¥/ろ（Muhenkan/Henkan/Zenkaku_Hankaku/Hiragana_Katakana、ホスト側の補正シム込み）、Shift/Ctrl のワンショット、直接タッチの長押しで右クリックとドラッグでの範囲選択、手元キーボードのトラックパッド（移動・タップ・右ボタン）、ホイール、クリップボード双方向（日本語・絵文字・𠮷、複数行）、手元キーボードのキーでの GDM ログイン。手元 IME の Unicode イベントは配列にある文字（ASCII）しか届かない: GNOME Remote Desktop が配列に無い keysym（é、漢字、絵文字）を「No keycode found」で捨てる。キーバーの 📋（次の確定文字を貼り付けで送る）で回避できるが 1 回の確定分だけ。あわせて、メニューから手元キーボードを出すと下からのスライドが解像度変更で止まり、キーが画面外に残る不具合を直した（スライドをやめてその場に置く）。あわせて、証明書確認が時間切れで失敗した後もシートが残る不具合を直した。
- （2026-10-07 対応）手元キーボード（デッキ）を折りたたみでない端末でも使いやすくした。表示設定を端末に保存して全セッション共通にし（従来はセッション単位で保存せず、毎回「常に表示」を選び直す必要があった）、メニューに出し入れのボタンを置き、項目名から折りたたみ前提の言い方を外した。
- 2 本指タップ／2 本指スクロールを手で触って確かめる。ジェスチャー判定は単体試験（`TrackpadGestureTrackerTests`）、右クリックとホイールが Windows に届くことは実ホストで確認済みだが、2 本の指を同時に置く操作そのものは XCUITest（twoFingerTap、内部の event synthesizer とも）が iPhone Duo シミュレータで合成できない。
- （2026-10-07 対応済み）同じ Windows ユーザーへ 2 本つなぐとセッションを奪い合い、自動再接続で取り返し続けていた。bridge がサーバーの ErrorInfo を読んでいなかったのが原因で、今は FreeRDP の last error を常に渡し、サーバーが意図して終えた切断（引き継ぎ・切断・サインアウト・アイドル）は「切断済み」にして自動再接続しない。Windows 11 は同一ユーザーの引き継ぎを 0x5 ではなく 0x1（RPC_INITIATED_DISCONNECT）で送る。最後の画面の上に理由と「再接続」を出し、再接続は同じ接続先の新しいセッションを開く（切断済みのセッションは戻せないため。セッションメニューの「再接続」も切断済みでは何もしていなかったので同じ動作にした）。Windows 11 VM へ Duo と iPad の 2 台から同一ユーザーで接続して、奪い合いが起きないことを確認。
- （2026-10-07 対応済み）サーバーが実際に選んだ方式は bridge ABI 3 の `transport_security` で受け取り、セッションメニューの「通信の保護」に出す。
- （2026-10-07 対応済み）セッション最初の音声 packet が node 構築前に届いて捨てられていた。ring を 1 秒にして解消。
- session 切替で音声が混ざらないこと: 確認済み（2026-10-07）。実機 Windows を表示中は VM の音を再生せず（audio node も作らない）、VM に切り替えると「audio follows」が出てから再生する。
- clipboard/audio 本文が log/disk に残らないこと: 確認済み（2026-10-07）。当日のアプリのログ約 8 万行とアプリのデータ領域（Duo/iPad）に、クリップボード・入力文字・パスワードが 0 件。info レベルのログはメモリにしか残らず数分で消えるため、試験中に取るには `log stream` を使う。
- Microsoft IME の「変換=IME-オン / 無変換=IME-オフ」は `HKCU\Software\Microsoft\IME\15.0\IMEJP\MSIME` の `IsKeyAssignmentEnabled=1`、`KeyAssignmentHenkan=0`（IME-オン）、`KeyAssignmentMuhenkan=1`（IME-オフ）。設定画面で変えた差分から確認。この割当で英数/かな相当のキーが IME オフ/オンになり、連打しても切り替わらないこと（KEY-IME-01B）を確認済み。

2026-10-07 に対応済み（Windows 11 で確認）:

- 単独の Win キー: タップで Win を送りスタートが開く。長押しで one-shot（Win+E など）。
- Windows JIS の Caps キー表示を Caps に戻し、メニューで Ctrl に変えられるようにした。
- クリックボタン無しのトラックパッド。
- 拡大率: bridge ABI 3 で DesktopScaleFactor / DeviceScaleFactor を接続時と各 layout で送る。メニューの「Windows の拡大率」（既定は自動＝端末の倍率、iPhone で 300%）。
- 折り曲げたときの解像度: 「画面に合わせて変える」（既定、上半分の大きさを要求）か「変えずに縮小表示」（画面全体の大きさを要求し上半分に縮小）。
- （2026-10-08）safe area: 既定で Dynamic Island・画面の角・ホームインジケータを避けて描画し、「画面の端まで使う」で全画面に戻せる。インセットは SwiftUI の `ignoresSafeArea` 配下では 0 になるため UIKit のウィンドウから読む（`WindowSafeAreaReader`）。iPhone 17 Pro シミュレータと GNOME Remote Desktop で確認: 縦は上 62pt・下 34pt を避けて 1206x2334、横は左右 62pt・下 20pt を避けて 2250x1146、全画面で 2622x1206、デッキ表示中は上だけ避ける。
- （2026-10-08）解像度のプルダウン: 全体設定・接続先・セッションメニューに `自動` と固定サイズ 13 種。セッション中の変更は DISP でその場で反映（1920x1080 を確認）。接続先エディタが表示しない項目（初期倍率など）を保存のたびに「全体設定に従う」へ戻していた不具合もあわせて直した。メニューの「接続中の解像度変更に対応していません」が、disp チャネルが接続後に開くために誤って出ていたのを、メニュー表示時に読み直すよう直した。
- （2026-10-08）ソフトウェアキーボード表示中のポインター追従（iPhone 向け Windows App と同じ動き、既定オン）。iPhone 17 Pro シミュレータと GNOME Remote Desktop で、画面下端近くをタップしてからキーボードを出すと、その位置がキーバーの上に来るまで持ち上がることを確認。
- （2026-10-08）手元キーボード: 高さのつまみ（25〜75%）、iPad/折りたたみでのフローティング（移動・大きさ変更）、解像度の `表示中の大きさで固定`。iPhone 17 Pro と iPad Air 13 のシミュレータと GNOME Remote Desktop で確認。
- （2026-10-08）あわせて直した不具合: 拡大時に content が左上基準で置かれ、はみ出しの片側に届かず反対側は地が見えていた（中央に置いてから pan する）。サーバーから新しいフレームが来ない大きさの変化（固定解像度や DISP 非対応での回転、デッキの出し入れ）で、古い絵が引き伸ばされたまま残っていた（レイアウトのたびに描き直す）。タッチで置いたカーソルが、大きさの変化の後に古い位置（デスクトップの外）に描かれていた（送ったピクセルの位置に描く）。
- （2026-10-08）手元キーボードの左右分割（横向き、iPad/折りたたみ）と、折りたたみ端末の「横向きで折り曲げたときも手元キーボードを出す」。左右分割は iPad Air 13 シミュレータの横向きで GNOME Remote Desktop へ入力して確認（両側のスペースを含む）。iPhone Duo シミュレータ（Xcode-beta、DeviceHub でヒンジと回転を操作）で、横向きで少し折る→オンなら分割デッキが下に出て左右のページに分かれる／オフなら出ない、縦向き（ラップトップ）で折る→ヒンジの下に通常配列、を確認。折ったときに縦向きへ固定する案は、Duo ではアプリからの回転要求が拒否されるため取りやめた。
- （2026-10-08）メニューボタンの上のキーボードボタン（iOS のキーボード／手元キーボードの出し入れ）と、手元キーボードの大きさのリセット（つまみのダブルタップ、メニューの「元に戻す」）。iPhone 17 Pro シミュレータと GNOME Remote Desktop で確認。iOS のキーボードが出るとボタンがその後ろに隠れていたので、キーボードの上へ逃がすようにした。
- （2026-10-08）機能追加（その 2）。確認は iPad Air 13 / iPhone 17 Pro シミュレータと GNOME Remote Desktop（kurisu）:
  - 操作しないときのボタン: 薄くする（従来）／ほとんど見えなくする／画面の端に寄せる（残った端をタップで復帰、復帰のタップでは動作しない）。
  - ショートカット: キー＋修飾キーを 1 タップで送る（押しっぱなしを残さない）。既定は Ctrl+Alt+Delete、Ctrl+Shift+Esc、Win+R、Alt+Tab。キーバー・手元キーボード上の列（オフにできる）・セッションメニューに並び、設定とセッションメニューから編集する。
  - `.rdp` ファイル（Files/メール、一覧の読み込みボタン）と `rdp://` リンク（Microsoft 形式と `rdp://user@host:port`）。保存済みの接続先と一致すればそのまま接続し、未登録は編集画面で確認してから保存する（リンクだけで未知のホストへは接続しない）。ファイル内のセキュリティ設定は使わない。ショートカット App の「接続先に接続」（`mremote://connect?profile=`）。リンクの判定は単体試験（`OpenRequestTests`、`RDPFileTests`）。XCUITest の `open(url)` はテスト用の起動引数なしでアプリを起動し直すため、UI 試験にはしていない。ショートカット App 上での動作は未確認。
  - 外部ディスプレイ: 「デスクトップを表示」（既定。モニターの大きさでデスクトップを要求し、端末はキーボード＋トラックパッド）／「デュアルモニター」（端末を左、モニターを右にした 2 画面。DISP で 2 台のレイアウトを送る）／「ミラーリング」。シミュレータでは外部ディスプレイをつなげないため、DEBUG の起動引数 `-mremote-fake-external-display` で 1280x720 の代わりのモニターを画面の隅に描いて確認した: デスクトップ表示で 1280x720 に変わりトラックパッドでポインターが動く、デュアルモニターで GNOME が 2048x1366 + 1280x720（3328x1366）を受け入れ、ログイン後のデスクトップが 2 画面に広がり、ポインターがモニター側へ移る。実機のモニター（シーンの受け渡し、ミラーリングへの戻り）は未確認。
  - タッチとペン（bridge ABI 4、RDPEI）: 画面のタッチに「Windows のタッチとして送る」を追加。Apple Pencil は筆圧・傾き・回転付きのペンとして送る（iPad、既定オン）。GNOME Remote Desktop で rdpei が接続し、タッチでファイルを選択できた。Windows 11 Pro VM でも rdpei が接続し、ポインターの種類を記録する WinForms ウィンドウ（`GetPointerType`）でタップ・ドラッグが PT_TOUCH の down/up として届くことを確認した（Windows が左クリックへの変換も行う）。ペンはシミュレータで Apple Pencil を合成できないため未確認（実機 iPad で確かめる）。
  - RD ゲートウェイ（ABI 4）: 接続先ごとに設定（HTTPS、だめなら RPC。接続先と同じユーザーか、ゲートウェイ専用のユーザー/パスワード（Keychain））。ゲートウェイの証明書はゲートウェイの名前で確認・保存する。`.rdp` のゲートウェイ指定も読む。手元にゲートウェイが無く、実接続は未確認（bridge の契約試験と単体試験のみ）。
  - フォルダの共有（ABI 4、rdpdr の drive）: このアプリのフォルダ（ファイル App の「mRemote」）か、選んだフォルダ（ブックマーク、接続中だけ開く）を名前付きドライブとして共有。GNOME Remote Desktop は rdpdr はつながるがドライブを受け取らない。Windows 11 Pro VM で「このアプリのフォルダ」を共有し、RDP セッション内（`schtasks /IT`）から `\\tsclient\<ドライブ名>` の一覧・読み込み・書き込みができ、Windows が書いたファイルが端末側のフォルダに届くことを確認した。選んだフォルダ（ブックマーク）の共有は実機で確かめる。
  - FreeRDP を rdpei と drive 入りで作り直した（`scripts/build-freerdp-xcframework.sh`）。bridge の契約試験 8 本（ABI 4 を含む）は通常・AddressSanitizer とも通過。
- （2026-10-08）機能追加（その 3）。確認は iPad Air 13 シミュレータと Windows 11 Pro VM（ARM64、UTM）:
  - Wake-on-LAN: 接続先ごとに MAC アドレス・送り先（既定はブロードキャスト 255.255.255.255:9、ルーターやリレーのアドレスも可）・「接続の前に起こす」。マジックパケットを 200 ms おきに 3 回送り、RDP のポートが応答するまで最大 2 分待ってから接続する。一覧のスワイプ「起動」でも送れる。送信はループバックの単体試験（`WakeOnLANSenderTests`）のみで、実際に PC を起こすことは未確認。実機の iPhone/iPad からブロードキャストを送るには Apple のマルチキャスト通信の entitlement（`com.apple.developer.networking.multicast`）が要る。無い場合はルーターやリレー宛てのユニキャストだけが届く。
  - 一覧のグループ・お気に入り・検索: 接続先にグループ名とお気に入りを持たせ、一覧を「お気に入り」→グループごと→その他に分け、名前・ホスト・グループで絞り込む。UI 試験で確認。
  - サムネイル: セッションスイッチャーと一覧の実行中の行に、各セッションの最後の画面を小さく出す。
  - iPad の複数ウィンドウ: 一覧の長押しメニュー「新しいウィンドウで接続」で、セッションごとに別のウィンドウ（Stage Manager / Split View）を開く。復元したウィンドウの接続先が消えていれば一覧を出す。UI 試験で確認。
  - クリップボードの画像とファイル（bridge ABI 5）: 画像は PNG と DIB、ファイルは FileGroupDescriptorW と FILECONTENTS（1 MB ずつ）。セッションメニューから「画像を貼り付け」「ファイルを貼り付けで送る…」「リモートの画像を端末へコピー」「リモートでコピーしたファイルを保存」（ファイル App の「mRemote › 受信」）。Windows VM で、Windows でコピーした 90x60 の画像を端末へ取り込んで Windows へ戻す往復、Windows でコピーした 2 ファイルの受信（内容一致）、端末のファイルをエクスプローラーへ貼り付け（内容一致）を確認。送ったあとの自動 Ctrl+V は、Windows でフォーカスのあるウィンドウにだけ届く。
  - マイク（ABI 5、audin）: 接続先の「マイクを使う」（既定オフ）。Windows 側のアプリが録音を始めたときだけ AVAudioEngine で録り、サーバーが選んだ形式の 16 bit PCM にして送る。録音中は音声セッションを play-and-record に切り替え、メニューに「マイクを使用中」を出す。シミュレータでは macOS が Simulator のマイク利用を尋ねるダイアログで止まり、実際の録音は未確認。
  - Apple Pencil のホバー: ペン先が画面から浮いているあいだ、位置と傾きをペンのホバー（接触なし）として送る。シミュレータでは Apple Pencil を合成できず未確認。
  - H.264（ABI 5）: 接続先の「H.264 で画面を受け取る」（既定オン）。AVC420 / AVC444 / AVC444v2 の surface command を bridge が受け取り、VideoToolbox で 1 本目のストリームを 4:2:0 として復号する。Windows は 10.x の GFX capability でしか AVC を使わない（8.1 の AVC420 は使わなかった）。Windows VM で capability 10.7 が選ばれ、AVC444v2 のフレームが復号・表示されることを確認（VM 側で AVC444 を優先するグループポリシー `AVC444ModePreferred` を一時的に設定し、確認後に消した）。
  - RemoteApp（ABI 5、RAIL）: 接続先にプログラムと引数（`.rdp` の `remoteapplicationprogram` / `remoteapplicationcmdline` も読む）。サーバーの RAIL handshake には FreeRDP の既定の応答（クライアントの handshake）を返し、サーバーが既存のウィンドウを送り終えた（デスクトップの ARC_COMPLETED）ところでプログラムを起動する。Windows 11 はウィンドウを 1 枚ずつの GFX surface（MapSurfaceToWindow）で送るので、ウィンドウ情報の order にある位置・表示状態・重なり順に従って、デスクトップの画面の上に並べて描く（ウィンドウのない所は黒）。Windows VM（`TSAppAllowList\fDisabledAllowList` を一時的に 1 にし、確認後に 0 へ戻した）で `charmap.exe` が開き、文字の選択と「選択」ボタンのクリックが届くことを確認。RemoteApp では H.264 を使わない: AVC で送られたウィンドウが届き始めて数秒後に、Windows が GFX のエラー（0x80070057）で接続を切った。`notepad.exe` はストア版のメモ帳に置き換わり、ウィンドウが出ないまま約 30 秒後にサインアウトされた。ウィンドウの影や半透明は扱わない（不透明として描く）。タイトルバーのドラッグでの移動（RAIL の local move/size）は未対応。
  - FreeRDP を AUDIN と RAIL 入り、`WITH_GFX_H264` で作り直した。bridge の契約試験と H.264 復号試験の 10 本は通常・AddressSanitizer とも通過。
- 音声: 実ホストの音で落ちていた render block の isolation を修正。
- アクセシビリティ監査（`AppUITests/AccessibilityAuditUITests.swift`、約 1 分）: 一覧・編集・設定・ヘルプ・セッション・セッションメニュー・手元キーボードに Xcode の監査をかけ、通過。デッキのキー表示を Dynamic Type に追従させた（キーの大きさは変わらないので、拡大は元の大きさまで。上限なしにすると見切れる）。受け入れた指摘はテスト内の `knownIssues` に理由付きで残す: リモート画面のコントラスト/見切れ、ナビゲーションバーのキャンセル、キー表示、ヘルプの行（監査がその場で文字を大きくするため画面下に押し出された行が「一部未対応」になる。最大サイズで折り返して表示されることを目視で確認済み）。
- エラー文言: 接続とクリップボードの失敗を「何が起きたか＋何を確かめるか」に書き直した。バックエンドの英語の詳細は末尾の括弧に残す。
- 予約ショートカットとバックグラウンドの制約: [help-limitations.md](help-limitations.md) と、設定の「ヘルプ > 送れないキーとバックグラウンド」。予約ショートカットの表は iPadOS の既定割当に基づくもので、実機での取得可否の記録（KEY-RESERVED-01）は未了。

## 9. Phase 7 — リリース仕上げ

- accessibility、String Catalog、日本語/英語文言（2026-10-07: `App/Localizable.xcstrings` を追加。開発言語は日本語のまま、画面の文言 271 件に英訳。`String` で組み立てる文言は `String(localized:)` にした。手元キーボードのキー表示（半/全・無変換など）は物理キーの刻印に合わせて訳さない。ログ用の文字列は対象外。コマンドラインのビルドはカタログへキーを足さないので、`tools/l10n/missing-keys.py <DerivedData>/Build/Intermediates.noindex` で漏れを確認する。英訳はネイティブ確認前）
- エラー/help、予約 shortcut と background 制約の説明（文言と help 画面は 2026-10-07 に用意し、同日 String Catalog で英訳。予約 shortcut の実機記録が残り。`docs/help-limitations.md` は日本語のみ）
- performance/energy/thermal tuning、network condition test
- security review、fuzz/negative test、privacy manifest/用途説明
- dependency vulnerability/license/SBOM、暗号輸出申告
- TestFlight 実機 matrix、crash/metric triage
- release gate と既知制約の承認

## 10. Phase 8 — SSH 拡張（将来）

RDP v1 の後、次を新規 module として追加する。詳細設計と段階（8.0〜8.5）は [ssh-design.md](ssh-design.md)。

状況（2026-10-17）: 8.0〜8.4 とローカルポートフォワードを実装済み（ブランチ feature/ssh-design）。試験の記録は ssh-design.md §15。

- `SSHConfiguration` と credential/host key trust
- `SSHRemoteSession`（接続 lifecycle/state/event）
- terminal presentation、PTY size、terminal keyboard mapping
- protocol-specific 接続 form section

再利用するもの:

- profile list/CRUD、Keychain、session manager/switcher
- global navigation、error/log infrastructure
- focus と複数 session の policy

再利用しないもの:

- RDP scan code mapping、pointer、Metal bitmap renderer
- `rdpsnd`/`cliprdr` channel（SSH terminal の clipboard は別 adapter）

## 11. Risk register

| Risk | 影響 | 早期検出/対策 |
|---|---|---|
| FreeRDP の iOS build/静的 add-in が版依存 | 必須 channel が動かない | Phase 0 で版固定前に SVC/DVC negotiation とデータ往復、bridge に版差を隔離 |
| 英数 key-up/keyboard 個体差 | IME key が押下残り/非対応 | KeyEcho と実機 matrix、usage ごとの固定 source policy、releaseAll |
| iPadOS 予約 shortcut | Windows 操作の一部が送れない | 実測した compatibility 表と virtual key bar |
| 4K×複数 session の memory | jetsam | dirty region、buffer 数制御、非表示 texture 解放、実測後 guidance |
| rdpsnd backend/codec | 音切れ・工数増 | Phase 0 で PCM-only device callback/wave confirm、Phase 5 で SPSC ring |
| pasteboard permission | UX 悪化 | 常時 read をせず user-initiated control、direction setting |
| background suspension | 接続が切れる | 維持を保証せず復帰検査/再接続。UI に明記 |
| C callback/challenge teardown race | crash/use-after-free/deadlock | callback data の即時 copy、opaque bridge、generation、全終了経路で wait を wake、idempotent stop、sanitizer stress test |
| license/codec 条件 | App Store 配布不可 | 最小 dependency、SBOM、codec 追加を release gate 化 |

## 12. 実装開始前に確定する既定値

回答がなくても次の仮定で Phase 0 を開始できる。

| 論点 | 現在の仮定 |
|---|---|
| 最低 OS | iPadOS/iOS 17.0 |
| 配布 | App Store |
| 音声 | remote playback のみ。microphone なし |
| clipboard | 明示操作の bidirectional `CF_UNICODETEXT`。自動監視、画像/ファイルなし |
| multi-session | 前景中 2 session 必須、3 session 目標。background 維持保証なし |
| RD Gateway/RemoteApp | v1 MVP 外 |
| local IME mode | 確定文字を Unicode keyboard event、不成立文字を明示 paste。host IME OFF を案内 |

方針が異なる場合、影響が大きいのは音声入力、RD Gateway、最低 OS、clipboard file transfer の四点である。
