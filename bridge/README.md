# FreeRDP C bridge spike

Phase 0 用の opaque-handle C ABI、host 上で FreeRDP なしに実行できる契約テスト、固定版 FreeRDP 3.31.1 用 iOS adapter です。通常の CMake build は `unavailable` backend を選び、生成する `mRemoteRDPBridge.xcframework` だけが実 adapter を含みます。FreeRDP の型や OpenSSL の証明書 pointer は公開 header に出しません。

## 契約

- `mr_rdp_session_run` を呼んだ session 専用 thread だけで callback を直列実行する。
- config、hostname、callback table は create 中に copy する。callback の DER は backend の一時 pointer から deep copy してから渡す。
- callback view は callback return までだけ有効。DER は `chain[0]` が leaf、後続が issuer で、Swift は各 blob と length を `Data` 等へ同期的に copy してから MainActor へ渡す。
- certificate response は connection generation と challenge ID の両方に束縛し、回答は一度だけ受理する。
- copied DER、hostname、port を `SecTrust` の SSL policy または限定 pin policy で評価した側だけが accept decision を返す。callback 未設定時は拒否する。
- `request_stop` は thread-safe/idempotent で、backend wait と certificate wait の両方を wake する。
- 所有側の外部 lifetime gate が新規 API 呼び出しを閉じた後、`destroy` は stop、登録済み in-flight API、run/callback drain、backend 解放の順で終了する。
- run/callback thread からの自己 `destroy` は deadlock 防止のため拒否する。
- username/password は非空、domain は `NULL/0` のときだけ省略とし、明示長の span を create 中に deep copy する。埋め込み NUL を拒否し、password copy は全 cleanup 経路で消去する。
- generation `0` は予約値として create 時に拒否する。
- BGRA frame の bytes と dirty rectangles は callback return までだけ有効。Swift は同期的に copy し、generation/surface generation/frame ID、stride、byte length、矩形範囲を検証してから非同期処理へ渡す。
- wheelは各軸を1 eventあたり `+/-32767` に制限し、queue内の合算も同じ範囲で飽和させる。workerは最大64 input commandごとにevent loopへ戻り、channel/deadline処理を飢餓させない。
- `cliprdr`、`rdpsnd`、`drdynvc`、`disp`、`rdpgfx`、`rdpei`、`rdpdr` の接続/切断は固定 enum と session 内単調 sequence だけで通知し、backend の channel 名/pointer を ABI 外へ出さない。
- Phase 0 clipboard probe は最大 64 KiB、NUL 終端 UTF-16LE の `CF_UNICODETEXT` 1件に限定する。embedded NUL/不正 surrogate を拒否し、callback/export へは probe ID、stage、byte count、SHA-256、status だけを渡す。
- DISP は200–8192 pxの primary monitor 1台と、ABI 4 からはその右に上端をそろえた2台目（100%、幅の合計 16384 px まで）に限定し、FreeRDPが記録値を丸めないよう偶数widthだけを受理する。
- ABI 4 の RD Gateway は設定したホスト/ポートの証明書だけを `MR_RDP_CERTIFICATE_ROLE_GATEWAY` として同じ challenge 経路で問い合わせる。redirect 先の証明書は従来どおり受理しない。ゲートウェイのパスワードもコンピューターのものと同じく create 中に copy し、全 cleanup 経路で消去する。
- ABI 4 のドライブ共有は `MR_RDP_CHANNEL_FLAG_DRIVE` のときだけ、絶対パス1つを固定の名前で共有する。
- ABI 4 のタッチ（contact 0–255）とペンはキーと同じ bounded queue を通り、DOWN は対応する UP/CANCEL の空きを予約する。MOVE/HOVER は直前の同種だけをまとめる。`MR_RDP_CHANNEL_FLAG_TOUCH` なしの session では `UNSUPPORTED`。

