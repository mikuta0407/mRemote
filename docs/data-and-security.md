# データ・セキュリティ設計

## 1. データ分類

| 分類 | 例 | 保存方針 |
|---|---|---|
| 接続メタデータ | 表示名、host、port、ユーザー名、画面設定 | app container の versioned store。iCloud 同期は初期 OFF |
| 秘密情報 | パスワード、将来の秘密鍵/token | Keychain のみ。profile store/log へ入れない |
| 信頼情報 | host/port、証明書 SHA-256 fingerprint、期限 | persistent pin は Keychain。秘密ではないが改ざんを防ぐ |
| 一時機密データ | framebuffer、clipboard、音声、入力 | 必要な間だけ memory。通常はファイルへ書かない |
| 診断情報 | 状態遷移、error code、性能値 | OSLog。本文と秘密値を redaction |
| UI 設定 | scroll、theme、floating button position | UserDefaults/設定 store |

接続先情報は組織構成を推測できるため、秘密でないからといって analytics や crash report へ完全な host/user を送らない。

## 2. 永続モデル

profile はアプリが所有する versioned schema で永続化する。FreeRDP の設定をそのまま serialize しない。persistent certificate pin は Keychain に置く。

**採用: 単一 JSON document（`Persistence` module）。** 当初 SwiftData を第一候補としたが、Phase 1 で次の理由から versioned JSON document store を採用した。

- 保存件数は接続先数十件程度で、query engine を必要としない。
- schema migration を明示的な chain（`SchemaMigrator`）として書けるため、migration test が Simulator なしで開発機上で回せる。SwiftData の migration plan は同じ検証が難しい。
- 実ファイル 1 個なので、WAL/SHM/temporary file まで data protection を確認する対象が減る。

security 要件は変えていない。ファイルは Application Support 配下に atomic write し、iOS では `completeUntilFirstUserAuthentication` を明示付与する（atomic write は新しい inode を作るため、書き込み option と書き込み後の属性設定の両方で指定する）。件数や query 要件が増えた場合は SwiftData への移行を再検討する。

profile store は iOS Data Protection を有効にし、少なくとも最初の端末 unlock 前には読めない保護クラスを使う。SwiftData の実ファイルだけでなく WAL/SHM と migration 用 temporary file も同じ保護対象であることを実機で確認する。診断 export を除き、profile database や framebuffer/clipboard の temporary file を独自に作らない。

### 2.1 ProfileRecord

```text
ProfileRecord
  id: UUID
  schemaVersion: Int
  displayName: String
  protocolKind: "rdp"
  host: String
  port: UInt16
  username: String?
  domain: String?
  credentialReference: UUID?
  protocolPayload: versioned RDPProfilePayload
  overrides: ProfileOverrides
  createdAt / updatedAt / lastConnectedAt
```

`protocolPayload` は RDP 固有項目を持つ。将来 SSH payload を追加しても共通 column と一覧 query を維持する。任意の FreeRDP command-line option 文字列を保存・注入する escape hatch は設けない。検証を迂回し、互換性と安全性を損なうためである。

### 2.2 RDPProfilePayload

```text
RDPProfilePayload v1
  resolutionPolicy: inherit | adaptive | fixed(width, height)
  initialScale: inherit | fit | oneToOne
  displayQuality: inherit | automatic | explicit(...)
  keyboardLayout: inherit | japanese | us | automatic
  audioPlayback: inherit | enabled | disabled
  clipboardPolicy: inherit | disabled | bidirectional | sendOnly | receiveOnly
  scrollDirection: inherit | normal | reversed
  reconnectPolicy: inherit | disabled | automatic
  securityPolicy: secureAutomatic | nlaRequired | tlsRequired | legacyExplicit
```

設定値の default を各画面へ散らさず、schema migration と `EffectiveProfileResolver` に集約する。`inherit` は現在の global value を接続開始時に解決する。host、security、keyboard layout、channel、remote resolution 等はその session の immutable `EffectiveConnectionConfiguration` とし、変更は再接続後に有効となる。

zoom/pan/Fit、現在の scroll inversion/sensitivity、local audio mute 等は handshake 設定と分け、memory 上の mutable `SessionRuntimeState` に置く。セッションメニューの変更は現在の session へ即時反映し、profile/global を暗黙に書き換えない。「この接続先の既定に保存」を明示した場合だけ profile override を更新する。

