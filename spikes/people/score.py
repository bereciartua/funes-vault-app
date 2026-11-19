#!/usr/bin/env python3
"""Spike H scoring against each story's ground truth (who each memory is really about), not what the system could
know at each step: a `sole_known` link that turns out wrong counts as wrong. Writes results/report.md.

    python3 score.py [--set main|astra] [--verbose]

System people are aligned to story people by majority over their links (name and role). A role link is:
- right / wrong by person, tallied per basis (named, stated_unique, context: "full"; sole_known; untrusted);
- for a reference the story says can't be decided: `candidates` or a role group is right ("ambiguity kept"),
  a named person is wrong unless it's the true one (then it's tallied by basis like any other);
- for a decidable reference: `candidates` or a group (when the truth is a named person) is a miss, not wrong.
A truth person never named in the story (a role group) is matched by the group's type and label class.
Also counted: links to people a memory must not be linked to, role links where the story lists none, people the
system made that aren't people (pets, apps, the user), relation precision and recall, labels not in the text.
"""
import argparse
import json
import os
from collections import Counter, defaultdict
from pathlib import Path

from people import fold, label_class

HERE = Path(__file__).resolve().parent
FULL = {"named", "stated_unique", "context"}


def names_match(a, b):
    a, b = fold(a), fold(b)
    return a == b or a in b.split() or b in a.split() or a in b or b in a


def role_starts(m):
    """Start offsets of a memory's truth role phrases; a surface listed twice takes its occurrences in order."""
    out, after = [], {}
    for r in m["roles"]:
        i = m["text"].find(r["surface"], after.get(r["surface"], 0))
        if i < 0:
            i = m["text"].index(r["surface"])
        after[r["surface"]] = i + len(r["surface"])
        out.append(i)
    return out


