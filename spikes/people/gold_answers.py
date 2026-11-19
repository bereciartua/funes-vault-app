#!/usr/bin/env python3
"""Phase 13a.2: scripted model answers from a story set's own ground truth, for playing a set that has no recorded calls
yet (the person fixture, before the Gates step's live runs). It plays every story and order through facts.py exactly as
run_facts.py does, with the people call group, but each call is answered by a script reading the story's labels: the
names it lists, its facts, and who each role phrase refers to (a roster id once that person is known, the name when the
memory names them, the group when they aren't known yet, "unknown" for a reference the story says can't be decided,
"someone_else" for a phrase the story doesn't list). No model is called. The output is run.py's format, so
export_replay.py and the Swift harness replay it like a recording (`scripts/facts_harness.sh <set> gold`).

What it proves: the set plays end to end (formats, ids, surfaces, orders) and its labels hang together under the
scorers. It measures nothing about a model: a perfect reader still leaves references the story calls decidable as
groups until a later memory names the person.

    python3 gold_answers.py --set persons <out.jsonl>
"""
import argparse
import json
from pathlib import Path

import facts as F
import run_facts
from score import role_starts

HERE = Path(__file__).resolve().parent
CTX = {}
_build_prompt = F.build_prompt


def _capture(state, mem, phrases, group):
    CTX.update(state=state, mem=mem, phrases=phrases)
    ins, prompt, ids = _build_prompt(state, mem, phrases, group)
    CTX["ids"] = ids
    return ins, prompt, ids


F.build_prompt = _capture       # run_facts.call reads F.build_prompt at call time


class Gold:
    """Answers a call from the story's labels. `emap` follows which facts.py entity each story person became."""

    def __init__(self, story, user_aliases):
        self.story, self.ua = story, user_aliases
        self.mems = {m["id"]: m for m in story["memories"]}
        self.emap = {}

    def learn(self, state):
        for m in self.mems.values():
            for n in m["names"]:
                hit = state.names.get((m["id"], n["surface"]))
                if hit and hit[0] and n["person"] not in ("user", "?"):
                    self.emap.setdefault(n["person"], hit[0])
            for r, st in zip(m["roles"], role_starts(m)):
                d = state.decisions.get((m["id"], st))
                tp = self.story["people"].get(r["person"], {})
                if d and d[0] and tp.get("group") and not tp.get("names"):
                    self.emap.setdefault(r["person"], d[0])

    def generate(self, instructions, prompt, schema):
        state, mem, phrases, ids = CTX["state"], CTX["mem"], CTX["phrases"], CTX["ids"]
        self.learn(state)
        m = self.mems[mem["id"]]
        sent = mem["sent"]
        rid = {e.id: k for k, e in ids.items()}
        roster = lambda g: rid.get(self.emap.get(g))
        named_here = {n["person"]: n["surface"] for n in m["names"] if n["person"] not in ("user", "?") and n["surface"] in sent}
        people = []
        for n in m["names"]:
            if n["person"] == "user" or n["surface"] not in sent:
                continue
            if n["person"] == "?":
                people.append({"name": n["surface"], "quote": n["surface"], "person": "ambiguous"})
                continue
            known = roster(n["person"])
            if known:
                person = known
            else:
                clash = any(F.fold(n["surface"]) in {F.fold(a) for a in e.aliases} for e in ids.values() if e.name)
                person = "different" if clash else "new"
            people.append({"name": n["surface"], "quote": n["surface"], "person": person})
        facts = []
        for f in m["facts"]:
            g = f["person"]
            if g is None:
                entity, name = ("none" if f["polarity"] == "negative" else "group"), None
            elif roster(g):
                entity, name = roster(g), None
            elif g in named_here:
                entity, name = "name", named_here[g]
            elif self.story["people"].get(g, {}).get("group"):
                entity, name = "group", None
            else:
                continue
            label = f["label"] if f["label"] and F._norm(f["label"]) in F._norm(sent) else None
            facts.append({"quote": sent, "predicate": f["type"], "entity": entity, "name": name, "label": label,
                          "polarity": f["polarity"], "status": f["status"], "deceased": f["deceased"], "only": f["only"],
                          "count": f["count"], "time": None, "start": None, "end": None, "preceded_by": None,
                          "followed_by": None, "also_called": None,
                          "qualifiers": {k: None for k in F.group_qualifiers([f["type"]])}})
        truth = dict(zip(role_starts(m), m["roles"]))
        roles = []
        for i, ph in enumerate(phrases):
            r = truth.get(ph.start)
            if r is None:
                ref = "someone_else"
            elif not r["resolvable"]:
                ref = "unknown"
            elif roster(r["person"]):
                ref = roster(r["person"])
            elif r["person"] in named_here:
                ref = "name:" + named_here[r["person"]]
            else:
                ref = "group"
            roles.append({"id": f"r{i + 1}", "refers_to": ref})
        out = {"facts": facts, "roles": roles, "things": []}
        if "people" in schema.get("properties", {}):
            out["people"] = people
        return {"ok": True, "content": out, "ms": 0}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="persons")
    ap.add_argument("out")
    a = ap.parse_args()
    suffix = "" if a.set == "main" else f"-{a.set}"
    data = json.loads((HERE / f"fixtures/stories{suffix}.json").read_text())
    ua = data["user"]["aliases"]
    lines, calls_n = [], 0
    for s in data["stories"]:
        mems = {m["id"]: m for m in s["memories"]}
        for i, order in enumerate([[m["id"] for m in s["memories"]]] + s.get("orders", [])):
            gold = Gold(s, ua)
            state, calls = run_facts.play(gold, [mems[x] for x in order], ua, ["people"])
            res = run_facts.dump_people(state, calls)
            res.update(story=s["id"], orderIndex=i, order=order, provider="gold", run=1, groups="people", registry=F.R.version)
            lines.append(json.dumps(res, ensure_ascii=False))
            calls_n += len(calls)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text("\n".join(lines) + "\n")
    print(f"gold answers: {len(lines)} plays, {calls_n} calls -> {a.out}")


if __name__ == "__main__":
    main()
