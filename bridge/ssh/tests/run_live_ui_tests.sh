#!/usr/bin/env bash
# Runs AppUITests/LiveSSHUITests in the iOS Simulator against a throwaway
# sshd (the Simulator shares the host's loopback). Headless: the Simulator
# boots without its window.
#
# As run_live_app_tests.sh: an sshd on this Mac by default, or with
# MR_SSH_LINUX=1 a Linux container with tmux, where alone the tmux tests run.
#
# Usage: bridge/ssh/tests/run_live_ui_tests.sh [simulator name] [only-testing]

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVICE="${1:-iPad Pro 11-inch (M5)}"
ONLY="${2:-mRemoteUITests/LiveSSHUITests}"
SSHD="${MR_SSHD:-/usr/sbin/sshd}"
LINUX="${MR_SSH_LINUX:-0}"
DOCKER_CONTEXT="${MR_DOCKER_CONTEXT:-colima-mremote-test}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

work="$(mktemp -d "${TMPDIR:-/tmp}/mr-ssh-live.XXXXXX")"
sshd_pid=""
container=""
cleanup() {
    [[ -n "$sshd_pid" ]] && kill "$sshd_pid" 2>/dev/null || true
    [[ -n "$container" ]] && docker --context "$DOCKER_CONTEXT" rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -C mremote-live -f "$work/user_ed25519"
cp "$work/user_ed25519.pub" "$work/authorized_keys"
chmod 600 "$work/authorized_keys"
port=$(( 20000 + RANDOM % 20000 ))

if [[ "$LINUX" == 1 ]]; then
    user=tester
    docker --context "$DOCKER_CONTEXT" build -q -t mremote-ssh-test "$REPO/bridge/ssh/tests/linux-host" >/dev/null
    container="$(docker --context "$DOCKER_CONTEXT" run -d --rm --hostname linux -p "127.0.0.1:$port:22" \
        -e "AUTHORIZED_KEY=$(cat "$work/user_ed25519.pub")" mremote-ssh-test)"
else
    user="$(id -un)"
    ssh-keygen -q -t ed25519 -N "" -f "$work/host_ed25519"
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
# Should the app look for tmux, it finds an empty directory rather than the
# developer's own sessions. Nothing here starts or stops tmux.
SetEnv TMUX_TMPDIR=$work/tmux
CONFIG
    mkdir -p "$work/tmux"
    "$SSHD" -D -e -f "$work/sshd_config" 2>"$work/sshd.log" &
    sshd_pid=$!
fi
for _ in $(seq 100); do
    banner="$(nc -w 1 127.0.0.1 "$port" </dev/null 2>/dev/null | head -c 4 || true)"
    [[ "$banner" == "SSH-" ]] && break
    sleep 0.2
done

cd "$REPO"
TEST_RUNNER_MREMOTE_UITEST_SSH_PORT="$port" \
TEST_RUNNER_MREMOTE_UITEST_SSH_USER="$user" \
TEST_RUNNER_MREMOTE_UITEST_SSH_KEY="$(base64 < "$work/user_ed25519" | tr -d "\n")" \
TEST_RUNNER_MREMOTE_UITEST_SHOTS="${MR_SHOTS:-$work}" \
TEST_RUNNER_MREMOTE_UITEST_STORE_SHOTS="${MR_STORE_SHOTS:-}" \
TEST_RUNNER_MREMOTE_UITEST_TMUX_HOST="$([[ "$LINUX" == 1 ]] && echo isolated || echo none)" \
xcodebuild test -project mRemote.xcodeproj -scheme mRemote \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath build/dd-sim -skipMacroValidation \
    -skipPackagePluginValidation -collect-test-diagnostics never \
    -only-testing:"$ONLY" \
    2>&1 | grep -E "Test Case|error:|\*\* TEST|Executed" || true
