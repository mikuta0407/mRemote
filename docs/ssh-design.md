# SSH クライアント設計（Phase 8）

[roadmap.md](roadmap.md) Phase 8 の詳細設計。[architecture.md](architecture.md) §1・§3・§4 の「RDP と SSH はプロファイル、ライフサイクル、一覧/切替 UI までを共通にし、描画と入力は共通化しない」方針を前提に、何を足し、何を変え、何を使い回すかを決める。

本文書の状態: **実装済み（2026-10-17、ブランチ feature/ssh-design）**。8.0〜8.5 のうちポートフォワードまで入った。設計から変えた点は各節の「実装」に書き、§15 にまとめた。

## 1. スコープ

### 1.1 対象

- 対話シェル（PTY 付き `session` channel）。1 プロファイル = 1 接続 = 1 シェル。
- 認証: パスワード、keyboard-interactive（OTP 等の複数プロンプト）、公開鍵（Ed25519 / ECDSA / RSA の SHA-2 署名）。
- ホスト鍵の TOFU（初回確認）と、変更時の強い警告。
- 端末エミュレーション: xterm-256color、UTF-8、代替画面、マウスレポート、bracketed paste。
- iPad/iPhone（UIKit）と Mac（Mac Catalyst）。複数セッションと既存のスイッチャー、ウインドウ分離。
- 鍵の取り込み（OpenSSH 形式ファイル / 貼り付け）とアプリ内生成（Ed25519）。

### 1.2 後続（8.5 以降、§13）

- ローカルポートフォワード（`-L`）。特に「SSH 越しの RDP」（踏み台経由で mRemote の RDP セッションを張る）は本アプリならではの価値があるので最優先の後続とする。
- OSC 52 によるリモート→端末のクリップボード書き込み（既定オフ）。
- Secure Enclave の ECDSA P-256 鍵（秘密鍵を端末から出さない）。
- ジャンプホスト（ProxyJump）。

### 1.3 対象外

- SFTP/SCP のファイル転送 UI、X11 転送、エージェント転送、リモートポートフォワード（`-R`）。
- mosh。iOS のバックグラウンド制約（§9）には有効だが、別プロトコル・別サーバーが要るので SSH とは別機能として扱う。
- `~/.ssh/config` の取り込み。必要になったら import 機能として後で足す。

## 2. 既存設計との関係

| 層 | 使い回す | SSH で足す |
|---|---|---|
| SessionCore | `RemoteSession`、`SessionStateMachine`、`SessionGeneration`、`SessionFactoryRegistry`、`SessionManager`、`ConnectionProfile` の共通項目（表示名、endpoint、account、WoL、グループ、お気に入り） | `ProtocolKind.ssh`、`SSHConfiguration`、`TerminalSession` capability、ホスト鍵/keyboard-interactive の challenge |
| Persistence | `ProfileDocument`、migration chain | schema v3（§5.3） |
| AppleAdapters | `CredentialRepository`（パスワード）、`KeychainStore`、`LoginKeychain` | `KnownHostRepository`、`SSHKeyRepository` |
| App | 一覧/編集シートの骨格、`SessionWorkspaceModel` の状態・challenge・再接続 UI、スイッチャー、Mac のセッションメニュー、ウインドウ分離 | `TerminalSurface`、SSH 用の編集セクション、端末用キーバー |
| ネイティブ | ピン留めソースからの静的 XCFramework、薄い C bridge、セッションごとの専用 worker | `mRemoteSSH.xcframework`（libssh2 + `mr_ssh` bridge） |

使い回さないもの（roadmap Phase 8 のとおり）: RDP scan code 変換、ポインター/`ViewportTransform`、Metal 描画、`rdpsnd`/`cliprdr`、`ClipboardMirror`。

## 3. 採用ライブラリ

### 3.1 SSH: libssh2（第一候補）

| 候補 | ライセンス | 長所 | 短所 | 判断 |
|---|---|---|---|---|
| **libssh2 1.11.x** | BSD-3-Clause | C で小さい。RSA（rsa-sha2-256/512）、Ed25519、ECDSA、keyboard-interactive、PTY、direct-tcpip（ポートフォワード）が揃う。**FreeRDP 用にピン留めビルドしている OpenSSL をそのまま使える**。既存の「ピン留めソース → 静的 XCFramework → 薄い C bridge → 専用 worker」の型にそのまま乗る | ブロッキング/ノンブロッキング API のラップを自前で書く。2026 年も CVE 修正が続いているので追従が要る | **採用候補** |
| SwiftNIO SSH（+ Citadel） | Apache-2.0（Citadel は MIT） | Pure Swift、async/await、CryptoKit | SwiftNIO SSH 本体は RSA を扱わない（Ed25519/ECDSA のみ）。既存の RSA 鍵や RSA ホスト鍵だけのサーバーに繋がらない。RSA を足す Citadel はコミュニティ保守。SwiftNIO 一式という依存が増え、アプリはこれまで SPM のリモート依存を持っていない | 不採用（RSA が必須のため） |
| libssh（libssh.org） | LGPL-2.1 | 機能が多い | App Store 配布の静的リンクと LGPL の再リンク要件が両立しにくい | 不採用 |

