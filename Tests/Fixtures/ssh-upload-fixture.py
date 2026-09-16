#!/usr/bin/env python3
"""Execute the real upload shell commands locally, replacing only SSH transport."""
import os
import pathlib
import shlex
import subprocess
import sys
import time

args = sys.argv[1:]
assert "BatchMode=yes" in args and "StrictHostKeyChecking=yes" in args
assert args[args.index("-l") + 1] == "tester"
assert args[args.index("-p") + 1] == "2222"
host = args[args.index("--") + 1]
if host == "denied.test":
    sys.exit("Host key verification failed")
command = args[-1]
assert "/tmp/herdr-drop-" in command
parts = shlex.split(command)
root_setup = len(parts) == 4 and parts[:3] == ["umask", "077;", "mkdir"]
if root_setup and host in ("setup-failure.test", "slow.test"):
    subprocess.run(["/bin/sh", "-c", command], check=True)
    if "-i" in args:
        pathlib.Path(args[args.index("-i") + 1] + ".upload-path").write_text(parts[3])
    if host == "setup-failure.test":
        sys.exit("SETUP_DIRECTORY=" + parts[3])
    # Delay only the upload, never the cleanup connection. The caller cancels
    # after observing the directory, so no fixed sleep is needed in the test.
    time.sleep(30)
    sys.exit(0)
os.execl("/bin/sh", "sh", "-c", command)
