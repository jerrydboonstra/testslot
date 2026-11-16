import os
import sys
import time


RAN = [None]  # the exit code of a command that has finished, so an internal error after it can't replace it
INTERNAL_ERROR = 70  # no test runner uses it for a failed suite; see the exit codes in the docstring


def die(msg, code=2):
    print(f"testslot: {msg}", file=sys.stderr)
    sys.exit(code)


def open_lock(path):
    """Open a lock file, creating it group-writable (0660) if missing, so the other account can open it too."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o660)
        os.fchmod(fd, 0o660)  # umask 022 would otherwise drop the group's write bit
        return fd
    except FileExistsError:
        pass
    try:
        return os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    except PermissionError:
        return os.open(path, os.O_RDONLY | os.O_NOFOLLOW)  # flock works on a read-only descriptor


def clock_seconds(text):
    """ps's cumulative cpu time, [[dd-]hh:]mm:ss[.ss], in seconds; None if it isn't that."""
    try:
        days, _, rest = text.rpartition("-")
        secs = 0.0
        for part in rest.split(":"):
            secs = secs * 60 + float(part)
        return secs + (float(days) * 86400 if days else 0)
    except ValueError:
        return None


def fmt_limit(s):
    return f"{s / 60:g}m" if s % 60 == 0 else f"{s:g}s"


def fmt_elapsed(t):
    if not t:
        return "-"
    s = int(time.time() - t)
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def secs(x):
    if x is None:
        return "-"
    x = int(x)
    return f"{x // 3600}h{x % 3600 // 60:02d}m" if x >= 3600 else f"{x // 60}m{x % 60:02d}s"
