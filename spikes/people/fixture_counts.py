#!/usr/bin/env python3
"""Phase 13a.2: role references per person predicate in the story sets, and structural checks of a set's labels.

The qualification gate pools the person predicates and needs at least 20 per predicate (memory processing §11.10). A
role reference is one listed role in a story's truth, counted under the predicate whose registry word its phrase uses
("my late grandmother" is other_family), once per play: the natural order and each extra order. A phrase with no
registry word counts under none. `resolvable` counts only the references the story says can be decided.

    python3 fixture_counts.py [sets…]          counts per predicate for each set and pooled (default main astra mixed)
    python3 fixture_counts.py --check persons  also checks the set's structure and the consistency of its labels

The checks read labels, never a model's output: ids that exist, surfaces in their text, orders that are permutations,
dates, each role phrase's word against the person's relation in the story, labels in the text, and not_linked people
the same memory links.
"""
import argparse
import json
import re
from collections import Counter
from datetime import date
from pathlib import Path

from people import fold

HERE = Path(__file__).resolve().parent
TYPES = ["partner", "parent", "child", "sibling", "other_family", "friend", "manager", "colleague", "care", "other"]
REG = json.loads((HERE / "registry.json").read_text())
LEX = {fold(w): p["id"] for p in REG["predicates"] if p["object_kind"] == "person" for e in p["lexicon"] for w in e["words"]}


def load(name):
    if name == "canary13":
        return json.loads((HERE / "fixtures/canary-13a2/stories.json").read_text())
    return json.loads((HERE / "fixtures" / ("stories.json" if name == "main" else f"stories-{name}.json")).read_text())


QUERY_KINDS = ("before", "after", "year", "current", "previous", "role_in_stint", "negative", "no_answer")
# What the 13a.2 blind work fixture must cover, by the story tags its author gives (`traps`), and its floors.
WORK_TRAPS = ("untrusted_end", "concurrent_slots", "rehire", "promotion", "freelance_clients", "vendor", "gap", "renamed",
              "import", "spanish", "negative_wording")
WORK_FLOORS = {"decidable": 30, "negatives": 5, "clients": 3, "vendors": 3}


def check_timeline(data, work):
    """The work and canary sets' timeline labels: jobs and dates as written, stints, questions, traps and floors."""
    out = []
    decidable = negatives = clients = vendors = 0
    traps = Counter()
    for s in data["stories"]:
        sid = s["id"]
        mems = {m["id"]: m for m in s["memories"]}
        orgs = {t["org"] for t in s.get("timeline", [])}
        for t in s.get("timeline", []):
            for x in t.get("memories", []):
                if x not in mems:
                    out.append(f"{sid}: stint {t['org']} cites unknown memory {x}")
            for k in ("start", "end"):
                v = t.get(k) or ""
                if v and not __import__("re").fullmatch(r"\d{4}(-\d{2}(-\d{2})?)?", v):
                    out.append(f"{sid}: stint {t['org']} {k} '{v}' isn't YYYY, YYYY-MM or YYYY-MM-DD")
            clients += t.get("kind") == "client"
            vendors += t.get("kind") == "vendor"
        for m in s["memories"]:
            at = f"{sid} {m['id']}"
            if m.get("sensitivity", "low") not in ("public", "low", "internal", "sensitive", "restricted", "secret"):
                out.append(f"{at}: sensitivity {m.get('sensitivity')}")
            for j in m.get("jobs", []):
                if j["org"] not in m["text"]:
                    out.append(f"{at}: job '{j['org']}' not in text")
                for k in ("start", "end", "time", "preceded_by", "followed_by", "also_called"):
                    if j.get(k) and j[k] not in m["text"]:
                        out.append(f"{at}: job {j['org']} {k} '{j[k]}' isn't written in the text")
            for f in m.get("facts", []):
                for k in ("start", "end", "time"):
                    if f.get(k) and f[k] not in m["text"]:
                        out.append(f"{at}: fact {k} '{f[k]}' isn't written in the text")
            for o in m.get("organizations", []):
                if o["surface"] not in m["text"]:
                    out.append(f"{at}: organization '{o['surface']}' not in text")
        for q in s.get("queries", []):
            if q["kind"] not in QUERY_KINDS:
                out.append(f"{sid} {q['id']}: kind {q['kind']}")
            if q.get("answer_org") and q["answer_org"] not in orgs:
                out.append(f"{sid} {q['id']}: answer {q['answer_org']} isn't a stint of the story")
            if q["kind"] in ("negative", "role_in_stint"):
                negatives += 1
                if q.get("answer_org"):
                    out.append(f"{sid} {q['id']}: a {q['kind']} question with an answer")
            elif q.get("answer_org"):
                decidable += 1
        for c in s.get("corrections", []):
            if c.get("after") not in mems or c.get("op") not in ("reject", "start", "end") or c.get("person") not in s["people"]:
                out.append(f"{sid}: correction {c}")
        traps.update(s.get("traps", []))
    if work:
        n = {"decidable": decidable, "negatives": negatives, "clients": clients, "vendors": vendors}
        out += [f"{k}: {n[k]} (at least {v})" for k, v in WORK_FLOORS.items() if n[k] < v]
        out += [f"no story tagged {t}" for t in WORK_TRAPS if not traps[t]]
    return out


