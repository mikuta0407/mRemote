# SSH C bridge

`mr_ssh` は libssh2 を opaque handle の C ABI で包む（[docs/ssh-design.md](../../docs/ssh-design.md) §6.1）。契約は `include/mremote/ssh_bridge.h` の先頭に書いてある。要点:

- libssh2 に触るのは `mr_ssh_session_run` を呼んだ thread だけ。callback もその thread で直列に呼ぶ。他の API は任意の thread から呼べ、queue に積んで self-pipe で起こすだけ。
- ホスト鍵・認証・keyboard-interactive は challenge ID 付きで一度だけ答えられる。stop は待機中の challenge と I/O 待ちの両方を起こす。
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

パスワードと keyboard-interactive はこの sshd では試せない（PAM とシステムのパスワードが要る）。VM の「リモートログイン」で確認する。
