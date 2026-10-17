# SSH C bridge

`mr_ssh` は libssh2 を opaque handle の C ABI で包む（[docs/ssh-design.md](../../docs/ssh-design.md) §6.1）。契約は `include/mremote/ssh_bridge.h` の先頭に書いてある。要点:

- libssh2 に触るのは `mr_ssh_session_run` を呼んだ thread だけ。callback もその thread で直列に呼ぶ。他の API は任意の thread から呼べ、queue に積んで self-pipe で起こすだけ。
- ホスト鍵・認証・keyboard-interactive は challenge ID 付きで一度だけ答えられる。stop は待機中の challenge と I/O 待ちの両方を起こす。
- 名前解決は使い捨ての thread で行い、run thread は結果・stop・`connect_timeout_ms`（名前解決と TCP 接続で共有）のどれか早いものを待つ。打ち切られた解決は thread が終わり次第自分で片付ける。
- libssh2 の送信は bridge の send queue が全部受け取り、socket が取らなかった分は poll で後から送る（`send_callback`）。libssh2 に送りかけの packet が残らないので、どの状態で stop しても teardown は短時間で終わり、session を解放しきれる。
- forward の閉じかけの tunnel がサーバーの CLOSE を 10 秒待っても来なければ諦め、枠を空ける（channel は session と一緒に解放。諦めた channel は最大 8 本）。
- 出力は `on_output` の戻り値で受け取った量を返す。足りなければ読み出しを止め、SSH の window でサーバーを止める。`mr_ssh_session_resume_output` で再開する。
- パスワード、秘密鍵、パスフレーズ、入力バイト列はコピーして使い、使用後に消去する。
- 許可するアルゴリズムは `ssh_bridge.c` 先頭の preference に固定（SHA-1、DSA、CBC は使わない）。

## ビルド

アプリ用は `scripts/build-ssh-xcframework.sh` が libssh2（`config/dependencies/libssh2.lock` の commit）と bridge を 3 slice の `artifacts/mRemoteSSH.xcframework` にする。OpenSSL は含めず、`FreeRDP.xcframework` の OpenSSL をアプリが一度だけリンクする。

## ローカル検証

開発機に一時的な sshd（127.0.0.1、公開鍵のみ、鍵はテストごとに生成して削除）を立てて叩く。

```sh
scripts/build-ssh-xcframework.sh --fetch-only
cmake -S bridge/ssh -B /tmp/mremote-ssh -DBUILD_TESTING=ON \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@4)"
cmake --build /tmp/mremote-ssh
ctest --test-dir /tmp/mremote-ssh --output-on-failure
```

`-DMR_SSH_SANITIZER=address` / `thread` で sanitizer 付きに構成できる（別の build directory で）。

`BUILD_TESTING` の構成では bridge を `MR_SSH_TEST_HOOKS` 付きでビルドする（名前解決が固まる host 名、libssh2 の未解放 block 数）。xcframework には入らない。macOS の ASan は leak 検出をしないので、libssh2 の leak はこの block 数で確かめる。

パスワードと keyboard-interactive はこの sshd では試せない（PAM とシステムのパスワードが要る）。VM の「リモートログイン」で確認する。
