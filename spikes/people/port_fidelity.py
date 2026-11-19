#!/usr/bin/env python3
"""Phase 13a.2's port-fidelity gate: the Swift pipeline against the Python harness on the same model answers.

Pairs (Python lines, Swift lines) of one set, each the same answers played through both pipelines:
- recorded: the spike's own result lines (results-h3b) and the Swift replay of the same recorded calls
  (`facts_harness.sh <set>`);
- gold: gold_answers.py's Python play and its Swift replay (`facts_harness.sh <set> gold`). Where the Swift roster leaves
  someone out by alias trust (§11.4), the harness's gold reader answers as a reader of the Swift prompt would; those
  plays compare a perfect reader of each prompt, not identical answers, and the report says how many there were.

Compared per play, canonically (no ids): every link (memory, role start or name surface → basis and person by name or
role group), every relation (person by name, predicate, negated), and every timeline answer (Swift's own judgment against
score_facts.judge on Python's state, where Python kept its state). A difference passes only if it's listed in
port_fidelity_known.json with the rule that makes Swift decide differently on purpose. Aggregates (score.py's measures)
are reported with their difference in points.

    python3 port_fidelity.py <set>:<mode>:<python.jsonl>:<swift.jsonl> [...] [--json out.json]
    python3 port_fidelity.py --h2              Spike H2's timeline: H2's own extraction through score_facts.convert, every
                                               work-queries.json question judged by facts.py, written to
                                               results-13a2/h2-timeline-python.json, which the Swift test
                                               FactsPortFidelityTests compares with the Swift time model's judgments
    python3 port_fidelity.py --standard build/facts-harness [--json out.json]
                    the recorded replays of main, astra and mixed, and the gold plays of main, astra, mixed and persons,
                    as `facts_harness.sh <set>` and `facts_harness.sh <set> gold` leave them
"""
import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

import score

HERE = Path(__file__).resolve().parent
KNOWN = HERE / "port_fidelity_known.json"


def who(r):
    out = {}
    for p in r.get("people", []):
        g = p.get("group")
        out[p["id"]] = p.get("name") or (("group:" + ":".join(str(x) for x in g)) if g else "?")
    return out


def links(r):
    w = who(r)
    out = {}
    for l in r.get("links", []):
        at = l["start"] if l["kind"] == "role" else l["surface"]
        out[f'link {l["memory"]} {l["kind"]} {at}'] = f'{l["basis"]} {w.get(l["person"], l["person"]) if l["person"] else "-"}'
    for x in r.get("relations", []):
        k = f'relation {w.get(x["person"], x["person"])} {x["type"]}'
        out[k] = ("negated" if x.get("negated") else "positive") + f' {x.get("status")}'
    return out


def timeline(r, story):
    """(question id → outcome) by Swift's own judgment, and by score_facts.judge on the line's state if it has one."""
    swift = r.get("swift_judged") or {}
    py = {}
    if r.get("state") and story.get("queries"):
        import score_facts as SF
        from run_facts import load_state
        state = load_state(r["state"])
        for q in story["queries"]:
            if q["kind"] in SF.TIMELINE_KINDS + ("negative", "role_in_stint"):
                py[q["id"]] = SF.judge(state, q, story.get("timeline", []))[0]
    return swift, py


def timeline_right(judged, stories, plays):
    """Decidable timeline questions answered right (gap told included), over every decidable question of every play."""
    right = total = 0
    for k, outs in judged.items():
        for q in stories[k[0]].get("queries", []):
            if q.get("answer_org") and q["kind"] not in ("negative", "role_in_stint"):
                total += 1
                right += outs.get(q["id"]) in ("right", "right_gap")
    return (100.0 * right / total) if total else None


