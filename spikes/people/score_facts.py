#!/usr/bin/env python3
"""Spike H3: timeline scoring on facts.py's state.

    python3 score_facts.py work <state.json> <queries.json>            a run_facts.py `work` state vs a fixture's truth
    python3 score_facts.py convert <h2-extract.jsonl> <vault.json> <out-state.json>   H2's extraction through facts.apply
                                                                                       (tests the generic timeline alone)
Queries use work_history.py's fixture format: {timeline, queries[{id, kind, query, answer_org}]}. For every query the
generic `intent` decides whether it's a timeline query, and for before / after which predicate and anchor; the answer
is facts.before / facts.after. A wrong answer is one that names another entity; "gap" and "ambiguous" are told.
"""
import argparse
import json
import sys
from pathlib import Path

import facts as F
from run_facts import load_state


TIMELINE_KINDS = ("before", "after", "year", "current", "previous", "no_answer")


def judge(state, q):
    """One query -> an outcome: right, right_gap (right entity, gap told), wrong, told (no answer, a note), miss (no
    intent on a decidable question), told_gap (a gap told where the truth is undecidable), triggered / quiet (negatives)."""
    it = F.intent(q["query"], state)
    if q["kind"] in ("negative", "role_in_stint"):
        return ("triggered" if it else "quiet"), it, None
    decidable = bool(q.get("answer_org"))
    if not it:
        return ("miss" if decidable else "told"), it, None
    got, basis = F.answer(state, it, q["query"])
    want = set(F.entity_matches(state, it[0], q["answer_org"])) if decidable else set()
    if isinstance(got, list):                  # several current jobs: right if the truth is among them
        got = next((g for g in got if g in want), ("several", tuple(got)))
    if got is None:
        return ("told" if not decidable else "told_decidable"), it, basis
    if decidable and not want and basis == "gap":
        return "told_gap", it, basis           # the truth isn't an entity of this predicate (a study gap): a gap told is right
    if not decidable:
        return ("told_gap" if basis == "gap" else "wrong"), it, basis
    if got in want:
        return ("right_gap" if basis == "gap" else "right"), it, basis
    return "wrong", it, basis


def score_work(state, data, out=print):
    c, rows = {}, []
    for q in data["queries"]:
        if q["kind"] not in TIMELINE_KINDS + ("negative", "role_in_stint"):
            continue
        outcome, it, basis = judge(state, q)
        c[outcome] = c.get(outcome, 0) + 1
        if it and q["kind"] in ("before", "after") and it[1] != q["kind"]:
            c["operator_mismatch"] = c.get("operator_mismatch", 0) + 1
        rows.append((q["id"], q["kind"], f"{basis}: {outcome}" if basis else outcome))
    dec = sum(c.get(k, 0) for k in ("right", "right_gap", "wrong_decidable", "told_decidable", "miss")) + \
        sum(1 for q in data["queries"] if q["kind"] in TIMELINE_KINDS and q.get("answer_org") and judge(state, q)[0] == "wrong")
    out(f"decidable: right {c.get('right', 0)}, right with a gap told {c.get('right_gap', 0)}, told {c.get('told_decidable', 0)}, "
        f"no intent {c.get('miss', 0)}; undecidable: told {c.get('told', 0)}, gap told {c.get('told_gap', 0)}; "
        f"WRONG {c.get('wrong', 0)}; negatives triggered {c.get('triggered', 0)} of {c.get('triggered', 0) + c.get('quiet', 0)}; "
        f"operator mismatches {c.get('operator_mismatch', 0)}")
    return {"counts": c, "rows": rows}


def employers(state, data, out=print):
    pred = F.R.timeline_preds()[0] if F.R.timeline_preds() else None
    truth = [t for t in data["timeline"] if t["kind"] in ("employee", "self_employed")]
    ents = {f.entity for f in state.facts if f.type == pred and not f.negated}
    found = {t["org"] for t in truth if F.entity_matches(state, pred, t["org"])}
    wrong = [e for e in ents if not any(e in F.entity_matches(state, pred, t["org"]) for t in truth)]
    clients = [t for t in data["timeline"] if t["kind"] == "client"]
    clients_as_emp = sum(1 for t in clients if F.entity_matches(state, pred, t["org"]))
    out(f"employers in the truth {len({t['org'] for t in truth})}; found {len(found)}; {pred} entities {len(ents)} "
        f"(not employers: {len(wrong)}); clients recorded as {pred}: {clients_as_emp} of {len(clients)}")
    return {"truth": len({t['org'] for t in truth}), "found": len(found), "entities": len(ents), "not_employers": len(wrong),
            "clients_as_employer": clients_as_emp}