libssh2 の暗号は OpenSSL backend を使う。FreeRDP の XCFramework には静的 OpenSSL が同梱されているので、**同じ OpenSSL を二重にリンクしない**ために次のどちらかにする。スパイクで決める。

- (A) OpenSSL を独立した `OpenSSL.xcframework` に切り出し、FreeRDP と libssh2 の両方がそれを参照する（build script の分割が要るが、依存関係として素直）。
- (B) libssh2 を FreeRDP と同じ archive に入れる（`libmremote-freerdp.a` を `libmremote-native.a` にする）。build script の変更は小さいが、SSH の更新のたびに FreeRDP 側の成果物も作り直しになる。

既定案は (A)。`scripts/build-ssh-xcframework.sh` を新設し、`artifacts/*.sha256` と SPDX（`generate-dependency-metadata.sh`）にも libssh2 を載せる。

**実装:** (A) の変形にした。OpenSSL を切り出す代わりに、libssh2 を `FreeRDP.xcframework` が公開している OpenSSL ヘッダーに対してコンパイルし、`mRemoteSSH.xcframework`（libssh2 + `mr_ssh`）には OpenSSL を入れない（スクリプトが `EVP_*` の定義が無いことを検査する）。アプリは OpenSSL を FreeRDP 経由で一度だけリンクする。RDP bridge が FreeRDP を同梱しないのと同じ形で、FreeRDP のビルドスクリプトには手を入れずに済んだ。libssh2 は 1.11.1 以降リリースが無く、1.11.1 は OpenSSL 4 より古いので、2026 年のセキュリティ修正を含む master の commit を `config/dependencies/libssh2.lock` に固定した。

### 3.2 端末エミュレーター: SwiftTerm（第一候補）

- MIT。UI 非依存の端末エンジンと、UIKit/AppKit の front-end を持つ。商用の iOS SSH クライアントで使われている。
- UIKit の `TerminalView` は `UITextInput` を実装しており、**日本語 IME の変換中文字列（marked text）を扱える**。端末では RDP と逆に、ローカル IME で確定した UTF-8 を送るのが正しいので、ここは SwiftTerm に任せる。
- Mac Catalyst での動作は公式に明記されていないので、スパイクで確認する（UIKit front-end がそのまま動く想定）。
- SPM のリモート依存は初めてになる。既存方針（ピン留め・SBOM）に合わせ、**exact version 指定**（`exactVersion`）で取り込み、`Package.resolved` をコミットし、ライセンス画面と SPDX に載せる。

自作のエンジンは不採用。VT100/xterm の互換性（代替画面、DEC モード、全角幅、結合文字）を個人開発で追うのは割に合わない。

**実装:** SwiftTerm 1.20.0（exact）。1.99.0 は 2.0 へ向けて API を変える途中版なので避けた。Mac Catalyst では UIKit 版がそのまま動く（ビルドと実行を確認）。取り込みに伴って二つ要るものがある: シェーダー用の Xcode Metal toolchain（`xcodebuild -downloadComponent MetalToolchain`）と、build-info プラグインのためのコマンドラインビルドの `-skipPackagePluginValidation`（`scripts/release.sh` に追加済み）。

## 4. モジュール構成

[architecture.md](architecture.md) §3 で予告した `SSHProtocol` と `TerminalSurface` を、既存の RDP と同じ配置ルールで置く。

| モジュール | 配置 | 責務 |
|---|---|---|
| `SSHProtocol` | `Packages/mRemoteKit/Sources/SSHProtocol` | SSH の設定値の検証、ホスト鍵の判定ポリシー、libssh2 のエラーコード → `RemoteSessionError` の対応、鍵ファイルの解析（OpenSSH 形式の判別と公開鍵の取り出し）。libssh2 を要しないので host の `swift test` で試験できる |
| `TerminalCore` | `Packages/mRemoteKit/Sources/TerminalCore` | 端末出力のバッファ（§6.3）、入力 queue、PTY サイズの debounce、キー → バイト列の変換表（ソフトキーバー/Mac のキー）。UIKit も SwiftTerm も import しない |
| SSH session adapter | `App/SSH/` | `SSHRemoteSession`（actor）と `SSHNativeSession`（worker）。C bridge を叩くので bridging header が要り、RDP と同じくアプリ側に置く |
| `TerminalSurface` | `App/Terminal/` | SwiftTerm の `TerminalView` を包む UIView、テーマ、フォント、選択とコピー、キーバー |
| `mr_ssh` bridge | `bridge/ssh/`（C） | libssh2 の handle を opaque に包む C ABI。§6.1 |

依存方向は既存と同じく上から下のみ。`SSHProtocol` と `RDPProtocol` は互いに import しない。

**実装:** `TerminalCore` は作らなかった。出力バッファ（`TerminalOutputBuffer`）と `TerminalSession` は `LatestDesktopFrameStore` と同じく `SessionCore` に、キー → バイト列の変換表は scan code と同じくプロトコル側の `SSHProtocol` に置いた。

## 5. データモデル

### 5.1 SessionCore

