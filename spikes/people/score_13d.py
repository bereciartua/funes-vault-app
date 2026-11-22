#!/usr/bin/env python3
"""Phase 13d's live answer gates (the Phase 13 plan's acceptance table), scored from the Swift harness's records
(Packages/FunesCore/Tests/FunesCoreTests/FactsAnswerLiveTests.swift), which carry the app's own selection, attributes
and inferred marks.

    python3 score_13d.py answers --engine haiku|terra [--sets main,astra,busy] [--dir <dry run's out=>]
    python3 score_13d.py spikeg  --engine haiku|terra [--dir ...]

`answers` reads results-13d/answers-<engine>/<set>-r3.jsonl and the blind judge's <set>-r3-judge.jsonl
(`ANS_DIR=../results-13d/answers-<engine> python3 search_answers.py judge --set <set> --engine r3`). Arms: P plain (13b),
F learned facts, W F with a wrong link on a trap. Gate ("Answers on linked questions"):
- complete: every set answered and judged, one verdict per answer, each verdict for the answers as they are now (the
  judge line's hash), no failed answer, every F and W answer made with learned facts (none fell back to 13b's);
- coverage (with the author's waivers, results-13d/waivers-<engine>.json, each naming one sample read by hand): F
  covers at least as many answers as P in every family (Spike H's kinds: the first tag, and on the busy
  set the tuning or test half), and abstains right at least as often. An F answer identical to P's (same request, so
  the same cached answer) takes P's verdict, so the judge's noise on one text can't count as a gain or a loss;
- 0 wrong entity with correct links: no F claim the judge calls wrong_person rests on learned facts (the app marked it,
  or it cites a memory that carried an attribute or that a link admitted), and F has no more wrong_person claims of the
  model's own than P;
- with an injected wrong link: at most 1 failure per 30 W answers whose prompt carried the trap with its wrong
  attribute. A failure is an unmarked claim citing the trap that the judge doesn't call fact, true_other or hedged, or
  any unmarked wrong_person claim.
Listed to be read by hand: every question whose samples differ between P and F (covers or abstains), every F
wrong_person claim and every W failure.

`spikeg` reads results-13d/spike-g-<engine>/<set>-<arm>.jsonl and scores P and F with Spike G's own scorer and labels
(spikes/search-answers/score.py, labels.json). A question counts as answerable if either arm sent a memory holding the
answer, so an arm that loses the memory can't score its "no answer" as right. Gate ("Spike G's gates with the feature
on"): both sets, every question, no failed answer, every F answer made with learned facts; F on both sets together has
correct claims ≥ 95%, the right "no answer" ≥ 90%, answered ≥ 80% of answerable; no new wrong claims (a wrong claim of
F's whose rule, or labelled text, no P answer to that question has); no claim in either arm left unlabelled. p95 isn't
gated here: cached answers keep their first latency, and Spike G measured it.

Writes results-13d/gate-<kind>-<engine>.md and prints it.
"""
import argparse
import importlib.util
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

import rank_eval
from search_answers import answers_hash

HERE = Path(__file__).resolve().parent
OUT = HERE / "results-13d"
FIXTURES = {"main": "fixtures/search-queries.json", "astra": "fixtures/search-queries-astra.json",
            "busy": "fixtures/search-queries-busy.json"}
OK_LABELS = {"fact", "true_other", "hedged"}


def lines(path):
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()] if path.exists() else []


def family(q, set_name):
    """Spike H's kinds (search_answers.py's score): the first tag, and on the busy set its tuning or test half too (each
    busy question has a family of its own, too small to gate on)."""
    tag = (q.get("tags") or [q.get("set") or "?"])[0]
    return f"{tag} {rank_eval.half(q)}" if set_name.startswith("busy") else tag


def waivers(engine):
    """The author's waivers (results-13d/waivers-<engine>.json): each names one sample, read by hand."""
    p = OUT / f"waivers-{engine}.json"
    return json.loads(p.read_text())["waivers"] if p.exists() else []


