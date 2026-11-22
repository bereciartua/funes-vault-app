#!/usr/bin/env python3
"""13e.2's equivalence check (the plan's step 3 tests): Spike T round 2's recorded comparisons, run through the direct
time-model call (`TimelineCheck`'s intent, as the product calls it), against what the spike's canonical-question path
answered on the same live store (results-spike-t2/raw/check-<engine>.json). No model is called: the live store is
replayed from round 2's recorded Haiku read.

    python3 direct_vs_canonical.py [--engine haiku|terra] [--out DIR]

Prints, per engine, how many comparisons both paths answered the same (the same organizations, or both can't tell),
and lists every difference with both answers. The trusted side is informational: the spike's "trusted" store left out
agents' memories only, while the product's trusted graph leaves out every untrusted assertion (imports and shared text
too)."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
RAW = HERE / "results-spike-t2" / "raw"
SET = "workr"


def comparisons(engine):
    out = {}
    for line in (RAW / f"records-{engine}.jsonl").read_text().splitlines():
        r = json.loads(line)
        sid, qid, arm = r["key"]
        if arm != "B" or not r.get("ok"):
            continue
        c = (r.get("content") or {}).get("comparison") or {}
        if not c.get("made"):
            continue
        m = re.search(r"^Question: (.*)$", r.get("prompt", ""), re.M)
        out.setdefault(sid, []).append({
            "id": qid, "search": m.group(1) if m else "", "made": True, "operator": c.get("operator", ""),
            "anchor_org": c.get("anchor_org", ""), "stint": c.get("stint", "") or "any", "anchor_date": c.get("anchor_date", ""),
            "end_date": c.get("end_date", ""), "kind": c.get("kind", "") or "any", "answer_org": c.get("answer_org", "")})
    return out


def run(engine, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    comps = out_dir / f"comparisons-{engine}.json"
    comps.write_text(json.dumps(comparisons(engine), indent=1))
    export = out_dir / f"export-live-{SET}.jsonl"
    subprocess.run(["python3", str(HERE / "export_replay.py"), str(HERE / "results-h3/claude-haiku-separate-r2" / f"{SET}.jsonl"),
                    str(HERE / "fixtures" / f"stories-{SET}.json"), str(export)], check=True)
    tag = f"direct-{engine}"
    opts = [f"set={SET}", f"replay={export}", "orders=natural", f"comparisons={comps}", f"out={out_dir}", f"tag={tag}"]
    p = subprocess.run(["swift", "test", "--package-path", str(REPO / "Packages/FunesCore"), "--filter", "FactsHarnessTests/fullRun"],
                       env=dict(os.environ, FUNES_FACTS_HARNESS=";".join(opts)), capture_output=True, text=True)
    if p.returncode != 0 or "facts harness:" not in p.stdout:
        raise SystemExit(f"swift failed: {p.stdout[-1500:]}{p.stderr[-400:]}")
    direct = {}
    for line in (out_dir / f"swift-replay-{tag}" / f"{SET}.jsonl").read_text().splitlines():
        r = json.loads(line)
        for qid, v in (r.get("swift_direct") or {}).items():
            direct[f"{r['story']}|{qid}"] = v
    return direct


def names(entry):
    """The spike's grammar answer: (outcome, {basis, entities}) → the organizations, or None for can't tell."""
    if not entry or not entry[1] or not entry[1].get("entities"):
        return None
    return sorted(entry[1]["entities"])


def ours(side):
    if not side or not side.get("entities") or side.get("basis") in ("ambiguous", "unknown"):
        return None
    return sorted(side["entities"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=["haiku", "terra"], action="append")
    ap.add_argument("--out", default=str(REPO / "build" / "direct-vs-canonical"))
    a = ap.parse_args()
    for engine in a.engine or ["haiku", "terra"]:
        direct = run(engine, Path(a.out))
        chk = json.loads((RAW / f"check-{engine}.json").read_text())
        canon = chk["canonical"]
        same = differ = invalid = skipped = 0
        diffs = []
        for key, d in sorted(direct.items()):
            if not canon.get(key):
                skipped += 1           # the spike wrote no canonical question for it (it can't be compared)
                continue
            if d.get("invalid"):
                invalid += 1
                diffs.append(f"  {key}: direct invalid; canonical {names(chk['live-full'].get(key))}")
                continue
            c, o = names(chk["live-full"].get(key)), ours(d.get("full"))
            if c == o:
                same += 1
            else:
                differ += 1
                diffs.append(f"  {key}: direct {o} ({d['full'].get('basis')}); canonical {c} — {canon[key]!r}")
        print(f"{engine}: {same} the same, {differ} different, {invalid} invalid, {skipped} without a canonical question")
        for line in diffs:
            print(line)


if __name__ == "__main__":
    main()
