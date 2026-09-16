#!/bin/bash
# Requires installed, authenticated Codex and Claude Code. Sends generated test
# text/images to both services. Uses a disposable Herdr server and localhost SSH.
set -euo pipefail
cd "$(dirname "$0")/.."
HERDR_TEST_BIN="${HERDR_BIN:-$(command -v herdr)}"
command -v codex >/dev/null
command -v claude >/dev/null
TEST_ROOT="$(mktemp -d /tmp/herdr-agent-drops.XXXXXX)"
TEST_SOCKET="$TEST_ROOT/config/herdr/sessions/native-client-test/herdr.sock"
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        for log in server.log ssh.log ssh-client.log; do
            if [ -f "$TEST_ROOT/$log" ]; then
                printf '\n%s:\n' "$log" >&2
                cat "$TEST_ROOT/$log" >&2
            fi
        done
    fi
    env -u HERDR_SESSION HERDR_SOCKET_PATH="$TEST_SOCKET" "$HERDR_TEST_BIN" server stop >/dev/null 2>&1 || true
    if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    if [ -n "${SSH_PID:-}" ]; then kill "$SSH_PID" 2>/dev/null || true; wait "$SSH_PID" 2>/dev/null || true; fi
    python3 - "$TEST_ROOT" <<'PY'
import pathlib, re, shutil, sys
root = pathlib.Path(sys.argv[1])
log = root / 'uploads'
if log.exists():
    for path in log.read_text().splitlines():
        if re.fullmatch(r'/tmp/herdr-drop-[A-Fa-f0-9-]{36}', path):
            shutil.rmtree(path, ignore_errors=True)
shutil.rmtree(root)
PY
    exit "$status"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/client_key"
cp "$TEST_ROOT/client_key.pub" "$TEST_ROOT/authorized_keys"
TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
cat > "$TEST_ROOT/sshd_config" <<EOF
Port $TEST_PORT
ListenAddress 127.0.0.1
HostKey $TEST_ROOT/host_key
PidFile $TEST_ROOT/sshd.pid
AuthorizedKeysFile $TEST_ROOT/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowUsers $(id -un)
EOF
python3 - "$TEST_ROOT" "$TEST_PORT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
key = (root / 'host_key.pub').read_text().split()
(root / 'known_hosts').write_text('[127.0.0.1]:' + sys.argv[2] + ' ' + ' '.join(key[:2]) + '\n')
(root / 'ssh').write_text('''#!/usr/bin/env python3
import os, pathlib, shlex, sys
root = pathlib.Path(__file__).parent
command = shlex.split(sys.argv[-1])
if len(command) == 4 and command[:3] == ['umask', '077;', 'mkdir']:
    with (root / 'uploads').open('a') as log:
        log.write(command[3] + '\\n')
os.execv('/usr/bin/ssh', ['ssh', '-o', 'UserKnownHostsFile=' + str(root / 'known_hosts')] + sys.argv[1:])
''')
(root / 'ssh').chmod(0o755)
PY
/usr/sbin/sshd -D -e -f "$TEST_ROOT/sshd_config" > "$TEST_ROOT/ssh.log" 2>&1 &
SSH_PID=$!
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/state"
env -u HERDR_SESSION -u HERDR_SOCKET_PATH XDG_CONFIG_HOME="$TEST_ROOT/config" XDG_STATE_HOME="$TEST_ROOT/state" \
    "$HERDR_TEST_BIN" --session native-client-test server > "$TEST_ROOT/server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
    if ! kill -0 "$SSH_PID" 2>/dev/null; then
        printf 'Test SSH server exited during startup.\n' >&2
        exit 1
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        printf 'Test Herdr server exited during startup.\n' >&2
        exit 1
    fi
    [ -S "$TEST_SOCKET" ] && break
    sleep 0.1
done
if [ ! -S "$TEST_SOCKET" ]; then
    printf 'Timed out waiting for the test Herdr socket.\n' >&2
    exit 1
fi
SSH_READY=false
for _ in {1..100}; do
    if ! kill -0 "$SSH_PID" 2>/dev/null; then
        printf 'Test SSH server exited during startup.\n' >&2
        exit 1
    fi
    if "$TEST_ROOT/ssh" -p "$TEST_PORT" -i "$TEST_ROOT/client_key" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=1 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=yes "$(id -un)@127.0.0.1" true > "$TEST_ROOT/ssh-client.log" 2>&1; then
        SSH_READY=true
        break
    fi
    sleep 0.1
done
if [ "$SSH_READY" != true ]; then
    printf 'Could not authenticate to the test SSH server.\n' >&2
    exit 1
fi
export HERDR_DROP_TEST_ROOT="$TEST_ROOT"
export HERDR_DROP_TEST_SSH="$TEST_ROOT/ssh"
export HERDR_DROP_TEST_KEY="$TEST_ROOT/client_key"
export HERDR_DROP_TEST_PORT="$TEST_PORT"
bash scripts/test-terminal-keyboard.sh --agent-drops "$TEST_SOCKET" "$HERDR_TEST_BIN"
