# テスト計画

## 1. 方針

本計画の規模は `README.md` の「開発体制と試験スケール」に従う。個人開発なので、手元にある
1 構成での確認と自動テストで実用上の品質を担保し、持っていない機種/周辺機器は「未検証」と
明示して保証しない。以下のマトリクスは「いつか揃えたら確認する軸」の一覧であり、
release の必須条件ではない。

RDP server だけを観察して不具合箇所を推測せず、次の境界ごとに検証する。

1. Apple event → 正規化 input
2. 正規化 input → RDP scan code/pointer PDU
3. FreeRDP callback → frame/audio/clipboard adapter
4. session state → UI
5. 実機 → 実 Windows server の end-to-end

特に英数/かなは、「画面上で IME が切り替わった」だけでなく、クライアントでの HID event 数と Windows 側で受信した scan code/down/up を突き合わせる。

## 2. 自動テスト構成

### 2.1 Unit test

| 対象 | 主なケース |
|---|---|
| `KeyboardLayoutMapper` | HID→Set 1、extended flag、英数→`0x7B`、かな→`0x79`、未知 usage |
| `KeyboardSourcePolicy` | usage ごとの固定 UIKit/GC/unsupported、neutral 境界だけでの切替、選択外 source の破棄 |
| `KeyboardEventArbiter` | 遅延 GC、重複 down/up、cancel、stale focus generation、releaseAll、orphan event |
| input queue | high-water、down 用 up-slot 予約、pointer coalesce、saturation 時 gate/recovery、up 非欠落 |
| modifier state | 左右 modifier、one-shot/lock、focus 喪失時の一括解放 |
| `ViewportTransform` | Fit/100%/zoom/pan/letterbox、回転、境界 clamp、Retina scale に非依存 |
| `ScrollAccumulator` | 小数 delta、正負、縦横、反転、上限分割、端数保持 |
| `SessionStateMachine` | 正常接続、challenge、cancel、再接続、二重 disconnect、stale callback |
| `EffectiveProfileResolver` | global 継承、個別上書き、schema default、migration |
| `ClipboardCoordinator` | Unicode、方向 policy、hash loop、session isolation、size limit |
| trust policy | host/port/fingerprint scope、期限、fingerprint 変更、今回のみ信頼 |
| error mapper | FreeRDP/native code から安定した UI error category への変換 |

table-driven test data に通常 US/JIS キーと左右修飾/extended key を含め、scan code の golden file は根拠と review owner を明記する。

### 2.2 Component/integration test

FreeRDP の代わりに `FakeRemoteSession` を使い、SwiftUI/UIkit を以下のシナリオで test する。

- 接続中→challenge→接続済み→再接続→切断
- 一覧へ戻っても session 維持、明示切断だけで終了
- 2 session 必須、3 session 目標の focus 切替と入力/音声/clipboard isolation
- 複数 session の challenge queue、回答 ID/generation、cancel/timeout
- フローティングメニュー開閉で `releaseAll` と first responder 復帰
- profile 編集の即時/次回接続反映
- VoiceOver label、Dynamic Type、iPhone/iPad adaptive sheet

FreeRDP bridge には C test harness を作る。

- create/run/stop/destroy の繰り返しと二重 stop
- callback buffer の stride/length/rectangle validation
- connect cancel と証明書 challenge timeout
- SVC/DVC add-in の build-time 登録、capability negotiation、実データ往復
- 可変 FreeRDP surface と renderer buffer の分離、frame signal coalesce/full-damage fallback
- malformed/oversize clipboard/audio data
- callback 中の teardown と late callback 抑止

Address Sanitizer、Thread Sanitizer（対応範囲）、Undefined Behavior Sanitizer を CI/Simulator harness で定期実行する。

### 2.3 UI test

- 初回空状態→追加→保存→接続
- 入力 validation と未保存変更の破棄確認
- 実行中セッション表示、切替、一覧復帰、切断確認
- 資格情報 challenge、証明書初回/変更警告
- global 設定と profile override
- app inactive 時の privacy cover

OS の Local Network/paste 許可 prompt は test plan を分離し、既許可状態だけの UI test で見逃さない。

## 3. 実機/周辺機器マトリクス

### 3.1 実際に検証する構成（基準構成）

現時点で手元にあるのは次の 1 構成だけであり、これが唯一の「検証済み」構成である。

