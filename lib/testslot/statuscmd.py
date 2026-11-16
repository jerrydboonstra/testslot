import json
import os
import time
from testslot import admission
from testslot import config
from testslot import pacing
from testslot import procs
from testslot import state
from testslot import util


def job(h, now):
    """One holder as a job record, for status --json."""
    started = h.get("since")
    return {"pid": h.get("pid"), "pgid": h.get("pgid"), "account": h.get("account"), "repo": h.get("repo"),
            "command": h.get("command"), "kind": h.get("kind"), "cpus": state.cpus_of(h), "state": h.get("state"),
            "observed": state.valid_observed(h), "observed_via": h.get("observed_via"), "cgroup": h.get("cgroup"), "cgroup_note": h.get("cgroup_note"),
            "charged": state.charged_cpus(h), "shrunk": state.valid_observed(h) is not None and state.shrunk(h, state.cpus_of(h), state.valid_observed(h)),
            "shrink_after": state.record_shrink_after(h),
            "queued": h.get("queued"), "started": started,
            "wait_s": round((started or now) - h["queued"], 1) if h.get("queued") else None,
            "run_s": round(now - started, 1) if started else None,
            "orphan": bool(h.get("orphan")), "backfill": bool(h.get("backfill")), "log": h.get("log"),
            "wait_reason": h.get("wait_reason") if h.get("state") == "waiting" and isinstance(h.get("wait_reason"), str) else "",
            "paused": bool(h.get("paused_since") or h.get("load_paused_since")),
            "pause_reason": [r for r, k in (("load", "load_paused_since"), ("start-rate", "paused_since")) if h.get(k)],
            "pauses": h.get("pauses") or 0, "load_pauses": h.get("load_pauses") or 0, "requeued": h.get("requeued_from"),
            "limit_s": h.get("limit_s") if isinstance(h.get("limit_s"), (int, float)) and not isinstance(h.get("limit_s"), bool) else None,
            "limit_left_s": round(h["limit_s"] - (now - started), 1) if started and isinstance(h.get("limit_s"), (int, float))
                            and not isinstance(h.get("limit_s"), bool) else None}


def snapshot():
    """The queue right now: what runs, what waits (in turn order), the load and the cap."""
    now = time.time()
    hs = state.read_holders()
    known = {h["pid"] for h in hs} | {h.get("pgid") for h in hs if h.get("pgid")}
    running = [job(h, now) for h in hs if state.holds_cpus(h)]
    queue = [h for h in hs if h.get("state") == "waiting" and h.get("kind") != "track"]
    live = [h for h in queue if not procs.stopped(h["pid"])]
    waiting = [dict(job(h, now), position=n + 1, stopped=False) for n, h in enumerate(live)]
    waiting += [dict(job(h, now), position=None, stopped=True) for h in queue if procs.stopped(h["pid"])]
    tracked = [job(h, now) for h in hs if h.get("kind") == "track" and h.get("state") != "waiting"]
    outside = []
    for p, how in procs.outside_runs(known):
        acct, cwd, cmd = procs.proc_info(p)
        try:
            pgid = os.getpgid(p)
        except OSError:
            pgid = None
        outside.append({"pid": p, "pgid": pgid, "account": acct, "cwd": cwd, "command": cmd, "how": how,
                        "note": procs.outside_note() if how == "flock" else ""})
    used = sum(j["charged"] for j in running)
    held = admission.reserving(live, now)
    # the host's start rate as the freshest wrapper read it (status itself takes no reading: two are needed, a second apart)
    rates = [(h.get("host_rate_at"), h.get("host_rate")) for h in hs if isinstance(h.get("host_rate_at"), (int, float))
             and isinstance(h.get("host_rate"), (int, float)) and now - h["host_rate_at"] <= 5 * config.START_RATE_S]
    start_rate = max(rates)[1] if rates else None
    reserved_by = None
    if held:
        reserved_by = next(j for j in waiting if j["pid"] == held["pid"])
    return {"host": os.uname().nodename, "generated_at": round(now, 3), "cores": config.CORES, "cap": config.read_cap(), "load_cap": config.read_load_cap(), "platform": config.PLATFORM,
            "start_rate_cap": pacing.read_start_rate_cap(), "start_rate": start_rate,
            "load": config.loadavg(), "cpus_in_use": round(used, 2), "cpus_free": round(max(0, config.read_cap() - used), 2),
            "reserve_s": config.RESERVE, "reserved_by": reserved_by,
            "running": running, "waiting": waiting, "tracked": tracked, "outside": outside}


