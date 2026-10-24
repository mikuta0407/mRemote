#!/usr/bin/env bash
# Runs AppTests/SSHRemoteSessionLiveTests in the iOS Simulator against a
# throwaway sshd (the Simulator shares the host's loopback). Headless: the
# Simulator boots without its window.
#
# Two hosts:
#   - by default an sshd on this Mac, 127.0.0.1, for the current user;
#   - MR_SSH_LINUX=1: a Linux container (linux-host/Dockerfile) with tmux,
#     through Docker context $MR_DOCKER_CONTEXT (colima-mremote-test). Only
#     here do the tests that start and stop tmux sessions run: on this Mac
#     they could reach the developer's own tmux server.
#
# Usage: bridge/ssh/tests/run_live_app_tests.sh [simulator name]

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVICE="${1:-iPad Pro 11-inch (M5)}"
SSHD="${MR_SSHD:-/usr/sbin/sshd}"
LINUX="${MR_SSH_LINUX:-0}"
DOCKER_CONTEXT="${MR_DOCKER_CONTEXT:-colima-mremote-test}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

work="$(mktemp -d "${TMPDIR:-/tmp}/mr-ssh-live.XXXXXX")"
sshd_pid=""
socks_pid=""
container=""
cleanup() {
    [[ -n "$socks_pid" ]] && kill "$socks_pid" 2>/dev/null || true
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
    container="$(docker --context "$DOCKER_CONTEXT" run -d --rm -p "127.0.0.1:$port:22" \
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
# The app looks for tmux on connecting; this keeps it to an empty directory
# rather than the developer's own sessions. Nothing here starts or stops tmux.
SetEnv TMUX_TMPDIR=$work/tmux
CONFIG
    mkdir -p "$work/tmux"
    "$SSHD" -D -e -f "$work/sshd_config" 2>"$work/sshd.log" &
    sshd_pid=$!
fi
# Up when it answers with its banner, not just the port: the container's
# port is open before sshd is.
for _ in $(seq 100); do
    banner="$(nc -w 1 127.0.0.1 "$port" </dev/null 2>/dev/null | head -c 4 || true)"
    [[ "$banner" == "SSH-" ]] && break
    sleep 0.2
done

# A SOCKS5 proxy, as a user would have one: OpenSSH's dynamic forward
# through the same sshd.
socks_port=$(( port + 1 ))
ssh -N -D "127.0.0.1:$socks_port" -p "$port" -i "$work/user_ed25519" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$user@127.0.0.1" &
socks_pid=$!
for _ in $(seq 50); do nc -z 127.0.0.1 "$socks_port" 2>/dev/null && break; sleep 0.1; done

cd "$REPO"
TEST_RUNNER_MREMOTE_SSH_TEST_SOCKS_PORT="$socks_port" \
TEST_RUNNER_MREMOTE_SSH_TEST_PORT="$port" \
TEST_RUNNER_MREMOTE_SSH_TEST_USER="$user" \
TEST_RUNNER_MREMOTE_SSH_TEST_KEY="$work/user_ed25519" \
TEST_RUNNER_MREMOTE_SSH_TEST_TMUX_HOST="$([[ "$LINUX" == 1 ]] && echo isolated || echo none)" \
xcodebuild test -project mRemote.xcodeproj -scheme mRemote \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath build/dd-sim-test -skipMacroValidation \
    -skipPackagePluginValidation \
    -only-testing:mRemoteTests/SSHRemoteSessionLiveTests \
    2>&1 | grep -E "Test Case|error:|\*\* TEST|Executed" || true