def answers_gate(engine, sets, marks=None):
    """The answers gate's verdicts and report lines. `marks`: {(set, id, arm, rep): [inferred per claim]} from a replay
    at the code that ships (qualify.py), where it marks differently from the live run; the judge's verdicts stay bound
    to the answers it read."""
    marks = marks or {}
    d = OUT / f"answers-{engine}"
    waived = {(w["set"], w["question"], w["arm"], w["rep"]): w for w in waivers(engine) if w["gate"] == "answers" and w["rule"] == "coverage"}
    out = [f"# 13d gate: answers on linked questions ({engine})", "",
           "Arms: P plain (13b, what ships), F learned facts (attributes on), W F with a wrong link on a trap. "
           "Swift's selection, attributes and marks; Opus judged blind to the arm.", ""]
    problems, fam_fail, review, waived_lines = [], [], [], []
    wrong = Counter()
    w_answers = w_fail = w_skipped = w_cites = w_cites_marked = 0
    for s in sets:
        rs = lines(d / f"{s}-r3.jsonl")
        if not rs:
            problems.append(f"{s}: no answers")
            continue
        recs = {(r["id"], r["arm"], r["rep"]): r for r in rs}
        by_q = defaultdict(list)
        for r in rs:
            by_q[r["id"]].append(r)
        judged = {}
        for j in lines(d / f"{s}-r3-judge.jsonl"):
            judged[j["id"]] = j                                # the last line per question
        qs = {q["id"]: q for q in json.loads((HERE / FIXTURES[s]).read_text())["queries"]}
        failed = [k for k, r in recs.items() if r["outcome"] == "failed"]
        fell_back = [k for k, r in recs.items() if r["arm"] != "P" and r["outcome"] != "failed" and not r.get("factsRevision")]
        if failed:
            problems.append(f"{s}: {len(failed)} failed answers ({', '.join(f'{q} {a}{n}' for q, a, n in failed[:5])})")
        if fell_back:
            problems.append(f"{s}: {len(fell_back)} F/W answers without learned facts")
        verdict = {}
        for qid, group in by_q.items():
            reps = {arm: sorted(r["rep"] for r in group if r["arm"] == arm) for arm in ("P", "F", "W")}
            if not reps["P"] or reps["P"] != reps["F"] or (reps["W"] and reps["W"] != reps["P"]):
                problems.append(f"{s} {qid}: samples don't pair ({reps})")
            j = judged.get(qid)
            if not j or not j.get("ok"):
                problems.append(f"{s} {qid}: not judged")
                continue
            if j.get("answers_hash") != answers_hash(group):
                problems.append(f"{s} {qid}: judged answers that have changed since")
                continue
            got = {}
            for v in j.get("verdicts") or []:
                if 0 < v["answer"] <= len(j["map"]):
                    got[tuple(j["map"][v["answer"] - 1])] = v
            if set(got) != {(r["arm"], r["rep"]) for r in group}:
                problems.append(f"{s} {qid}: {len(got)} verdicts for {len(group)} answers")
            for (arm, rep), v in got.items():
                verdict[(qid, arm, rep)] = v
        # An F answer identical to P's takes P's verdict (the note on F's marks aside, the judge read the same text).
        for (qid, arm, rep), v in list(verdict.items()):
            p = recs.get((qid, "P", rep))
            if arm == "F" and p and recs[(qid, arm, rep)]["hash"] == p["hash"] and (qid, "P", rep) in verdict:
                pv = verdict[(qid, "P", rep)]
                verdict[(qid, arm, rep)] = {**v, "covers": pv["covers"], "abstains_right": pv["abstains_right"]}

        cov = defaultdict(Counter)
        for (qid, arm, rep), v in verdict.items():
            q, rec = qs[qid], recs[(qid, arm, rep)]
            fam = family(q, s)
            if q.get("answerable"):
                cov[fam][(arm, "ans")] += 1
                cov[fam][(arm, "covers")] += bool(v["covers"])
                if (s, qid, arm, rep) in waived and not v["covers"]:
                    cov[fam][(arm, "waived")] += 1
            else:
                cov[fam][(arm, "noans")] += 1
                cov[fam][(arm, "abst")] += bool(v["abstains_right"])
            exercised = arm == "W" and rec.get("trapSent") and rec["outcome"] != "failed"
            if arm == "W":
                if exercised:
                    w_answers += 1
                else:
                    w_skipped += 1
            about, admitted = rec.get("about") or {}, set(rec.get("admitted") or [])
            for cl in v["claims"]:
                if not 0 < cl["claim"] <= len(rec["claims"]):
                    continue
                claim = rec["claims"][cl["claim"] - 1]
                marked = bool(claim.get("inferred"))
                if (s, qid, arm, rep) in marks:
                    marked = marks[(s, qid, arm, rep)][cl["claim"] - 1]
                cites = {c["memory"] for c in claim["citations"]}
                if exercised:
                    trap = rec.get("injected") in cites
                    w_cites += trap
                    w_cites_marked += trap and marked
                    if not marked and ((trap and cl["label"] not in OK_LABELS) or cl["label"] == "wrong_person"):
                        w_fail += 1
                        review.append(f"- W FAILURE {s} **{qid}** W{rep} ({cl['label']}, unmarked): {claim['text']} — judge: {cl['why']}")
                if cl["label"] != "wrong_person" or arm == "W":
                    continue
                facts = marked or bool(cites & (set(about) | admitted))
                wrong[(arm, "facts" if facts else "own")] += 1
                if arm == "F":
                    review.append(f"- F wrong_person {s} **{qid}** F{rep} ({'learned facts' if facts else 'model own'}, "
                                  f"{'marked' if marked else 'unmarked'}): {claim['text']} — judge: {cl['why']}")
        for qid in sorted(by_q):
            vec = lambda arm, k: [verdict.get((qid, arm, n), {}).get(k) for n in sorted(r["rep"] for r in by_q[qid] if r["arm"] == arm)]
            k = "covers" if qs[qid].get("answerable") else "abstains_right"
            if vec("P", k) != vec("F", k):
                review.append(f"- {s} **{qid}** {qs[qid]['query']}: {k} P {vec('P', k)}, F {vec('F', k)}"
                              + (f", W {vec('W', k)}" if vec("W", k) else ""))
        out += [f"## {s}", "", "| Family | P covers | F covers | W covers | P abstains | F abstains |", "|---|---|---|---|---|---|"]
        for fam in sorted(cov):
            c = cov[fam]
            cell = lambda arm, k, n: f"{c[(arm, k)]}/{c[(arm, n)]}" if c[(arm, n)] else "–"
            out.append(f"| {fam} | {cell('P', 'covers', 'ans')} | {cell('F', 'covers', 'ans')} | {cell('W', 'covers', 'ans')} "
                       f"| {cell('P', 'abst', 'noans')} | {cell('F', 'abst', 'noans')} |")
            if c[("F", "covers")] + c[("F", "waived")] < c[("P", "covers")] or c[("F", "abst")] < c[("P", "abst")]:
                fam_fail.append(f"{s}: {fam}")
            elif c[("F", "covers")] < c[("P", "covers")]:
                waived_lines.append(f"{s}: {fam} (F {c[('F', 'covers')]}/{c[('F', 'ans')]} vs P {c[('P', 'covers')]}/{c[('P', 'ans')]}; "
                                    f"{c[('F', 'waived')]} sample(s) waived by the author)")
        out.append("")
    ok = {
        "complete": not problems,
        "coverage ≥ plain on every family": not fam_fail and not problems,
        "0 wrong entity with correct links": wrong[("F", "facts")] == 0 and wrong[("F", "own")] <= wrong[("P", "own")],
        "≤ 1 W failure per 30 W answers with the trap sent": w_answers > 0 and w_fail * 30 <= w_answers,
    }
    out += ["## Gate", ""] + [f"- {'PASS' if v else 'FAIL'}: {k}" for k, v in ok.items()]
    out += [f"  - {p}" for p in problems[:30]] + ([f"  - … {len(problems) - 30} more"] if len(problems) > 30 else [])
    out += [f"  - F below P: {', '.join(fam_fail)}"] if fam_fail else []
    out += [f"  - WAIVED: {w}" for w in waived_lines]
    for w in waived.values():
        out.append(f"    - {w['set']} {w['question']} {w['arm']}{w['rep']}: {w['reason']} ({w['decided']}, {w['date']})")
    out += [f"  - wrong_person: F resting on learned facts {wrong[('F', 'facts')]}, F model's own {wrong[('F', 'own')]}, "
            f"P model's own {wrong[('P', 'own')]}, P resting on learned facts {wrong[('P', 'facts')]}",
            f"  - W: {w_fail} failures in {w_answers} answers with the trap sent ({w_skipped} W answers without it, not counted); "
            f"{w_cites} claims cite the trap, {w_cites_marked} marked", ""]
    out += ["## To read by hand", ""] + (review or ["- nothing"])
    return ok, out


