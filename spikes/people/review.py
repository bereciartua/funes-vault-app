#!/usr/bin/env python3
"""Spike H, the author's vault: the author checks links in the terminal (§15). The sample is 50 random links to a
person, plus every `named` or `context` link about family (partner, parent, child, sibling, other family). Memory
text and names are shown only here, in the author's terminal; verdicts are saved by link key in <dir>/review.json,
which holds no text. Resumable: rerun to continue.

    python3 review.py <private dir>            review
    python3 review.py <private dir> --counts   counts only (no text, no names)

Another engine's backfill against the reviewed one: every link to a person is in scope, and a link with the same key
whose person has a name in common with a link already judged takes that verdict, so only the differences are shown.

    python3 review.py <dir> --backfill backfill-haiku.json --verdicts review-haiku.json --reference backfill.json:review.json
"""
import argparse
import json
import random
import sqlite3
import sys
from collections import Counter
from pathlib import Path

from people import role_phrases

FAMILY = {"partner", "parent", "child", "sibling", "other_family"}
FULL = {"named", "stated_unique", "context"}
PERSON_BASES = FULL | {"sole_known", "untrusted", "confirmed"}
B, R, DIM, Y = "\033[1m", "\033[0m", "\033[2m", "\033[33m"


def key(l):
    return f"{l['memory']}|{l['kind']}|{l.get('start', l['surface'])}"


def build(d, backfill="backfill.json", everything=False):
    bf = json.loads((d / backfill).read_text())
    c = sqlite3.connect(f"file:{d / 'vault-copy.sqlite'}?mode=ro", uri=True).cursor()
    text = dict(c.execute("select id, body from memory"))
    prof = c.execute("select given_name, family_name, preferred_name from profile").fetchone() or (None,) * 3
    first = prof[2] or prof[0]
    aliases = [a for a in {first, prof[1], f"{first} {prof[1]}" if first and prof[1] else None} if a]
    people = {p["id"]: p for p in bf["people"]}
    rels = {}
    for r in bf["relations"]:
        if not r["negated"]:
            rels.setdefault(r["person"], []).append(r)
    linked = [l for l in bf["links"] if l["person"] in people and people[l["person"]]["name"] and l["basis"] in PERSON_BASES]
    for l in linked:
        if l["kind"] == "role":
            ph = next((p for p in role_phrases(text[l["memory"]], aliases) if p.start == l["start"]), None)
            l["type"] = ph.type if ph else None
        else:
            l["type"] = next((r["type"] for r in rels.get(l["person"], []) if r["type"] in FAMILY), None)
    rnd = random.Random(20261114)
    sample = linked if everything else rnd.sample(linked, min(50, len(linked)))
    family = [l for l in linked if l["basis"] in ("named", "context") and l["type"] in FAMILY]
    items, seen = [], set()
    for tag, group in (("sample", sample), ("family", family)):
        for l in group:
            k = key(l)
            if k in seen:
                for it in items:
                    if it["key"] == k:
                        it["tags"].append(tag)
                continue
            seen.add(k)
            items.append({"key": k, "tags": [tag], "link": l})
    rnd.shuffle(items)
    return items, text, people, rels, len(linked), bf


def names_of(bf, pid):
    p = next((x for x in bf["people"] if x["id"] == pid), None)
    return {a.lower() for a in (p["aliases"] if p else [])}


def inherit(d, items, ref):
    """Verdicts carried from a reviewed backfill: same link key and a shared name. Returns (verdicts, ref link keys)."""
    bpath, vpath = ref.split(":")
    rbf = json.loads((d / bpath).read_text())
    rv = json.loads((d / vpath).read_text())
    rlinks = {key(l): l for l in rbf["links"]}
    out = {}
    for it in items:
        l, k = it["link"], it["key"]
        if k in rv and k in rlinks and names_of(rbf, rlinks[k]["person"]) & it["names"]:
            out[k] = rv[k]
    return out, rv, rlinks, rbf


def show(i, n, it, text, people, rels):
    l = it["link"]
    t = text[l["memory"]]
    if l["kind"] == "role":
        s, e = l["start"], l["start"] + len(l["surface"])
    else:
        s = t.find(l["surface"])
        e = s + len(l["surface"]) if s >= 0 else -1
    hl = t[:s] + B + Y + t[s:e] + R + t[e:] if s >= 0 else t
    p = people[l["person"]]
    rel = "; ".join(f"{r['label'] or r['type']}" + (" (former)" if r["status"] == "former" else "") for r in rels.get(p["id"], []))
    print(f"\n{DIM}── {i}/{n} ─────────────────────────────────────────{R}")
    print(hl)
    print(f"\n  {B}{l['surface']}{R}  →  {B}{p['name']}{R}" + (f"  {DIM}({rel}){R}" if rel else "")
          + f"\n  {DIM}aliases: {', '.join(p['aliases'])} · basis: {l['basis']}{R}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--counts", action="store_true")
    ap.add_argument("--backfill", default="backfill.json")
    ap.add_argument("--verdicts", default="review.json")
    ap.add_argument("--reference", default="")
    a = ap.parse_args()
    d = Path(a.dir)
    items, text, people, rels, n_linked, bf = build(d, a.backfill, everything=bool(a.reference))
    for it in items:
        it["names"] = {x.lower() for x in people[it["link"]["person"]]["aliases"]}
    vpath = d / a.verdicts
    verdicts = json.loads(vpath.read_text()) if vpath.exists() else {}
    if a.reference:
        inherited, rv, rlinks, rbf = inherit(d, items, a.reference)
        for k, v in inherited.items():
            verdicts.setdefault(k, v)
        mine = {it["key"] for it in items}
        missed = [k for k, v in rv.items() if v == "right" and k not in mine]
        if a.counts:
            print(json.dumps({"inherited": len(inherited), "to_review": sum(1 for it in items if it["key"] not in verdicts),
                              "reference_right_links_missing_here": len(missed)}))
    if a.counts:
        c = Counter()
        for it in items:
            v = verdicts.get(it["key"])
            b = "full" if it["link"]["basis"] in FULL else it["link"]["basis"]
            c[(b, v or "unreviewed")] += 1
            for tag in it["tags"]:
                c[(tag, v or "unreviewed")] += 1
        print(json.dumps({"links_to_people": n_linked, "items": len(items),
                          "sample": sum(1 for it in items if "sample" in it["tags"]),
                          "family": sum(1 for it in items if "family" in it["tags"]),
                          "by": {f"{k[0]}:{k[1]}": v for k, v in sorted(c.items())}}, indent=1))
        return
    todo = [it for it in items if it["key"] not in verdicts]
    print(f"{B}People links to check{R}: {len(items)} ({len(todo)} left). For each, is the highlighted phrase really "
          f"about that person?\n  y = right   n = wrong   ? = can't tell   q = save and stop (rerun to continue)")
    done = len(items) - len(todo)
    for it in todo:
        done += 1
        show(done, len(items), it, text, people, rels)
        while True:
            ans = input("  right? [y/n/?/q] ").strip().lower()
            if ans in ("y", "n", "?", "q"):
                break
        if ans == "q":
            break
        verdicts[it["key"]] = {"y": "right", "n": "wrong", "?": "unsure"}[ans]
        vpath.write_text(json.dumps(verdicts))
        vpath.chmod(0o600)
    left = sum(1 for it in items if it["key"] not in verdicts)
    print(f"\n{'All done' if not left else f'{left} left'}. Verdicts saved (ids only). You can close this tab.")


if __name__ == "__main__":
    sys.exit(main())