```swift
public enum ProtocolKind: String, … {
    case rdp
    case ssh
}

public enum ProtocolConfiguration: Hashable, Sendable, Codable {
    case rdp(RDPConfiguration)
    case ssh(SSHConfiguration)
}

public struct SSHConfiguration: Hashable, Sendable, Codable {
    /// 試す順。既定は [.publicKey, .keyboardInteractive, .password]。
    public var authentication: SSHAuthentication
    public var terminal: TerminalPreferences      // Inheritable な端末設定
    /// 接続直後にシェルへ送るコマンド。例: `tmux new -A -s main`
    public var startupCommand: String?
    public var keepAliveInterval: Inheritable<KeepAliveInterval>
    public var clipboardPolicy: Inheritable<ClipboardPolicy>
    public var reconnectPolicy: Inheritable<ReconnectPolicy>
    /// TERM 環境変数。既定 "xterm-256color"。
    public var terminalType: String
}

public struct SSHAuthentication: Hashable, Sendable, Codable {
    /// 公開鍵認証に使う鍵。nil なら公開鍵認証をしない。
    public var keyID: SSHKeyID?
    public var allowsKeyboardInteractive: Bool
    public var allowsPassword: Bool
}

public struct TerminalPreferences: Hashable, Sendable, Codable {
    public var fontSize: Inheritable<Double>
    public var theme: Inheritable<TerminalTheme>
    /// Mac/ハードウェアキーボードの Option を Meta（ESC 前置）として送る。
    public var optionAsMeta: Inheritable<Bool>
    public var cursorStyle: Inheritable<TerminalCursorStyle>
    public var scrollbackLines: Inheritable<Int>
}
```

- ユーザー名は既存の `RemoteAccount.username` を使い、パスワードは既存の `credentialReference`（`CredentialRepository`）に入れる。SSH ではユーザー名を必須にする（空なら保存時に検証エラー）。`domain` は使わない。
- 秘密鍵そのものはプロファイルに入れない。`SSHKeyID` で `SSHKeyRepository`（§7.2）を参照する。複数のプロファイルが同じ鍵を使える。
- 既定ポートは 22。編集シートでプロトコルを切り替えたとき、ポートが既定値（3389/22）のままなら追従させる。
- `GlobalSettings` に端末の既定値（フォントサイズ、テーマ、Option as Meta、keepalive）を足す。`inherit` を接続時に一度だけ解決する既存の規則に従う。

### 5.2 EffectiveConnectionConfiguration

現在の `EffectiveConnectionConfiguration` は RDP の項目を平らに持ち、`EffectiveProfileResolver` は RDP 以外で `preconditionFailure` する。ここは SSH を足す前に形を変える。

```swift
public struct EffectiveConnectionConfiguration: Hashable, Sendable {
    // 共通（プロトコルに依らない）
    public let profileID: ProfileID?
    public let displayName: String
    public let endpoint: RemoteEndpoint
    public let account: RemoteAccount
    public let clipboardPolicy: ClipboardPolicy
    public let reconnectPolicy: ReconnectPolicy
    // プロトコル固有
    public let protocolSettings: EffectiveProtocolSettings
}

public enum EffectiveProtocolSettings: Hashable, Sendable {
    case rdp(EffectiveRDPSettings)       // 今の RDP 固有の項目をここへ移す
    case ssh(EffectiveSSHSettings)
}
```

RDP の項目を参照している箇所（`SessionWorkspaceModel`、`RDPRemoteSession`、メニューなど）は機械的に `configuration.rdp?.xxx` へ置き換える。移行を楽にするため、最初の段階では `EffectiveConnectionConfiguration` に RDP 項目を返す computed property を残してもよい（RDP 以外では呼ばない前提の暫定措置。8.1 の終わりで消す）。

**実装:** 作り替えはしなかった。既存の平らな RDP 項目はそのまま残し、`ssh: EffectiveSSHSettings?` と `protocolKind` を足した。SSH のときの RDP 項目は全体設定の値（未使用）が入る。RDP の呼び出し側を一つも変えずに済み、退行の危険が無いため。項目が増えて扱いにくくなったら上の形に移す。

### 5.3 永続化と schema

- `ProtocolConfiguration` の Codable は synthesized のままで、新しい case `ssh` が増えるだけ。v2 の文書はそのまま読める。
- ただし **SSH のプロファイルを含む文書を旧ビルドが読むと decode に失敗し、malformed 扱いになる**。ダウングレード時にこれが起きないよう、schema を **v3** に上げる（データ変換のない version だけの migration）。旧ビルドは `documentFromFutureVersion` で明確に拒否する。これは既存の「新しい版の文書を部分的に読まない」方針と同じ。
- `SSHKeyID` と鍵のメタデータ（名前、種類、公開鍵、指紋、作成日）は秘密ではないが、秘密鍵と一緒に消えるべきなので Keychain 側に置く（§7.2）。プロファイル文書は ID だけを持つ。

## 6. セッション実装

### 6.1 C bridge（`mr_ssh`）

FreeRDP bridge（[architecture.md](architecture.md) §5.2）と同じ契約で作る: opaque handle、callback のスレッド・バッファの所有者・寿命を header に明記、Swift の context は `Unmanaged` で持ち、stop 完了後に callback が来ないことを保証してから解放する。

