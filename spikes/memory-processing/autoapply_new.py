#!/usr/bin/env python3
"""Auto-apply simulation for new memories (memory processing §5.7) on the two-call results.
  python3 autoapply_new.py <provider> [gate]
Correct = the piece matches an expected one with no wrong claim, and its link decision is right.
Agents follow their own access, so agent inputs are left out. Gates for Everything except conflicts:
none, atomic (atomic and the support check passes), single (the input gave exactly one piece)."""
import sys
from score import INPUTS, load, score_extraction

prov = sys.argv[1]
res = score_extraction(load(prov, "extract"), decisions=load(prov, "decide"))
rows = [r for r in res["rows"] if INPUTS[r["input"]]["type"] != "agent"]
for r in rows:
    # Optional pieces carry no link expectation: creating them is fine.
    r["ok"] = r["correct"] and (r["link_ok"] if "link_ok" in r else r.get("action") == "create")
typed = {"capture_typed", "capture_dictated", "seed_answer"}
dups = [r for r in rows if r["action"] == "duplicate"]
print(f"{prov}: user pieces {len(rows)}")
print(f"  Duplicates only (dropped as already saved): {sum(r['ok'] for r in dups)}/{len(dups)}")
for gate in ("none", "atomic", "single"):
    applied = []
    for r in rows:
        if gate == "atomic" and (r.get("atomic") is False or r["support"].get("notInInput")):
            continue
        if gate == "single" and r["n_in_input"] != 1:
            continue
        if r["action"] in ("update", "retract") and r["type"] not in typed:
            continue
        applied.append(r)
    ok = sum(r["ok"] for r in applied)
    print(f"  Everything except conflicts, gate {gate}: {ok}/{len(applied)} correct "
          f"({100 * ok / max(1, len(applied)):.0f}%), {100 * len(applied) / len(rows):.0f}% of pieces applied")
