import math
import os
import signal
import subprocess
import sys
import threading
import time
from testslot import admission
from testslot import cgroup
from testslot import config
from testslot import sampling
from testslot import state


# XNU hands out pids in order: forkproc() in bsd/kern/kern_fork.c does `if (++pid >= PID_MAX) pid = 100;` with
# PID_MAX 99999 (bsd/sys/proc_internal.h), so the highest pid it gives is 99998 and one cycle is 100..99998, 99899 pids.
# debt: forkproc() also skips pids still in use (a live process, group or session), so an advance can overcount by those,
# mostly long-lived daemons; a skip over many is rare. Upgrade: sysctl(KERN_PROC) for the kernel's own count.
PID_MAX = 99999
PID_WRAP_TO = 100
PID_CYCLE = PID_MAX - PID_WRAP_TO   # 99899: pids 100 to 99998
_LAST_RATE_CAP = None


def _read_start_rate_cap():
    global _LAST_RATE_CAP
    path = os.path.join(config.DIR, "start-rate-cap")
    for src in (config._read(path), os.environ.get("TESTSLOT_START_RATE_CAP")):
        try:
            if src and src.strip() and math.isfinite(float(src.strip())) and float(src.strip()) > 0:
                _LAST_RATE_CAP = float(src.strip())
                return _LAST_RATE_CAP
        except ValueError:
            pass
    if not os.path.exists(path) and not os.environ.get("TESTSLOT_START_RATE_CAP"):
        return None  # no file and no override: no throttle
    return _LAST_RATE_CAP  # a file half-written this instant keeps the last good value


def read_start_rate_cap():
    """Process starts a second, for the whole host, over which a run pauses itself: $DIR/start-rate-cap, else
    TESTSLOT_START_RATE_CAP, else None (no throttle). setup-mac.sh writes 120 on a Mac; Linux has none."""
    return config._cached("start-rate-cap", _read_start_rate_cap)


def pid_starts(old, new):
    """Processes started between two macOS probe children with pids old and new: the pids handed out between them,
    across a wrap, less the second probe itself."""
    return (new - old) % PID_CYCLE - 1