```c
typedef struct mr_ssh_session mr_ssh_session;

typedef struct {
    const char *host; uint16_t port;
    const char *username;
    const char *term; uint16_t cols, rows, px_width, px_height;
    uint32_t keepalive_seconds;
    uint32_t connect_timeout_ms;
} mr_ssh_config;

typedef struct {
    /* worker スレッドから呼ばれる。buf は呼び出し中だけ有効。 */
    void (*host_key)(void *ctx, int key_type, const uint8_t *blob, size_t len);
    void (*auth_methods)(void *ctx, const char *methods_csv);
    void (*kbd_interactive)(void *ctx, const char *name, const char *instruction,
                            const mr_ssh_prompt *prompts, size_t count);
    void (*output)(void *ctx, const uint8_t *buf, size_t len);   /* stdout/stderr 合流 */
    void (*state)(void *ctx, int state, int error);
} mr_ssh_callbacks;

mr_ssh_session *mr_ssh_session_create(const mr_ssh_config *, const mr_ssh_callbacks *, void *ctx);
int  mr_ssh_session_run(mr_ssh_session *);                 /* worker で戻るまでブロック */
void mr_ssh_session_answer_host_key(mr_ssh_session *, int accept);
void mr_ssh_session_answer_password(mr_ssh_session *, const char *password);
void mr_ssh_session_answer_kbd_interactive(mr_ssh_session *, const char *const *answers, size_t count);
void mr_ssh_session_answer_public_key(mr_ssh_session *, const uint8_t *key, size_t len,
                                      const char *passphrase);
int  mr_ssh_session_write(mr_ssh_session *, const uint8_t *buf, size_t len);   /* 任意スレッド */
int  mr_ssh_session_resize(mr_ssh_session *, uint16_t cols, uint16_t rows,
                           uint16_t px_width, uint16_t px_height);              /* 任意スレッド */
void mr_ssh_session_output_resume(mr_ssh_session *);       /* §6.3 の backpressure 解除 */
void mr_ssh_session_request_stop(mr_ssh_session *);
void mr_ssh_session_destroy(mr_ssh_session *);
```

- worker は libssh2 をノンブロッキングで使い、socket と self-pipe（write/resize/stop/answer の wake 用）を `poll` する一本のループにする。libssh2 の session は **worker スレッドだけが触る**。`write`/`resize` は bridge 内の lock 付き queue に積んで self-pipe を叩くだけにする。
- 認証の答え待ちは RDP と同じく、session generation と challenge ID に束縛した condition で当該 worker だけを待たせる。cancel/timeout/teardown は必ず同じ wait を起こす。
- 秘密鍵とパスワードは bridge 内でコピーし、使用後に `explicit_bzero` する。libssh2 には `libssh2_userauth_publickey_frommemory` で渡し、一時ファイルを作らない。
- 許可するアルゴリズムを `libssh2_session_method_pref` で明示する。ホスト鍵と署名は `ssh-ed25519`、`ecdsa-sha2-nistp*`、`rsa-sha2-512`、`rsa-sha2-256` だけにし、SHA-1 の `ssh-rsa` 署名と DSA、CBC 暗号は既定で拒否する。古いサーバー用の緩和スイッチは作らない（必要になったら別途判断）。

### 6.2 `SSHRemoteSession`（actor）

```swift
public protocol TerminalSession: RemoteSession {
    /// data plane: 出力の受け口（§6.3）。SessionManager を通さない。
    nonisolated var terminalOutput: TerminalOutputBuffer { get }
    /// data plane: 入力。同期的に積むだけ。
    nonisolated var terminalInput: any TerminalInputSink { get }
    func resizeTerminal(_ size: TerminalSize) async
}
```

- `RemoteSession` の lifecycle/state/challenge をそのまま実装する。状態機械は既存の `SessionStateMachine` を使い、新しい状態は足さない。
  - `connecting` → ホスト鍵確認・認証で `awaitingUser` → `connecting`（`resumeAttempt`）→ シェル起動で `connected`。
  - 接続中に socket が切れたら `failed`。SSH はシェルの状態がサーバー側で失われるので、RDP のような透過的な `reconnecting` は **しない**（§9）。
- `ClipboardCapableSession` は **実装しない**。SSH にはリモートクリップボードの channel がないため。端末のコピー/ペーストはローカルの選択範囲と `UIPasteboard` の間で完結する（§8.3）。
- `AudioCapableSession`/`DesktopSession` も実装しない。既存の capability 分割がそのまま効く。
- 新しい `SessionControlEvent` は足さない方針。シェルの終了は `endedByServer(.signedOut)` ではなく、新しい `RemoteEndReason.shellExited(status: Int32?)` を足して表す（`exit` で閉じたのか、切断されたのかを UI で言い分けるため）。

### 6.3 出力の backpressure

RDP のフレームは「最新だけあればよい」ので `LatestDesktopFrameStore` で間引けたが、端末出力は **一バイトも落とせない**。代わりに SSH の channel window を使って送り手を止める。

