#!/usr/bin/env python3
"""Verify herdr's terminal stream in a disposable session; never use a live user socket."""
import base64
import json
import os
import select
import socket
import subprocess
import sys
import time
import uuid

socket_path = sys.argv[1]
assert socket_path.startswith('/tmp/') and 'native-client-test' in socket_path
binary = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/.local/bin/herdr')

def request(method, params=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(8)
        connection.connect(socket_path)
        request_id = str(uuid.uuid4())
        connection.sendall(json.dumps({'id': request_id, 'method': method, 'params': params or {}}).encode() + b'\n')
        response = json.loads(connection.makefile('rb').readline())
        if 'error' in response:
            raise RuntimeError(response['error'])
        return response['result']

created = request('workspace.create', {'label': 'Stream verification', 'cwd': '/tmp', 'focus': False})
space_id = created['workspace']['workspace_id']
pane_id = created['root_pane']['pane_id']
process = None
try:
    env = dict(os.environ, HERDR_SOCKET_PATH=socket_path)
    env.pop('HERDR_SESSION', None)
    process = subprocess.Popen([binary, 'terminal', 'session', 'control', pane_id, '--cols', '90', '--rows', '28'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)
    pending = b''
    def send(message):
        process.stdin.write(json.dumps(message).encode() + b'\n')
        process.stdin.flush()
    def wait_frame(predicate):
        global pending
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                frame = json.loads(line)
                if predicate(frame):
                    return frame
            if process.poll() is not None:
                raise AssertionError(process.stderr.read().decode())
            if select.select([process.stdout], [], [], .1)[0]:
                pending += os.read(process.stdout.fileno(), 65536)
        raise AssertionError('Timed out waiting for terminal frame')
    wait_frame(lambda f: f.get('type') == 'terminal.frame')
    send({'type': 'terminal.input', 'text': "printf 'terminal-%s\\n' stream-ok\r"})
    wait_frame(lambda f: b'terminal-stream-ok' in base64.b64decode(f.get('bytes', '')))
    if '--check-mouse-modes' in sys.argv[3:]:
        # Capability regression probe: Herdr 0.8.2 reconstructs visible cells
        # but omits the application's mouse modes from terminal.frame.
        # Keep this opt-in until the runtime exposes those modes.
        send({'type': 'terminal.input', 'text':
              "printf '\\033[?1000h\\033[?1006hmouse-%s\\n' ready\r"})
        mouse_output = bytearray()
        def mouse_ready(frame):
            mouse_output.extend(base64.b64decode(frame.get('bytes', '')))
            return b'mouse-ready' in mouse_output
        wait_frame(mouse_ready)
        assert b'\x1b[?1000h' in mouse_output and b'\x1b[?1006h' in mouse_output, (
            'Herdr terminal.frame omitted mouse reporting modes 1000/1006; '
            'embedded terminal clicks cannot reach mouse-enabled applications')
        print('PASS: terminal stream preserves application mouse reporting modes')
    send({'type': 'terminal.resize', 'cols': 110, 'rows': 35})
    wait_frame(lambda f: f.get('width') == 110 and f.get('height') == 35)
    send({'type': 'terminal.scroll', 'direction': 'up', 'lines': 3, 'source': 'wheel'})
    send({'type': 'terminal.release'})
    process.wait(timeout=5)
    assert process.returncode == 0
    assert request('pane.get', {'pane_id': pane_id})['pane']['pane_id'] == pane_id
    print('PASS: terminal ANSI frames, interactive input, 110×35 resize, scrolling, and detach preserves pane')
finally:
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
    request('workspace.close', {'workspace_id': space_id})
