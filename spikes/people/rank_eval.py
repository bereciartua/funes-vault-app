#!/usr/bin/env python3
"""Spike H, search ranks, round 2 (ROUND2.md §4, §6): measures, injected failures, the tuning grid and the lock.

    python3 rank_eval.py grid             tune on the main set (both reads) and the busy set's tune families
    python3 rank_eval.py lock B O CAP     freeze the choice, with hashes of the code, fixtures and grid
    python3 rank_eval.py report           every set at the locked choice, with link truth and injected failures

Rank measures, without (plain search) and with people, per query and per target:
- best target in the top 3 and in the top 8;
- losses, reported separately: any target ranked worse, a target out of the top 3, a target out of the top 8;
- traps (decoys) above the best target and in the top 3;
- name-only queries: precision and recall of memories about the person in the top 10;
- injected failures:
  - a missed link: each admitted target's link removed in turn;
  - a missing relation: every role link of the matched people removed at once;
  - a wrong link: each trap admitted at the full weight;
  - for each, the target's rank against plain search.
Busy-set queries are split by family (a family never crosses halves): tune if sha1(family) is even, else test.
"""
import hashlib
import json
import sys
import time
from collections import Counter
from pathlib import Path

import search
from search import best_rank, paths, rank_people

HERE = search.HERE
OUT = search.OUT
LOCK = OUT / "locked.json"
import os
READS = tuple(os.environ.get("READS", "r3").split(","))   # round 2 used haiku,haiku2


def half(q):
    if not q.get("family"):
        return None
    return "tune" if int(hashlib.sha1(q["family"].encode()).hexdigest(), 16) % 2 == 0 else "test"


def runs_for(set_name, which=None):
    out = []
    for eng in READS:
        _, queries, bf_path, plan_path, scores_path = paths(set_name, eng)
        if not scores_path.exists():
            continue
        qs = {q["id"]: q for q in json.loads(queries.read_text())["queries"]}
        plan = {p["id"]: p for p in json.loads(plan_path.read_text())}
        sc = json.loads(scores_path.read_text())["queries"]
        if which:
            sc = [e for e in sc if half(qs[e["id"]]) == which]
        out.append((set_name, eng, qs, plan, sc))
    return out


def measure(runs, inject=False):
    c = Counter()
    rows = []
    for set_name, eng, qs, plan, sc in runs:
        for e in sc:
            q, p = qs[e["id"]], plan[e["id"]]
            base, ppl, _ = rank_people(e, p)
            kind = (q.get("tags") or ["?"])[0] if set_name == "busy" else q["set"]
            k = f"{set_name}:{kind}"
            if q.get("about"):
                about = set(q["about"])
                for arm, lst in (("base", base), ("ppl", ppl)):
                    hit = sum(m in about for m in lst[:10])
                    c[(k, f"nm_prec_{arm}")] += hit
                    c[(k, f"nm_rec_{arm}")] += hit
                c[(k, "nm_shown")] += 10
                c[(k, "nm_about")] += len(about)
                continue
            if not q.get("targets"):
                if p["admitted"] and kind == "collision":
                    c[(k, "collision_matched")] += 1
                continue
            c[(k, "n")] += 1
            rb, rp = best_rank(base, q["targets"]) or 999, best_rank(ppl, q["targets"]) or 999
            c[(k, "top3_base")] += rb <= 3
            c[(k, "top3_ppl")] += rp <= 3
            c[(k, "top8_base")] += rb <= 8
            c[(k, "top8_ppl")] += rp <= 8
            c[(k, "better")] += rp < rb
            for t in q["targets"]:
                tb = base.index(t) + 1 if t in base else 999
                tp = ppl.index(t) + 1 if t in ppl else 999
                c[(k, "targets")] += 1
                c[(k, "t_worse")] += tp > tb
                c[(k, "t_out3")] += tb <= 3 < tp
                c[(k, "t_out8")] += tb <= 8 < tp
                c[(k, "t_in8_new")] += tp <= 8 < tb
            for d in q.get("decoys", []):
                c[(k, "decoys")] += 1
                c[(k, "d3_base")] += d in base[:3]
                c[(k, "d3_ppl")] += d in ppl[:3]
                c[(k, "dabove_base")] += (base.index(d) + 1 if d in base else 999) < rb
                c[(k, "dabove_ppl")] += (ppl.index(d) + 1 if d in ppl else 999) < rp
            rows.append({"set": set_name, "read": eng, "id": q["id"], "kind": kind, "query": q["query"], "base": rb, "ppl": rp})
            if inject:
                inj(c, k, q, p, e, base, rb)
    return c, rows


