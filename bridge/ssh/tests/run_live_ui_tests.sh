#!/usr/bin/env bash
# Runs AppUITests/LiveSSHUITests in the iOS Simulator against a
# throwaway sshd on 127.0.0.1 (the Simulator shares the host's loopback).
# Headless: the Simulator boots without its window.
#
# Usage: bridge/ssh/tests/run_live_ui_tests.sh [simulator name]

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVICE="${1:-iPad Pro 11-inch (M5)}"
SSHD="${MR_SSHD:-/usr/sbin/sshd}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

work="$(mktemp -d "${TMPDIR:-/tmp}/mr-ssh-live.XXXXXX")"
sshd_pid=""
cleanup() {
    [[ -n "$sshd_pid" ]] && kill "$sshd_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -f "$work/host_ed25519"
ssh-keygen -q -t ed25519 -N "" -C mremote-live -f "$work/user_ed25519"
cp "$work/user_ed25519.pub" "$work/authorized_keys"
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
for _ in $(seq 50); do nc -z 127.0.0.1 "$port" 2>/dev/null && break; sleep 0.1; done

cd "$REPO"
TEST_RUNNER_MREMOTE_UITEST_SSH_PORT="$port" \
TEST_RUNNER_MREMOTE_UITEST_SSH_USER="$(id -un)" \
TEST_RUNNER_MREMOTE_UITEST_SSH_KEY="$(base64 < "$work/user_ed25519" | tr -d "\n")" TEST_RUNNER_MREMOTE_UITEST_SHOTS="${MR_SHOTS:-$work}" \
xcodebuild test -project mRemote.xcodeproj -scheme mRemote \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath build/dd-sim-test \
    -skipPackagePluginValidation \
    -only-testing:mRemoteUITests/LiveSSHUITests \
    2>&1 | grep -E "Test Case|error:|\*\* TEST|Executed" || true
