#!/usr/bin/env python3
"""Exports Spike E's and Spike F's fixtures and one provider's recorded outputs for FunesCore's tests (Phase 6a,
task 6a.7; Spike F's fix).

  python3 export_recordings.py [provider] [extraction] [decisions]    # default claude-opus extract-fC3 decide-fC3

Writes Packages/FunesCore/Tests/FunesCoreTests/fixtures/processing/: the two input sets, the vault, and
recorded-<provider>.json with, per input, the raw extraction output of each chunk call and the raw decisions
(targets are the vault's `mNNN` ids; the test's recorded provider maps them to the prompt's aliases). Also Spike F's
episodes and recorded-episodes-<provider>.json: per episode, the raw extraction output of each chunk call with the
prompt Funes ships (variant C3).
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
    extraction = sys.argv[2] if len(sys.argv) > 2 else "extract-fC3"
    decisions_exp = sys.argv[3] if len(sys.argv) > 3 else "decide-fC3"
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ("inputs.json", "inputs-astra.json", "vault.json", "episodes.json"):
        shutil.copy(HERE / "fixtures" / name, OUT / name)
    out = {"format": "funes.spike-e.recording.v1", "provider": provider, "prompt": f"{extraction} + {decisions_exp}", "inputs": {}}
    for suffix in ("", "-astra"):
        ext, dec = records(provider, f"{extraction}{suffix}"), records(provider, f"{decisions_exp}{suffix}")
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

    episodes = {"format": "funes.spike-f.recording.v1", "provider": provider, "prompt": "C3", "episodes": {}}
    for line in (HERE / "results" / "spike-f" / provider / "C3.jsonl").read_text().splitlines():
        rec = json.loads(line)
        calls = sorted(rec.get("calls") or [], key=lambda c: c["chunk"])
        if calls and all(c.get("ok") for c in calls) and rec.get("pieces"):
            episodes["episodes"][rec["id"]] = {"extract": [(c.get("raw") or {}).get("pieces") or [] for c in calls],
                                               "keptPieces": len(rec["pieces"])}
    path = OUT / f"recorded-episodes-{provider}.json"
    path.write_text(json.dumps(episodes, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{path}: {len(episodes['episodes'])} episodes")


if __name__ == "__main__":
    main()
