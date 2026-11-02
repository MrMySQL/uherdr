#!/usr/bin/env python3
"""ssh stand-in that behaves like a remote login shell on this Mac.

Real ssh joins every word after the host with spaces, and the remote login shell
parses that line again. This does the same, `<shell> -c "<joined words>"`, in a
new session as sshd does. UHERDR_FIXTURE_SHELL picks the shell (default /bin/sh;
the tests also use /bin/dash). Only used by tests; never contacts an SSH host.
"""
import os
import sys

args = sys.argv[1:]
if "--" not in args:
    sys.stderr.write("ssh-shell-fixture: expected `-- host command…`\n")
    sys.exit(255)
args = args[args.index("--") + 1:]
if len(args) < 2:
    sys.stderr.write("ssh-shell-fixture: missing host or command\n")
    sys.exit(255)
shell = os.environ.get("UHERDR_FIXTURE_SHELL", "/bin/sh")
if os.environ.get("UHERDR_FIXTURE_CWD"):
    # Where the login shell starts (sshd starts it in the user's home).
    os.chdir(os.environ["UHERDR_FIXTURE_CWD"])
if os.environ.get("UHERDR_FIXTURE_DETACH") == "1":
    # Like sshd: the job runs in a session of its own, so stopping the
    # client (this process, and its process group) doesn't stop the job. It
    # only sees its stdin close.
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.execv(shell, [shell, "-c", " ".join(args[1:])])
    _, status = os.waitpid(pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 255)
try:
    os.setsid()
except PermissionError:
    pass  # already a process-group leader (Foundation's Process starts children that way)
os.execv(shell, [shell, "-c", " ".join(args[1:])])