def metrics(lines, stories):
    T = Counter()
    for r in lines:
        T += score.score_run(stories[r["story"]], r)[0]
    pct = lambda a, b: (100.0 * a / b) if b else None
    resolvable = T["role_refs"] - T["ambiguity_kept"] - T["undecidable_guessed_wrong"]
    return {
        "full basis right": pct(T["full_right"], T["full_right"] + T["full_wrong"]),
        "sole_known right": pct(T["sole_known_right"], T["sole_known_right"] + T["sole_known_wrong"]),
        "untrusted right": pct(T["untrusted_right"], T["untrusted_right"] + T["untrusted_wrong"]),
        "decidable linked right": pct(T["full_right"] + T["sole_known_right"] + T["untrusted_right"] + T["group_right"], resolvable),
        "undecidable kept": pct(T["ambiguity_kept"], T["ambiguity_kept"] + T["undecidable_guessed_wrong"]),
        "names right": pct(T["name_full_right"], T["name_full_right"] + T["name_full_wrong"]),
        "relations precision": pct(T["relations_right"], T["relations_system"]),
        "relations recall": pct(T["relations_found"], T["relations_truth"]),
        "forbidden links": T["forbidden_link"],
    }


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def expected_plays(stories):
    return sum(1 + len(s.get("orders", [])) for s in stories.values())


def explain(at, a, b, known, used):
    """An investigated difference: the same place, and exactly the same values on each side."""
    e = known.get(at)
    if e is not None and e.get("python") == a and e.get("swift") == b:
        used.add(at)
        return e["rule"]
    return None


def compare(set_name, mode, py_path, sw_path, known, used):
    fx = json.loads((HERE / "fixtures" / ("stories.json" if set_name == "main" else f"stories-{set_name}.json")).read_text())
    stories = {s["id"]: s for s in fx["stories"]}
    load = lambda p: {(r["story"], r["orderIndex"]): r for r in map(json.loads, Path(p).read_text().splitlines()) if r}
    py, sw = load(py_path), load(sw_path)
    diffs, allowed = [], []
    want = expected_plays(stories)
    if len(py) != want or len(sw) != want:
        diffs.append(f"{set_name} {mode}: {len(py)} Python and {len(sw)} Swift plays, {want} expected")
    jp, js = {}, {}
    for k in sorted(set(py) | set(sw)):
        at = f"{set_name} {mode} {k[0]}#{k[1]}"
        if k not in py or k not in sw:
            diffs.append(f"{at}: play missing on one side")
            continue
        a, b = links(py[k]), links(sw[k])
        ta, tb = timeline(py[k], stories[k[0]]), timeline(sw[k], stories[k[0]])
        if ta[1]:
            jp[k], js[k] = ta[1], tb[0]
        for q, o in tb[0].items():                       # Swift's judgment vs Python's on the same answers
            if q in ta[1]:
                a[f"timeline {q}"], b[f"timeline {q}"] = ta[1][q], o
        for x in sorted(set(a) | set(b)):
            if a.get(x) == b.get(x):
                continue
            line = f"{at} {x} | python: {a.get(x)} | swift: {b.get(x)}"
            rule = explain(f"{at} {x}", a.get(x), b.get(x), known, used)
            (allowed if rule else diffs).append(line + (f"  [{rule}]" if rule else ""))
    mp, ms = metrics(py.values(), stories), metrics(sw.values(), stories)
    if jp:
        mp["timeline decidable right"], ms["timeline decidable right"] = timeline_right(jp, stories, want), timeline_right(js, stories, want)
    points = {m: (None if mp[m] is None or ms[m] is None else ms[m] - mp[m]) for m in mp}
    return {"set": set_name, "mode": mode, "plays": len(sw), "expected_plays": want, "python_sha256": sha(py_path),
            "swift_sha256": sha(sw_path), "python": mp, "swift": ms, "points": points, "unexplained": diffs, "explained": allowed}