- ABI 6 の MACRDPX（`external/macrdpx`）は `MR_RDP_CHANNEL_FLAG_MACRDPX` と非 0 の `macrdpx_caps` が揃うときだけ静的チャンネルを要求し、接続時に client HELLO を送る。サーバーからは HELLO・STREAM_STATUS・INPUT_SOURCE だけを `on_macrdpx` に渡し（交渉済み caps 付き、文字列は callback 中だけ有効）、`mr_rdp_session_send_macrdpx` は client→server の型だけを mrx_encode で検証してキーと同じ有界・順序付きキューへ入れる。Mac のキー/ボタンの down は対応する up の空きを予約し、移動と同じ phase の継続スクロールはまとめる。サーバーの HELLO が来るまで、またはチャンネルが開かなければ送信は捨てる。
- ABI 7 の SOCKS5 プロキシは `proxy_type` が `MR_RDP_PROXY_SOCKS5` のときだけ `proxy_hostname`（253 byte まで）と `proxy_port`（0 は 1080）を受け取り、FreeRDP の `ProxyType`/`ProxyHostname`/`ProxyPort` に渡す。コンピューターへの接続も RD ゲートウェイへの接続もプロキシ経由になり、接続先の名前はプロキシが解決する（SOCKS5 の domain address）。プロキシでのサインイン（RFC 1929）の欄は予約で、NULL/0 以外は拒否する。

raw C pointer 自体は stale call を防げません。所有側（Swift の `NativeSessionCallGate`）は全 API 呼び出しと destroy 開始を外部で直列化し、呼び出し開始から内部の in-flight 登録までを destroy と競合させてはいけません。登録済みの run/callback/send は drain 対象です。

## ローカル検証

```sh
git submodule update --init   # external/macrdpx
cmake -S bridge -B /tmp/mremote-bridge-build -DBUILD_TESTING=ON
cmake --build /tmp/mremote-bridge-build
ctest --test-dir /tmp/mremote-bridge-build --output-on-failure
```

Address/Undefined Behavior Sanitizer:

```sh
cmake -S bridge -B /tmp/mremote-bridge-asan \
  -DBUILD_TESTING=ON -DMR_BRIDGE_SANITIZER=address
cmake --build /tmp/mremote-bridge-asan
ctest --test-dir /tmp/mremote-bridge-asan --output-on-failure
```

Thread Sanitizer は `-DMR_BRIDGE_SANITIZER=thread` で別 build directory に構成します（Address Sanitizer との同時使用はしません）。

`contract_tests.c` の `concurrent stop and call stress` は sanitizer 実行を前提にしたテストです。run と並行して別 thread から send/respond/cancel/stop を繰り返し、challenge wait と wake、run の return、消えた challenge への response が競合する窓を踏みます。個々の呼び出しは stopping 中なら失敗して当然なので、assert しているのは「crash しない」「data race がない」「callback が矛盾した値を観測しない」の三点だけです。`destroy` は両 thread の join 後にだけ呼びます。これは所有側の外部 gate（Swift の `RDPNativeCallGate`）と同じ契約です。

PEM parser の strict whitespace/trailing-data、malformed PEM、16枚/8 MiB 上限テストは host OpenSSL を明示して有効にします。macOS + Homebrew の例:

```sh
cmake -S bridge -B /tmp/mremote-bridge-certificate-tests \
  -DBUILD_TESTING=ON \
  -DMR_BRIDGE_CERTIFICATE_TESTS=ON \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
cmake --build /tmp/mremote-bridge-certificate-tests
ctest --test-dir /tmp/mremote-bridge-certificate-tests --output-on-failure
```

## iOS adapter artifact

固定版 `FreeRDP.xcframework` を先に生成し、bridge を別の静的 XCFramework として作ります。最終 app は両方と `Foundation` / `AudioToolbox` を link します。

```sh
scripts/build-rdp-bridge-xcframework.sh --dry-run
scripts/build-rdp-bridge-xcframework.sh
scripts/verify-rdp-bridge-xcframework.sh \
  artifacts/mRemoteRDPBridge.xcframework \
  artifacts/FreeRDP.xcframework
(cd artifacts && shasum -a 256 -c mRemoteRDPBridge.xcframework.sha256)
```

builder は device arm64 と Simulator arm64 を `-Wall -Wextra -Wpedantic -Werror` で compile し、host/build path の混入を拒否します。verifier は bridge と FreeRDP の一致する slice を実 link し、静的 channel table から `cliprdr`、`rdpsnd`、`rdpdr`、`drdynvc`、`disp`、`rdpgfx`、iOS audio subsystem が最終 binary に保持されることを検査します。

## rdpsnd の版非依存契約

`include/mremote/rdpsnd.h` は FreeRDP の plugin struct を公開せず、`FormatSupported`、`Open`、`SetFormat`、`Play`、`Close`、`Free` に対応する PCM sink を定義します。