def score_run(story, res):
    mems = {m["id"]: m for m in story["memories"]}
    truth_people = story["people"]
    people = {p["id"]: p for p in res["people"]}
    # truth for each link
    def truth_of(link):
        m = mems[link["memory"]]
        if link["kind"] == "role":
            for r, st in zip(m["roles"], role_starts(m)):
                if st == link["start"]:
                    return r
            return None
        for n in m["names"]:
            if names_match(n["surface"], link["surface"]):
                return n
        return None

    votes = defaultdict(Counter)
    for l in res["links"]:
        t = truth_of(l)
        if t and l["person"] and t["person"] not in ("?",):
            votes[l["person"]][t["person"]] += 1
    align = {pid: c.most_common(1)[0][0] for pid, c in votes.items()
             if not (people.get(pid, {}).get("group") and not people[pid]["name"])}
    # groups align to unnamed truth people by type/label
    for pid, p in people.items():
        if p["group"] and pid not in align:
            for tid, tp in truth_people.items():
                if tp.get("group") and tp["group"][0] == p["group"][0] and label_class(*tp["group"]) == p["group"][1]:
                    align[pid] = tid

    c = Counter()
    errors = []
    for l in res["links"]:
        m = mems[l["memory"]]
        t = truth_of(l)
        sys_person = l["person"]
        aligned = align.get(sys_person)
        is_group = bool(sys_person and people.get(sys_person, {}).get("group") and not people[sys_person]["name"])
        if l["kind"] == "role":
            if t is None:
                if sys_person and not is_group and l["basis"] not in ("candidates", "someone_else"):
                    c["role_extra_linked"] += 1
                    errors.append(f"{l['memory']}: '{l['surface']}' linked to {people[sys_person]['name']} ({l['basis']}) but the story lists no reference")
                else:
                    c["role_extra_ok"] += 1
                continue
            c["role_refs"] += 1
            tp = truth_people.get(t["person"], {})
            truth_is_group = bool(tp.get("group"))
            if l["basis"] in ("candidates", "someone_else") or (is_group and not truth_is_group):
                if not t["resolvable"]:
                    c["ambiguity_kept"] += 1
                else:
                    c["role_miss"] += 1
                    errors.append(f"{l['memory']}: '{l['surface']}' left as {l['basis']}, truth {t['person']} (decidable)")
                continue
            ok = aligned == t["person"]
            bucket = "full" if l["basis"] in FULL else l["basis"]
            c[f"{bucket}_{'right' if ok else 'wrong'}"] += 1
            if l.get("predicate"):                 # per predicate (the Gates' "≥ 20 per predicate"); not in the report
                c[f"{bucket}_{'right' if ok else 'wrong'}@{l['predicate']}"] += 1
            if t["resolvable"] and ok:             # recall against the truth (the Gates' denominator below)
                c["resolvable_right"] += 1
            if not t["resolvable"] and not ok:
                c["undecidable_guessed_wrong"] += 1
            if not ok:
                errors.append(f"{l['memory']}: '{l['surface']}' → {people.get(sys_person, {}).get('name') or sys_person} ({l['basis']}), truth {t['person']}")
        else:
            if t is None:
                if sys_person:
                    c["name_extra"] += 1
                    errors.append(f"{l['memory']}: name '{l['surface']}' linked to a person the story doesn't list")
                continue
            c["name_refs"] += 1
            if t["person"] == "?":
                ok = sys_person is None and l["basis"] == "ambiguous"
                c["name_ambiguous_kept" if ok else "name_ambiguous_guessed"] += 1
                if not ok:
                    errors.append(f"{l['memory']}: ambiguous '{l['surface']}' → {people.get(sys_person, {}).get('name')}")
                continue
            if t["person"] == "user":
                c["name_user_wrong" if sys_person else "name_user_ok"] += 1
                continue
            ok = aligned == t["person"]
            bucket = "name_" + ("full" if l["basis"] == "named" else l["basis"])
            c[f"{bucket}_{'right' if ok else 'wrong'}"] += 1
            if not ok:
                errors.append(f"{l['memory']}: name '{l['surface']}' → {people.get(sys_person, {}).get('name') or sys_person} ({l['basis']}), truth {t['person']}")
    # role references the code never produced
    linked_starts = {(l["memory"], l.get("start")) for l in res["links"] if l["kind"] == "role"}
    for m in story["memories"]:
        if m["id"] not in res["order"]:
            continue
        for r, st in zip(m["roles"], role_starts(m)):
            c["resolvable_truth"] += 1 if r["resolvable"] else 0
            if r["resolvable"]:                    # a phrase with no registry word isn't a role phrase Funes reads
                from fixture_counts import predicate_of
                c["resolvable_truth_lexicon" if predicate_of(r["surface"]) else "resolvable_outside_lexicon"] += 1
            if (m["id"], st) not in linked_starts:
                c["role_not_found"] += 1
        names_linked = [l for l in res["links"] if l["kind"] == "name" and l["memory"] == m["id"]]
        for n in m["names"]:
            if n["person"] == "user" and not any(names_match(n["surface"], l["surface"]) for l in names_linked):
                c["name_user_ok"] += 1
            if n["person"] not in ("user",) and not any(names_match(n["surface"], l["surface"]) for l in names_linked):
                c["name_not_found"] += 1
                errors.append(f"{m['id']}: name '{n['surface']}' not recorded")
        # must-not links
        for bad in m["not_linked"]:
            for l in res["links"]:
                if l["memory"] == m["id"] and align.get(l["person"]) == bad and l["basis"] not in ("candidates",):
                    c["forbidden_link"] += 1
                    errors.append(f"{m['id']}: linked to {bad}, which the story forbids ({l['basis']})")
    # people that aren't people
    for pid, p in people.items():
        if p["name"] and pid not in align:
            c["false_person"] += 1
            errors.append(f"made a person '{p['name']}' the story doesn't have")
    # relations
    truth_rel = {(f["person"], f["type"]) for m in story["memories"] for f in m["facts"]
                 if f["person"] and f["polarity"] == "positive"}
    truth_neg = {(f["person"], f["type"]) for m in story["memories"] for f in m["facts"]
                 if f["person"] and f["polarity"] == "negative"}
    sys_rel = set()
    for r in res["relations"]:
        if r["negated"]:
            continue
        key = (align.get(r["person"]), r["type"])
        sys_rel.add(key)
        if key in truth_neg:
            c["relation_denied_but_kept"] += 1
            errors.append(f"relation {key} kept though the story denies it")
        texts = " ".join(mems[e]["text"] for e in r["evidence"] if e in mems).lower()
        if r["label"] and r["label"].lower() not in texts:
            c["label_invented"] += 1
    c["relations_truth"] += len(truth_rel)
    c["relations_found"] += len(truth_rel & sys_rel)
    c["relations_system"] += len(sys_rel)
    c["relations_right"] += len(sys_rel & truth_rel)
    c["calls"] += len(res["calls"])
    c["calls_failed"] += sum(1 for x in res["calls"] if not x["ok"])
    c["ms"] += sum(x.get("ms") or 0 for x in res["calls"])
    c["prompt_tokens"] += sum(x.get("promptTokens") or 0 for x in res["calls"])
    c["output_tokens"] += sum(x.get("outputTokens") or 0 for x in res["calls"])
    return c, errors


