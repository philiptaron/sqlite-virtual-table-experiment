"""
What a process can tell about a lock it holds on NFS, and so whether it
has lost it. Run by test/nfs-cluster.nix:

  lockprobe LOCK GO OUT

Locks LOCK the way Nix locks a path (a blocking fcntl write lock on the
whole file) and writes "locked" to OUT. Once the file GO exists, tries
each check on the locked file descriptor and writes what each returned to
OUT as a line of JSON. It does that again once GO.again exists, and then
also tries taking the lock again. Then it waits for GO.exit before
exiting, and so unlocking.

Nothing here closes another descriptor for LOCK: closing any of them
would drop all of this process's locks on it.
"""

import errno
import fcntl
import json
import os
import sys
import time

lock, go, out = sys.argv[1:]


def wait_for(path):
    while not os.path.exists(path):
        time.sleep(0.2)


def attempt(fn):
    try:
        result = fn()
        return "ok" if result is None else f"ok: {result!r}"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))


def pread_direct(fd):
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_DIRECT)
    try:
        return os.pread(fd, 1, 0)
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFL, flags)


def in_proc_locks(fd):
    """Our lock's line in /proc/locks, which the kernel keeps locally."""
    st = os.fstat(fd)
    ino = f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"
    with open("/proc/locks") as f:
        mine = [l.strip() for l in f if f" {os.getpid()} " in l and ino in l]
    return mine or "not there"


fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.lockf(fd, fcntl.LOCK_EX)
with open(out, "w") as f:
    f.write("locked\n")
wait_for(go)

checks = {
    "fstat": lambda: os.fstat(fd).st_size,
    "pread": lambda: os.pread(fd, 1, 0),
    "pread O_DIRECT": lambda: pread_direct(fd),
    "pwrite 0 bytes": lambda: os.pwrite(fd, b"", 0),
    "/proc/locks": lambda: in_proc_locks(fd),
}


def probe(round, extra={}):
    results = {"round": round, "kernel": os.uname().release}
    for name, fn in {**checks, **extra}.items():
        results[name] = attempt(fn)
    with open(out, "a") as f:
        f.write(json.dumps(results) + "\n")


probe("first")
wait_for(go + ".again")
# Last, since taking the lock again may change what the others see.
probe("again", {"lock again": lambda: fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)})
wait_for(go + ".exit")