def convert(recs, vault):
    """H2's extracted jobs applied through facts.apply, as if the work call group had returned them."""
    vm = {m["id"]: m for m in json.loads(Path(vault).read_text())["memories"]}
    state = F.State([])
    pred_emp = next(p for p in F.R.timeline_preds())
    pred_client = next((p for p in F.R.preds if F.R.kind_of(p) == F.R.kind_of(pred_emp) and p != pred_emp), None)
    for r in recs:
        m = vm.get(r["id"], {})
        mem = {"id": r["id"], "text": (m.get("title", "") + "\n" + m.get("body", "")), "written": r["written"][:10],
               "source": "capture", "trust": r.get("trust", "trusted")}
        mem["sent"] = mem["text"]
        state.memories[r["id"]] = mem
        rels = []
        for j in r["jobs"]:
            pred = pred_client if j.get("kind") == "client" else pred_emp
            if pred is None:
                continue
            quals = {k: None for k in F.group_qualifiers([pred])}
            if "kind" in quals:
                quals["kind"] = j.get("kind") if j.get("kind") != "client" else None
            if "title" in quals:
                quals["title"] = j.get("role")
            rels.append({"quote": j["quote"], "predicate": pred, "entity": "name", "name": j["org"], "label": None,
                         "polarity": "positive", "status": j["status"], "deceased": False, "only": False, "count": None,
                         "time": None, "start": j["start"], "end": j["end"],
                         # H2's prompt: "before / after: another organization the note says this job came before or after"
                         "followed_by": j["before"], "preceded_by": j["after"],
                         "also_called": j.get("also_called"), "qualifiers": quals})
        F.apply(state, mem, [], [], rels, [], {}, [])
    return state


def score_stories(results, fixture, out=print):
    """Story results saved with --keep-state: each story's queries on its own final state (per play, and per distinct
    question: right only if right in every order, wrong if wrong in any), and organizations misfiled."""
    stories = {x["id"]: x for x in json.loads(Path(fixture).read_text())["stories"]}
    plays, per_q = {}, {}
    mis = {"client_as_timeline": 0, "vendor_as_timeline": 0, "vendor_as_recorded": 0, "employers_truth": 0, "employers_found": 0}
    wrong_rows = []
    for line in Path(results).read_text().splitlines():
        res = json.loads(line)
        st = stories[res["story"]]
        if not st.get("queries"):
            continue
        state = load_state(res["state"])
        r = score_work(state, {"timeline": st["timeline"], "queries": st["queries"]}, out=lambda *_: None)
        for k, v in r["counts"].items():
            plays[k] = plays.get(k, 0) + v
        for (qid, kind, outcome) in r["rows"]:
            per_q.setdefault((res["story"], qid), []).append(outcome.split(": ")[-1])
            if outcome.endswith("wrong") or outcome == "triggered":
                wrong_rows.append((res["story"], res["orderIndex"], qid, outcome))
        tl = F.R.timeline_preds()
        others = [p for p in F.R.preds if F.R.uses(p, "recorded") and not F.R.uses(p, "linked")]
        for t in st["timeline"]:
            hits_tl = any(F.entity_matches(state, p, t["org"]) for p in tl)
            hits_rec = any(F.entity_matches(state, p, t["org"]) for p in others)
            if t["kind"] == "client":
                mis["client_as_timeline"] += hits_tl
            elif t["kind"] == "vendor":
                mis["vendor_as_timeline"] += hits_tl
                mis["vendor_as_recorded"] += hits_rec
            elif t["kind"] in ("employee", "self_employed"):
                mis["employers_truth"] += 1
                mis["employers_found"] += hits_tl
    distinct = {}
    for k, outs in per_q.items():
        o = "wrong" if "wrong" in outs else ("triggered" if "triggered" in outs else (outs[0] if len(set(outs)) == 1 else "varies"))
        distinct[o] = distinct.get(o, 0) + 1
    out("per play: " + ", ".join(f"{k} {v}" for k, v in sorted(plays.items())))
    out("per distinct question: " + ", ".join(f"{k} {v}" for k, v in sorted(distinct.items())) + f" (of {len(per_q)})")
    out(f"organizations: employers found {mis['employers_found']}/{mis['employers_truth']}; clients under a timeline predicate "
        f"{mis['client_as_timeline']}; vendors under a timeline predicate {mis['vendor_as_timeline']}; vendors recorded as clients "
        f"{mis['vendor_as_recorded']}")
    for row in wrong_rows:
        out("   " + " ".join(str(x) for x in row))
    return plays, distinct, mis


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["work", "convert", "stories"])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("c", nargs="?")
    ap.add_argument("--rows", action="store_true")
    a = ap.parse_args()
    if a.cmd == "stories":
        score_stories(a.a, a.b)
        return
    if a.cmd == "convert":
        recs = [json.loads(l) for l in Path(a.a).read_text().splitlines()]
        state = convert(recs, a.b)
        from run_facts import dump_state
        Path(a.c).write_text(json.dumps(dump_state(state, []), ensure_ascii=False))
        print(f"facts {len(state.facts)}; entities {len(state.entities)}")
        return
    state = load_state(json.loads(Path(a.a).read_text()))
    data = json.loads(Path(a.b).read_text())
    employers(state, data)
    res = score_work(state, data)
    if a.rows:
        for r in res["rows"]:
            print("  ", *r)


if __name__ == "__main__":
    sys.exit(main())
