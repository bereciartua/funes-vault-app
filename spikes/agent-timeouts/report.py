#!/usr/bin/env python3
"""Summarise logs/events.jsonl (or the path given) per server process.

For each wait_seconds call: requested seconds, whether the client sent a
progressToken, and how it ended (completed and sent, cancelled by the client
after N s, client hung up after N s). For each request_memory: the
get_memory_request polls with their age and outcome.

Usage: report.py [LOG] [--agent SUBSTRING] [--since EPOCH_SECONDS]
"""

import json
import sys
import time
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main(argv):
    path = HERE / "logs" / "events.jsonl"
    agent_filter, since = None, 0.0
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--agent":
            agent_filter = args.pop(0).lower()
        elif a == "--since":
            since = float(args.pop(0))
        else:
            path = Path(a)
    if not path.exists():
        print(f"no log at {path}")
        return 1

    procs = OrderedDict()
    for line in path.read_text().splitlines():
        e = json.loads(line)
        if e["t"] < since:
            continue
        procs.setdefault(e["pid"], []).append(e)

    for pid, events in procs.items():
        name = next((e["agent"] for e in reversed(events) if e.get("agent")), "?")
        if agent_filter and agent_filter not in name.lower():
            continue
        calls = [e for e in events if e["event"] in ("wait_start", "request_created", "poll")]
        if not calls:
            continue
        t0 = events[0]["t"]
        print(f"== pid {pid}  agent={name}  started {time.strftime('%H:%M:%S', time.localtime(t0))}")
        init = next((e for e in events if e["event"] == "initialize"), None)
        if init:
            print(f"   protocol={init.get('protocol')} client={init.get('client')}")
        closed = next((e for e in events if e["event"] == "stdin_closed"), None)
        for e in events:
            ev = e["event"]
            if ev == "wait_start":
                rid, start = e["id"], e["t"]
                end = next((x for x in events if x.get("id") == rid and x["event"] in
                            ("wait_done", "wait_cancelled", "send_failed")), None)
                cancel = next((x for x in events if x["event"] == "cancel_received" and x.get("id") == rid), None)
                sent = any(x["event"] == "out" and x["message"].get("id") == rid and "result" in x["message"]
                           for x in events)
                if cancel:
                    how = f"CANCELLED by client after {cancel['t'] - start:.1f} s ({cancel.get('reason')})"
                elif sent:
                    how = f"completed, result sent after {end['t'] - start:.1f} s"
                elif closed and closed["t"] > start:
                    how = f"client hung up after {closed['t'] - start:.1f} s"
                else:
                    how = "no result (still running or killed)"
                print(f"   wait_seconds({e['seconds']:>3}) progressToken={e['has_token']!s:5} "
                      f"progress={e['progress']!s:5} -> {how}")
            elif ev == "request_created":
                print(f"   request_memory -> needs_approval request_id={e['request_id']} "
                      f"(in-call wait {e['incall_wait']} s)")
            elif ev == "poll":
                print(f"   get_memory_request({e['request_id']}) at age {e.get('age', '?')} s "
                      f"-> {e['outcome']} (poll #{e.get('polls', '?')})")
        if closed:
            print(f"   client hung up after {closed['uptime']} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