1. worker は channel から読んだバイト列を `TerminalOutputBuffer`（固定容量の SPSC リング、既定 1 MiB）に書き、描画側へ coalesced signal を一つ送る。
2. リングの空きが閾値を下回ったら、worker は channel の読み出しを止める。libssh2 は window adjust を送らなくなり、サーバーは window が尽きた時点で送信を止める。`cat` した巨大ファイルでもメモリは増えない。
3. 描画側（MainActor）は signal を受けたらリングを drain して SwiftTerm に `feed` する。一回の drain は時間で区切り（例: 8 ms）、残りは次の runloop に回して UI を固めない。
4. drain で空きが戻ったら `mr_ssh_session_output_resume` で worker を起こす。

非表示のセッション（`SessionVisibility.background`）でも drain は続ける。端末の状態（カーソル位置、代替画面）は出力をすべて食わせないと再現できないため。描画（SwiftTerm の再描画）だけを止める。

### 6.4 入力

- `TerminalInputSink.send(_ bytes: [UInt8])` は同期的に bounded queue へ積む。順序を保ち、落とさない。queue が溢れたら（ネットワークが詰まって worker が送れないとき）入力 gate を閉じ、ユーザーに「送信が詰まっています」を出す。無制限に溜めない（[architecture.md](architecture.md) §4 の入力 queue の方針と同じ）。
- 貼り付けは一度に大きく積まない。チャンク（例: 4 KiB）で積み、queue の空きを待つ。
- PTY サイズの変更は 150 ms で debounce して `window-change` を送る。回転や Stage Manager のリサイズで連打しない。

## 7. 認証と信頼

### 7.1 ホスト鍵（TOFU）

`SessionChallenge` に case を足す:

```swift
public enum SessionChallenge {
    case credential(CredentialChallenge)
    case certificate(CertificateChallenge)
    case hostKey(HostKeyChallenge)                      // 新規
    case keyboardInteractive(KeyboardInteractiveChallenge) // 新規
}

public struct HostKeyChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let port: UInt16
    public let keyType: String            // "ssh-ed25519" など
    public let sha256Fingerprint: String  // OpenSSH 表記 "SHA256:…"（base64、末尾 = なし）
    public let disposition: HostKeyDisposition
}

public enum HostKeyDisposition: Hashable, Sendable {
    case unknown                                       // 初回
    case changed(previousType: String, previousFingerprint: String)
}
```

- 判定は `KnownHostRepository`（`AppleAdapters`）で行う。キーは `host:port`、値は鍵の種類と blob の SHA-256。既存の `TrustRepository` と同じく Keychain に置き、`LoginKeychain` の経路（Mac の ad-hoc 署名ビルド）にも対応する。列挙できない file keychain 向けに、`TrustRepository` と同じ index item を持つ。
- 一致すれば質問しない。初回は指紋を見せて「この鍵を信頼する / 今回だけ / キャンセル」。応答は既存の `ChallengeResponse.trustPersistently` / `.trustOnce` / `.cancel` を使い回す。
- **変更時**は `CertificateDisposition.fingerprintChanged` と同じ扱い: 初回と違う画面と文言で強く警告し、保存済みの鍵を黙って置き換えない。置き換えは「古い鍵を削除して新しい鍵を信頼する」という明示操作だけにする。
- 端末側で指紋を確かめる方法（`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`）をシートに書く。
- 設定画面の「信頼済みの証明書」に並べて、「既知のホスト鍵」の一覧と削除を置く。

### 7.2 鍵の管理（`SSHKeyRepository`）

- Keychain の generic password に、秘密鍵（OpenSSH 形式のバイト列）を `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` で保存する。iCloud キーチェーンには同期しない。メタデータ（名前、種類、公開鍵、指紋）は同じ item の attribute か、別の非秘密 item に置く。
- 取り込み: ファイル（`UIDocumentPicker`）または貼り付け。パスフレーズ付きの鍵は、取り込み時に一度復号して検証し、**パスフレーズごと保存するかどうかをユーザーに選ばせる**（保存しない場合は接続のたびに `credential` challenge で聞く）。
  - **実装:** 取り込み時には復号しない（OpenSSH 形式の暗号化は bcrypt_pbkdf + AES で、Swift 側に実装を持ち込む価値が無い）。公開鍵と指紋は暗号化されていない部分から読める。パスフレーズは接続時に `keyPassphrase` challenge で聞き、「保存」を選んでも **サインインに成功したときだけ** Keychain に入れる。古い PEM 形式の暗号化鍵は `ssh-keygen -p` で書き直すよう案内して断る。
- 生成: Ed25519 をアプリ内で作り、公開鍵を `ssh-ed25519 AAAA… mRemote@<端末名>` の形でコピー/共有できるようにする。生成は CryptoKit の `Curve25519.Signing` で行い、OpenSSH 形式への書き出しは `SSHProtocol` に置く（試験しやすいため）。
- 鍵の一覧は設定画面に置き、編集シートでは選ぶだけにする。鍵を消すとき、それを使っているプロファイルを示す。

### 7.3 認証の順序と challenge

1. サーバーの `userauth_list` を取得する。
2. プロファイルで許可された方式を、公開鍵 → keyboard-interactive → パスワードの順に試す。
3. 保存済みのパスワードがあれば一度だけ使い、拒否されたら `CredentialChallenge(storedCredentialWasRejected: true)` で聞き直す。同じ秘密を繰り返し送らない（RDP と同じくアカウントロック対策）。
4. keyboard-interactive は `KeyboardInteractiveChallenge`（name、instruction、プロンプトの配列と echo の有無）を出し、シートで複数欄を表示する。プロンプトが 1 つで "Password:" 系の場合も、保存済みパスワードの自動入力には使わない（OTP を誤って保存しないため）。
5. 全部失敗したら `authenticationFailed`。