def compare_h2(swift_path, known, used):
    """Spike H2's timeline: facts.py's judgments against Swift's time model with facts.py's intent supplied (each
    difference must be explained), and coverage (decidable right) with each side's own grammar, in points."""
    py = json.loads((HERE / "results-13a2/h2-timeline-python.json").read_text())
    sw = json.loads(Path(swift_path).read_text())
    data = json.loads((HERE / "fixtures/work-queries.json").read_text())
    diffs, allowed = [], []
    for q, want in sorted(py["judged"].items()):
        if q not in sw["judged"]:
            diffs.append(f"h2 {q}: no Swift judgment")
            continue
        if q in py["intents"]:
            got = sw["with_python_intent"].get(q)
            if got != want:
                at = f"h2 time-model - {q}"
                rule = explain(at, want, got, known, used)
                (allowed if rule else diffs).append(f"{at} | python: {want} | swift: {got}" + (f"  [{rule}]" if rule else ""))
    dec = [q["id"] for q in data["queries"] if q.get("answer_org") and q["kind"] not in ("negative", "role_in_stint")]
    tally = lambda j: {o: sum(1 for q in dec if j.get(q) == o) for o in sorted({j.get(q) for q in dec})}
    pr = 100.0 * sum(py["judged"].get(q) in ("right", "right_gap") for q in dec) / len(dec)
    sr = 100.0 * sum(sw["judged"].get(q) in ("right", "right_gap") for q in dec) / len(dec)
    wrong = [q for q, o in sw["judged"].items() if o in ("wrong", "triggered")]
    diffs += [f"h2 {q}: Swift {sw['judged'][q]}" for q in wrong]
    return {"set": "h2", "mode": "convert", "plays": 1, "expected_plays": 1, "decidable": len(dec),
            "python": {"timeline decidable right": pr, "outcomes": tally(py["judged"])},
            "swift": {"timeline decidable right": sr, "outcomes": tally(sw["judged"])},
            "points": {"timeline decidable right": sr - pr}, "unexplained": diffs, "explained": allowed,
            "python_sha256": sha(HERE / "results-13a2/h2-timeline-python.json"), "swift_sha256": sha(swift_path)}


def gold_reader(out_dir):
    """The gold reader's counts from the Swift gold plays' manifests (unexplained must be 0)."""
    res = {}
    for s in ("main", "astra", "mixed", "persons"):
        p = Path(out_dir) / f"swift-replay-gold-{s}" / f"{s}-manifest.json"
        m = json.loads(p.read_text()) if p.exists() else {}
        res[s] = {"substituted": m.get("substituted"), "unexplained": m.get("unexplained")}
    return res


