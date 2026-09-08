#!/usr/bin/env python3
"""Controlled SSH stand-in: discovery/errors and real Unix-stream forwarding.

Only used by tests with disposable local sockets; never contacts an SSH host.
"""
import os
import select
import socket
import sys
import threading
import time

args = sys.argv[1:]
parent_pid = os.getppid()
# A crashed assertion cannot run Swift defers. Exit with its test owner anyway.
def watch_parent():
    while os.getppid() == parent_pid:
        time.sleep(0.2)
    os._exit(0)

threading.Thread(target=watch_parent, daemon=True).start()
host = args[args.index("--") + 1]
if host == "denied.test":
    print("Host key verification failed.", file=sys.stderr)
    sys.exit(255)
if host == "slow.test":
    time.sleep(30)
    sys.exit(0)
if "-L" not in args:
    print("Login banner")
    print("UHERDR_HOME=/Users/remote")
    print("UHERDR_SOCKET=/tmp/herdr-fixture-default.sock")
    sys.exit(0)
if host == "forward-failure.test":
    print("Could not request local forwarding.", file=sys.stderr)
    sys.exit(255)

forwards = [args[index + 1].split(":", 1) for index, arg in enumerate(args) if arg == "-L"]
for local, remote in forwards:
    if not local.startswith("/tmp/uh-") or not remote.startswith("/tmp/"):
        sys.exit("Fixture requires disposable /tmp sockets")

def forward(client, remote):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(remote)
        while True:
            readable, _, _ = select.select([client, upstream], [], [], 10)
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                (upstream if source is client else client).sendall(data)
    except (OSError, ConnectionError):
        pass
    finally:
        client.close()
        upstream.close()

listeners = {}
for local, remote in forwards:
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(local)
    listener.listen()
    listeners[listener] = remote
while True:
    readable, _, _ = select.select(listeners, [], [])
    for listener in readable:
        client, _ = listener.accept()
        threading.Thread(target=forward, args=(client, listeners[listener]), daemon=True).start()