class StartRate:
    """The host's process starts a second since the last reading. Linux: the `processes` counter in /proc/stat
    (every fork and clone, threads included). macOS: the pid of a child started for the purpose, since pids are
    handed out in order, so short-lived starts count too. None until two readings, or when a reading fails."""
    # debt: on macOS each running wrapper's probe adds about one start a second to every other wrapper's reading;
    # the bias is accepted (a few starts against a cap of 120). Upgrade: subtract the count of throttling wrappers.

    def __init__(self):
        self.last = None  # (counter, monotonic time)

    def counter(self):
        if not config.LINUX:
            p = subprocess.Popen(["/usr/bin/true"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            p.wait()
            return p.pid
        with open("/proc/stat", encoding="utf-8") as f:
            for line in f:
                if line.startswith("processes "):
                    return int(line.split()[1])
        return None

    def read(self):
        if config.FAKE_START_RATE:
            try:
                return float((config._read(config.FAKE_START_RATE) or "").strip())
            except ValueError:
                return None
        try:
            c, now = self.counter(), time.monotonic()
        except (OSError, ValueError):
            c, now = None, time.monotonic()
        last, self.last = self.last, (None if c is None else (c, now))
        if c is None or last is None or now <= last[1]:
            return None
        starts = pid_starts(last[0], c) if not config.LINUX else max(0, c - last[0])
        return max(0.0, starts / (now - last[1]))


def start_throttle(rec, holder_path, pgid, lock, scope, is_cancelled, stop, ask_requeue=None, ask_stop=None):
    """The start-rate throttle, a second thread of the wrapper: every START_RATE_S it reads the host's process starts.
    Over the cap (averaged over START_RATE_WINDOW readings, with the latest over 80% of it), it stops the run's group (and its cgroup) and watches the
    1-second reading. A fall of half the cap within PAUSE_MAX_S makes the burst the run's own: it resumes once the
    reading is under 80% of the cap, or after PAUSE_MAX_S, and may pause again from the next reading. No such fall:
    the burst is outside work, so the run resumes and isn't paused again for HOLD_OFF_S. `stop` ends the thread
    (the cpu sampler's event, set under `lock`); the thread resumes the group before it ends.
    A cancel (`is_cancelled`) is checked before each SIGSTOP and again right after, since the wrapper's signal handler
    can't take `lock`: a TERM must never sit pending behind a stop."""
    # debt: on macOS a pause reaches the process group only, so a child that called setsid keeps running (Linux
    # stops the cgroup too). Upgrade: walk the run's descendants by ppid and stop them as well.
    rate = StartRate()

    def signal_run(sig):
        try:
            os.killpg(pgid, sig)
        except OSError:
            pass
        cgroup.signal_scope(scope, sig)

    def say(text):
        try:
            print(f"testslot: {text}", file=sys.stderr, flush=True)
        except (OSError, ValueError):
            pass

    def loop():
        window = []
        paused_at = None      # monotonic, while paused
        base = None           # the averaged rate that tripped this pause
        own = False           # this pause saw the rate fall: the burst is the run's
        hold_until = 0.0
        last_line, since_line, paused_since_line = None, 0, 0.0
        load_at = None        # monotonic, while the load pause holds this run
        over_since = None     # monotonic: when the run's unpaused reading went over REQUEUE_X times its declaration (None: it is not over)
        lp_at_over = 0        # the load pauses counted when it did
        paused_first = None   # monotonic: when the load pause first held it since it went over: the requeue clock starts here
        asked = False         # the requeue was asked for: it is asked once

        def resume(now):
            nonlocal paused_at
            if load_at is None:  # a load pause still holds the run: it is resumed when both have cleared
                signal_run(signal.SIGCONT)
            took = now - paused_at
            paused_at = None
            with lock:
                rec["paused_since"] = None
                rec["resumed_at"] = time.time()
                rec["paused_s"] = (rec.get("paused_s") or 0) + took
                rec["max_pause_s"] = max(rec.get("max_pause_s") or 0, took)
                write()
            return took

        def write():
            if stop.is_set():
                return  # the run has removed its record, or is about to
            try:
                state.write_holder(holder_path, rec)
            except OSError:
                pass

        def load_tick(now):
            """The load pause: this wrapper pauses its own run when it is the worst over-user, and resumes it when the
            load is under the load cap. Every wrapper reads the same records, so exactly one decides it is the one."""
            nonlocal load_at
            load = config.loadavg()[0]
            if load_at is not None:
                if load < config.read_load_cap() or is_cancelled():
                    took = now - load_at
                    load_at = None
                    with lock:
                        rec["load_paused_since"] = None
                        rec["resumed_at"] = time.time()
                        rec["load_paused_s"] = (rec.get("load_paused_s") or 0) + took
                        write()
                    if paused_at is None:  # a start-rate pause still holds it otherwise
                        signal_run(signal.SIGCONT)
                    say(f"resumed after {took:.0f}s: load {load:g} is under the load cap {config.read_load_cap():g}")
                return
            if load <= config.LOAD_TRIGGER_X * config.CORES or is_cancelled():
                return
            target = sampling.worst_over_user(state.read_holders())
            if target is None or target.get("pid") != os.getpid():
                return
            seen = state.valid_observed(target)
            signal_run(signal.SIGSTOP)
            if is_cancelled():
                signal_run(signal.SIGCONT)
                return
            load_at = now
            with lock:
                rec["load_paused_since"] = time.time()
                rec["load_pauses"] = (rec.get("load_pauses") or 0) + 1
                write()
            say(f"paused: load {load:g} on {config.CORES} cores is over {config.LOAD_TRIGGER_X:g} times the cores, and this run uses "
                f"{seen:g} cpus but declared {state.cpus_of(rec):g}; it resumes when the load is under {config.read_load_cap():g}")

        def requeue_tick(now):
            """Ask the wrapper to stop this run and start it again, when requeue_due() says so. The 5 minutes count from the
            run's first load pause since its reading went over, not from when it went over, so the pause always has its turn
            first. A paused sample says nothing about what the run uses: the latest unpaused reading stands while it is paused."""
            nonlocal over_since, lp_at_over, paused_first, asked
            if ask_requeue is None or asked or is_cancelled():
                return
            with lock:
                if not state.pausing(rec):
                    seen = state.valid_observed(rec)
                    if seen is not None and seen > config.REQUEUE_X * state.cpus_of(rec):
                        if over_since is None:
                            over_since, lp_at_over, paused_first = now, rec.get("load_pauses") or 0, None
                    else:
                        over_since = paused_first = None
                if over_since is not None and paused_first is None and (rec.get("load_pauses") or 0) > lp_at_over:
                    paused_first = now
            if paused_first is None or now - paused_first < config.REQUEUE_AFTER_S:
                return
            load = config.loadavg()[0]
            if load <= config.LOAD_TRIGGER_X * config.CORES:
                return
            others = [h for h in state.read_holders() if h["pid"] != os.getpid() and h.get("state") in ("admitted", "running")
                      and h.get("kind") != "track" and not h.get("orphan")]
            if not sampling.requeue_due(rec, len(others), load, now - paused_first):
                return
            asked = True
            with lock:
                rec["requeue_peak"] = rec.get("peak")
                rec["requeue_declared"] = state.cpus_of(rec)
                rec["requeue_load"] = load
                write()
            ask_requeue()

        limit_asked = False

        def limit_tick():
            """Ask the wrapper to stop this run once its time limit has passed, when it started past a waiting run and a run
            that was ahead of it still waits. Its own check each tick, for every run with a limit (a heavy or requeued one too)."""
            nonlocal limit_asked
            # debt: checked once per START_RATE_S tick, so a stop lands up to a tick after the limit; the limit is minutes, so a tick is
            # noise. Upgrade: a timer set from the limit when the run starts.
            if ask_stop is None or limit_asked or is_cancelled():
                return
            limit, since = rec.get("limit_s"), rec.get("since")
            if not rec.get("backfill") or not limit or not since or time.time() - since <= limit:
                return
            if not admission.waiters_ahead(state.read_holders(), os.getpid(), rec.get("queued", 0)):
                return
            limit_asked = True
            ask_stop()

        try:
            while not stop.wait(config.START_RATE_S):
                limit_tick()
                requeue_tick(time.monotonic())
                load_tick(time.monotonic())
                cap = read_start_rate_cap()
                if cap is None and paused_at is None:
                    window.clear()
                    continue
                r = rate.read()
                now = time.monotonic()
                if r is not None:
                    window = (window + [r])[-config.START_RATE_WINDOW:]
                    with lock:  # for status: one small write a second, and only while a cap is set
                        rec["host_rate"], rec["host_rate_at"] = round(r, 1), time.time()
                        write()
                if paused_at is not None:
                    if cap is None:  # the cap was taken away mid-pause
                        resume(now)
                        continue
                    if r is not None and base - r >= cap / 2:
                        own = True
                    if own and (r is not None and r < 0.8 * cap or now - paused_at >= config.PAUSE_MAX_S):
                        resume(now)
                    elif now - paused_at >= config.PAUSE_MAX_S:
                        resume(now)
                        hold_until = now + config.HOLD_OFF_S
                        say(f"host starts {base:.0f}/s did not fall while this run was paused, so they are not its own; "
                            f"not pausing it for {config.HOLD_OFF_S:g}s (cap {cap:g}/s)")
                    continue
                if cap is None or not window or now < hold_until or is_cancelled():
                    continue
                avg = sum(window) / len(window)
                # the latest reading must be over the resume line too: just after a resume the average still holds the
                # pre-pause readings, and pausing a run whose rate has already fallen would only flap
                if avg <= cap or r is None or r < 0.8 * cap:
                    continue
                signal_run(signal.SIGSTOP)
                if is_cancelled():  # a cancel began between the check and the stop: let its TERM through at once
                    signal_run(signal.SIGCONT)
                    continue
                paused_at, base, own = now, avg, False
                with lock:
                    rec["paused_since"] = time.time()
                    rec["pauses"] = (rec.get("pauses") or 0) + 1
                    write()
                since_line += 1
                if last_line is None:
                    say(f"paused (up to {config.PAUSE_MAX_S:g}s): host starts {avg:.0f}/s, cap {cap:g}/s")
                    last_line, since_line, paused_since_line = now, 0, rec.get("paused_s") or 0
                elif now - last_line >= config.PAUSE_REPORT_S:
                    took = (rec.get("paused_s") or 0) - paused_since_line
                    say(f"paused {since_line} times in {now - last_line:.0f}s ({took:.0f}s), host starts {avg:.0f}/s, cap {cap:g}/s")
                    last_line, since_line, paused_since_line = now, 0, rec.get("paused_s") or 0
        finally:
            if load_at is not None:  # likewise for the load pause
                signal_run(signal.SIGCONT)
                with lock:
                    rec["load_paused_since"] = None
            if paused_at is not None:  # however the thread ends, the run is left running
                signal_run(signal.SIGCONT)
                with lock:
                    took = time.monotonic() - paused_at
                    rec["paused_since"] = None
                    rec["paused_s"] = (rec.get("paused_s") or 0) + took
                    rec["max_pause_s"] = max(rec.get("max_pause_s") or 0, took)

    thread = threading.Thread(target=loop, daemon=True)
    mask = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGALRM, signal.SIGUSR1, signal.SIGUSR2}
    signal.pthread_sigmask(signal.SIG_BLOCK, mask)  # signals go to the main thread, as for the sampler
    try:
        thread.start()
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, mask)
    return thread