### 2.3 実行中 SessionRecord

実行中の socket/native pointer を永続化しない。memory 上でのみ次を持つ。

```text
SessionRecord
  sessionID: UUID
  sourceProfileID: UUID?
  effectiveConfiguration: immutable snapshot
  state / generation
  createdAt / focusedAt
  protocolSessionHandle
```

scene 復元には profile ID と「接続中だった」事実だけを保存し、ユーザーの再接続 policy に従う。同じ native handle の復元を試みない。

## 3. 資格情報

- パスワードは Keychain generic password item として保存する。
- `service` は app 固有固定値、`account` は推測可能な host 名ではなく credential UUID とする。
- profile は UUID reference だけを保持する。
- foreground 接続用途の既定 accessibility は `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` とする。
- Mac で provisioning profile を持たない ad-hoc 署名のビルド（Homebrew で配るもの）はデータ保護 Keychain に書けない（errSecMissingEntitlement）。起動時に書き込みで判定し、その場合は login keychain に置く（`KeychainStore`、2026-10-16）。Mac Catalyst の `SecItem*` は `kSecUseDataProtectionKeychain = false` を無視して常にデータ保護 Keychain を使うので、login keychain へはファイル Keychain の API（`SecKeychainAddGenericPassword` など。Catalyst の SDK では使えない扱いなので実行時に引く）で読み書きする（`LoginKeychain`、2026-10-17）。この API は一覧を取れないため、承認済みの証明書は endpoint の一覧を別の item に持つ。login keychain の item はアプリの署名で守られ、更新後は一度アクセス許可を求められることがある。accessibility 属性は login keychain では効かない。
- optional の Face ID/Touch ID 保護を追加する場合は LocalAuthentication と access control を用い、接続 worker 上で認証 UI を開始しない。
- 接続 challenge 用の password buffer は使用後に可能な範囲で zeroize し、`String` の長期保持や debug description を避ける。
- profile 複製時に資格情報を共有するかは明示選択とし、既定では共有しない。
- profile 削除時に参照数が 0 になった credential の削除を提案する。

パスワードを FreeRDP へ渡す境界ではコピー回数を抑え、bridge が所有権と破棄時点を保証する。

## 4. RDP transport と認証

- NLA/CredSSP と TLS を既定とする。
- 古い RDP Security への downgrade を自動で許可しない。必要なら profile ごとの明示設定、警告、監査表示を必要とする。実装: 接続設定の「接続方式」で「レガシー RDP セキュリティ」を選ぶと確認ダイアログを出し、許可したときだけ設定する。bridge は policy が許す protocol だけを X.224 で提示し、PostConnect でサーバーが選んだ protocol を再確認する。接続時のトーストとセッションメニューに「古い RDP セキュリティを許可した接続先」と表示する。
- TLS version/cipher は採用 FreeRDP/OpenSSL の安全な既定を使い、互換目的の弱い global override を設けない。
- hostname verification を行い、FreeRDP の「常に証明書を受け入れる」設定を release build で禁止する。
- 認証失敗と network error を分け、保存パスワードを無制限に再試行して account lockout を誘発しない。
- 自動再接続は session generation を更新し、古い connection callback/input が新接続へ混入しないようにする。

## 5. 証明書検証と明示信頼

通常の trust 判定は `SecTrust` を唯一の authoritative path とする。Phase 0 の Go/No-Go 条件として、採用 FreeRDP 版の certificate callback から leaf/chain DER を app 所有 memory へコピーできることを確認する。`SecPolicyCreateSSL(server: true, hostname:)` 相当の SSL policy で iOS system trust store、chain、hostname、有効期間を評価する。

FreeRDP/OpenSSL 内蔵の known-hosts file とアプリ独自 pin を二重運用しない。FreeRDP の callback は `SecTrust` の結果、または次の限定的な user pin policy の結果だけを返す。

system trust が成立しない場合、証明書が有効期間内かつ hostname 一致で、原因が private CA/自己署名等の untrusted root であるときだけ、ユーザーの明示承認を host + port + SHA-256 fingerprint に束縛して保存できる。期限切れと hostname mismatch は既定で hard reject とし、persistent override を許可しない。

評価は段階に分け、拒否は必ず「どの段階で落ちたか」を evidence に残す。system 評価の error は自己署名なら常に `errSecNotTrusted` で、原因の識別に使えないためである。

