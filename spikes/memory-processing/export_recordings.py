#!/usr/bin/env python3
"""Exports Spike E's fixtures and one provider's recorded v2 outputs for FunesCore's tests (Phase 6a, task 6a.7).

  python3 export_recordings.py [provider]    # default claude-opus

Writes Packages/FunesCore/Tests/FunesCoreTests/fixtures/processing/: the two input sets, the vault, and
recorded-<provider>.json with, per input, the raw extraction output of each chunk call and the raw decisions
(targets are the vault's `mNNN` ids; the test's recorded provider maps them to the prompt's aliases).
"""
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "Packages/FunesCore/Tests/FunesCoreTests/fixtures/processing"


def records(provider, experiment):
    f = HERE / "results" / provider / f"{experiment}.jsonl"
    return {json.loads(l)["id"]: json.loads(l) for l in f.read_text().splitlines()}


def main():
    provider = sys.argv[1] if len(sys.argv) > 1 else "claude-opus"
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ("inputs.json", "inputs-astra.json", "vault.json"):
        shutil.copy(HERE / "fixtures" / name, OUT / name)
    out = {"format": "funes.spike-e.recording.v1", "provider": provider, "prompt": "extract-v2 + decide-v2", "inputs": {}}
    for suffix in ("", "-astra"):
        ext, dec = records(provider, f"extract-v2{suffix}"), records(provider, f"decide-v2{suffix}")
        for iid, rec in ext.items():
            calls = sorted(rec.get("calls") or [], key=lambda c: c["chunk"])
            if not calls or not all(c.get("ok") for c in calls):
                continue
            decisions = []
            for call in (dec.get(iid) or {}).get("calls") or []:
                if call.get("ok"):
                    decisions += (call.get("raw") or {}).get("decisions") or []
            out["inputs"][iid] = {
                "extract": [(c.get("raw") or {}).get("pieces") or [] for c in calls],
                "decisions": decisions,
                "keptPieces": len(rec.get("pieces") or []),
            }
    path = OUT / f"recorded-{provider}.json"
    path.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{path}: {len(out['inputs'])} inputs")


if __name__ == "__main__":
    main()
