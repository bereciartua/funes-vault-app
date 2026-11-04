#!/usr/bin/env python3
"""Exports Spike G's recorded model outputs, with the text sent for each memory, for FunesCore's
validation test (Packages/FunesCore/Tests/FunesCoreTests/fixtures/search-answers/recorded.json).
Every call with a raw answer is kept; the expected kept and dropped claims are this harness's
validation, which FunesCore's must match."""
import json
from pathlib import Path

from answer import build, validate
from run import load

HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "Packages/FunesCore/Tests/FunesCoreTests/fixtures/search-answers/recorded.json"

records = []
for set_name in ("main", "astra"):
    questions, search = load(set_name)
    qs = {q["id"]: q for q in questions}
    for path in sorted((HERE / "results").glob(f"*/{set_name}.jsonl")):
        provider = path.parent.name
        for line in path.read_text().splitlines():
            r = json.loads(line)
            if "raw" not in r:
                continue
            b = build(qs[r["id"]], search[r["id"]], "apple" if provider == "apple" else "cloud")
            v = validate(r["raw"], b["sent"])
            records.append({"provider": provider, "set": set_name, "id": r["id"],
                            "sent": [{"ref": m["ref"], "text": m["text"]} for m in b["sent"]],
                            "raw": r["raw"], "kept": [c["text"] for c in v["claims"]], "dropped": len(v["dropped"])})
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps({"format": "funes.spike-g.recorded.v1", "records": records}, ensure_ascii=False, indent=1) + "\n")
print(f"{len(records)} recordings, {sum(r['dropped'] for r in records)} claims dropped")
