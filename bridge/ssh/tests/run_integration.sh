#!/usr/bin/env bash
# Starts a throwaway sshd on 127.0.0.1 for the current user - public keys
# only, generated here and deleted afterwards - and runs the bridge tests
# against it.
#
# Usage: run_integration.sh path/to/ssh_bridge_tests

set -euo pipefail

TESTS="$1"
SSHD="${MR_SSHD:-/usr/sbin/sshd}"
[[ -x "$SSHD" ]] || { echo "sshd not found: $SSHD" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/mr-ssh-test.XXXXXX")"
sshd_pid=""
cleanup() {
    [[ -n "$sshd_pid" ]] && kill "$sshd_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

keygen() { ssh-keygen -q -t "$1" ${3:+-b "$3"} -N "${4:-}" -C mremote-test -f "$work/$2"; }
keygen ed25519 host_ed25519
keygen ed25519 user_ed25519
keygen rsa user_rsa 3072
keygen ecdsa user_ecdsa 256
keygen ed25519 user_encrypted "" "correct horse"
keygen ed25519 user_unknown
cat "$work"/user_ed25519.pub "$work"/user_rsa.pub "$work"/user_ecdsa.pub \
    "$work"/user_encrypted.pub > "$work/authorized_keys"
chmod 600 "$work/authorized_keys"

port=$(( 20000 + RANDOM % 20000 ))
cat > "$work/sshd_config" <<CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $work/host_ed25519
PidFile $work/sshd.pid
AuthorizedKeysFile $work/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel ERROR
CONFIG

"$SSHD" -D -e -f "$work/sshd_config" 2>"$work/sshd.log" &
sshd_pid=$!
for _ in $(seq 50); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    sleep 0.1
done
nc -z 127.0.0.1 "$port" || { cat "$work/sshd.log" >&2; exit 1; }

MR_SSH_TEST_PORT="$port" \
MR_SSH_TEST_USER="$(id -un)" \
MR_SSH_TEST_DIR="$work" \
"$TESTS"
