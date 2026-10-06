#!/usr/bin/env python3
"""
codex_passive_snapshot.py - TokenBar fallback: newest Codex rate-limit snapshot from local rollouts.

Zero network, zero credentials. Reads only the TAIL of the newest rollout files in
$CODEX_HOME/sessions (and archived_sessions), looks at `event_msg` lines whose payload
is `token_count` with a `rate_limits` object, and merges the sparse updates:
the newest non-null `primary` and the newest non-null `secondary` are kept separately,
each with its own observation time. Windows whose `resets_at` has passed are reported
as reset (effectiveUsedPercent = 0), because the snapshot predates the reset.

Output is normalized to the app-server v2 camelCase shape plus provenance fields.
"""
import glob
import json
import os
import sys
import time
from datetime import datetime, timezone

TAIL_BYTES = 512 * 1024
MAX_FILES = 8
LIMIT_ID = "codex"


def newest_rollouts(home):
    pats = [os.path.join(home, d, "**", "rollout-*.jsonl") for d in ("sessions", "archived_sessions")]
    files = [f for p in pats for f in glob.glob(p, recursive=True)]
    return sorted(files, key=os.path.getmtime, reverse=True)[:MAX_FILES]


def tail_lines(path, nbytes=TAIL_BYTES):
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - nbytes))
        data = fh.read()
    lines = data.split(b"\n")
    if size > nbytes:
        lines = lines[1:]  # first line is probably partial
    return lines


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def main():
    home = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
    best = {"primary": None, "secondary": None, "meta": None}
    for f in newest_rollouts(home):
        for raw in tail_lines(f):
            if b'"rate_limits"' not in raw:
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            p = o.get("payload") or {}
            rl = p.get("rate_limits")
            if p.get("type") != "token_count" or not isinstance(rl, dict):
                continue
            if rl.get("limit_id") not in (None, LIMIT_ID):
                continue  # e.g. "premium" buckets
            ts = parse_ts(o.get("timestamp", ""))
            for k in ("primary", "secondary"):
                w = rl.get(k)
                if w and (best[k] is None or ts > best[k][0]):
                    best[k] = (ts, w, os.path.basename(f))
            if best["meta"] is None or ts > best["meta"][0]:
                best["meta"] = (ts, rl)
        if best["primary"] and best["secondary"]:
            break  # newest file(s) already gave both windows

    now = time.time()
    out = {"source": "rollout", "codexHome": home, "limitId": LIMIT_ID}
    if best["meta"]:
        rl = best["meta"][1]
        out["planType"] = rl.get("plan_type")
        out["credits"] = rl.get("credits")
        out["rateLimitReachedType"] = rl.get("rate_limit_reached_type")
        out["lastEventAt"] = datetime.fromtimestamp(best["meta"][0], timezone.utc).isoformat()
    for k in ("primary", "secondary"):
        if not best[k]:
            out[k] = None
            continue
        ts, w, fn = best[k]
        resets_at = w.get("resets_at")
        if resets_at is None and w.get("resets_in_seconds") is not None:  # older Codex builds
            resets_at = ts + w["resets_in_seconds"]
        reset_passed = resets_at is not None and resets_at <= now
        out[k] = {
            "usedPercent": w.get("used_percent"),
            "windowDurationMins": w.get("window_minutes"),
            "resetsAt": resets_at,
            "observedAt": datetime.fromtimestamp(ts, timezone.utc).isoformat(),
            "ageMin": round((now - ts) / 60, 1),
            "resetPassed": reset_passed,
            "effectiveUsedPercent": 0 if reset_passed else w.get("used_percent"),
            "file": fn,
        }
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
