#!/usr/bin/env python3
"""Spike H3's canary, deterministic part (no model): each canary story's true partner episodes (from GPT-6-Astra's
truth) become canned extractions, applied through facts.apply under registry-canary.json; then the story's queries go
through facts.intent and facts.before / after. Tests the registry and the frozen code alone.

    python3 canary_ci.py [registry-canary.json] [fixtures/stories-canary.json]
"""
import json
import sys
from pathlib import Path

import facts as F
import score_facts as S

HERE = Path(__file__).resolve().parent


def main():
    reg = sys.argv[1] if len(sys.argv) > 1 else HERE / "registry-canary.json"
    fx = sys.argv[2] if len(sys.argv) > 2 else HERE / "fixtures" / "stories-canary.json"
    F.set_registry(reg)
    pred = F.R.timeline_preds()
    pred = next(p for p in pred if F.R.kind_of(p) == "person")
    data = json.loads(Path(fx).read_text())
    tot = {"right": 0, "wrong": 0, "ambiguous": 0, "negatives_triggered": 0}
    rows = []
    for st in data["stories"]:
        s = F.State(data["user"]["aliases"])
        for i, t in enumerate(st["timeline"]):
            name = t["org"]
            mem = {"id": f"t{i}", "text": name, "sent": name, "written": "2026-10-31", "source": "capture"}
            s.memories[mem["id"]] = mem
            r = {"quote": name, "predicate": pred, "entity": "name", "name": name, "label": None, "polarity": "positive",
                 "status": "current" if not t["end"] else "former", "deceased": False, "only": False, "count": None, "time": None,
                 "start": t["start"] or None, "end": t["end"] or None, "preceded_by": None, "followed_by": None, "also_called": None,
                 "qualifiers": {k: None for k in F.group_qualifiers([pred])}}
            F.apply(s, mem, [], [{"name": name, "quote": name, "person": "new"}], [r], [], {}, [])
        res = S.score_work(s, {"timeline": st["timeline"], "queries": st["queries"]}, out=lambda *_: None)
        for k in tot:
            tot[k] += res[k]
        rows += [(st["id"], *r) for r in res["rows"]]
    print(f"canary CI ({F.R.version}): before/after right {tot['right']}, wrong {tot['wrong']}, ambiguous or gap told {tot['ambiguous']}; "
          f"negatives that triggered {tot['negatives_triggered']}")
    for r in rows:
        if "WRONG" in r[-1] or r[-1] == "triggered" or "ambiguous" in r[-1] or "gap" in r[-1]:
            print("  ", *r)
    return tot


if __name__ == "__main__":
    main()
