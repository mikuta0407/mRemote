# mRemote 設計ドキュメント

## 目的

mRemote は、iPadOS/iOS から Windows へ接続する RDP クライアントである。特に、JIS 物理キーボードの「英数」「かな」を iPadOS の IME 切替に消費させず、Windows 側へそれぞれ「無変換」「変換」として送れることを主要な価値とする。

本文書群は基本設計である。実行可能な Phase 0 スパイク、再現手順、現在の Gate 状態は
[`phase0/README.md`](../phase0/README.md) を入口とする。MVP は Swift 製のネイティブ UI と FreeRDP 系ネイティブコアを組み合わせ、複数 RDP セッション、マウス、リモート音声再生、双方向テキストクリップボードを提供する。将来の SSH 追加を、画面や永続化層の作り直しなしに行える境界を設ける。

## 開発体制と試験スケール

本プロジェクトは個人開発である。開発者は一人、実機は iPad mini (第 7 世代) と Apple Magic
Keyboard、接続先は手元の Windows 11 が一台である。App Store での公開は予定しているが、
社内配布や商用サポートの体制はない。

文書は設計判断の根拠を残すために詳しく書くが、**検証の規模は上記の実態に合わせる**。具体的には:

| 項目 | 本プロジェクトの方針 |
|---|---|
| 反復試験の回数 | 各 10 回程度。回数を増やすより、失敗時に原因が特定できる記録を残すことを優先する |
| 端末マトリクス | 手元の 1 構成のみ。他機種は「未検証」と明示し、保証しない |
| レビュー/承認 | reviewer と operator は同一人物。承認プロセスではなく、後から自分が再現できる記録として書く |
| 自動テスト | ロジック層（入力調停、scan code、証明書評価、状態機械）は自動テストで担保する。ここは回数を惜しまない |
| 実機試験 | 自動化できない部分（IME UI の非表示、実 Windows との往復、音声、性能）に限定する |
| 性能目標値 | SLA ではなく、退行に気付くための目安とする |

「100 回」「全端末マトリクス」といった商用規模の記述は、この方針に沿って各文書で
現実的な回数へ置き換えてある。将来スケールを上げる場合はこの表を先に更新する。

## 文書一覧

| 文書 | 内容 |
|---|---|
| [requirements.md](requirements.md) | スコープ、要件、受入条件、前提 |
| [architecture.md](architecture.md) | モジュール構成、FreeRDP 境界、並行処理、ライフサイクル |
| [input-design.md](input-design.md) | 物理/ソフトキーボード、マウス、HID-to-RDP 変換 |
| [ui-flow.md](ui-flow.md) | 画面遷移、接続設定、セッション操作 |
| [data-and-security.md](data-and-security.md) | データモデル、認証情報、証明書、プライバシー |
| [test-plan.md](test-plan.md) | テスト戦略、端末マトリクス、受入試験 |
| [traceability.md](traceability.md) | 要件 ID と設計・テスト・実装 phase の対応 |
| [ssh-design.md](ssh-design.md) | Phase 8 の SSH クライアント設計（設計案） |
| [roadmap.md](roadmap.md) | スパイクからリリースまでの段階計画 |
| [help-limitations.md](help-limitations.md) | 利用者向けヘルプ原稿: 送れないキー、バックグラウンドの制約、Windows IME の設定 |

## 現時点の主要決定

| 項目 | 決定 |
|---|---|
| 対応 OS | iPadOS/iOS 17.0 以上を初期基準とする。引き下げは FreeRDP PoC 後に判断する |
| UI | SwiftUI をアプリシェルに使い、RDP 描画・低レベル入力面は UIKit/Metal で実装する |
| RDP コア | FreeRDP を固定バージョンでソースビルドし、静的リンクした XCFramework と C ABI の薄いアダプターで隔離する |
| 描画 | FreeRDP の可変 surface から描画側所有の BGRA buffer へ更新矩形をコピーし、Metal へ部分更新する。メインスレッドでデコードしない |
| 物理キー | usage ごとに `UIResponder.presses*` または検証済み `GCKeyboard` の一方を固定選択し、HID usage を RDP scan code に変換する |
| 英数/かな | LANG2 `0x91` を Windows の無変換、LANG1 `0x90` を変換へ意味変換する |
| ローカル IME | 物理キーボード利用中の RDP 描画面は `UIKeyInput`/`UITextInput` を実装せず、iPadOS IME を介さない |
| 複数接続 | 1 セッションにつき 1 接続ワーカーを持ち、画面から離れても明示切断までは前景で接続を維持する |
| 音声 | MVP はリモートから端末への再生 (`rdpsnd`)。マイク入力 (`audin`) は対象外 |
| クリップボード | MVP は `CF_UNICODETEXT` の明示操作による双方向転送。自動監視、画像・ファイル転送は対象外 |
| バックグラウンド | iOS の任意時間実行は前提にしない。復帰時に状態確認し、切断済みなら再接続を案内する |

## KeyProbe による確認済み事項

`work/getiPadKey` と実機結果 `work/KeyProbe_ScrShot.jpeg` から、少なくとも検証端末/キーボードの組み合わせで次を確認済みである。

- 英数は USB HID LANG2 (`0x91`)、かなは LANG1 (`0x90`) として届く。
- 両キーとも UIKit と GameController (`GCKeyboard`) の双方で検出されている。
- 実機画像で key-up まで明示的に確認できるのは「かな」であり、UIKit と GCKeyboard の双方で観測されている。「英数」の key-up 対称性は製品版の実機試験で確定する。
- `characters` は意味変換に使わず `UIKey.keyCode`/`GCKeyCode.rawValue` を使う。実測では表示文字が空文字とは限らず、物理キーの意味を安定して表さない。
- 同一イベントが二経路に届くため、両方をそのまま送信してはならない。

この結果は全 iPadOS バージョン、全 JIS キーボードを保証するものではない。正式な対応範囲は [test-plan.md](test-plan.md) の実機マトリクスで確定する。

## 未確定事項

以下は設計を止めない既定値を置いた。製品方針が決まり次第更新する。

1. 配布形態は App Store を想定する（社内配布専用なら証明書・ログ・MDM 要件を追加する）。
2. 音声は再生のみとする。マイク転送が必要なら `audin` と録音権限を別機能として追加する。
3. クリップボードはテキストのみ、端末との転送はユーザーのコピー/貼り付け操作起点とする。自動同期、画像、HTML、ファイルコピーは後続候補とする。
4. RD Gateway、RemoteApp、スマートカード、USB/カメラ/ドライブ/プリンターのリダイレクトは MVP 外とする。
5. 一つのアプリウィンドウ内でセッションを切り替える。Stage Manager の複数ウィンドウ対応は後続とする。