def seen_text(j):
    """' (using 7.9)' for a running run whose wrapper has a reading, else nothing."""
    text = f" (using {j['observed']:g})" if j.get("observed") is not None and j.get("state") != "waiting" else ""
    if j.get("shrunk") and j.get("state") != "waiting":
        text += f" [charged {j['charged']:g} of {j['cpus']}: under its size for {util.secs(j.get('shrink_after') or config.SHRINK_AFTER_S)} or more]"
    if j.get("cgroup_note") and j.get("state") != "waiting":
        text += f" [counted by process group, not cgroup: {j['cgroup_note']}]"
    return text


def cmd_status(argv):
    if argv not in ([], ["--json"]):
        util.die("usage: testslot status [--json]")
    snap = snapshot()
    if argv:
        print(json.dumps(snap, indent=1))
        return 0
    load = " ".join(f"{x:.2f}" for x in snap["load"])
    print(f"{os.uname().nodename.split('.')[0]} test slots: load {load} on {config.CORES} cores; cap {config.read_cap()} cpus, "
          f"{snap['cpus_in_use']} in use, {snap['cpus_free']} free")
    if snap["start_rate_cap"] is not None:
        now_rate = "not read (no run is reading it)" if snap["start_rate"] is None else f"{snap['start_rate']:g}/s now"
        print(f"start-rate cap {snap['start_rate_cap']:g} process starts/s for the host; {now_rate}")
    if snap["load"][0] >= config.read_load_cap():
        print(f"closed: the 1-minute load is at or over the load cap; nothing starts until it falls under {config.read_load_cap():g}")
    if not (snap["running"] or snap["waiting"] or snap["tracked"] or snap["outside"]):
        print("free: nothing running, nothing waiting")
        return 0
    for title, group, clock in (("holding", snap["running"], "started"), ("waiting", snap["waiting"], "queued"),
                                ("tracked (no slot)", snap["tracked"], "started")):
        if group:
            print(f"{title}:")
        for j in group:
            gone = "  (wrapper killed: still running, WITHOUT a slot, still counts against the cap)" if j["orphan"] else ""
            at = time.strftime("%H:%M", time.localtime(j[clock])) if j.get(clock) else "-"
            pos = ("  (stopped)" if j.get("stopped") else f"  #{j['position']}") if "position" in j else ""
            if j.get("backfill"):
                pos += "  (started by backfill)"
            if j.get("limit_s"):
                pos += f"  (limit {util.fmt_limit(j['limit_s'])}" + (f", {max(j['limit_left_s'], 0):.0f}s left)" if j.get("limit_left_s") is not None else ")")
            if j.get("state") == "waiting" and j.get("wait_reason"):
                pos += f"  (waiting: {j['wait_reason']})"
            if j.get("requeued"):
                r = j["requeued"]
                pos += (f"  (requeued once: declared {r.get('declared', 0):g}, peak {r.get('peak', 0):g}, now {r.get('cpus', 0):g}; "
                        f"a second overrun is left to the load pause)")
            if "load" in (j.get("pause_reason") or []):
                pos += f"  (paused: load {snap['load'][0]:g} on {snap['cores']} cores, using more than it declared)"
            if "start-rate" in (j.get("pause_reason") or []):
                pos += "  (paused: host starts over the start-rate cap)"
            if snap["reserved_by"] and j["pid"] == snap["reserved_by"]["pid"]:
                pos += "  (cpus reserved for it)"
            print(f"  {j['kind']:5}  {j['account']:6}  pgid {str(j['pgid'] or '-'):>7}  {at} {util.fmt_elapsed(j[clock]):>7}  "
                  f"{j['cpus']} cpus{seen_text(j)}{pos}  {j['repo']}{gone}\n         {j['command']}\n         log {j['log']}")
    if snap["outside"]:
        print("running outside testslot (an flock on the heavy file, or a test-parallel no slot holds):")
        for o in snap["outside"]:
            cmd = o["command"] if len(o["command"]) <= 160 else o["command"][:157] + "..."   # a suite names every module
            print(f"  {o['account']:6}  pgid {str(o['pgid'] or '?'):>7}  {o['cwd']}\n         {cmd}"
                  + (f"\n         its note: {o['note']}" if o["note"] else ""))
    return 0
