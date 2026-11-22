import math
import os
import signal
import threading
import time
from testslot import cgroup
from testslot import config
from testslot import state


def fake_observed(pgid=None):
    """The reading tests put in TESTSLOT_OBSERVED_DIR/<pgid> (this run's own), else in TESTSLOT_OBSERVED, or None."""
    try:
        if config.OBSERVED_DIR and pgid is not None:
            own = config._read(os.path.join(config.OBSERVED_DIR, str(pgid)))
            if own is not None and own.strip():
                return float(own.strip())
        return float((config._read(config.OBSERVED_FILE) or "").strip()) if config.OBSERVED_FILE else None
    except ValueError:
        return None


def start_sampler(rec, holder_path, pgid, lock, scope=None):
    """Sample this run's cgroup (`scope`), else its group, every SAMPLE_S in a thread of the wrapper and record it in the holder (`observed`,
    cores, over the last interval; no further averaging). The thread never touches the turnstile, only this
    run's own file, and `stop` ends it: set it under `lock` before the wrapper's last write, so the thread
    can't put a record back after the run has removed it. Returns (stop event, thread)."""
    # debt: one interval is the window, so a one-tick burst can hold the next start back for a few seconds;
    # upgrade: average the last two intervals. Processes that start and exit between samples go uncounted on the
    # process-group path (see group_cpu_seconds).
    stop = threading.Event()

    def loop():
        pids = {}
        before, at = (cgroup.cgroup_cpu_seconds(scope) if scope else cgroup.group_cpu_seconds(pgid, pids)), time.monotonic()
        low_since = None  # when the reading first fell under the declaration, and stayed there (monotonic)
        while not stop.wait(config.SAMPLE_S):
            seen = fake_observed(pgid) if (config.OBSERVED_FILE or config.OBSERVED_DIR) else None
            now = time.monotonic()
            total = None  # cpu seconds the run has used so far, for the history line (the tests check it against the real cost)
            if not (config.OBSERVED_FILE or config.OBSERVED_DIR):
                cpu = cgroup.cgroup_cpu_seconds(scope) if scope else cgroup.group_cpu_seconds(pgid, pids)
                total = None if cpu is None else round(cpu, 2)
                if cpu is not None and before is not None and now > at:
                    seen = max(0.0, (cpu - before) / (now - at))
                before, at = cpu, now
            seen = None if seen is None else round(seen, 2)
            with lock:
                if stop.is_set():
                    return
                peak = rec.get("peak")
                declared = state.cpus_of(rec)
                if state.pausing(rec):
                    shrink = bool(rec.get("shrunk"))  # a paused sample's near-zero cpu moves the shrink clock neither way
                elif (rec.get("observed_via") == "cgroup" and rec.get("kind") == "light" and seen is not None
                        and state.valid_observed(dict(rec, observed=seen)) is not None and seen < declared):
                    low_since = now if low_since is None else low_since
                    shrink = now - low_since >= config.SHRINK_AFTER_S
                else:
                    low_since, shrink = None, False  # a bad read, a climb back or a group reading restarts the clock
                if (rec.get("kind") == "light" and seen is not None
                        and state.valid_observed(dict(rec, observed=seen)) is not None and seen > (peak or 0)):
                    peak = seen   # the highest usable reading so far, for the history line; None readings count for nothing
                if (rec.get("observed") == seen and rec.get("peak") == peak and rec.get("cpu_s") == total
                        and bool(rec.get("shrunk")) == shrink and not shrink):  # a shrunk record is rewritten every sample
                    continue
                rec["shrunk"] = shrink
                rec["sampled_at"] = time.time() if shrink else None
                rec["sample_s"] = config.SAMPLE_S
                rec["shrink_after"] = config.SHRINK_AFTER_S  # N and the margin as this run's wrapper reads them, for status and the charge
                rec["shrink_margin"] = config.SHRINK_MARGIN
                rec["observed"] = seen  # None when this read failed: the run is charged what it declared
                rec["peak"] = peak
                rec["cpu_s"] = total
                try:
                    state.write_holder(holder_path, rec)
                except OSError:
                    pass

    thread = threading.Thread(target=loop, daemon=True)
    mask = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGALRM, signal.SIGUSR1, signal.SIGUSR2}
    signal.pthread_sigmask(signal.SIG_BLOCK, mask)  # a new thread inherits the mask: signals go to the main thread
    try:
        thread.start()
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, mask)
    return stop, thread


def worst_over_user(hs):
    """The holder to pause when the load is too high, or None. Light runs that are running, with a usable reading above
    what they declared, and not already paused by the load pause; the largest over-use in cpus wins, a tie going to the
    one started last. None when this would leave fewer than two runs going: a lone run is never paused."""
    live = [h for h in hs if h.get("state") in ("admitted", "running") and h.get("kind") != "track" and not h.get("orphan")]
    going = [h for h in live if not state.pausing(h)]
    if len(going) < 2:
        return None
    best = None
    for h in going:
        seen = state.valid_observed(h)
        if h.get("kind") != "light" or seen is None:
            continue
        over = round(seen - state.cpus_of(h), 2)
        if over <= 0:
            continue
        key = (over, h.get("since") or h.get("queued") or 0, h["pid"])
        if best is None or key > best[0]:
            best = (key, h)
    return best[1] if best else None


def requeue_size(peak):
    """What the run declares when it starts again: its peak, rounded up, held to the cap as it is now."""
    return int(min(max(1, math.ceil(peak)), max(1, config.read_cap())))


def requeue_due(rec, others_going, load, since_pause):
    """Whether this run is to be stopped and started again: a light run still reading over REQUEUE_X times its declared cpus
    that was first paused by the load pause since_pause seconds ago (None: it has not been paused since it went over, or it
    is not over), with the load over the trigger and another run going. Never a heavy, track, CI or already requeued run (a requeue would start it again without --ci), and
    never one with no usable reading (it is not over then)."""
    return (rec.get("kind") == "light" and not rec.get("ci") and not rec.get("requeued_from") and others_going >= 1 and since_pause is not None
            and since_pause >= config.REQUEUE_AFTER_S and load > config.LOAD_TRIGGER_X * config.CORES)


def stop_sampler(sampler):
    """End the run's sampler: the flag is set under the lock, so no write follows it."""
    if sampler:
        stop, thread, lock, throttle = sampler
        with lock:
            stop.set()
        thread.join(timeout=3)
        throttle.join(timeout=3)  # it resumes a stopped group on its way out