def predicate_of(surface):
    """The predicate of a role phrase's registry word (the last one, so "my mom's friend" would read as friend)."""
    s = fold(surface)
    hits = [(m.start(), LEX[t]) for m in re.finditer(r"[\w'-]+", s) for t in [m.group()] if t in LEX]
    hits += [(s.find(w), p) for w, p in LEX.items() if " " in w and w in s]
    return max(hits)[1] if hits else None


def counts(data):
    allc, res = Counter(), Counter()
    for s in data["stories"]:
        plays = 1 + len(s.get("orders", []))
        for m in s["memories"]:
            for r in m["roles"]:
                p = predicate_of(r["surface"])
                allc[p] += plays
                res[p] += plays if r["resolvable"] else 0
    return allc, res


def row(c):
    return ", ".join(f"{t} {c.get(t, 0)}" for t in TYPES) + (f", none {c[None]}" if c.get(None) else "")


def check(data):
    """Problems with a set's structure or the consistency of its labels."""
    out = []
    ua = {fold(a) for a in data["user"]["aliases"]}
    for s in data["stories"]:
        sid, people = s["id"], s["people"]
        ids = [m["id"] for m in s["memories"]]
        if len(set(ids)) != len(ids):
            out.append(f"{sid}: duplicate memory ids")
        for o in s.get("orders", []):
            if sorted(o) != sorted(ids):
                out.append(f"{sid}: order {o} isn't a permutation")
        rel = {}
        for m in s["memories"]:
            for f in m["facts"]:
                if f["person"] and f["polarity"] == "positive":
                    rel.setdefault(f["person"], set()).add(f["type"])
        for pid, p in people.items():
            if p.get("group"):
                rel.setdefault(pid, set()).add(p["group"][0])
                if p["group"][0] not in TYPES:
                    out.append(f"{sid}: {pid}'s group type {p['group'][0]} isn't a relation type")
        prev = None
        for m in s["memories"]:
            at = f"{sid} {m['id']}"
            try:
                d = date.fromisoformat(m["written"])
                if prev and d < prev:
                    out.append(f"{at}: written {m['written']} before the memory it follows")
                prev = d
            except ValueError:
                out.append(f"{at}: date {m['written']}")
            if m["source"] not in ("capture", "agent", "import"):
                out.append(f"{at}: source {m['source']}")
            text = m["text"]
            linked = set()
            for n in m["names"]:
                if n["surface"] not in text:
                    out.append(f"{at}: name '{n['surface']}' not in text")
                if n["person"] == "?":
                    if len(n.get("of", [])) < 2 or any(x not in people for x in n["of"]):
                        out.append(f"{at}: ambiguous '{n['surface']}' needs two known candidates")
                elif n["person"] == "user":
                    if fold(n["surface"]) not in ua:
                        out.append(f"{at}: '{n['surface']}' given as the user but isn't one of the user's names")
                elif n["person"] not in people:
                    out.append(f"{at}: name '{n['surface']}' → unknown person {n['person']}")
                else:
                    linked.add(n["person"])
                    names = people[n["person"]]["names"]
                    if names and not any(fold(n["surface"]) in fold(x) or fold(x) in fold(n["surface"]) for x in names):
                        out.append(f"{at}: '{n['surface']}' isn't among {n['person']}'s names {names}")
            seen = {}
            for r in m["roles"]:
                if r["surface"] not in text:
                    out.append(f"{at}: role '{r['surface']}' not in text")
                    continue
                n_here = text.count(r["surface"])
                seen[r["surface"]] = seen.get(r["surface"], 0) + 1
                if seen[r["surface"]] > n_here:
                    out.append(f"{at}: role '{r['surface']}' listed more often than it occurs")
                if r["person"] not in people:
                    out.append(f"{at}: role '{r['surface']}' → unknown person {r['person']}")
                    continue
                if r["resolvable"]:
                    linked.add(r["person"])
                p = predicate_of(r["surface"])
                if p is None:
                    out.append(f"{at}: role '{r['surface']}' has no registry word")
                elif p not in rel.get(r["person"], set()):
                    out.append(f"{at}: role '{r['surface']}' ({p}) → {r['person']}, whom the story gives "
                               f"{sorted(rel.get(r['person'], set())) or 'no relation'}")
                owner = fold(r["surface"]).split()[0] if r["surface"].strip() else ""
                if owner not in {"my", "mi", "mis", "the"} and not any(fold(r["surface"]).startswith(a + "'s") or fold(r["surface"]).startswith(a + "’s") for a in ua):
                    out.append(f"{at}: role '{r['surface']}' doesn't start at an owner")
            for f in m["facts"]:
                if f["type"] not in TYPES:
                    out.append(f"{at}: fact type {f['type']}")
                if f["person"] and f["person"] not in people:
                    out.append(f"{at}: fact about unknown person {f['person']}")
                if f["label"] and fold(f["label"]) not in fold(text):
                    out.append(f"{at}: label '{f['label']}' not in text")
                if f["person"] is None and f["polarity"] == "positive" and f["count"] is None and not f["label"]:
                    out.append(f"{at}: a positive fact about nobody, with no count or plural label")
            for x in m["not_linked"]:
                if x not in people:
                    out.append(f"{at}: not_linked {x} isn't a person")
                elif x in linked:
                    out.append(f"{at}: {x} is both linked and not_linked")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*", default=["main", "astra", "mixed"])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    pool, pool_r = Counter(), Counter()
    bad = False
    for name in a.sets:
        data = load(name)
        c, r = counts(data)
        pool += c
        pool_r += r
        n_mem = sum(len(s["memories"]) for s in data["stories"])
        plays = sum(1 + len(s.get("orders", [])) for s in data["stories"])
        print(f"{name}: {len(data['stories'])} stories, {n_mem} memories, {plays} plays")
        print(f"  all:        {row(c)}")
        print(f"  resolvable: {row(r)}")
        if a.check:
            probs = check(data)
            if name in ("work13", "canary13"):
                probs += check_timeline(data, work=name == "work13")
            print(f"  checks: {len(probs)} problem(s)")
            for p in probs:
                print("   -", p)
            bad = bad or bool(probs)
    if len(a.sets) > 1:
        print(f"pooled ({' + '.join(a.sets)}):")
        print(f"  all:        {row(pool)}")
        print(f"  resolvable: {row(pool_r)}")
        short = [t for t in TYPES if pool.get(t, 0) < 20]
        print(f"  under 20: {', '.join(short) if short else 'none'}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