| 段階 | 内容 | 不成立時 |
|---|---|---|
| `system-trust` | platform trust store に対する authoritative 評価 | 次段へ |
| `presented-chain` | 提示 chain の全 link・署名・有効期間を、終端証明書を anchor として Basic X.509 で検証 | **hard reject** |
| `server-purpose` | name check を外した SSL policy（serverAuth 等） | **警告付き `今回のみ信頼`** |
| `hostname-binding` | name check のみ（hostname 入力時） | **hard reject** |

`presented-chain` が下限である。ここで落ちる証明書は「未知」ではなく壊れている（署名不正・期限切れ・chain 断絶）ため override を許可しない。一方 `server-purpose` は Apple が server 証明書に課す要件であって RDP の trust model が要求するものではなく、identity は fingerprint の明示レビューで確立される。Microsoft 純正クライアントも同種の証明書を警告のうえ継続させるため、hard reject ではなく警告付きの `今回のみ信頼` とし、承認 UI に「iOS の server 証明書要件を満たさない」ことを明示する。

提示 chain に同一証明書が重複して含まれる場合は、提示順を保ったまま重複を落としてから評価する。gnome-remote-desktop は自己署名証明書を leaf と chain の両方として提示するため、そのままでは leaf 自身を issuer とする path を組もうとし、終端証明書を anchor に選ぶ規則も退化する。evidence の fingerprint は提示されたままの chain を hash する（重複は `repeated-chain-entries` として記録する）。

hostname binding の例外は接続先を IPv4/IPv6 literal で入力した場合に限る。Windows RDP の自己署名証明書は machine name を dNSName として持ち iPAddress SAN を持たないため、IP literal 宛では SSL policy の name binding が原理的に成立しない。この場合に限り fallback 評価の SSL policy から hostname を外し、chain 署名・有効期間・serverAuth EKU は据え置いたまま、identity 確認を fingerprint の明示レビューへ置き換える。iPAddress SAN を持つ証明書は authoritative な system 評価で従来どおり `.trusted` に到達するため、この緩和路には入らない。緩和が効いた接続は evidence へ `binding=ip-literal-unverified` を残し、承認 UI に「hostname 未検証」を明示する。hostname を入力した接続の mismatch は従来どおり hard reject のままとする。

persistent 承認時に Keychain へ保存する `TrustRecord` payload（`今回のみ`は memory 上の connection generation にだけ保持する）:

```text
id, profileID?, normalizedHost, port,
sha256Fingerprint, subjectSummary, issuerSummary,
notBefore, notAfter, createdAt
```

`sha256Fingerprint` は leaf certificate の完全な DER に対する SHA-256 と定義する。表示用の subject/issuer は識別根拠に使わない。保存 record 自体も Keychain の app 固有 access group に限定し、同期しない。

検証規則:

- fingerprint 一致だけで host/port の違う接続へ信頼を流用しない。
- 有効期限切れ、hostname mismatch、fingerprint 変更を別々に表示する。前二者は既定で承認 action を出さない。IP literal 接続の name 未検証は mismatch とは別に扱い、承認 action を出したうえで警告文を必ず添える。
- 保存済み fingerprint が変わった場合は MITM/再発行の可能性として強い警告を出し、自動置換しない。承認 action は出すが、初回承認とは別の文言・別のボタン（「変更を承知のうえで今回のみ接続」「新しい証明書に置き換えて保存」）とし、以前の fingerprint を併記する。承認 action を出さないと、正当な証明書更新でその接続先がアプリ内から永久に使えなくなり、警告を読む代わりに trust record を消す習慣を作ってしまう。
- 保存済み fingerprint が変わった場合の警告は、新しい証明書が system trust を満たしていても出す。公的 CA の署名は「以前ユーザーが承認したのと同じサーバーである」ことの証明にはならない。
- `今回のみ信頼` は永続化しない。
- trust callback 待ちの間も接続キャンセル可能にし、タイムアウト時は拒否扱いとする。DER callback memory は判定完了後に破棄する。
- 設定画面から trust record を確認/削除できる。

## 6. クリップボードのプライバシー

MVP はプレーンテキストだけを扱う。

