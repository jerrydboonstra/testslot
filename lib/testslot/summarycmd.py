import getpass
import json
import time
from testslot import config
from testslot import state
from testslot import statuscmd
from testslot import util


def parse_span(text):
    """'90s', '30m', '12h', '2d' or plain seconds -> seconds."""
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    try:
        if text[-1:] in units:
            return float(text[:-1]) * units[text[-1]]
        return float(text)
    except (ValueError, IndexError):
        util.die(f"summary: --since wants a span like 30m, 12h or 2d, not {text}")


def read_history(since):
    """History lines that ended at or after `since`, oldest first, from history.jsonl.1 and history.jsonl."""
    out = []
    for path in (config.HISTORY + ".1", config.HISTORY):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(r, dict):
                        continue
                    ended = r.get("ended") or 0
                    if isinstance(ended, bool) or not isinstance(ended, (int, float)):
                        continue  # a hand-edited or half-written line: skipped, not an error for every reader
                    if ended >= since:
                        out.append(r)
        except OSError:
            pass
    return sorted(out, key=lambda r: r.get("ended") or 0)


def spread(xs):
    """median, p90 and max of a list of seconds, or None for each when empty."""
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return {"median": None, "p90": None, "max": None}
    pick = lambda q: xs[min(len(xs) - 1, int(q * len(xs)))]
    mid = len(xs) // 2
    med = xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2
    return {"median": round(med, 1), "p90": round(pick(0.9), 1), "max": round(xs[-1], 1)}


def summarize(span):
    now = time.time()
    since = now - span
    runs = read_history(since)
    timed = [r for r in runs if not r.get("lost")]  # a lost run's end is only when it was found gone
    snap = statuscmd.snapshot()
    # declared cpus over time, 24 buckets across the span: finished runs plus the ones still going
    width = span / 24
    busy = [0.0] * 24
    spans = [(r.get("started"), r.get("ended"), r.get("cpus") or 0) for r in timed]
    spans += [(j["started"], now, j["cpus"]) for j in snap["running"]]
    for s, e, c in spans:
        if not (s and e and c):
            continue
        for b in range(24):
            lo, hi = since + b * width, since + (b + 1) * width
            busy[b] += c * max(0.0, min(e, hi) - max(s, lo)) / width
    ok = [r for r in runs if r.get("exit") == 0]
    cancelled = [r for r in runs if r.get("cancelled") and not r.get("lost")]
    lost = [r for r in runs if r.get("lost")]
    by_repo = {}
    for r in runs:
        by_repo[r.get("repo") or "?"] = by_repo.get(r.get("repo") or "?", 0) + 1
    hist = {"since": round(since, 3), "until": round(now, 3), "runs": len(runs), "ok": len(ok),
            "failed": len(runs) - len(ok) - len(cancelled) - len(lost), "cancelled": len(cancelled), "lost": len(lost), "backfilled": sum(1 for r in runs if r.get("backfill")),
            "wait_s": spread([r.get("wait_s") for r in timed]), "run_s": spread([r.get("run_s") for r in timed]),
            "cpu_s": round(sum((r.get("run_s") or 0) * (r.get("cpus") or 0) for r in timed), 1),
            "by_repo": dict(sorted(by_repo.items(), key=lambda kv: -kv[1])),
            "cpus_over_time": {"bucket_s": round(width, 1), "cpus": [round(x, 2) for x in busy]}}
    return {"now": snap, "history": hist}


def cmd_summary(argv):
    span, as_json = 12 * 3600, False
    while argv:
        a = argv.pop(0)
        if a == "--json":
            as_json = True
        elif a == "--since" and argv:
            span = parse_span(argv.pop(0))
        else:
            util.die("usage: testslot summary [--since 12h] [--json]")
    if not (0 < span < float("inf")):
        util.die("summary: --since must be a span more than zero")
    state.prune(getpass.getuser())  # so a run whose wrapper was killed shows up without waiting for the next run
    out = summarize(span)
    if as_json:
        print(json.dumps(out, indent=1))
        return 0
    n, h = out["now"], out["history"]
    load = " ".join(f"{x:.2f}" for x in n["load"])
    print(f"now: load {load} on {config.CORES} cores; cap {config.read_cap()} cpus, {n['cpus_in_use']} in use; "
          f"{len(n['running'])} running, {len(n['waiting'])} waiting, {len(n['outside'])} outside testslot")
    for j in n["running"]:
        print(f"  running  {j['account']:6} {j['cpus']:>2} cpus{statuscmd.seen_text(j)}  {util.fmt_elapsed(j['started']):>7}  {j['repo']}"
              + ("  (started by backfill)" if j.get("backfill") else ""))
    for j in n["waiting"]:
        print(f"  {('#' + str(j['position'])) if j['position'] else 'stop':<3} wait {j['account']:6} {j['cpus']:>2} cpus  {util.fmt_elapsed(j['queued']):>7}  {j['repo']}"
              + ("  (cpus reserved for it)" if n["reserved_by"] and j["pid"] == n["reserved_by"]["pid"] else ""))
    span = h["until"] - h["since"]
    label = f"{span / 86400:g}d" if span >= 172800 else f"{span / 3600:g}h" if span >= 3600 else f"{span / 60:g}m"
    print(f"last {label}: {h['runs']} runs ({h['ok']} ok, {h['failed']} failed, {h['cancelled']} cancelled, "
          f"{h['lost']} lost), {round(h['cpu_s'] / 3600, 1)} cpu-hours, {h['backfilled']} started by backfill")
    for name in ("wait_s", "run_s"):
        st = h[name]
        label = "wait" if name == "wait_s" else "run "
        print(f"  {label}: median {util.secs(st['median'])}, p90 {util.secs(st['p90'])}, longest {util.secs(st['max'])}")
    bars = " ▁▂▃▄▅▆▇█"
    line = "".join(bars[min(8, round(8 * c / config.read_cap()))] for c in h["cpus_over_time"]["cpus"])
    print(f"  cpus over time (cap {config.read_cap()}, oldest left): |{line}| peak {max(h['cpus_over_time']['cpus']):.1f}")
    for repo, count in list(h["by_repo"].items())[:5]:
        print(f"  {count:>4}  {repo}")
    return 0