def cmd_answers(a):
    ok, out = answers_gate(a.engine, a.sets.split(","))
    report = OUT / f"gate-answers-{a.engine}.md"
    report.write_text("\n".join(out) + "\n")
    print("\n".join(out))
    return 0 if all(ok.values()) else 1


def spike_g_scorer():
    spec = importlib.util.spec_from_file_location("spike_g_score", HERE.parent / "search-answers" / "score.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def spikeg_gate(engine, suffix=""):
    """Spike G with the feature on: verdicts and report lines. `suffix` "-timeline": 13e.2's run, F with the rows and
    checks on (FactsAnswerLiveTests `timeline=1`)."""
    g = spike_g_scorer()
    labels_path = HERE.parent / "search-answers" / "labels.json"
    labels = json.loads(labels_path.read_text()) if labels_path.exists() else {}
    # This gate's own hand labels (Spike G's rule: a claim neither keys nor labels decide is read and labelled).
    own = OUT / f"labels-spikeg-{engine}.json"
    if own.exists():
        labels.update(json.loads(own.read_text()))
    d = OUT / f"spike-g-{engine}{suffix}"
    out = [f"# 13d gate: Spike G with the feature on ({engine})", "",
           "P plain (13b), F learned facts (attributes on); Spike G's scorer and labels; answerable if either arm sent the "
           "answer's memory. Latency isn't gated here.", "",
           "| Arm | Set | Correct claims | Right \"no answer\" | Answered (answerable) | Wrong | Unmatched |", "|---|---|---|---|---|---|---|"]
    totals = defaultdict(Counter)
    sigs = defaultdict(lambda: defaultdict(set))           # (set, qid) -> arm -> wrong signatures
    problems, review = [], []
    for s, sfx in (("main", ""), ("astra", "-astra")):
        questions = json.loads((HERE.parent / "search-answers" / f"fixtures/questions{sfx}.json").read_text())["questions"]
        arms = {arm: lines(d / f"{s}-{arm}.jsonl") for arm in ("P", "F")}
        if not all(arms.values()):
            problems.append(f"{s}: missing {', '.join(k for k, v in arms.items() if not v)}")
            continue
        sent = defaultdict(set)
        for recs in arms.values():
            for r in recs:
                sent[r["id"]] |= set(r.get("sent") or [])
        for arm, recs in arms.items():
            missing = {q["id"] for q in questions} - {r["id"] for r in recs}
            if missing:
                problems.append(f"{s} {arm}: {len(missing)} questions not answered")
            failed = [r["id"] for r in recs if r["outcome"] == "failed"]
            if failed:
                problems.append(f"{s} {arm}: failed {', '.join(failed)}")
            if arm == "F":
                fb = [r["id"] for r in recs if r["outcome"] != "failed" and not r.get("factsRevision")]
                if fb:
                    problems.append(f"{s} F: {len(fb)} answers without learned facts")
            provider = f"{engine}-13d-{arm}"
            scored = [{**r, "sent": sorted(sent[r["id"]])} for r in recs]
            r, unmatched, wrongs = g.score(provider, s, scored, questions, labels)
            for k in ("claims", "correct", "wrong", "unmatched", "answerable", "answered", "noAnswerable", "rightNoAnswer"):
                totals[arm][k] += r[k]
            for qid, text, bad in wrongs:
                sigs[(s, qid)][arm].add(text if bad == ["labelled wrong"] else tuple(sorted(bad)))
                review.append(f"- WRONG {arm} {s}/{qid}: {text} ({', '.join(bad)})")
            for key, query, text in unmatched:
                review.append(f"- UNMATCHED `{key}` ({query}): {text}")
            out.append(f"| {arm} | {s} | {g.pct(r['correct'], r['claims'])} | {g.pct(r['rightNoAnswer'], r['noAnswerable'])} "
                       f"| {g.pct(r['answered'], r['answerable'])} | {r['wrong']} | {r['unmatched']} |")
    f = totals["F"]
    new_wrong = [k for k, by in sigs.items() if by["F"] - by["P"]]
    ok = {
        "complete": not problems,
        "correct claims ≥ 95%": f["claims"] > 0 and f["correct"] / f["claims"] >= g.GATES["correct"],
        "right \"no answer\" ≥ 90%": f["noAnswerable"] > 0 and f["rightNoAnswer"] / f["noAnswerable"] >= g.GATES["no_answer"],
        "answered ≥ 80% of answerable": f["answerable"] > 0 and f["answered"] / f["answerable"] >= g.GATES["answered"],
        "no new wrong claims": not new_wrong,
        "no claim left unlabelled (both arms)": f["unmatched"] == 0 and totals["P"]["unmatched"] == 0,
    }
    out += ["", "## Gate (F, both sets)", ""] + [f"- {'PASS' if v else 'FAIL'}: {k}" for k, v in ok.items()]
    out += [f"  - {p}" for p in problems]
    out += [f"  - new wrong claims: {', '.join(f'{s}/{q}' for s, q in new_wrong)}"] if new_wrong else []
    out += ["", "## To review", ""] + (review or ["- nothing"])
    return ok, out


def cmd_spikeg(a):
    sfx = "-timeline" if a.timeline else ""
    ok, out = spikeg_gate(a.engine, sfx)
    report = OUT / f"gate-spikeg-{a.engine}{sfx}.md"
    report.write_text("\n".join(out) + "\n")
    print("\n".join(out))
    return 0 if all(ok.values()) else 1


def main():
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["answers", "spikeg"])
    ap.add_argument("--engine", default="haiku")
    ap.add_argument("--sets", default="main,astra,busy")
    ap.add_argument("--dir", default="", help="read records from here instead of results-13d (a dry run's out=)")
    ap.add_argument("--timeline", action="store_true", help="spikeg: 13e.2's run with the rows and checks on")
    a = ap.parse_args()
    if a.dir:
        OUT = Path(a.dir)
    return {"answers": cmd_answers, "spikeg": cmd_spikeg}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
