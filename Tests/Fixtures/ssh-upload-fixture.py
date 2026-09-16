#!/usr/bin/env python3
"""Execute the real upload shell commands locally, replacing only SSH transport."""
import os
import sys
import time

args = sys.argv[1:]
assert "BatchMode=yes" in args and "StrictHostKeyChecking=yes" in args
assert args[args.index("-l") + 1] == "tester"
assert args[args.index("-p") + 1] == "2222"
host = args[args.index("--") + 1]
if host == "denied.test":
    sys.exit("Host key verification failed")
if host == "slow.test":
    time.sleep(30)
command = args[-1]
assert "/tmp/herdr-drop-" in command
os.execl("/bin/sh", "sh", "-c", command)
