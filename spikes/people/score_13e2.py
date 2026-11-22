#!/usr/bin/env python3
"""13e.2's timeline gate, scored (ADR-0032 decision 9, amended 2026-11-21; frozen with the gate's code). Reads the set,
the live answer records (FactsTimelineGateTests, `answers-<engine>/answers.jsonl`), the final claim labels (judge_13e2.py:
both judges, the adjudicator, the corrected labels), the gate read's dumps and Phase A's reads.

    python3 score_13e2.py --engine haiku|terra [--dir results-13e2] [--read <read dir>] [--phase-a <dir>]... [--json out]

Per engine, arm R against the corrected labels (P is the negatives' baseline); every target counts across every sample:
- complete: every question × arm × sample answered once and every answer with claims judged;
- decidable right ≥ 85%: an answers_right claim and no answers_wrong, wrong_other or someone_else claim;
- decidable wrong: 0 unmarked, ≤ 1 marked (marked: every wrong claim carries the inferred mark);
- undecidable "not sure" ≥ 90%: rows sent, no claim answering with an organization, and a not_sure claim or no answer;
- negatives wrong ≤ P's + 1 (a failed answer is wrong);
- 0 someone_else claims;
- 0 owed checks skipped: (a) a claim a judge calls temporal without a check; (b) judge-free: on an answer with rows, an
  unchecked claim §10.4's rule owes a check, implemented here from the record (the model's comparison flag, the citations
  of memories only the rows brought, the story's employer names, the registry's cues, years and dates); (c) a question
  with a temporal claim in any arm where R sent no rows;
- 0 claims code fails to mark: any claim a judge calls inferred, without the mark;
- p95 of R's live end-to-end duration ≤ 15 s, a failed answer counting as over;
- the facts behind the rows: qualify.timeline_measures (with its slot check) on the gate read and Phase A's reads: 0 wrong
  facts, ≤ 1 wrong date, 0 succession from untrusted text or across slots; a disputed item the fact adjudicator ruled
  stated is removed.
Failed answers are never a pass; one retry for a transport error was made by the harness.
"""
import argparse
import ast
import json
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

import judge_13e2 as J
import qualify

HERE = Path(__file__).resolve().parent
# Samples of arm R, fixed before the freeze: the author chose 1 (2026-11-22). Percentages pool them; zero targets count
# across all of them; the negatives' allowance is pooled (R's wrong over every sample ≤ P's × samples + 1).
GATE_REPS = 1
MIN_CLASSES = {"decidable": 50, "undecidable": 50, "negative": 40}
UNDECIDABLE_TRAPS = ["rehire", "possible_overlap", "same_year_handover", "agent_competitor", "rename", "exact_day"]
TRAPS_MIN = 4
TARGETS = {"decidable_right": 0.85, "decidable_unmarked_wrong": 0, "decidable_marked_wrong": 1, "undecidable_not_sure": 0.90,
           "negatives_over_plain": 1, "someone_else": 0, "owed_skipped": 0, "unmarked_inferred": 0, "p95_ms": 15000,
           "wrong_facts": 0, "wrong_dates": 1}
ANSWERING = ("answers_right", "answers_wrong")
WRONG = ("answers_wrong", "wrong_other", "someone_else")


def _lang():
    return json.loads(qualify.REGISTRY.read_text())["language"]


def _matches(t, words):
    """Whole words; a registry stem ending in * ("regres*") matches any word it begins."""
    for w in words:
        stem = w.endswith("*")
        w = J.fold(w.rstrip("*"))
        if w and re.search(r"(?<!\w)" + re.escape(w) + (r"" if stem else r"(?!\w)"), t):
            return True
    return False


def _bounds(r):
    """The registry's bounding time prepositions (since, until…): time prepositions that are neither year nor range ones,
    as §10.4's rule reads them."""
    return sorted(set(r["time_prepositions"]) - set(r["year_prepositions"]) - set(r["range_prepositions"]))


def selection_cue(text):
    """§10.4's own cue of a claim whose comparison said made: false: before, after, since, until or a return (read here
    from the registry, not from SearchAnswerer.owes)."""
    r = _lang()
    return _matches(J.fold(text), r["operators"]["before"] + r["operators"]["after"] + _bounds(r) + r["return_cues"])


def time_cue(text):
    """§10.4's operator or time cue of a search or a claim: before, after, since, until, now, previous, a return, a year
    or a date (not bare prepositions, nor episode words)."""
    r = _lang()
    t = J.fold(text)
    words = [w for k in ("before", "after", "previous", "current") for w in r["operators"][k]] + _bounds(r) + r["return_cues"]
    return _matches(t, words) or bool(re.search(r"\b(19|20)\d{2}\b", t)) or bool(re.search(r"\b\d{1,2}[/-]\d{1,2}([/-]\d{2,4})?\b", t))