## 8. UI

### 8.1 接続先一覧と編集シート

- 一覧の行に SSH/RDP の小さなバッジ（SF Symbols の `terminal` / `display`）を出す。並び順やグループは共通。
- 編集シートの先頭に「プロトコル」（RDP / SSH）を置き、選んだ側のセクションだけを出す（[ui-flow.md](ui-flow.md) §1 の「RDP 固有項目をセクション化」の実装）。
- SSH セクション:
  - 基本: 表示名、ホスト、ポート（22）、ユーザー名（必須）
  - 認証: 鍵（なし / 一覧から選ぶ / 取り込む / 生成する）、パスワード（保存する場合）、keyboard-interactive を許可
  - 端末: フォントサイズ、テーマ、Option を Meta に、接続後に実行するコマンド
  - 詳細: keepalive、TERM、クリップボード（OSC 52 を実装するまでは「端末からのコピーを許可」のみ）
  - 共通: グループ、お気に入り、Wake on LAN
- `.rdp` ファイルの取り込みや Mac 拡張など RDP 専用の項目は SSH では出さない。
- 後続で `ssh://user@host:port` の URL を開けるようにする（既存の `rdp://` の取り込み経路と同じ確認付き）。

### 8.2 ワークスペース

- `SessionWorkspaceModel` はセッションの器（状態、challenge、再接続 UI、ウインドウ、スイッチャー用サムネイル）として使い回し、`desktop` と並べて `terminal: (any TerminalSession)?` を持たせる。描画部分は `SessionWorkspaceView` が `desktop` なら `RemoteDesktopView`、`terminal` なら `TerminalWorkspaceView` を出し分ける。
- 機能の大半（クリップボードの mirror、解像度、拡張ディスプレイ、ラップトップ姿勢）は desktop にしか関係しない。`SessionWorkspaceModel` が肥大化しているので、SSH を足す前に desktop 専用の部分を `DesktopWorkspaceController` に切り出す（8.3 の最初の作業）。
- サムネイルは SwiftTerm の view を一定間隔（表示中のみ）でスナップショットする。
- iPad/iPhone のフローティングメニュー（Mac ではメニューバーの「セッション」メニュー）に出す項目:

| 項目 | RDP | SSH |
|---|---|---|
| ショートカットを送る | ○ | ×（Ctrl などはキーバーで送る） |
| 解像度 / 画質 | ○ | × |
| 文字の大きさ（拡大 / 縮小 / 標準） | × | ○（Mac は ⌘+ / ⌘- / ⌘0） |
| 画面を消去（ローカルのスクロールバックを消す） | × | ○ |
| ペースト | ○ | ○（§8.3） |
| 再接続 / 切断 | ○ | ○ |

### 8.3 キーボード、IME、コピー/ペースト

RDP と方針が逆になる点が多いので明記する。

| 項目 | RDP（既存） | SSH |
|---|---|---|
| ローカル IME | 使わない（scan code を送る） | **使う**。確定した UTF-8 を送る。SwiftTerm の `UITextInput` 実装に任せる |
| 英数/かなキー | 無変換/変換として送る | ローカルの IME 切替として使う（送らない） |
| ⌘ キー（Mac/ハードウェア） | Windows/Mac のキーとして送る | **ローカルに残す**。⌘C コピー、⌘V ペースト、⌘K 消去、⌘+/- 文字の大きさ |
| Option | Alt として送る | 設定で Meta（ESC 前置）か文字入力かを選ぶ |
| Mac の `MacKeyboardCapture` | キーを横取りする | 端末セッションでは無効にする |
| ソフトウェアキーボード | 既存のキーバー | 端末用のキーバー: Esc、Tab、Ctrl（ラッチ）、Alt、↑↓←→、`\|` `~` `/` `-`、F1–F12（スクロール）。**実装:** 自前の `TerminalKeyBar`（横スクロール）: Esc、Ctrl・Alt（ラッチ、ソフトキーボードの次の入力にも効く）、Tab、↑↓←→、PgUp/PgDn、Home/End、Del、`~` `\|` `/` `-` `\` `` ` ``、F1–F12、タッチで選択の切替。キーボードを閉じるボタンは右端に固定。SwiftTerm 内蔵のバーは幅に収まる分しか出ず PgUp などが無いため置き換えた。矢印・PgUp/PgDn・Del は長押しでリピート。PgUp/PgDn は修飾なし・DECCKM オフのとき手元のスクロールバック（ハードウェアキーと同じ） |