def inj(c, k, q, p, e, base, rb):
    """Injected failures: the best target's rank under each, against plain search."""
    def rank_with(p2):
        return best_rank(rank_people(e, p2)[1], q["targets"]) or 999
    for t in q["targets"]:
        if t in p["admitted"]:
            p2 = {**p, "admitted": {m: w for m, w in p["admitted"].items() if m != t}}
            r = rank_with(p2)
            c[(k, "miss_n")] += 1
            c[(k, "miss_worse_than_plain")] += r > rb
            c[(k, "miss_out3")] += rb <= 3 < r
    roles = {m for m, v in p["via"].items() if v["kind"] == "role"}
    if roles & set(q["targets"]):
        p2 = {**p, "admitted": {m: w for m, w in p["admitted"].items() if m not in roles}}
        r = rank_with(p2)
        c[(k, "rel_n")] += 1
        c[(k, "rel_worse_than_plain")] += r > rb
        c[(k, "rel_out3")] += rb <= 3 < r
    for d in q.get("decoys", []):
        p2 = {**p, "admitted": {**p["admitted"], d: "full"}, "others": [m for m in p.get("others", []) if m != d]}
        b2, l2, _ = rank_people(e, p2)
        c[(k, "wrong_n")] += 1
        c[(k, "wrong_decoy_top3")] += d in l2[:3]
        c[(k, "wrong_target_worse")] += (best_rank(l2, q["targets"]) or 999) > rb


def configure(boost, others, cap):
    search.BOOST = {"full": boost, "weak": round(boost * 0.7, 3), "cand": round(boost * 0.3, 3)}
    search.OTHERS = others
    search.CAP = cap


def summarize(c, prefix=None):
    keys = sorted({k for k, _ in c if prefix is None or k.startswith(prefix)})
    tot = Counter()
    for (k, m), v in c.items():
        if k in keys:
            tot[m] += v
    return tot


GRID = [(b, o, cap) for b in (0.0, 0.1, 0.2, 0.3) for o in (0.0, 0.1) for cap in (None, 5)]


def cmd_grid():
    runs = runs_for("main") + runs_for("busy", "tune")
    print("boost others cap | top3 base→ppl | top8 | t_worse t_out3 t_out8 | decoys top3 base→ppl | miss>plain rel>plain | wrong: decoy top3")
    configure(0, 0, None)
    search_admit = True
    for b, o, cap in [("base", None, None)] + GRID:
        if b == "base":
            # the exact baseline: no admission at all
            t = summarize(measure([(s, e, qs, {k: {**v, "admitted": {}, "others": []} for k, v in pl.items()}, sc)
                                   for s, e, qs, pl, sc in runs], inject=False)[0])
        else:
            configure(b, o, cap)
            t = summarize(measure(runs, inject=True)[0])
        print(f"{str(b):5} {str(o):5} {str(cap):4} | {t['top3_base']}→{t['top3_ppl']}/{t['n']} | {t['top8_base']}→{t['top8_ppl']} | "
              f"{t['t_worse']} {t['t_out3']} {t['t_out8']} | {t['d3_base']}→{t['d3_ppl']}/{t['decoys']} | "
              f"{t['miss_worse_than_plain']}/{t['miss_n']} {t['rel_worse_than_plain']}/{t['rel_n']} | {t['wrong_decoy_top3']}/{t['wrong_n']}")


def cmd_lock(b, o, cap):
    files = ["search.py", "rank_eval.py", "search_answers.py", "people.py", "build_search.py",
             "fixtures/search-vault-busy.json", "fixtures/search-queries-busy.json", "fixtures/search-queries-astra.json"]
    LOCK.write_text(json.dumps({"boost": b, "others": o, "cap": cap, "locked_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                                "rule": "no per-target losses on the tune data, then most targets in the top 3, then fewest "
                                        "losses under a missed link",
                                "sha256": {f: hashlib.sha256((HERE / f).read_bytes()).hexdigest() for f in files}}, indent=1))
    print(LOCK.read_text())