def owed(rc, query, names, cited):
    """§10.4's rule, from the record: the comparison said made, or the claim cites a memory only the rows brought, or it
    names one of the story's employers while the search or the claim has a cue (with made: false, only the claim's own
    selection cue)."""
    if rc.get("comparisonSomeoneElse"):
        return False                                   # someone else's job: kept unchecked, as §10.4 says
    if rc.get("comparisonMade") is True or any(c["memory"] in cited for c in rc["citations"]):
        return True
    if not names_employer(rc["text"], names):
        return False
    if rc.get("comparisonMade") is False:
        return selection_cue(rc["text"])
    return time_cue(query) or time_cue(rc["text"])


def employer_names(story):
    out = set()
    for t in story["timeline"]:
        if t["kind"] in ("employee", "self_employed"):
            out |= {J.fold(n) for n in qualify.labelled_names(story, t["org"]) if len(n) >= 3}
    return out


def names_employer(text, names):
    t = J.fold(text)
    return any(re.search(r"(?<!\w)" + re.escape(n) + r"(?!\w)", t) for n in names)


def disputed_questions(dirpath):
    """Questions an answer judged under the original labels disagrees with, on both engines (None until both exist)."""
    orig = J.original_labels()
    out = set()
    for engine in ("haiku", "terra"):
        if not (Path(dirpath) / f"answers-{engine}" / "answers.jsonl").exists():
            return None
        recs, claims = J.final_claims(dirpath, engine, orig)
        for r in recs:
            c = claims.get(J.akey(r))
            if c is not None and r["outcome"] != "failed" and J.disagrees(orig[(r["story"], r["id"])], c):
                out.add(f"{r['story']}/{r['id']}")
    return sorted(out)


def minimums(stories, lab):
    """The corrected set still meets decision 9's minimums (else the run is void)."""
    probs, classes, traps = [], Counter(), Counter()
    for s in stories.values():
        for q in s["queries"]:
            c = lab[(s["id"], q["id"])]["class"]
            classes[c] += 1
            if c == "undecidable":
                for t in q.get("traps", []):
                    traps[t] += 1
    probs += [f"void: {classes[c]} {c} questions after the label rule, want ≥ {n}" for c, n in MIN_CLASSES.items() if classes[c] < n]
    probs += [f"void: {traps[t]} undecidable {t} questions after the label rule, want ≥ {TRAPS_MIN}" for t in UNDECIDABLE_TRAPS
              if traps[t] < TRAPS_MIN]
    return probs