| 軸 | 構成 |
|---|---|
| 端末 | iPad mini (第 7 世代) |
| キーボード | Apple Magic Keyboard (JIS) |
| pointer | 入手でき次第追加。未入手のうちは pointer 系ケースを `未検証` とする |
| 接続先 | 手元の Windows 11 一台 |

Phase 0 の基準環境には端末型番、OS version/build、keyboard 型番/接続方式、関連する iPadOS
設定を記録する。他の構成で動く保証はしない。不具合報告を受けたら、その構成を下の表へ
追加してから対応する。

### 3.2 将来スケールを上げる場合の軸

機材が増えた、または不具合報告が来たときに、次の軸から必要なものだけを 3.1 へ移す。
最初から全部を埋めることは目指さない。

| 軸 | 構成 |
|---|---|
| OS | 最低対応版、最新対応版、次版 beta は互換性確認のみ |
| 端末 | iPad Pro/Air の代表 2 世代、memory の少ない対応 iPad、代表 iPhone |
| Apple JIS | iPad 用 Magic Keyboard (Smart Connector)、Magic Keyboard JIS (Bluetooth) |
| PC JIS | USB-C/adapter 接続 106/109、Bluetooth 106/109 |
| pointer | Magic Mouse/一般 BT mouse、Magic Trackpad/keyboard trackpad、USB mouse |
| 表示形態 | full screen、Split View/Stage Manager 対応端末、縦/横回転 |
| 設定 | iPadOS hardware keyboard 配列、Caps Lock 入力ソース切替、Globe 割当、Full Keyboard Access ON/OFF、modifier 入替あり/なし |

Phase 0 の基準環境には端末型番、OS version/build、keyboard 型番/firmware/接続方式、上記 iPadOS 設定、Stage Manager/Split View 状態を記録する。

Simulator はロジック/UI test には使うが、英数/かな、GCKeyboard、mouse hardware、audio route、性能の合否には使わない。

## 4. RDP server マトリクス

検証対象は手元の Windows 11 一台である。以下は同様に「機会があれば確認する軸」であり、
未確認のものは release note で未検証と明示する。

- サポート対象の Windows client Pro/Enterprise の最低版と最新更新版
- サポート対象の Windows Server の最低版と最新更新版
- 日本語 106/109 keyboard layout と US layout
- NLA 必須、system CA certificate、private CA、自己署名
- LAN、高遅延/VPN、IPv4/IPv6/DNS
- console resolution、1080p、1440p、4K、動的 resize 対応/非対応
- audio 有効/無効、clipboard policy 有効/無効

Windows 10 等、サポート終了 OS を互換対象にするかは product policy として別途決定し、対象に含める場合だけ matrix へ追加する。

## 5. 入力の重点試験

### 5.1 Windows 側観測ツール

テスト専用 `KeyEcho` を用意し、Windows low-level keyboard event の scan code、VK、extended、down/up、timestamp を表示/JSON 出力する。scan code 列自体から文字を推測できるため、合成した試験列だけを入力する隔離環境で使い、通常業務環境へ配布せず、結果は試験完了後に削除する。

クライアント側 input diagnostics の `eventID`/timestamp と組み合わせ、次を機械比較する。

```text
1 physical press
  = 1 normalized down + 1 normalized up
  = 1 expected remote scan-code down + 1 expected up
```

### 5.2 必須ケース

