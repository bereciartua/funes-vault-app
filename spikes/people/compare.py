#!/usr/bin/env python3
"""Spike H: compare two result folders (default results-v2 vs results) per engine, both sets combined and per set."""
import glob
import json
import sys
from collections import Counter

from score import score_run

ENGINES = ["claude-opus", "claude-haiku", "codex-terra", "codex-luna"]


def stats(T):
    full = T["full_right"] + T["full_wrong"]
    res = T["role_refs"] - T["ambiguity_kept"] - T["undecidable_guessed_wrong"]
    right = T["full_right"] + T["sole_known_right"] + T["untrusted_right"] + T["group_right"]
    pc = lambda a, b: f"{100 * a / b:.1f}%" if b else "–"
    return {"full": f"{T['full_right']}/{full} = {pc(T['full_right'], full)}",
            "wrong": T["full_wrong"] + T["sole_known_wrong"] + T["untrusted_wrong"] + T["group_wrong"],
            "recall": pc(right, res), "misses": T["role_miss"],
            "ambiguity": pc(T["ambiguity_kept"], T["ambiguity_kept"] + T["undecidable_guessed_wrong"]),
            "names_amb": f"{T['name_ambiguous_kept']}/{T['name_ambiguous_kept'] + T['name_ambiguous_guessed']}",
            "forbidden": T["forbidden_link"], "extra_roles": T["role_extra_linked"], "false_people": T["false_person"],
            "not_found": T["role_not_found"], "rel_P": pc(T["relations_right"], T["relations_system"]),
            "rel_R": pc(T["relations_found"], T["relations_truth"]), "labels": T["label_invented"]}


def main():
    bases = sys.argv[1:] or ["results-v2", "results"]
    for eng in ENGINES:
        for base in bases:
            A, per, cost, n = Counter(), {}, 0.0, 0
            for setn, suf in [("main", ""), ("astra", "-astra")]:
                S = {s["id"]: s for s in json.load(open(f"fixtures/stories{suf}.json"))["stories"]}
                T = Counter()
                for p in glob.glob(f"{base}/{eng}/{setn}*.jsonl"):
                    for line in open(p):
                        r = json.loads(line)
                        c, _ = score_run(S[r["story"]], r)
                        T += c
                        cost += sum(x.get("costUSD") or 0 for x in r["calls"])
                        n += len(r["calls"])
                per[setn] = T
                A += T
            print(f"{eng:13} {base:11} ALL  {stats(A)} calls {n} cost ${cost:.2f}")
            for k, v in per.items():
                print(f"{'':25} {k:5} {stats(v)}")


if __name__ == "__main__":
    main()
