#!/usr/bin/env python3
"""Capture one paste from a real PTY, without interpreting or submitting it."""
import os
import select
import sys
import termios
import tty

original = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b'\x1b[?2004hpaste-fixture-ready\r\n')
    received = bytearray()
    while select.select([0], [], [], 10 if not received else 1)[0]:
        received.extend(os.read(0, 65536))
    with open(sys.argv[1], 'wb') as capture:
        capture.write(received)
    os.write(1, b'\x1b[?2004lpaste-fixture-done\r\n')
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