def pct(a, b):
    return f"{a}/{b} = {100 * a / b:.0f}%" if b else "–"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="main")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    suffix = "" if a.set == "main" else f"-{a.set}"
    data = json.loads((HERE / f"fixtures/stories{suffix}.json").read_text())
    stories = {s["id"]: s for s in data["stories"]}
    lines = [f"# Spike H report ({a.set} set)", ""]
    for d in sorted(x for x in (HERE / os.environ.get("RESULTS_DIR", "results")).iterdir() if x.is_dir()):
        paths = [p for p in [d / f"{a.set}.jsonl"] + sorted(d.glob(f"{a.set}-run*.jsonl")) if p.exists()]
        if not paths:
            continue
        total, errs = Counter(), []
        runs = [json.loads(l) for p in paths for l in p.read_text().splitlines() if l.strip()]
        for res in runs:
            c, e = score_run(stories[res["story"]], res)
            total += c
            errs += [f"{res['story']}#{res['orderIndex']} r{res.get('run', 1)} {x}" for x in e]
        T = total
        full = T["full_right"] + T["full_wrong"]
        resolvable = T["role_refs"] - T["ambiguity_kept"] - T["undecidable_guessed_wrong"]
        lines += [f"## {d.name} ({len(runs)} story runs over {len(paths)} run(s))", "",
                  "| Measure | Result |", "|---|---|",
                  f"| Role links, full basis (named, stated, context) right | {pct(T['full_right'], full)} |",
                  f"| Role links, sole_known right | {pct(T['sole_known_right'], T['sole_known_right'] + T['sole_known_wrong'])} |",
                  f"| Role links, untrusted right | {pct(T['untrusted_right'], T['untrusted_right'] + T['untrusted_wrong'])} |",
                  f"| Decidable role references linked to the right person (or to the role group, for someone never named) | {pct(T['full_right'] + T['sole_known_right'] + T['untrusted_right'] + T['group_right'], resolvable)} |",
                  f"| Decidable role references left unresolved (misses) | {T['role_miss']} |",
                  f"| Undecidable references kept ambiguous | {pct(T['ambiguity_kept'], T['ambiguity_kept'] + T['undecidable_guessed_wrong'])} |",
                  f"| Name links right (named) | {pct(T['name_full_right'], T['name_full_right'] + T['name_full_wrong'])} |",
                  f"| Ambiguous names kept ambiguous | {pct(T['name_ambiguous_kept'], T['name_ambiguous_kept'] + T['name_ambiguous_guessed'])} |",
                  f"| The user's own name kept off the people list | {pct(T['name_user_ok'], T['name_user_ok'] + T['name_user_wrong'])} |",
                  f"| Links the story forbids | {T['forbidden_link']} |",
                  f"| Role links where the story has none (quotes, negations, injections) | {T['role_extra_linked']} |",
                  f"| People made that aren't people | {T['false_person']} |",
                  f"| Names not recorded | {T['name_not_found']} |",
                  f"| Relations: precision · recall | {pct(T['relations_right'], T['relations_system'])} · {pct(T['relations_found'], T['relations_truth'])} |",
                  f"| Relations kept though denied | {T['relation_denied_but_kept']} |",
                  f"| Labels not in the text | {T['label_invented']} |",
                  f"| Calls (failed) · mean seconds · tokens in/out | {T['calls']} ({T['calls_failed']}) · "
                  f"{T['ms'] / max(T['calls'], 1) / 1000:.1f} · {T['prompt_tokens']:,}/{T['output_tokens']:,} |", ""]
        if errs:
            lines += ["Errors:", ""] + [f"- {e}" for e in (errs if a.verbose else errs[:40])] + [""]
    (HERE / os.environ.get("RESULTS_DIR", "results") / "report.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
