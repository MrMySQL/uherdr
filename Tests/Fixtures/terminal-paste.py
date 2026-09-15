#!/usr/bin/env python3
"""Capture one paste from a real PTY, without interpreting or submitting it."""
import os
import select
import sys
import termios
import time
import tty

original = termios.tcgetattr(0)
mode = sys.argv[2] if len(sys.argv) > 2 else 'on'
expected = int(sys.argv[3])
if expected <= 0:
    raise ValueError('expected byte count must be positive')
try:
    tty.setraw(0)
    os.write(1, b'\x1b[?2004' + (b'h' if mode == 'on' else b'l')
             + ('paste-fixture-ready-' + mode + '\r\n').encode())
    received = bytearray()
    deadline = time.monotonic() + 10
    # The caller knows the complete input size, including consecutive pastes
    # and Enter. A closer cannot delimit the mode-off case or the first paste.
    while len(received) < expected:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([0], [], [], remaining)[0]:
            break
        chunk = os.read(0, 65536)
        if not chunk:
            break
        received.extend(chunk)
    with open(sys.argv[1], 'wb') as capture:
        capture.write(received)
    outcome = 'done' if len(received) == expected else 'failed'
    os.write(1, b'\x1b[?2004l' + ('paste-fixture-' + outcome + '-' + mode + '\r\n').encode())
    if outcome == 'failed':
        raise RuntimeError(f'expected {expected} bytes, received {len(received)} before deadline/EOF')
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