- キー → バイト列（矢印の `ESC [ A`/`ESC O A` の切替、Ctrl+文字、F キー）は SwiftTerm も持っているが、キーバーと Mac のメニューから送る分は `TerminalCore` の変換表を通し、host で試験する。
- コピー: SwiftTerm の選択範囲（長押し/ドラッグ、Mac はドラッグ）をローカルの pasteboard へ書く。リモートには何も送らない。
- ペースト: `UIPasteboard` を一度だけ読み、bracketed paste mode が有効なら `ESC [200~ … ESC [201~` で包んで送る。**改行を含む貼り付けで bracketed paste が無効なときは確認を出す**（貼り付けたコマンドが即実行される事故を防ぐ）。
- RDP の Mac 用 `ClipboardMirror`（自動同期）は SSH には持ち込まない。

## 9. ライフサイクルと再接続

- iOS/iPadOS でバックグラウンドに入ると socket は長くは生きない（[architecture.md](architecture.md) §10）。SSH はシェルの状態がサーバー側で失われるので、**RDP のような自動再接続はしない**。復帰時に切断を検出したら「切断されました（再接続）」を出し、再接続は新しいシェルになることを明示する。
- 作業を失わない手段として、`startupCommand` に `tmux new -A -s main` などを入れる使い方をヘルプで案内する。プロファイル作成時のヒントにも出す。
- keepalive（既定 30 秒、`libssh2_keepalive_config`）で NAT のタイムアウトを避け、相手の死活も検出する。
- Mac はバックグラウンド制約がないので、ウインドウが背面でも接続を保つ（既存の Mac の扱いと同じ）。
- **実装（切断を防ぐ努力）:** アプリを離れたとき、接続中のセッションがあれば `beginBackgroundTask` で iOS がくれる時間（約 30 秒）だけ動き続ける（`BackgroundGrace`、RDP にも効く）。その間も socket の読み書きと keepalive は続くので、ちょっと別のアプリを見て戻る程度なら切れない。バックグラウンドモード（音声など）を接続維持のためだけに宣言することはしない（[architecture.md](architecture.md) §8 の方針どおり）。
- シェルが `exit` で終わったら、セッションを閉じるか、そのまま「終了しました（再接続）」を出すかを設定で選べるようにする（既定は後者。最後の出力を読めるようにするため）。

## 10. エラー

`RemoteSessionError` に次を足す。既存の分類で足りるものは使い回す。

| 状況 | 対応 |
|---|---|
| 名前解決 / 到達不能 / 拒否 / タイムアウト | 既存の `nameResolutionFailed` などをそのまま使う |
| 鍵交換・暗号の合意失敗 | 既存の `securityNegotiationFailed` |
| ホスト鍵を拒否した、変更された鍵を受け入れなかった | **新規** `hostKeyRejected` |
| 認証方式が尽きた | 既存の `authenticationFailed` |
| サーバーが PTY/シェルを拒否した | 既存の `protocolFailure(detail:)` |

`isRetriable` は RDP と同じ考え方で、認証とホスト鍵の失敗は自動で再試行しない。libssh2 の `LIBSSH2_ERROR_*` からの対応表は `SSHProtocol` に置き、host で試験する。

## 11. セキュリティとプライバシー

[data-and-security.md](data-and-security.md) の既存方針に次を足す。

- ログに残さない: 端末の入出力、パスワード、パスフレーズ、秘密鍵、keyboard-interactive の回答。ホスト鍵の指紋は診断に出してよい（秘密ではない）が、ホスト名は既存方針どおりマスクする。
- 秘密鍵は Keychain（このデバイスのみ）にだけ置き、ファイルに書き出さない。エクスポートは公開鍵のみ。
- 端末出力に含まれる制御シーケンスのうち、ローカルに作用するものは既定で無効にする: OSC 52（クリップボード書き込み）、ウインドウタイトル以外の OSC、ファイル/URL を開く系。OSC 8 のリンクはタップ時に確認を出してから開く。
- アプリスイッチャー用のカバー（scene inactive 時）は端末にも適用する。
- 依存: libssh2 と SwiftTerm を SBOM とライセンス画面に載せる。libssh2 はセキュリティ修正の追従を release 前のチェック項目に加える。

## 12. テスト

[README.md](README.md) の試験スケール方針どおり、ロジックは自動テスト、実機は自動化できない部分だけにする。

| 種別 | 内容 |
|---|---|
| 単体（host、`swift test`） | `SSHConfiguration` の Codable と schema v2→v3、`EffectiveProfileResolver` の SSH 解決、ホスト鍵の判定（初回/一致/変更/ポート違い）、`KnownHostRepository`（login keychain 経路を含む）、libssh2 エラー対応表、OpenSSH 鍵の解析と Ed25519 生成の往復、`TerminalOutputBuffer` の backpressure、入力 queue の上限、キー → バイト列の変換表 |
| 結合（host） | 開発機で一時的な `sshd`（127.0.0.1 の高番ポート、使い捨てのホスト鍵と `authorized_keys`、テスト用の設定ファイル）を起動し、`mr_ssh` bridge をパスワード/鍵/keyboard-interactive で叩く。sanitizer（ASan/TSan）付きで回す（RDP bridge の stress と同じ扱い） |
| UI テスト | `FakeTerminalSession`（入力をそのまま返す scripted session）で、一覧 → 接続 → ホスト鍵シート → 入力のエコー → 切断までを流す。既存の `FakeSessionFactory` に `.ssh` を足す |
| 実機/VM | macOS VM（tart）の「リモートログイン」と、Linux（OpenSSH 9/10）に対して: 日本語 IME の入力、vim/tmux/htop の表示、回転とリサイズ、`cat` で巨大ファイル、バックグラウンド → 復帰、Mac のメニュー |

