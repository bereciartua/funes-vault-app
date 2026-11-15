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


def score_stories(results, fixture, out=print):
    """Story results saved with --keep-state: each story's timeline queries on its own final state, and the
    organizations misfiled (clients or vendors recorded under a timeline predicate, vendors recorded as clients)."""
    stories = {x["id"]: x for x in json.loads(Path(fixture).read_text())["stories"]}
    tot = {"right": 0, "wrong": 0, "ambiguous": 0, "negatives_triggered": 0, "runs": 0}
    mis = {"client_as_timeline": 0, "vendor_as_timeline": 0, "vendor_as_recorded": 0, "employers_truth": 0, "employers_found": 0}
    wrong_rows = []
    for line in Path(results).read_text().splitlines():
        res = json.loads(line)
        st = stories[res["story"]]
        if not st.get("queries"):
            continue
        state = load_state(res["state"])
        r = score_work(state, {"timeline": st["timeline"], "queries": st["queries"]}, out=lambda *_: None)
        tot["runs"] += 1
        for k in ("right", "wrong", "ambiguous", "negatives_triggered"):
            tot[k] += r[k]
        wrong_rows += [(res["story"], res["orderIndex"], *row) for row in r["rows"] if "WRONG" in row[-1] or row[-1] == "triggered"]
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
    out(f"story runs {tot['runs']}: before/after right {tot['right']}, wrong {tot['wrong']}, ambiguous or gap told {tot['ambiguous']}; "
        f"negatives that triggered {tot['negatives_triggered']}")
    out(f"organizations: employers found {mis['employers_found']}/{mis['employers_truth']}; clients under a timeline predicate "
        f"{mis['client_as_timeline']}; vendors under a timeline predicate {mis['vendor_as_timeline']}; vendors recorded as clients "
        f"{mis['vendor_as_recorded']}")
    for row in wrong_rows:
        out("   " + " ".join(str(x) for x in row))
    return tot, mis


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
    out2 = score_work(state, data, out=lambda s: print("resolver only (anchor by name, as H2's scorer): " + s), anchor_by_name=True)
    if a.rows:
        for r in res["rows"]:
            print("  ", *r)


if __name__ == "__main__":
    sys.exit(main())