| ID | 操作 | 期待結果 |
|---|---|---|
| KEY-EISU-01 | 英数を単押し×100 | 各回 `0x7B` down/up が 1 組、二重/欠落/押下残りなし |
| KEY-KANA-01 | かなを単押し×100 | 各回 `0x79` down/up が 1 組、二重/欠落/押下残りなし |
| KEY-IME-01 | Windows `KeyEcho` で英数/かな | `0x7B`→`VK_NONCONVERT`、`0x79`→`VK_CONVERT` と各 down/up を確認 |
| KEY-IME-01B | 文書化した Microsoft IME 割当で英数/かな交互 | host IME が期待状態になり、iPadOS の候補/文字が混入しない |
| KEY-IME-02 | 対象 press を消費し `super.presses*` を呼ばない | iPadOS の入力ソース切替/IME UI が起動せず、remote だけが受信する |
| KEY-DUP-01 | UIKit+GC 両方が発火 | policy で選んだ一方だけを使い remote は 1 組だけ受信 |
| KEY-DUP-02 | UIKit up の後に同 usage の遅延 GC down/up | UIKit policy では GC を全て破棄し ghost down を送らない |
| KEY-SOURCE-01 | key 保持中に source policy/focus 切替 | neutral まで新 source/session へ orphan event を送らない |
| KEY-QUARANTINE-01 | key 保持中にメニューを開き、メニュー中に解放 | GC physical state の up で隔離解除し、remote/次 session へ漏らさない |
| KEY-FAST-01 | 高速交互/同キー連打 | event order が保たれ、隣接 press が重複扱いされない |
| KEY-HOLD-01 | 文字/矢印を長押し | client 生成の repeat で down が連送され、key-up は解放時の一回だけ |
| KEY-HOLD-02 | 長押し中に別の文字キーを押し、先に離す | repeat が新しいキーへ移り、解放後は保持中のキーへ戻る |
| KEY-HOLD-03 | 長押し中に background/メニュー/切断 | repeat が即時停止し、押下残りも余分な down もない |
| KEY-HOLD-04 | 英数/かな/修飾キーを長押し | repeat せず down/up が各一組のまま |
| KEY-HOLD-05 | key repeat を Off にして長押し | down/up が各一組で、保持中に Off にしても解放は一回だけ |
| KEY-CHORD-01 | Ctrl/Alt/Shift を含む組合せ | 左右/extended を含め順序と解放が正しい |
| KEY-FOCUS-01 | modifier 押下中にメニュー/切替 | local state は即時 clear、writable な旧 session へ up を enqueue、他 session へ漏れなし |
| KEY-LIFE-01 | 押下中に background/keyboard 切断 | 復帰後に押下残りなし |
| KEY-RESERVED-01 | iPadOS 予約 shortcut | 取得可否を記録し、取得不可操作に UI 代替がある（2026-10-07: UI 代替とヘルプは用意済み、取得可否の実機記録は未実施） |
| KEY-PCJIS-01 | PC JIS の変換/無変換/かな/半角全角 | HID usage と Windows scan code/IME 動作を記録し、候補 mapping を確定 |
| KEY-LAYOUT-01 | 接続時の Client Core Data を trace | `keyboardLayout=0x00000411`、type `7` と関連 subtype/function-key field を確認 |

KeyProbe の既存スクリーンショットは実現可能性の証拠であり、製品版の regression test の代用にはしない。

## 6. マウス/トラックパッド試験

- display 四隅/中央への移動と Windows 側座標の一致
- Fit の letterbox、100%、2× zoom/pan、回転/resize 後の座標
- 左/右 click 各 20 回、double click、左右 drag、button 押下中の移動
- button 押下中のメニュー/切替/background で release
- 低速/高速の縦横 scroll、trackpad continuous delta、mouse discrete wheel
- 反転 OFF/ON がちょうど一度適用され、再起動/個別上書き後も保持
- pointer と touch を交互に使っても gesture state が残らない

## 7. 描画・性能試験

計測値:

- connection time（DNS/TCP/TLS/NLA/desktop ready の区間別）
- decode、surface copy、Metal upload/present の時間
- received update と presented frame、dropped/coalesced presentation 数
- input 受信→send queue の latency
- CPU、resident memory、thermal state、energy、network bytes

シナリオ:

1. 1080p の通常操作 30 分
2. 4K の動画/スクロール 15 分
3. resize/回転 20 回
4. 3×1080p session を 30 分維持し、5 秒ごとに切替
5. memory warning を模擬し、非表示 texture/cache が減ることを確認
6. 低帯域、高遅延、packet loss、network 切替で再接続
7. renderer が遅い状態で frame notification を連続し、queue が増えず最新完全状態へ追従
8. 全 frame slot を lease 中に最終更新が来て server が静止し、slot 返却後に最終画面が反映

初期 gate は、UI hang/watchdog/クラッシュ/jetsam がなく、input queue p95 が 16 ms 以下であること。frame rate と memory 上限は FreeRDP スパイクの baseline 測定後に端末 class ごとに確定する。

## 8. 音声試験

Windows 側で既知周波数/timestamp の test tone を再生し、次を測る。

- 44.1/48 kHz、mono/stereo の再生
- PCM だけを advertise し、server が非対応形式だけを提示した場合は安全に音声無効化
- `FormatSupported/Open/SetFormat/Play/Close/Free`、wave confirm、block alignment/timestamp
- 長時間での buffer drift、underflow/overflow、音切れ、遅延
- speaker、Bluetooth headset、有線/USB audio の route change
- Siri/電話等の interruption 後の再開
- session 切替時に旧 session が mute され、混音/click noise がない
- 非 focused session の PCM が蓄積せず、focus 後に古い backlog を再生しない
- remote audio 無効、端末音量 0、server 側 channel 拒否の UI

