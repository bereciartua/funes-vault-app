#!/usr/bin/env python3
"""Exports Spike E's tidy-up fixtures and the engines' recorded v2 outputs for FunesCore's tests (Phase 6b, task 6b.6).

  python3 export_tidy_recordings.py

Writes Packages/FunesCore/Tests/FunesCoreTests/fixtures/processing/: clusters.json, clusters-astra.json, and
recorded-tidy.json with, per engine and cluster, the raw `actions` the model returned to the second tidy-up prompt
(ids are the fixture's; the test's recorded provider maps them to the prompt's aliases). A failed call is left out.
"""
import json
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "Packages/FunesCore/Tests/FunesCoreTests/fixtures/processing"
# Spike E directory → the model id Funes names the engine by.
ENGINES = {"claude-opus": "claude-opus-5-5", "claude-haiku": "claude-haiku-5-5", "codex-terra": "gpt-5.6-terra",
           "codex": "gpt-6-luna"}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ("clusters.json", "clusters-astra.json"):
        shutil.copy(HERE / "fixtures" / name, OUT / name)
    out = {"format": "funes.spike-e.tidy-recording.v1", "prompt": "tidy-v2", "engines": {}}
    for directory, model in ENGINES.items():
        clusters = {}
        for suffix in ("", "-astra"):
            for line in (HERE / "results" / directory / f"tidy-v2{suffix}.jsonl").read_text().splitlines():
                rec = json.loads(line)
                if all(c.get("ok") for c in rec.get("calls") or [{}]):
                    clusters[rec["id"]] = (rec.get("raw") or {}).get("actions") or []
        out["engines"][model] = clusters
    path = OUT / "recorded-tidy.json"
    path.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{path}: {', '.join(f'{m} {len(c)}' for m, c in out['engines'].items())}")


if __name__ == "__main__":
    main()