def link_truth(set_name):
    """Links to a named person against the author's "about" per memory (busy set): precision and recall, by basis."""
    vault, _, _, _, _ = paths(set_name, READS[0])
    mems = {m["id"]: m for m in json.loads(vault.read_text())["memories"] if m.get("about") is not None}
    out = []
    for eng in READS:
        bf_path = paths(set_name, eng)[2]
        if not bf_path.exists():
            continue
        bf = json.loads(bf_path.read_text())
        people = {p["id"]: p for p in bf["people"] if p["name"]}

        def who(name):
            """People found whose name or alias is this name; a one-word name also matches by first name."""
            f = search.fold(name)
            out = set()
            for pid, p in people.items():
                names = {search.fold(x) for x in list(p["aliases"]) + [p["name"]]}
                if f in names or (len(f.split()) == 1 and f in {n.split()[0] for n in names}):
                    out.add(pid)
            return out
        c = Counter()
        for mid, m in mems.items():
            names = [n for n in m["about"] if search.fold(n) not in {search.fold(u) for u in search.USER}]   # not the user
            truth = set().union(*[who(n) for n in names]) if names else set()
            linked = {}
            for l in bf["links"]:
                if l["memory"] == mid and l["person"] in people and search.link_weight(l):
                    linked[l["person"]] = l["basis"]
            for pid, basis in linked.items():
                c[("linked", basis)] += 1
                c[("right" if pid in truth else "wrong", basis)] += 1
            for pid in truth:
                c["truth"] += 1
                c["found"] += pid in linked
            c["unmapped"] += sum(1 for n in names if not who(n))
        out.append((eng, c))
    return out


def cmd_report():
    lock = json.loads(LOCK.read_text())
    configure(lock["boost"], lock["others"], lock["cap"])
    changed = [f for f, h in lock["sha256"].items() if hashlib.sha256((HERE / f).read_bytes()).hexdigest() != h]
    lines = [f"# Spike H search ranks, round 2", "", f"Locked {lock['locked_at']}: boost {lock['boost']}, others "
             f"−{lock['others']}, cap {lock['cap']}." + (f" **Changed since the lock: {', '.join(changed)}.**" if changed else
                                                         " No locked file changed since."), ""]
    for label, runs in (("Main set (tuning)", runs_for("main")), ("Busy set, tune families", runs_for("busy", "tune")),
                        ("Busy set, test families", runs_for("busy", "test")), ("Held-out set (Astra, round 1)", runs_for("astra"))):
        if not runs:
            continue
        c, rows = measure(runs, inject=True)
        lines += [f"## {label} ({len(runs)} reads, counts summed over reads)", "",
                  "| Kind | Queries | Top 3 plain → people | Top 8 | Targets worse · out of top 3 · out of top 8 · newly in top 8 | "
                  "Traps in top 3 | Missed link worse than plain | Missing relation worse than plain | Wrong link puts trap in top 3 |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for k in sorted({k for k, _ in c}):
            t = summarize(c, k)
            if t["n"]:
                lines.append(f"| {k.split(':', 1)[1]} | {t['n']} | {t['top3_base']} → {t['top3_ppl']} | {t['top8_base']} → {t['top8_ppl']} | "
                             f"{t['t_worse']} · {t['t_out3']} · {t['t_out8']} · {t['t_in8_new']} of {t['targets']} | "
                             f"{t['d3_base']} → {t['d3_ppl']} of {t['decoys']} | {t['miss_worse_than_plain']} of {t['miss_n']} | "
                             f"{t['rel_worse_than_plain']} of {t['rel_n']} | {t['wrong_decoy_top3']} of {t['wrong_n']} |")
            if t["nm_shown"]:
                lines.append(f"| {k.split(':', 1)[1]} (name only) | – | precision in top 10: {t['nm_prec_base']} → {t['nm_prec_ppl']} of "
                             f"{t['nm_shown']}; recall: {t['nm_rec_base']} → {t['nm_rec_ppl']} of {t['nm_about']} | | | | | | |")
            if t["collision_matched"]:
                lines.append(f"| {k.split(':', 1)[1]} | – | collision queries that matched a person: {t['collision_matched']} | | | | | | |")
        lines += ["", "Per query (best target rank, plain → people):", ""]
        lines += [f"- {r['set']}/{r['read']} {r['id']} [{r['kind']}] {r['query']}: {r['base'] if r['base'] < 999 else '–'} → "
                  f"{r['ppl'] if r['ppl'] < 999 else '–'}" for r in rows if r["base"] != r["ppl"]]
        lines.append("")
    for eng, c in link_truth("busy"):
        bases = sorted({k[1] for k in c if isinstance(k, tuple) and k[0] == "linked"})
        lines += [f"Busy-set links ({eng}) against the author's truth: recall {c['found']}/{c['truth']}; "
                  + "; ".join(f"{b} {c[('right', b)]}/{c[('linked', b)]} right" for b in bases)
                  + f"; names in the truth that match no person found: {c['unmapped']}", ""]
    rep = OUT / "report-search2.md"
    rep.write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "grid":
        cmd_grid()
    elif cmd == "lock":
        b, o, cap = float(sys.argv[2]), float(sys.argv[3]), (None if sys.argv[4] == "None" else int(sys.argv[4]))
        cmd_lock(b, o, cap)
    elif cmd == "report":
        cmd_report()