録音 permission が要求されないことも確認する。

## 9. クリップボード試験

- ASCII、日本語、絵文字、結合文字、改行、空文字
- Windows CRLF と Swift `String` の変換
- NUL 終端 UTF-16LE、surrogate pair、embedded NUL 拒否
- format-list/request/response の順序、切断後の late response/generation 破棄
- local→remote、remote→local、双方向/片方向/無効 policy
- 連続して同じ内容、異なる内容、2 session 必須/3 session 目標の切替時 isolation
- size limit 直前/超過、invalid UTF-16、timeout、server channel 無効
- paste permission の初回/拒否/許可後の UX
- 本文が OSLog、profile store、diagnostic export に含まれないこと

## 10. ソフトウェアキーボード試験

| ID | 操作 | 期待結果 |
|---|---|---|
| SFT-POC-01 | ASCII capable proxy を日本語入力環境で表示 | host IME mode で local 日本語 IME/marked text が起動しないことを実機確認 |
| SFT-LOCAL-01 | local IME で変換/確定/キャンセル | 未確定文字は remote へ送らず、確定 UTF-16 を一度だけ送る |
| SFT-UNICODE-01 | BMP、surrogate pair、絵文字を対象 app 群へ入力 | 対応範囲を記録し、不成立文字は明示 clipboard paste に fallback |
| SFT-REMOTE-01 | host IME mode の ASCII と変換/無変換 | scan code down/up と host IME 動作が正しい |
| SFT-MOD-01 | 両モードの Ctrl/Alt/Shift/Win one-shot/lock | 状態表示、順序、解放が正しく、marked text 中は先に確定/取消を求める |
| SFT-SWITCH-01 | composition 中の mode/session 切替 | stale callback、未確定文字、modifier が次 mode/session へ漏れない |

`SFT-POC-01` を含むソフトウェアキーボード試験は Phase 6 の gate とする。

## 11. セキュリティ試験

- 正常な public/private CA、自己署名、期限切れ、hostname mismatch
- IP literal 宛の name 未検証（`今回のみ信頼` を出す）と、その状態でも期限切れ/署名不正は hard reject のままであること
- 拒否/警告のたびに evidence へ `stage=` が残り、`presented-chain` は hard reject、`server-purpose` は警告付き `今回のみ信頼`、`hostname-binding` は hard reject になること
- 同一証明書を重複提示する server（gnome-remote-desktop）で単一提示と同じ判定になり、evidence に `repeated-chain-entries` が残ること
- certificate callback の leaf/chain DER copy と `SecTrust` SSL hostname policy、OpenSSL known-hosts 非併用
- certificate challenge 中の cancel/timeout/background/disconnect が worker wait を解除し、callback memory の保持や stale 回答がないこと
- 保存 fingerprint 一致/変更、host/port 違い、今回のみ信頼
- NLA failure と account lockout を避ける retry 上限
- legacy security が暗黙 fallback しないこと
- app container dump に password/clipboard/frame がないこと
- Keychain item の accessibility と profile 削除時の参照整理
- malformed PDU/channel payload に対する bridge validation/fuzz test
- inactive 直後の app switcher snapshot が privacy cover であること
- Release binary の linked library、architecture、private API、license/SBOM 検査

## 12. ライフサイクル/障害試験

- connecting、challenge、connected の各状態で cancel
- Wi-Fi OFF/ON、Wi-Fi↔cellular、VPN 接続/切断、server reboot
- foreground↔background、画面 lock、長時間 suspend 後の復帰
- session 接続/切断を 20 回繰り返す
- 同時に複数 session が失敗しても UI が操作可能
- native callback と disconnect が競合しても use-after-free/二重解放がない
- OS memory warning/thermal state で縮退し、秘密データを disk spill しない
- 同時に複数 connect を開始しても resource reservation が上限を超えず、失敗/cancel 後に予約が解放される
- lock 後の foreground では protected data/Keychain が利用可能になるまで再接続せず、同じ session の再接続を重複起動しない

## 13. リリース gate

