#!/usr/bin/env python3
"""Phase 13a.2: export recorded model calls for the Swift fixture harness. Replays a results file through facts.py exactly
as replay.py does (recorded order and mode) and writes, per call, what the Swift side needs to replay it and to check its
validation against this one:

    python3 export_replay.py <results.jsonl> <fixture.json> <out.jsonl> [--every N]

Each line: story, orderIndex, call (its index in the play), memory, group, mode, raw (the model's output), roster (the
Python roster's ids -> name, aliases, group, kind), things (named things known then), phrases (start, surface, paired,
predicate), prompt (the message build_prompt sent) and validated (validate's result: people, facts, roles, things,
dropped reasons). `--every N` keeps every Nth call (for a test fixture); the replay still runs every call.
"""
import argparse
import json
from pathlib import Path

import facts as F


def entity(e):
    return {"name": e.name, "aliases": sorted(e.aliases), "group": list(e.group) if e.group else None, "kind": e.kind}


def export(res, story, ua, every, n0):
    mems = {m["id"]: m for m in story["memories"]}
    state = F.State(ua)
    out = []
    for i, c in enumerate(res["calls"]):
        mem = state.memories.get(c["memory"])
        if mem is None:
            mem = dict(mems[c["memory"]])
            mem["sent"] = F.user_text(mem["text"], ua)
            state.memories[mem["id"]] = mem
        group = c.get("group", "people")
        preds = F.R.group_preds(group)
        phrases = F.role_phrases(mem["text"], ua, preds=set(preds))
        _, prompt, ids = F.build_prompt(state, mem, phrases, group)
        things = [n for n, k in state.things.values()]
        if c.get("raw") is None:
            continue
        people, rels, roles, th, dropped = F.validate(c["raw"], mem, ids, phrases, state, preds)
        if (n0 + len(out)) % every == 0 or every == 1:
            out.append({
                "story": res["story"], "orderIndex": res["orderIndex"], "call": i, "memory": c["memory"], "group": group,
                "mode": c.get("mode", "full"), "raw": c["raw"],
                "roster": {pid: entity(e) for pid, e in ids.items()}, "things": things,
                "phrases": [{"start": ph.start, "surface": ph.surface, "paired": ph.paired, "predicate": ph.type} for ph in phrases],
                "prompt": prompt,
                "validated": {"people": people, "facts": rels, "roles": roles, "things": th, "dropped": [d[0] for d in dropped]},
            })
        else:
            out.append(None)
        F.apply(state, mem, phrases, people, rels, roles, ids, th, mode=c.get("mode", "full"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("fixture")
    ap.add_argument("out")
    ap.add_argument("--every", type=int, default=1)
    a = ap.parse_args()
    data = json.loads(Path(a.fixture).read_text())
    stories = {s["id"]: s for s in data["stories"]}
    ua = data["user"]["aliases"]
    rows, n = [], 0
    for line in Path(a.results).read_text().splitlines():
        if not line.strip():
            continue
        res = json.loads(line)
        got = export(res, stories[res["story"]], ua, a.every, n)
        n += len(got)
        rows += [r for r in got if r is not None]
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    print(f"exported {len(rows)} of {n} calls -> {a.out}")


if __name__ == "__main__":
    main()