def score_engine(dirpath, engine, reps=GATE_REPS, lab=None, check_minimums=True):
    stories, _ = J.load_set()
    lab = lab or J.labels()
    recs, claims = J.final_claims(dirpath, engine, lab)
    probs = minimums(stories, lab) if check_minimums else []
    corr = Path(dirpath) / "labels-corrected.json"
    if not corr.exists():
        probs.append("the label rule hasn't run (judge_13e2.py relabel)")
    elif json.loads(corr.read_text()).get("failed"):
        probs.append(f"the label rule has questions without a ruling: {json.loads(corr.read_text())['failed']}")
    else:
        # The disputes it ruled on are the ones the original labels' judgments give, on both engines.
        want = disputed_questions(dirpath)
        if want is not None and sorted(json.loads(corr.read_text()).get("disputed", [])) != sorted(want):
            probs.append("the label rule's disputed questions aren't the ones the judgments give")
    seen = Counter((r["story"], r["id"], r["arm"], r["rep"]) for r in recs)
    expected = {(s["id"], q["id"], arm, rep) for s in stories.values() for q in s["queries"]
                for arm, n in (("P", 1), ("R", reps)) for rep in range(1, n + 1)}
    for k in sorted(expected | set(seen)):
        if seen[k] != 1 or k not in expected:
            probs.append(f"{k[0]} {k[1]} {k[2]}{k[3]}: {seen[k]} records" + ("" if k in expected else " (not in the matrix)"))
    unjudged = [J.akey(r) for r in recs if claims.get(J.akey(r)) is None]
    if unjudged:
        probs.append(f"{len(unjudged)} answers without a complete judgment: {unjudged[:5]}")
    m = Counter()
    lists = {k: [] for k in ("decidable_missed", "decidable_wrong", "undecidable_answered", "negative_wrong_R", "negative_wrong_P",
                             "someone_else", "owed_skipped", "unmarked_inferred", "failed")}
    temporal_q = set()
    for r in recs:
        for c in claims.get(J.akey(r)) or []:
            if c["temporal"]:
                temporal_q.add((r["story"], r["id"]))
    durations = []
    for r in recs:
        k = J.akey(r)
        label = lab[(r["story"], r["id"])]
        cls = label["class"]
        cl = claims.get(k) or []
        failed = r["outcome"] == "failed"
        story = stories[r["story"]]
        q = next(x for x in story["queries"] if x["id"] == r["id"])
        if r["arm"] == "P":
            if cls == "negative":
                m["negatives_P"] += 1
                if failed or any(c["verdict"] in WRONG for c in cl):
                    m["negative_wrong_P"] += 1
                    lists["negative_wrong_P"].append(k)
            continue
        if failed:
            lists["failed"].append(f"{k} {r.get('error')}")
        if r.get("cached") and not failed:
            probs.append(f"{k}: an R answer from the cache has no live timing")
        if "durationMs" not in r:
            probs.append(f"{k}: no timing")
        durations.append(max(15001, r.get("durationMs", 0)) if failed else r.get("durationMs", 0))
        verdicts = [c["verdict"] for c in cl]
        if cls == "decidable":
            m["decidable"] += 1
            right = not failed and "answers_right" in verdicts and not any(v in WRONG for v in verdicts)
            m["decidable_right"] += right
            if not right:
                lists["decidable_missed"].append(k)
            wrong = [(c, r["claims"][c["n"] - 1]) for c in cl if c["verdict"] in ("answers_wrong", "wrong_other")]
            if wrong:
                marked = all(rc.get("inferred") for _, rc in wrong)
                m["decidable_marked_wrong" if marked else "decidable_unmarked_wrong"] += 1
                lists["decidable_wrong"].append(f"{k} {'marked' if marked else 'UNMARKED'}")
        elif cls == "undecidable":
            m["undecidable"] += 1
            ok = (not failed and r.get("rows") is not None and not any(v in ANSWERING + WRONG for v in verdicts)
                  and ("not_sure" in verdicts or r["outcome"] == "no_answer"))
            m["undecidable_not_sure"] += ok
            m["undecidable_no_answer"] += (not failed and r["outcome"] == "no_answer")
            if not ok:
                lists["undecidable_answered"].append(f"{k} rows={'yes' if r.get('rows') is not None else 'no'}")
        else:
            m["negatives_R"] += 1
            if failed or any(v in WRONG for v in verdicts):
                m["negative_wrong_R"] += 1
                lists["negative_wrong_R"].append(k)
        names = employer_names(story)
        for c in cl:
            rc = r["claims"][c["n"] - 1]
            at = f"{k} claim {c['n']}"
            if c["verdict"] == "someone_else":
                lists["someone_else"].append(at)
            if c["temporal"] and not rc.get("check"):
                lists["owed_skipped"].append(f"{at} (judge: temporal, unchecked)")
            # Code's own "not sure" line carries no Inferred tag by design (§10.4): not a marking failure.
            if c["inferred"] and not rc.get("inferred") and (rc.get("check") or {}).get("verdict") != "not_sure":
                lists["unmarked_inferred"].append(at)
        if r.get("rows") is not None:
            cited = set(r.get("cited") or [])
            for i, rc in enumerate(r["claims"], 1):
                if not rc.get("check") and owed(rc, q["query"], names, cited):
                    lists["owed_skipped"].append(f"{k} claim {i} (owed by §10.4's rule, unchecked)")
        elif (r["story"], r["id"]) in temporal_q and not failed:
            lists["owed_skipped"].append(f"{k} (a temporal claim in some arm, no rows sent)")
    lists["owed_skipped"] = sorted(set(lists["owed_skipped"]))
    p95 = statistics.quantiles(durations, n=20, method="inclusive")[18] if len(durations) >= 20 else (max(durations) if durations else None)
    per_rep_neg = Counter(r["rep"] for r in recs if r["arm"] == "R" and lab[(r["story"], r["id"])]["class"] == "negative"
                          and (r["outcome"] == "failed" or any(c["verdict"] in WRONG for c in claims.get(J.akey(r)) or [])))
    r_count = sum(1 for r in recs if r["arm"] == "R")
    if len(durations) != r_count:
        probs.append(f"{len(durations)} R answers timed of {r_count}")
    measures = {
        "decidable": m["decidable"], "decidable_right": m["decidable_right"],
        "decidable_right_rate": m["decidable_right"] / m["decidable"] if m["decidable"] else 0,
        "decidable_unmarked_wrong": m["decidable_unmarked_wrong"], "decidable_marked_wrong": m["decidable_marked_wrong"],
        "undecidable": m["undecidable"], "undecidable_not_sure": m["undecidable_not_sure"],
        "undecidable_not_sure_rate": m["undecidable_not_sure"] / m["undecidable"] if m["undecidable"] else 0,
        "undecidable_no_answer": m["undecidable_no_answer"],
        "negatives": m["negatives_R"], "negative_wrong_R_per_sample": dict(per_rep_neg), "negative_wrong_P": m["negative_wrong_P"],
        "someone_else": len(lists["someone_else"]), "owed_skipped": len(lists["owed_skipped"]),
        "unmarked_inferred": len(lists["unmarked_inferred"]), "failed": len(lists["failed"]),
        "p95_ms": p95, "live_answers_timed": len(durations), "samples": reps,
    }
    gates = {
        "complete": not probs,
        "decidable_right": measures["decidable_right_rate"] >= TARGETS["decidable_right"],
        "decidable_wrong": measures["decidable_unmarked_wrong"] == 0 and measures["decidable_marked_wrong"] <= TARGETS["decidable_marked_wrong"],
        "undecidable_not_sure": measures["undecidable_not_sure_rate"] >= TARGETS["undecidable_not_sure"],
        "negatives": sum(per_rep_neg.values()) <= m["negative_wrong_P"] * reps + TARGETS["negatives_over_plain"],
        "someone_else": measures["someone_else"] == 0,
        "owed_checks": measures["owed_skipped"] == 0,
        "marking": measures["unmarked_inferred"] == 0,
        "p95": p95 is not None and p95 <= TARGETS["p95_ms"],
    }
    return {"engine": engine, "problems": probs, "measures": measures, "gates": gates, "lists": lists}


