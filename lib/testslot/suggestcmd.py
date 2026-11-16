import math
from testslot import admission
from testslot import summarycmd
from testslot import util


def cmd_suggest(argv):
    """Print the last recorded peak cpu for a key as a whole number, or --default N, or nothing. The latest
    finished, non-cancelled light run with that key and a usable reading wins (not the highest), and a key with no
    such run in the two history generations gives the default. A suggestion above the cap is clamped by `run --cpus`,
    which says so on the caller's stderr. Runs of kind track (their reading is waiting on an API) and heavy (the whole
    box by definition) are never recorded or offered."""
    # debt: reads both history files in full on every call (up to 2 x HISTORY_MAX, so some tens of ms); upgrade:
    # keep a small per-key index file, or read the files backwards and stop at the first match.
    key, default = None, None
    while argv:
        a = argv.pop(0)
        if a == "--key" and argv:
            key = admission.store_key(argv.pop(0))
        elif a == "--default" and argv:
            n = argv.pop(0)
            if not n.isdigit() or int(n) < 1:
                util.die(f"suggest: --default wants a whole number of 1 or more, not {n}")
            default = int(n)
        elif a == "--":
            if not argv:
                util.die("usage: testslot suggest [--default N] (--key KEY | -- <command...>)")
            key = admission.derive_key(argv)
            break
        else:
            util.die(f"suggest: unknown option {a}")
    if key is None:
        util.die("usage: testslot suggest [--default N] (--key KEY | -- <command...>)")
    peak = None
    try:  # a record, not a gate: whatever goes wrong reading it, the caller gets its default or nothing
        for r in summarycmd.read_history(0):
            p = r.get("peak")
            if (r.get("key") == key and r.get("kind") not in ("track", "heavy") and not r.get("cancelled")
                    and isinstance(p, (int, float))
                    and not isinstance(p, bool) and math.isfinite(p) and p >= 0):
                peak = p   # oldest first, so the last one that fits is the latest run
    except Exception:
        peak = None
    if peak is not None:
        print(max(1, math.ceil(peak)))
    elif default is not None:
        print(default)
    return 0
