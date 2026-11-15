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


def by_name(state, q):
    pred = F.R.timeline_preds()[0]
    kind = F.R.kind_of(pred)
    names = sorted({a for f in state.facts if f.type == pred for a in state.entities[f.entity].aliases}, key=len, reverse=True)
    names += [s for v in F.R.preds[pred].get("placeholders", {}).values() for s in v]
    for n in names:
        nn = F.norm_name(n, kind)
        if nn and F.re.search(r"(?<!\w)" + F.re.escape(nn) + r"(?!\w)", F.fold(q["query"])):
            hits = F.entity_matches(state, pred, n)
            if hits:
                return pred, q["kind"], hits[0]
    return None


def score_work(state, data, out=print, anchor_by_name=False):
    right = wrong = amb = trig_neg = missed = 0
    rows = []
    for q in data["queries"]:
        it = F.intent(q["query"], state)
        if anchor_by_name and q["kind"] in ("before", "after"):
            it = by_name(state, q)    # H2's scorer: the anchor from the names in the query, no intent rule
        if q["kind"] in ("negative", "role_in_stint"):
            trig_neg += it is not None
            rows.append((q["id"], q["kind"], "triggered" if it else "not triggered"))
            continue
        if q["kind"] not in ("before", "after"):
            continue
        if not it or it[1] not in ("before", "after") or it[2] is None:
            amb += 1
            missed += it is None
            rows.append((q["id"], q["kind"], f"no anchor ({it[1] if it else 'no intent'}): ambiguous"))
            continue
        pred, op, x = it
        got, basis = (F.before if q["kind"] == "before" else F.after)(state, pred, x, q["query"])
        want = set(F.entity_matches(state, pred, q["answer_org"])) if q.get("answer_org") else set()
        ok = got is not None and got in want and basis != "gap"
        gap = basis == "gap"
        right += ok
        wrong += got is not None and not ok and not gap
        amb += got is None or gap
        rows.append((q["id"], q["kind"], f"{basis}: " + ("right" if ok else "gap told" if gap else "ambiguous" if got is None else "WRONG")))
    out(f"before/after queries: right {right}, wrong {wrong}, ambiguous or gap told {amb} (no intent: {missed}); "
        f"negative or in-fact queries that triggered the timeline: {trig_neg}")
    return {"right": right, "wrong": wrong, "ambiguous": amb, "negatives_triggered": trig_neg, "rows": rows}


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["work", "convert"])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("c", nargs="?")
    ap.add_argument("--rows", action="store_true")
    a = ap.parse_args()
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
    out2 = score_work(state, data, out=lambda s: print("resolver only (anchor by name, as H2's scorer): " + s), anchor_by_name=True)
    if a.rows:
        for r in res["rows"]:
            print("  ", *r)


if __name__ == "__main__":
    sys.exit(main())