def facts_gate(dirpath, read_dirs):
    """The facts behind the rows on the gate read and Phase A's reads, with the fact adjudicator's rulings."""
    reg = qualify.registry()
    stated = set()
    disputes = Path(dirpath) / "fact-disputes.jsonl"
    for l in (disputes.read_text().splitlines() if disputes.exists() else []):
        j = json.loads(l)
        if j.get("ok") and j.get("read") == "gate" and (j.get("ruling") or {}).get("stated") and len(ast.literal_eval(j["key"])) == 2:
            stated.add(j["key"])
    out = {}
    for name, d, fixture in read_dirs:
        stories = {s["id"]: s for s in json.loads(Path(fixture).read_text())["stories"]}
        lines = [json.loads(l) for l in Path(d).read_text().splitlines()]
        t = qualify.timeline_measures(lines, stories, reg)
        # Rulings apply to the gate read's plain facts only; Phase A's reads, dates, slots and merges are never waived.
        waive = stated if name == "gate read" else set()
        wf = [x for x in t["details"]["wrong_facts"] if x not in waive]
        wd = t["details"]["wrong_dates"]
        ok = (not wf and len(wd) <= TARGETS["wrong_dates"] and not t["succession_untrusted"] and not t["succession_cross_slot"])
        out[name] = {"wrong_facts": wf, "wrong_dates": wd, "succession_untrusted": t["succession_untrusted"],
                     "succession_cross_slot": t["succession_cross_slot"], "ruled_stated": sorted(waive & set(t["details"]["wrong_facts"])),
                     "pass": ok}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=["haiku", "terra"], required=True)
    ap.add_argument("--dir", default=str(HERE / "results-13e2"))
    ap.add_argument("--read", help="the gate read's directory (stories.jsonl)")
    ap.add_argument("--phase-a", action="append", default=[], help="a Phase A read's work13.jsonl or mixed.jsonl (repeat)")
    ap.add_argument("--json")
    ap.add_argument("--set", default="gate-13e2", help="the set under fixtures/ (development: gate-13e2-dev)")
    a = ap.parse_args()
    J.SET = HERE / "fixtures" / a.set
    J.RESULTS = Path(a.dir)
    out = score_engine(a.dir, a.engine, GATE_REPS)
    # The original labels' score, reported beside the corrected one (decision 9's label rule).
    if (Path(a.dir) / "labels-corrected.json").exists():
        orig = score_engine(a.dir, a.engine, GATE_REPS, J.original_labels(), check_minimums=False)
        out["original_labels"] = {"measures": orig["measures"], "gates": orig["gates"]}
    reads = []
    if a.read:
        reads.append(("gate read", str(Path(a.read) / "stories.jsonl"), str(J.SET / "stories.json")))
    for p in a.phase_a:
        s = "work13" if "work13" in Path(p).name else "mixed"
        reads.append((p, p, str(HERE / "fixtures" / f"stories-{s}.json")))
    if reads:
        out["facts"] = facts_gate(a.dir, reads)
        out["gates"]["facts"] = all(v["pass"] for v in out["facts"].values())
    out["pass"] = all(out["gates"].values())
    text = json.dumps(out, indent=1, ensure_ascii=False)
    if a.json:
        Path(a.json).write_text(text + "\n")
    print(json.dumps({"engine": a.engine, "pass": out["pass"], "gates": out["gates"], "measures": out["measures"],
                      "problems": out["problems"][:10]}, indent=1, ensure_ascii=False))
    return 0 if out["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
