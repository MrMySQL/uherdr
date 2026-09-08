#!/usr/bin/env python3
"""Disposable TUI: a tool call expands only when its first cell is clicked."""
import os
import re
import sys
import termios
import tty

fd = sys.stdin.fileno()
original = termios.tcgetattr(fd)
pending = b''
expanded = False


def write(data):
    os.write(sys.stdout.fileno(), data)


def draw():
    write(b'\x1b[H' + (b'v tool-expanded ' if expanded else b'> tool-collapsed'))
    write(b'\x1b[2;1H' + (b'tool-result: success' if expanded else b'\x1b[2K'))


try:
    tty.setraw(fd)
    write(b'\x1b[2J\x1b[H\x1b[?1000h\x1b[?1006h')
    draw()
    while True:
        pending += os.read(fd, 1024)
        while pending:
            if pending.startswith(b'\x1b'):
                match = re.match(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])', pending)
                if not match:
                    break
                button, column, row = map(int, match.groups()[:3])
                write(b'\x1b[4;1Hreceived: ' + repr(match[0]).encode('ascii') + b'\x1b[K')
                if (button, column, row) == (0, 1, 1):
                    if match[4] == b'M':
                        expanded = not expanded
                        draw()
                    else:
                        write(b'\x1b[3;1Hmouse-release-received')
                pending = pending[match.end():]
            else:
                key, pending = pending[:1], pending[1:]
                if key == b'q':
                    sys.exit(0)
                if key == b'd':
                    write(b'\x1b[?1000l\x1b[?1006l')
                elif key == b'e':
                    write(b'\x1b[?1000h\x1b[?1006h')
finally:
    write(b'\x1b[?1000l\x1b[?1006l\x1b[4;1Hmouse-fixture-finished\r\n')
    termios.tcsetattr(fd, termios.TCSANOW, original)
