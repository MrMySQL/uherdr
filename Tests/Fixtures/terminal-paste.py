#!/usr/bin/env python3
"""Capture one paste from a real PTY, without interpreting or submitting it."""
import os
import select
import sys
import termios
import tty

original = termios.tcgetattr(0)
mode = sys.argv[2] if len(sys.argv) > 2 else 'on'
try:
    tty.setraw(0)
    os.write(1, b'\x1b[?2004' + (b'h' if mode == 'on' else b'l')
             + ('paste-fixture-ready-' + mode + '\r\n').encode())
    received = bytearray()
    while select.select([0], [], [], 10 if not received else 1)[0]:
        received.extend(os.read(0, 65536))
    with open(sys.argv[1], 'wb') as capture:
        capture.write(received)
    os.write(1, b'\x1b[?2004l' + ('paste-fixture-done-' + mode + '\r\n').encode())
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
