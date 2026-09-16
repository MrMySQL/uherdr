#!/usr/bin/env python3
"""Disposable TUI: a tool call expands only when its first cell is clicked."""
import os
import base64
import re
import sys
import termios
import tty

fd = sys.stdin.fileno()
original = termios.tcgetattr(fd)
pending = b''
expanded = False
selection_start = None
selection_dragged = False
copy_count = 0


def write(data):
    os.write(sys.stdout.fileno(), data)


def draw():
    write(b'\x1b[H' + (b'v tool-expanded ' if expanded else b'> tool-collapsed'))
    write(b'\x1b[2;1H' + (b'tool-result: success' if expanded else b'\x1b[2K'))
    for row in range(5, 11):
        write(('\x1b[%d;1HSelect application-owned text café' % row).encode())
    size = os.get_terminal_size(fd)
    write(('\x1b[12;1Hpty-size: %dx%d' % (size.columns, size.lines)).encode())


try:
    tty.setraw(fd)
    write(b'\x1b[2J\x1b[H\x1b[?1002h\x1b[?1006h')
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
                if button == 0 and match[4] == b'M' and row >= 5:
                    selection_start = (column, row)
                    selection_dragged = False
                elif button == 32 and selection_start is not None:
                    selection_dragged = True
                elif button == 0 and match[4] == b'm' and selection_dragged:
                    copy_count += 1
                    payload = 'Native application selection café'.encode()
                    write(b'\x1b]52;c;' + base64.b64encode(payload) + b'\x07')
                    write(('\x1b[13;1Happlication-copy-count: %d' % copy_count).encode())
                    selection_start = None
                    selection_dragged = False
                pending = pending[match.end():]
            else:
                key, pending = pending[:1], pending[1:]
                if key == b's':
                    draw()
                if key == b'c':
                    write(b'\x1b]52;c;' + base64.b64encode(b'unfocused-application-copy') + b'\x07')
                    write(b'\x1b[14;1Hunfocused-copy-requested')
                if key == b'q':
                    write(b'\x1b]52;c;' + base64.b64encode(b'final-application-copy') + b'\x07')
                    sys.exit(0)
                if key == b'd':
                    write(b'\x1b[?1002l\x1b[?1006l')
                elif key == b'e':
                    write(b'\x1b[?1002h\x1b[?1006h')
finally:
    write(b'\x1b[?1002l\x1b[?1006l\x1b[4;1Hmouse-fixture-finished\r\n')
    termios.tcsetattr(fd, termios.TCSANOW, original)