COUNTS = {"forbidden links"}
STANDARD = ["main recorded", "astra recorded", "mixed recorded", "main gold", "astra gold", "mixed gold", "persons gold", "h2 convert"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pairs", nargs="*")
    ap.add_argument("--standard", metavar="HARNESS_OUT")
    ap.add_argument("--h2", action="store_true")
    ap.add_argument("--json")
    a = ap.parse_args()
    kf = json.loads(KNOWN.read_text()) if KNOWN.exists() else {"differences": [], "accepted_points": []}
    known = {e["at"]: e for e in kf["differences"]}
    accepted = {(e["pair"], e["metric"]): e for e in kf.get("accepted_points", [])}
    if a.h2:
        import score_facts as SF
        recs = [json.loads(l) for l in (HERE / "results-search/work-extract-fixture.jsonl").read_text().splitlines()]
        state = SF.convert(recs, HERE / "fixtures/work-vault.json")
        data = json.loads((HERE / "fixtures/work-queries.json").read_text())
        import facts as F
        rows, intents = {}, {}
        for q in data["queries"]:
            if q["kind"] not in SF.TIMELINE_KINDS + ("negative", "role_in_stint"):
                continue
            outcome, it, _ = SF.judge(state, q, data["timeline"])
            rows[q["id"]] = outcome
            if it:          # facts.py's intent, so Swift's time model can be compared with the grammar set aside
                pred, op, anchor = it
                if anchor is None:
                    intents[q["id"]] = [pred, op, None]
                elif hasattr(anchor, "lo"):
                    intents[q["id"]] = [pred, op, {"date": [anchor.lo, anchor.hi, str(getattr(anchor, "prec", getattr(anchor, "precision", "")))]}]
                else:
                    intents[q["id"]] = [pred, op, {"entity": state.entities[anchor].name}]
        out = HERE / "results-13a2/h2-timeline-python.json"
        out.write_text(json.dumps({"note": "Spike H2's extraction (results-search/work-extract-fixture.jsonl) through facts.py "
                                   "(score_facts.convert), each work-queries.json question judged by score_facts.judge. "
                                   "port_fidelity.py --h2 writes it.", "judged": rows, "intents": intents}, indent=1, sort_keys=True) + "\n")
        print(f"{len(rows)} questions -> {out}")
        return 0
    pairs = list(a.pairs)
    if a.standard:
        o = Path(a.standard).resolve()
        rec = {"main": "claude-haiku-people/main.jsonl", "astra": "claude-haiku-people/astra.jsonl",
               "mixed": "claude-haiku-separate/mixed.jsonl"}
        pairs += [f"{s}:recorded:{HERE / 'results-h3b' / f}:{o / f'swift-replay-{s}' / f'{s}.jsonl'}" for s, f in rec.items()]
        pairs += [f"{s}:gold:{o / f'gold-{s}.jsonl'}:{o / f'swift-replay-gold-{s}' / f'{s}.jsonl'}" for s in ("main", "astra", "mixed", "persons")]
        pairs += [f"h2:convert:-:{o / 'h2-timeline-swift.json'}"]
    if not pairs:
        ap.error("no pairs")
    out, ok, used = [], True, set()
    for p in pairs:
        set_name, mode, py_path, sw_path = p.split(":", 3)
        out.append(compare_h2(sw_path, known, used) if set_name == "h2" else compare(set_name, mode, py_path, sw_path, known, used))
    problems = []
    for r in out:
        pair = f"{r['set']} {r['mode']}"
        print(f"## {pair} ({r['plays']} plays of {r['expected_plays']}): {len(r['unexplained'])} unexplained, {len(r['explained'])} explained")
        for m, d in r["points"].items():
            if d is None:
                continue
            acc = accepted.get((pair, m))
            if m in COUNTS:                                  # a count, not a share: Swift may not have more
                over = d > 0
            else:
                over = abs(d) > 1.0 and not (acc and abs(acc["points"] - d) < 1e-9)
            print(f"  {m}: python {r['python'][m]:.2f} · swift {r['swift'][m]:.2f} · {d:+.2f}" + ("  OVER 1 POINT" if over else "")
                  + (f"  (accepted: {acc['reason']})" if acc and not over else ""))
            if over:
                problems.append(f"{pair} {m}: {d:+.2f}" + ("" if m in COUNTS else " points"))
        for l in r["unexplained"]:
            print("  UNEXPLAINED", l)
        for l in r["explained"]:
            print("  explained", l)
        problems += r["unexplained"]
    scope = {f"{r['set']} {r['mode']}" for r in out}
    stale = [at for at in known if at not in used and any(at.startswith(sc + " ") or at.startswith("h2 ") and "h2 convert" in scope
                                                          for sc in scope)]
    problems += [f"stale entry (no longer occurs): {at}" for at in stale]
    for at in stale:
        print("  STALE", at)
    reader = gold_reader(a.standard) if a.standard else {}
    problems += [f"gold reader {s}: {v['unexplained']} unexplained" for s, v in reader.items() if v["unexplained"] not in (0,)]
    missing = [x for x in STANDARD if x not in scope]
    if missing:
        problems.append(f"comparisons missing: {missing}")
    ok = not problems
    if a.json:
        import subprocess
        commit = subprocess.run(["git", "-C", str(HERE), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(HERE), "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
        Path(a.json).write_text(json.dumps({"format": "funes.facts-port-fidelity.v1", "pass": ok, "problems": problems,
                                            "commit": commit + ("+dirty" if dirty else ""), "gold_reader": reader,
                                            "known_sha256": sha(KNOWN) if KNOWN.exists() else None, "pairs": out},
                                           indent=1, ensure_ascii=False) + "\n")
    print("port fidelity:", "pass" if ok else f"FAIL ({len(problems)} problem(s))")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
