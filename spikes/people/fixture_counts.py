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
    return json.loads((HERE / "fixtures" / ("stories.json" if name == "main" else f"stories-{name}.json")).read_text())


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
            print(f"  checks: {len(probs)} problem(s)")
            for p in probs:
                print("   -", p)
    if len(a.sets) > 1:
        print(f"pooled ({' + '.join(a.sets)}):")
        print(f"  all:        {row(pool)}")
        print(f"  resolvable: {row(pool_r)}")
        short = [t for t in TYPES if pool.get(t, 0) < 20]
        print(f"  under 20: {', '.join(short) if short else 'none'}")


if __name__ == "__main__":
    main()