- Must 要件に対応する自動/手動 test case がすべて trace されている。
- Must 要件に対応する自動 test が緑で、手動確認が必要なものは基準構成で一度は通っている。
- 基準構成（3.1）で KEY 必須ケースが合格する。他のキーボードは未検証と明記する。
- 手元の Windows 11 への NLA/TLS 接続、証明書確認、1080p 描画が合格する。
- 2 session 同時接続、音声、text clipboard、pointer が実機で合格する。3 session は測れた範囲を記録する。
- crash、hang、credential leak、silent certificate acceptance の既知 blocker がない。
- dependency pin、license notice、SBOM、暗号輸出回答、privacy manifest/用途説明を確認する。App Store 提出に必須なので、ここは規模を下げない。
- 未検証の機種/キーボード/Windows 版と、iOS 予約 shortcut の制約を release note/help に明記する。

## 14. Windows で残っている確認（2026-10-09 時点）

UTM の Windows 11 ARM VM では次が決着しなかった。実機の Windows で確認する。

- iPad を縦向きにして DISP で 2048x2692 へリサイズした直後、Windows 側からセッションが切断された（2 回）。横向きでは安定。標準接続の経路は今回変えていないが、変更前のビルドでの比較は未実施。
- mstsc → macos-rdp-server（サーバー側の残課題。macos-rdp-server の docs/TESTING.md「Known issues」7 を参照）。
- 2026-10-10 に UTM の Windows 11 ARM VM（Edge）で確認済み: 1 本指のなぞりがタッチのパン（文字が選択されずにスクロール）、tap、同時に触れた 2 本指 tap の右 click メニュー（下のリンクは開かない）、2 本指スクロール（指の位置で、指と同じ向き）、保存済みの旧「Windows のタッチとして送る」が「タッチした場所を操作」として読まれること。2 本指は `LiveRDPUITests` の `fingers`（XCTest のイベント合成）で、XCUIElement の twoFingerTap は desktop surface に届かない。未確認（実機で）: 0.1 秒より遅れた 2 本目（送ったタッチの cancel）、トラックパッドの tap→ドラッグ（XCUI では tap と次のタッチの間が 0.36 秒空き、0.25 秒に収まらない）。
- 「タッチした場所を操作」で Windows に 1 本指がタッチとして届くこと（RDPEI が開いた後）。tap でクリック、長押しで右クリック、なぞると Edge やエクスプローラーでスクロール、テキストで選択。2 本目の指で送ったタッチが取り消され（誤タップにならない）、2 本指スクロール・2 本指タップの右クリック・ピンチの手元拡大になること。GNOME でも同様にタッチとして届くこと。ログイン画面（RDPEI 前）ではマウス扱いのまま操作できること。
- トラックパッド（画面全体・デッキのパッド）: タップ→すぐ触れて動かすとドラッグ（エクスプローラーのファイルが開かずに動く、ウィンドウのタイトルバーで移動）。2 回タップでダブルクリック。1 回タップのクリックが 0.25 秒遅れて届くことの体感。

## 15. UI test の既知の失敗（2026-10-19 時点）

Xcode 27.1 / iOS 27.1 シミュレータ（iPhone Duo、iPad Pro 11-inch (M5)、iPhone 18 Pro）で、次は当面直さずに残している。

- `AccessibilityAuditUITests.testEveryScreenPassesTheAudit`: 全機種で失敗する。指摘はコントラスト（failed / nearly passed）、Dynamic Type 非対応・一部非対応、Text clipped で、システム標準の部品に出ている。Xcode 27.1 にしてから出始めた。iPhone Duo の PC キーボードのキーが hit region の最小値を下回るのは `laptop-key-*` として既知扱いにしてある。
- `ConnectionFlowUITests.testAddingAProfileFromTheList`（iPad のみ）: 直前の `testAConnectionOpensInItsOwnWindow` で開いたセッションのウィンドウが残り、一覧の操作が届かず失敗する。
- 実行の注意:
  - iOS 27.1 ではシートが出るときの layer animation の 1 つが終了を通知しないことがあり、XCTest が操作ごとに 60 秒 ×2 待つ。`-mremote-ui-testing-without-animations` で UIKit のアニメーションを止めて避けている（接続フローと監査のテスト）。キーボードのテストはアニメーションを止めると SwiftUI がフローティングボタンの位置を XCTest に遅れて伝えるので止めない。
  - テストが 1 つでも失敗すると xcodebuild が `simctl diagnose` を最大 10 分走らせる。`-collect-test-diagnostics never` を付ける。