- advertise/accept するのは `WAVE_FORMAT_PCM`、mono/stereo、8/16-bit、8–192 kHz のみ。
- `blockAlign` と `avgBytesPerSec` を再計算して不整合を拒否し、wave byte 上限と frame alignment を検査する。
- focused session だけ PCM callback へ渡し、非 focused、consumer 不在、backpressure は即時 drop する。
- `Play` を受けたら、delivery/drop/malformed/closed の全経路で block number と timestamp を保った confirm callback をちょうど一度返す。
- callback は直列かつ同期的で、PCM view は callback 中だけ有効。実装側は bounded SPSC ring へその場で copy する。
- `Close` は active PCM/confirm callback を drain して idempotent に終了し、`Free` は NULL 化されて二度目も成功する。

この `mr_rdpsnd` は mock test と将来 upstream hook を評価するための版非依存契約で、stock FreeRDP 3.31.1 の `RDPSND_DEVICE_PLUGIN` には接続していません。同版の public `Play` / `PlayEx` は block number と server timestamp を渡さず、core の `rdpsnd_treat_wave` が再生 callback の前後に Wave Confirm PDU を送ります。そのため adapter から追加 confirm を送ると二重送信になります。

FreeRDP 3.31.1 は PCM-only の iOS subsystem と同時に、全 format を受理して音声を捨てる `fake` subsystem を静的リンクします。adapter は `PreConnect` で SVC/DVC の両 collection に `rdpsnd,sys:ios` を先に登録し、core が直後に呼ぶ common add-in loader の fallback (`sys:fake`) を避けます。loader は duplicate-name check で両方の指定を保持し、rdpsnd に必要な RDPDR と他の要求 channel を登録します。`AudioPlayback` は有効、microphone capture は無効です。

callback dispatch は、3.31.1 が実際に参照する `AsyncUpdate = FALSE`、`SynchronousStaticChannels = TRUE`、`SynchronousDynamicChannels = TRUE` で同期化します。同版の deprecated `AsyncChannels` は保存/getter 以外の runtime consumer がないため、同期性の根拠には使いません。

## Channel exercise ABI

`mr_rdp_session_start_clipboard_probe` は明示操作で作ったtest payloadをAPI return前にbackendへdeep copyし、worker上で `format-list sent` → `format-list response` → `data request` → `data response sent` をcount/hash-only callbackへ通知します。format-list responseまたはdata requestが10秒以内に届かない場合は、待っていたstageを `MR_RDP_ERROR_TIMEOUT` で通知してpayloadをzeroizeします。CLIPRDR PDUにはprobe IDがないため、遅延PDUを次のprobeへ誤帰属しないよう、timeout後のretryにはchannel/session再接続が必要です。payloadは応答、timeout、切断、stop、destroyの全経路でzeroizeします。通常のpasteboard同期やremote-to-local転送を実装するAPIではありません。

`mr_rdp_session_request_display_resize` は選択したharness fixture寸法を`disp`の`SendMonitorLayout`へqueueし、workerから要求ID・寸法・statusを返します。両APIとも該当channelが未接続なら失敗し、UIは接続telemetryを受けた場合だけ操作を有効にします。

これらのcallbackやmock round-tripが示すのはABI ownership、validation、count/hash loggingだけです。`P0-CH-01/02/03`を`PASS`にするには、signed physical iPadと実Windowsで同じcounter/hash/dimensionを取り、必要なwire/server側証拠と照合します。

## 固定版 adapter の範囲

`freerdp_backend.c` は次を adapter 内へ閉じ込めます。

- FreeRDP instance/context と static channel add-in の生成・破棄
- event loop の stop event 統合
- Set 1 code/extended flags と FreeRDP version 固有 keyboard flag の変換
- external certificate management callback の full PEM chain から leaf-first DER snapshot への変換。PEM は 8 MiB、DER chain は 4 MiB/16枚に制限し、trailing garbage と不完全な certificate を拒否
- `rdpsnd` の `sys:ios` 明示選択（upstream `fake` fallback の禁止）。Wave Confirm は stock core に所有させる
- channel connected/disconnected telemetry、bounded `CF_UNICODETEXT` probe、`disp` monitor-layout request
- framebuffer、pointer、channel callback の長さ・stride・矩形検証
- bounded input command queue と worker-thread 上での送信

adapter の compile/link と mock contract は、実 Windows の NLA/TLS、FreeRDP の実 callback timing、channel negotiation/data round-trip、wire 上の2回の Wave Confirm、実機音声を証明しません。それらは physical-device harness と packet/wire evidence を使う Phase 0 Gate の外部検証です。RD Gateway と redirected-host certificate は hostname challenge の意味が異なるため、この Phase 0 adapter では明示的に拒否します。
