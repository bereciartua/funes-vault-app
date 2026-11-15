#!/usr/bin/env python3
"""Spike H3b: replay saved model outputs through the current facts.py, with no model calls. Each story play's calls are
validated and applied again in their recorded order (full calls and reconciliations as they happened), so a change to
code (the time model, resolution, intent) is measured on exactly the same extractions.

    python3 replay.py <results.jsonl> <fixture.json> <out.jsonl>          (FACTS_REGISTRY picks the registry)

Limit: reconciliation calls are the ones the original run made; the new code might have asked for others.
"""
import json
import sys
from pathlib import Path

import facts as F
from run_facts import dump_people, dump_state

HERE = Path(__file__).resolve().parent


def replay(res, story, ua):
    mems = {m["id"]: m for m in story["memories"]}
    state = F.State(ua)
    calls = []
    for c in res["calls"]:
        mem = state.memories.get(c["memory"])
        if mem is None:
            mem = dict(mems[c["memory"]])
            mem["sent"] = F.user_text(mem["text"], ua)
            state.memories[mem["id"]] = mem
        group = c.get("group", "people")
        preds = F.R.group_preds(group)
        phrases = F.role_phrases(mem["text"], ua, preds=set(preds))
        _, _, ids = F.build_prompt(state, mem, phrases, group)
        if c.get("raw") is not None:
            people, rels, roles, things, dropped = F.validate(c["raw"], mem, ids, phrases, state, preds)
            F.apply(state, mem, phrases, people, rels, roles, ids, things, mode=c.get("mode", "full"))
        calls.append(c)
    return state, calls


def main():
    src, fixture, out = sys.argv[1:4]
    data = json.loads(Path(fixture).read_text())
    stories = {s["id"]: s for s in data["stories"]}
    ua = data["user"]["aliases"]
    lines = []
    for line in Path(src).read_text().splitlines():
        res = json.loads(line)
        state, calls = replay(res, stories[res["story"]], ua)
        new = dump_people(state, calls)
        new.update({k: res[k] for k in ("story", "orderIndex", "order", "provider", "run") if k in res},
                   groups=res.get("groups"), registry=F.R.version, replayed_from=src)
        new["state"] = dump_state(state, [])
        lines.append(json.dumps(new, ensure_ascii=False))
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text("\n".join(lines) + "\n")
    print(f"replayed {len(lines)} story plays -> {out}")


if __name__ == "__main__":
    main()
