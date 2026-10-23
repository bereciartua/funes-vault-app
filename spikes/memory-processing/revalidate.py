#!/usr/bin/env python3
"""Re-applies §5.4 validation to stored extraction results (after a validation change), in place.
  python3 revalidate.py <provider> <experiment>   Refuses when a decide run already used different pieces."""
import json
import sys
from pathlib import Path

from run import rebuild
from score import INPUTS

prov, exp = sys.argv[1], sys.argv[2]
f = Path(__file__).resolve().parent / "results" / prov / f"{exp}.jsonl"
recs = [json.loads(l) for l in f.read_text().splitlines()]
changed = 0
for r in recs:
    if r.get("rejected"):
        continue
    before = [p["body"] for p in r.get("pieces") or []]
    rebuild(r, INPUTS[r["id"]], with_link=exp == "onecall")
    changed += before != [p["body"] for p in r["pieces"]]
dec = f.parent / "decide.jsonl"
if exp == "extract" and changed and dec.exists():
    sys.exit(f"{changed} inputs changed but {dec} already used the old pieces; not writing")
f.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in recs))
print(f"{prov} {exp}: {changed} inputs changed")