- `UIPasteboard` の常時 polling はしない。
- ローカル→リモートの読み取りは paste button 等の明示操作から行う。
- リモート→ローカルは session 内に pending offer/data として保持し、ユーザーの copy 操作で system pasteboard へ書く。
- clipboard 本文を profile、UserDefaults、OSLog、analytics、crash breadcrumb に残さない。
- focused session ID、content hash、generation で loop と別 session への誤送信を防ぐ。
- 最大文字数/byte 数、UTF-16 検証、timeout を設ける。上限超過時は安全に拒否し UI へ通知する。
- clipboard policy を `disabled`、`bidirectional`、`sendOnly`、`receiveOnly` から選べる。

将来画像/ファイルへ拡張する場合は、UTType、temporary file protection、malware/サイズ対策を別設計とする。

## 7. 画面・音声・入力のプライバシー

- scene inactive 時はリモート画面へ privacy cover を重ね、app switcher snapshot に内容を残さない。
- screenshot/画面収録を完全に禁止できるとは約束しない。`UIScreen.isCaptured` 相当の状態を検出した場合の警告/blackout は product policy として後続判断する。
- framebuffer を一般の image cache や Photos へ保存しない。thumbnail を使う場合も memory only を既定とする。
- Release のキー診断は集計と英数/かな等の非文字 allow-list に限定する。HID usage/scan code の時系列も本文を再構成できるため、printable key は記録しない。
- 音声 PCM をファイルへ保存しない。
- 非 focused session の音声は mute/drop し、意図しない会話混入を防ぐ。

## 8. iOS 権限と宣言

| 項目 | 方針 |
|---|---|
| Local Network | LAN 宛て接続に備え `NSLocalNetworkUsageDescription` を具体的に記載し、接続直前に説明する |
| Bluetooth | system keyboard/mouse を UIKit/GameController 経由で使い、CoreBluetooth scan はしない |
| Microphone | 音声再生のみの MVP では要求しない |
| Camera/Photos | 要求しない |
| Background Modes | 接続維持目的だけで audio mode 等を申請しない |
| Encryption | TLS/CredSSP を含むため App Store Connect の輸出コンプライアンス回答をリリース工程へ入れる |

Info.plist の用途説明は機能追加と同じ review を必要とし、未使用権限を先に追加しない。

## 9. ログと診断 export

OSLog category:

- `session.lifecycle`
- `rdp.transport`
- `rdp.channel`
- `render.performance`
- `input.routing`
- `security.trust`

各 event にランダムな session ID と connection generation を付ける。host/user は既定で privacy private、password、clipboard、key characters、frame/audio は常に記録禁止とする。

診断 export はユーザーが明示操作したときだけ作成し、次を含む。

- app/OS/device model、FreeRDP と依存ライブラリ version
- redacted effective settings
- state transitions/error classification
- frame/input/audio/clipboard の件数・latency・drop 数
- dependency licenses

temporary export file は share sheet 完了/キャンセル後に削除する。

## 10. 依存関係とビルド供給網

- FreeRDP と transitive dependencies を tag だけでなく commit/checksum で固定する。
- 再現可能な build script から XCFramework、license notice、SBOM を生成する。
- CI で既知脆弱性と license を検査し、更新は FreeRDP bridge integration test を通す。
- 動的 plugin、ダウンロードした executable code、ユーザー入力した FreeRDP option の無検証注入を禁止する。
- FreeRDP/WinPR 本体の Apache-2.0 notice に加え、OpenSSL、zlib、codec 等の実際に link した license を Settings に掲載する。
- LGPL/GPL/特許対象 codec を追加する場合は法務・配布条件の確認を release gate とする。

## 11. 脅威と対策の要約

| 脅威 | 主な対策 |
|---|---|
| 偽 RDP server/MITM | hostname/chain 検証、fingerprint pin、変更時の強い警告 |
| 資格情報漏えい | Keychain、log redaction、buffer lifetime 制限、downgrade 禁止 |
| 悪意ある PDU/長さ | FreeRDP 更新、bridge 境界検証、payload 上限、fuzz/negative test |
| session 間入力漏れ | focusedSession gate、generation、切替時 releaseAll |
| clipboard 流出 | 方向 policy、ユーザー起点、focused session 限定、本文非保存 |
| app switcher から画面漏えい | inactive 時 privacy cover |
| 非表示 session の盗聴 | active/focused session だけ音声出力 |
| supply-chain 混入 | dependency pin、checksum、SBOM、静的登録 |