## 13. 段階計画

| 段階 | 内容 | 完了条件 |
|---|---|---|
| **8.0 スパイク** | libssh2 + OpenSSL を iOS / Simulator / Mac Catalyst の 3 slice でビルド（§3.1 の A/B を決める）。最小 harness で OpenSSH にパスワード・Ed25519・RSA(SHA-2) で接続し PTY を開く。SwiftTerm を iPad と Mac Catalyst に載せ、日本語 IME と vim を確認 | 3 slice が再現可能にビルドできる。三つの認証方式で接続できる。Catalyst で SwiftTerm が動き IME の変換中表示が崩れない。ここで §3 を確定する |
| **8.1 コア** | `ProtocolKind.ssh`、`SSHConfiguration`、`EffectiveProtocolSettings` への作り替え、schema v3、challenge の追加、`KnownHostRepository`、`SSHProtocol`・`TerminalCore` パッケージ | 既存の RDP の全テストが通ったまま、SSH の単体テストが通る |
| **8.2 セッション** | `mr_ssh` bridge、`SSHNativeSession`（worker）、`SSHRemoteSession`、factory 登録 | host の結合テスト（一時 sshd）が sanitizer 付きで通る |
| **8.3 UI** | `DesktopWorkspaceController` の切り出し、`TerminalSurface`、編集シートの SSH セクション、ホスト鍵/keyboard-interactive シート、端末キーバー、Mac のメニュー | VM/Linux 相手に §12 の実機項目が通る |
| **8.4 鍵** | `SSHKeyRepository`、取り込み、生成、設定画面の鍵一覧と既知のホスト一覧 | 生成した鍵で接続できる。鍵の削除で使用中のプロファイルが示される |
| **8.5 後続** | ローカルポートフォワードと「SSH 越しの RDP」、OSC 52、Secure Enclave 鍵、ProxyJump | 個別に判断 |

状況（2026-10-17）: 8.0〜8.4 と、8.5 のうちローカルポートフォワードが入った。ポートフォワードは bridge ABI 2 で、転送ごとに 127.0.0.1 で待ち受け、接続ごとに direct-tcpip チャネルで運ぶ（同時 64 接続まで、ウインドウによる背圧付き）。RDP の接続先を `localhost:<転送ポート>` にすれば「SSH 越しの RDP」になる。RDP プロファイルから SSH 接続を自動で張る連携は未実装。OSC 52、Secure Enclave 鍵、ProxyJump も未実装。

8.1 は RDP の既存コードの作り替え（`EffectiveConnectionConfiguration`）を含むので、SSH の機能より先に単独でマージし、RDP の退行がないことを確かめてから次に進む。

## 14. 未決事項

| 項目 | 既定案 | 決める時期 |
|---|---|---|
| OpenSSL の共有方法（§3.1 A/B） | **決定:** FreeRDP.xcframework の OpenSSL を共有（§3.1 の実装） | 8.0 |
| SwiftTerm を SPM で取り込むか、ソースを vendoring するか | **決定:** SPM の exact version（1.20.0） | 8.0 |
| iPhone で SSH を出すか | **決定:** 出す | 8.3 |
| シェル終了時の既定動作 | 画面を残して「終了しました」 | 8.3 |
| パスフレーズを Keychain に保存するか | ユーザーに選ばせる | 8.4 |
| ポートフォワードを 8.5 の最初にするか | **決定:** 入れる（優先度は高くない）。ローカル転送は実装済み | 8.4 の後 |

## 15. 試験の記録（2026-10-17）

| 試験 | 結果 |
|---|---|
| bridge 結合テスト（一時 sshd、Ed25519/RSA/ECDSA/パスフレーズ付き鍵、拒否された鍵、キャンセル、ホスト鍵拒否、challenge 中の停止、接続拒否、リサイズ、3 MiB の背圧、ポートフォワードで 1 MiB×2 接続の往復） | 合格。ASan・TSan 付きでも合格 |
| `swift test`（SSH の設定、schema v2→v3、resolver、出力バッファ、サインイン計画、キー変換、鍵ファイルの読み書きを ssh-keygen と照合、login keychain の既知ホスト/鍵） | 合格 |
| アプリ層ライブテスト（シミュレーター、一時 sshd）: 鍵サインイン・起動コマンド・リサイズ・シェル終了、信頼済みホスト鍵は聞かない・変わった鍵は警告し置き換えない、鍵が無ければ失敗、ポートフォワード越しに SSH バナー | 合格 |
| アプリ層ライブテスト（macOS VM の「リモートログイン」）: keyboard-interactive、保存済みパスワード、誤った保存パスワード → 一度だけ送って入力を求める | 合格 |
| UI ライブテスト（シミュレーター、画面なし）: 一覧 → ホスト鍵シート → 端末 → 日本語を含む入力 → メニュー → シェル終了の表示 | 合格。スクリーンショットで表示を確認 |
| Mac Catalyst | ビルドのみ確認（作業中のデスクトップを使わないため実行はしていない） |
