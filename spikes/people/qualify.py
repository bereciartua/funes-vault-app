#!/usr/bin/env python3
"""Phase 13a.2's Gates: from live harness runs to qualification records (memory processing §11.10), failing closed.

    python3 qualify.py scores <harness-out> --model claude-code/claude-haiku-5-5 [--port-fidelity pf.json] --out scores.json
        Every `<harness-out>/*-gates-r<N>/` directory of that model is a read (all of them are used; none can be picked).
        Computes every pass-table measure per read from the runs' lines (score.py, score_facts.py and the Swift dumps),
        and which records the measures allow. Writes scores.json with the sha256 of every input.
    python3 qualify.py records scores.json [--write]
        The records the scores allow, after the run checks (below). With --write: copies the evidence to
        results-13a2/gates/<model>/ and adds the records to Resources/facts-qualification.json. Writes nothing if any check
        fails.
    python3 qualify.py answer-scores --engine haiku --model claude-code/claude-haiku-5-5 --replay <dir> --out <scores-13d.json>
            [--facts-model claude-code/claude-haiku-5-5]
        Phase 13d's answer gates (score_13d.py) from the live records in results-13d/, with a replay of both gates from the
        response cache at one clean commit (FactsAnswerLiveTests, `dry=1;out=<dir>`): every request answered from the
        cache, so that commit's code sends exactly what the model answered, and the replay's records equal the live ones
        (bar each fixture vault's random ids). Copies the replay to results-13d/gates/<model>/ and writes the digests.
        `--model` is the answer model; `--facts-model` the Facts engine whose read the fixtures carry (the r3 Haiku
        read) and whose persons record the attributes records rest on.
    python3 qualify.py answer-records <scores-13d.json> [--write]
        The attributes records the answer gates allow (the person pool, unscoped and `sole_known`), on the facts key of the
        model's persons record, for that answer model at the replay's answer prompt version. `sole_known` also needs
        13a.2's sole_known measure. With --write: adds them to Resources/facts-qualification.json.
    python3 qualify.py verify
        For every shipped record: its evidence exists with the digests scores.json gives, the measures recomputed from the
        evidence lines equal scores.json's, and they pass. scripts/test.sh runs it. The Swift test
        FactsQualificationTests checks each record against the code that runs now and against its manifests.

Gates (one record each; §11.10's pass table):
- persons:   the person predicates, {recorded, linked}, people group. main + astra + mixed + persons, every read: full-basis
             links right ≥ 98% pooled with ≥ 20 full-basis links per person predicate, recall of resolvable references
             ≥ 90% (against every resolvable truth reference, undetected ones included; those whose phrase has no
             registry word are also reported apart); the same two on mixed alone.
- client:    client, {recorded}, work group. mixed + work13, every read: 0 clients under works at, 0 vendors as clients;
             true clients and vendors present (≥ 3 each) and at least one client recorded as a client.
- works_at:  works at, {recorded, linked}, work group. mixed + work13, every read: organization mentions under works at
             right ≥ 98% (≥ 20 of them), 0 clients or vendors as employers; mixed alone ≥ 98% too.
- Measured, no record: the timeline (works at, {timeline}: work13, and mixed alone, every read: 0 wrong facts, ≤ 1 wrong
             date, decidable questions right (gap told counted apart, both count) ≥ 90% with ≥ 30 decidable on work13,
             0 wrong answers, 0 negatives triggered (≥ 5 negatives), 0 succession from untrusted text or across slots).
             The author's decision in 13a.2's Gates step: works at ships linked only, the timeline and bridges stay
             unqualified, and timeline coverage is later work. `sole_known` ≥ 90% pooled (its record needs the unscoped
             attributes record, 13d's); the canary (its registry isn't the bundled one, so its record couldn't match).
Every record also needs port fidelity (port_fidelity.py's report, passing) and the privacy payload tests (the same CI).

Run checks (every run a record rests on): a live run; one commit, clean; the same engine, the group's prompt version and
registry version (the bundled registry); the provider named the exact model id on every response; every story and order
of the current fixture played once (no `only=`, no `orders=natural`), the fixture's digest the current file's; the
record's call group played; unsettled 0; nothing above the cloud limit in any payload; ≥ 2 reads, each run id distinct.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

import score

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
REGISTRY = REPO / "Packages/FunesCore/Sources/FunesCore/Resources/facts-registry.json"
RECORDS = REPO / "Packages/FunesCore/Sources/FunesCore/Resources/facts-qualification.json"
EVIDENCE = HERE / "results-13a2" / "gates"
WAIVERS = HERE / "results-13e1" / "waivers.json"


def waived(gate, target, registry_version=None):
    """The author's waiver of one target of a gate (13e.1), or None. It holds only for the registry version it names
    (a later grammar needs the author again), when one is given."""
    if not WAIVERS.exists():
        return None
    w = next((w for w in json.loads(WAIVERS.read_text())["waivers"] if w["gate"] == gate and w["target"] == target), None)
    # Bound to one registry version: none named, or another, waives nothing.
    if not w or not w.get("registry_version") or w["registry_version"] != registry_version:
        return None
    return w

SETS = {"persons": ["main", "astra", "mixed", "persons"], "client": ["mixed", "work13"], "works_at": ["mixed", "work13"],
        "timeline": ["work13", "mixed"], "sole_known": ["main", "astra", "mixed", "persons"], "canary": ["canary13"]}
THRESHOLDS = {"full": 0.98, "per_predicate": 20, "recall": 0.90, "works_at": 0.98, "works_at_units": 20,
              "decidable": 0.90, "decidable_min": 30, "wrong_dates": 1, "negatives_min": 5, "clients_min": 3,
              "vendors_min": 3, "sole_known": 0.90, "reads": 2}


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def fixture_path(s):
    if s == "canary13":
        return HERE / "fixtures/canary-13a2/stories.json"
    return HERE / "fixtures" / ("stories.json" if s == "main" else f"stories-{s}.json")


def registry():
    return json.loads(REGISTRY.read_text())


def person_predicates(reg):
    return [p["id"] for p in reg["predicates"] if p.get("object_kind") == "person"]


def group_of(reg, pred):
    return next(p["call_group"] for p in reg["predicates"] if p["id"] == pred)


# MARK: measures -----------------------------------------------------------------------------------------------------

def load_lines(p):
    return [json.loads(l) for l in Path(p).read_text().splitlines() if l.strip()]


def people_measures(lines, stories):
    T = Counter()
    for r in lines:
        T += score.score_run(stories[r["story"]], r)[0]
    per_pred = {k.split("@", 1)[1]: v for k, v in T.items() if k.startswith("full_right@")}
    for k, v in T.items():
        if k.startswith("full_wrong@"):
            per_pred.setdefault(k.split("@", 1)[1], 0)
    full_by_pred = {p: T.get(f"full_right@{p}", 0) + T.get(f"full_wrong@{p}", 0) for p in per_pred}
    return {"full_right": T["full_right"], "full_wrong": T["full_wrong"], "full_by_predicate": full_by_pred,
            "recall_right": T["resolvable_right"], "recall_truth": T["resolvable_truth"],
            "outside_lexicon": T["resolvable_outside_lexicon"],
            "sole_known_right": T["sole_known_right"], "sole_known_wrong": T["sole_known_wrong"],
            "forbidden": T["forbidden_link"]}


def org_measures(lines, stories, reg):
    """Organizations: works-at mentions against the truth, clients and vendors, per play."""
    import facts as F
    from run_facts import load_state
    emp = next(p["id"] for p in reg["predicates"] if "timeline" in p.get("uses", []) and p.get("object_kind") != "person")
    client = next((p["id"] for p in reg["predicates"] if p["id"] != emp and p.get("object_kind") != "person"
                   and "linked" not in p.get("uses", [])), None)
    m = Counter()
    for r in lines:
        st = stories[r["story"]]
        state = load_state(r["state"])
        orgs = {t["org"]: t for t in st.get("timeline", [])}
        mention_rel = {(mm["id"], o["org"]): o["relation"] for mm in st["memories"] for o in mm.get("organizations", [])}
        stint_mems = defaultdict(set)
        for t in st.get("timeline", []):
            if t["kind"] in ("employee", "self_employed"):
                stint_mems[t["org"]] |= set(t.get("memories", []))
        match = {o: set(F.entity_matches(state, emp, o)) for o in orgs}
        units = {}
        for f in r["state"]["facts"]:
            if f["type"] != emp or f.get("negated"):
                continue
            ent = f["entity"]
            truth = [o for o, ids in match.items() if ent in ids]
            for a in f.get("assertions", []):
                ok = any(a["memory"] in stint_mems.get(o, ()) or mention_rel.get((a["memory"], o)) in ("employer", "self_employed")
                         for o in truth)
                # One unit per memory and organization in a play. The gate is full-basis links (the acceptance table):
                # an untrusted memory's link is reported apart, as score.py counts people's (13e.1).
                key = (a["memory"], ent, a.get("trust") == "untrusted")
                units[key] = units.get(key, True) and ok
        for (_, _, untrusted), ok in units.items():
            m[("works_at_untrusted_" if untrusted else "works_at_") + ("right" if ok else "wrong")] += 1
        for o, t in orgs.items():
            hit_emp = bool(match[o])
            hit_client = bool(client and F.entity_matches(state, client, o))
            if t["kind"] == "client":
                m["clients"] += 1
                m["clients_as_employer"] += hit_emp
                m["clients_recorded"] += hit_client
            elif t["kind"] == "vendor":
                m["vendors"] += 1
                m["vendors_as_employer"] += hit_emp
                m["vendors_as_client"] += hit_client
    return dict(m)


def _range(s):
    """A truth date ('2019', '2019-03', '2019-03-14', '') as ordinal days (lo, hi), or None."""
    from datetime import date
    if not s:
        return None
    p = [int(x) for x in s.split("-")]
    if len(p) == 1:
        return date(p[0], 1, 1).toordinal(), date(p[0], 12, 31).toordinal()
    if len(p) == 2:
        nxt = date(p[0] + (p[1] == 12), p[1] % 12 + 1, 1).toordinal()
        return date(p[0], p[1], 1).toordinal(), nxt - 1
    d = date(*p).toordinal()
    return d, d


def timeline_measures(lines, stories, reg, person=False):
    """The timeline gate, from the Swift dumps: facts and dates against the truth stints, Swift's own judgments, and the
    succession checks. Wrong facts and dates are counted per distinct (story, item): wrong in any order is wrong.
    Questions are counted from the truth: a play with no judgment for one counts it as a miss (a negative as
    triggered), and a line without its dumps counts as malformed. `person`: the canary's person timeline predicate
    (its own registry), whose truth stints are the partner episodes.

    Untrusted-only facts and episodes (only an agent's or other untrusted text states them; Your Timeline marks them
    "from text you didn't write") are judged apart and reported, not gated (the author's amendment, 13e.1), except an
    untrusted fact the story's own labels deny ("I never worked at X" in a trusted memory): that stays a wrong fact.
    Answers are judged whatever they rest on. Each trusted episode is assigned one to one to a truth stint of its
    organization: one sharing its memories and overlapping its dates first, then one overlapping its dates, then one
    sharing its memories. An episode left without a stint of its own (a duplicate, or one organization read as two
    entities) is a wrong fact."""
    import facts as F
    from run_facts import load_state
    emp = next(p["id"] for p in reg["predicates"] if "timeline" in p.get("uses", [])
               and (p.get("object_kind") == "person") == person)
    kinds = ("partner",) if person else ("employee", "self_employed")
    m = Counter()
    wrong_facts, wrong_dates, wrong_answers, triggered = set(), set(), set(), set()
    untrusted_facts, untrusted_dates = set(), set()
    for r in lines:
        st = stories[r["story"]]
        state = load_state(r["state"])
        stints = [t for t in st.get("timeline", []) if t["kind"] in kinds]
        if "episodes" not in r["state"] or "succession" not in r["state"] or "swift_judged" not in r:
            m["malformed"] += 1
        names = {e["id"]: e for e in r["state"]["entities"]}
        # The story's own trusted denials: a negative job label in a memory that isn't an agent's.
        denied = set()
        for mm in st["memories"]:
            if mm.get("source") == "agent":
                continue
            for j in mm.get("jobs", []):
                if j.get("polarity") == "negative" and j.get("org"):
                    denied |= set(F.entity_matches(state, emp, j["org"]))
        for f in r["state"]["facts"]:
            if f["type"] != emp or f.get("negated"):
                continue
            if any(f["entity"] in F.entity_matches(state, emp, t["org"]) for t in stints):
                continue
            item = (r["story"], (names.get(f["entity"]) or {}).get("name"))
            only_untrusted = bool(f["evidence"]) and all(x[1] == "untrusted" for x in f["evidence"])
            (untrusted_facts if only_untrusted and f["entity"] not in denied else wrong_facts).add(item)

        def overlaps(e, t):
            a, b = _range(t["start"]), _range(t["end"])
            lo = a[0] if a else -10**9
            hi = b[1] if b else 10**9
            es = e["start"][0] if e["start"] else -10**9
            ee = e["end"][1] if e["end"] else 10**9
            return es <= hi and lo <= ee

        eps = [e for e in r["state"].get("episodes", []) if e["predicate"] == emp]
        # A stated rename is one entity on the timeline: its episodes carry the group's stand-in (13e.1). Truth is the
        # story's, not the system's merge: a group's episode fits a stint only if every member's name is that stint's
        # organization by a loose rule (one name inside the other), so a wrong merge leaves it unassigned, a wrong fact.
        group_of = {x: set(g) for g in r["state"].get("timeline_groups", []) for x in g}

        def norm(n):
            n = F.fold(n or "")
            for suf in (" inc.", " inc", " ltd.", " ltd", " llc", " gmbh", " s.a.", " sa", " s.l.", " sl"):
                if n.endswith(suf):
                    n = n[: -len(suf)]
            return n.strip()

        def loose(ent, org):
            a = [norm(x) for x in ((names.get(ent) or {}).get("aliases") or [(names.get(ent) or {}).get("name")])]
            o = norm(org)
            return any(x and (x in o or o in x) for x in a)
        assign = {}
        for trust_pass in (True, False):
            group = [e for e in eps if bool(e.get("trusted", True)) == trust_pass]
            taken = set()
            def options(e):
                ids = group_of.get(e["entity"], {e["entity"]})
                mine = [i for i, t in enumerate(stints) if ids & set(F.entity_matches(state, emp, t["org"]))
                        and (len(ids) == 1 or all(loose(x, t["org"]) for x in ids))]
                mems = set(e.get("memories", []))
                tiers = ([i for i in mine if mems & set(stints[i].get("memories", [])) and overlaps(e, stints[i])],
                         [i for i in mine if overlaps(e, stints[i])],
                         # by memories alone only for an undated episode: a dated one overlapping no stint is wrong
                         [i for i in mine if mems & set(stints[i].get("memories", []))] if not (e["start"] or e["end"]) else [])
                return mine, tiers
            # Fewest options first, so an episode with one fitting stint isn't crowded out.
            for e in sorted(group, key=lambda e: sum(len(x) for x in options(e)[1])):
                mine, tiers = options(e)
                if not mine:
                    ids = group_of.get(e["entity"], {e["entity"]})
                    if len(ids) > 1 and any(ids & set(F.entity_matches(state, emp, t["org"])) for t in stints):
                        # a merge the story doesn't make: its episode is no stint's
                        (wrong_facts if trust_pass else untrusted_facts).add((r["story"], (names.get(e["entity"]) or {}).get("name"), "merged"))
                    continue
                pick = next((i for tier in tiers for i in tier if i not in taken), None)
                if pick is None:
                    item = (r["story"], (names.get(e["entity"]) or {}).get("name"), "unassigned")
                    (wrong_facts if trust_pass else untrusted_facts).add(item)
                    continue
                if trust_pass:
                    taken.add(pick)
                assign[id(e)] = pick
        for e in eps:
            if id(e) not in assign:
                continue
            t = stints[assign[id(e)]]
            sink = wrong_dates if e.get("trusted", True) else untrusted_dates
            for bound, truth in (("start", t["start"]), ("end", t["end"])):
                got, want = e[bound], _range(truth)
                if got is None or got[2] == "handover":
                    continue                                   # unknown isn't wrong; a hand-over start is for role resolution only
                if want is None:
                    if bound == "end":                          # a current stint given an end
                        sink.add((r["story"], t["org"], t["start"], bound))
                    continue
                if got[1] < want[0] or got[0] > want[1]:
                    sink.add((r["story"], t["org"], t["start"], bound))
        answers = r.get("swift_answers") or {}
        for q in st.get("queries", []):
            neg = q["kind"] in ("negative", "role_in_stint")
            o = (r.get("swift_judged") or {}).get(q["id"]) or ("triggered" if neg else "miss")
            if o == "told_gap" and not q.get("answer_org") and (answers.get(q["id"]) or {}).get("entities"):
                o = "wrong"                                # a gap answer naming someone on a question that can't be decided
            m[o] += 1
            if o == "wrong":
                wrong_answers.add((r["story"], q["id"]))
            if o == "triggered":
                triggered.add((r["story"], q["id"]))
        s = r["state"].get("succession", {})
        m["succession_untrusted"] += len(s.get("from_untrusted", []))
        m["succession_cross_slot"] += len(s.get("across_slots", []))
        m["succession_unexplained"] += len(s.get("without_successor", []))
        m["inferred_ends"] += sum(1 for e in r["state"].get("episodes", []) if e.get("inferred_end"))
    decidable = sum(1 for r in lines for q in stories[r["story"]].get("queries", [])
                    if q.get("answer_org") and q["kind"] not in ("negative", "role_in_stint"))
    return {"right": m["right"], "right_gap": m["right_gap"], "decidable": decidable,
            "negatives": m["triggered"] + m["quiet"], "wrong_answers": len(wrong_answers), "triggered": len(triggered),
            "wrong_facts": len(wrong_facts), "wrong_dates": len(wrong_dates),
            "untrusted_wrong_facts": len(untrusted_facts), "untrusted_wrong_dates": len(untrusted_dates),
            "succession_untrusted": m["succession_untrusted"], "succession_cross_slot": m["succession_cross_slot"],
            "succession_unexplained": m["succession_unexplained"], "inferred_ends": m["inferred_ends"], "malformed": m["malformed"],
            "details": {"wrong_facts": sorted(map(str, wrong_facts)), "wrong_dates": sorted(map(str, wrong_dates)),
                        "untrusted_wrong_facts": sorted(map(str, untrusted_facts)),
                        "untrusted_wrong_dates": sorted(map(str, untrusted_dates)),
                        "wrong_answers": sorted(map(str, wrong_answers)), "triggered": sorted(map(str, triggered))}}


def measure_read(read_dir, reg, sets):
    """Every gate's measures for one read: {set: {...}} per kind."""
    out = {}
    for s in sets:
        p = Path(read_dir) / f"{s}.jsonl"
        if not p.exists():
            continue
        stories = {x["id"]: x for x in json.loads(fixture_path(s).read_text())["stories"]}
        lines = load_lines(p)
        want = Counter((x["id"], i) for x in stories.values() for i in range(1 + len(x.get("orders", []))))
        got = Counter((r["story"], r["orderIndex"]) for r in lines)
        out[s] = {"plays": {"expected": sum(want.values()), "missing": sum((want - got).values()), "extra": sum((got - want).values())},
                  "people": people_measures(lines, stories)}
        if s == "canary13":
            creg = json.loads((HERE / "fixtures/canary-13a2/registry.json").read_text())
            out[s]["timeline"] = timeline_measures(lines, stories, creg, person=True)
        elif any(x.get("timeline") for x in stories.values()):
            out[s]["orgs"] = org_measures(lines, stories, reg)
            out[s]["timeline"] = timeline_measures(lines, stories, reg)
    return out


# MARK: thresholds ---------------------------------------------------------------------------------------------------

def ratio(a, b):
    return a / b if b else 0.0


def judge_gate(gate, reads, reg, registry_version=None):
    """Problems with a gate's measures over its reads ([] = it passes). `reads`: {read: {set: measures}}."""
    t, probs = THRESHOLDS, []
    if len(reads) < t["reads"]:
        probs.append(f"{len(reads)} read(s), {t['reads']} needed")
    for rd, sets in sorted(reads.items()):
        missing = [s for s in SETS[gate] if s not in sets]
        if missing:
            probs.append(f"{rd}: no {', '.join(missing)}")
            continue
        for s in SETS[gate]:
            pl = sets[s].get("plays", {})
            if pl.get("missing") or pl.get("extra") or not pl.get("expected"):
                probs.append(f"{rd} {s}: plays {pl} against the fixture")
            if (sets[s].get("timeline") or {}).get("malformed"):
                probs.append(f"{rd} {s}: {sets[s]['timeline']['malformed']} lines without their dumps")
        if gate in ("persons", "sole_known"):
            pool = Counter()
            per_pred = Counter()
            for s in SETS[gate]:
                pm = sets[s]["people"]
                pool.update({k: pm[k] for k in ("full_right", "full_wrong", "recall_right", "recall_truth", "sole_known_right", "sole_known_wrong")})
                per_pred.update(pm["full_by_predicate"])
            if gate == "sole_known":
                if ratio(pool["sole_known_right"], pool["sole_known_right"] + pool["sole_known_wrong"]) < t["sole_known"]:
                    probs.append(f"{rd}: sole_known {pool['sole_known_right']}/{pool['sole_known_right'] + pool['sole_known_wrong']}")
                continue
            if ratio(pool["full_right"], pool["full_right"] + pool["full_wrong"]) < t["full"]:
                probs.append(f"{rd}: full basis {pool['full_right']}/{pool['full_right'] + pool['full_wrong']}")
            for p in person_predicates(reg):
                if per_pred.get(p, 0) < t["per_predicate"]:
                    probs.append(f"{rd}: {p} has {per_pred.get(p, 0)} full-basis links")
            if ratio(pool["recall_right"], pool["recall_truth"]) < t["recall"]:
                probs.append(f"{rd}: recall {pool['recall_right']}/{pool['recall_truth']}")
            mx = sets["mixed"]["people"]
            if ratio(mx["full_right"], mx["full_right"] + mx["full_wrong"]) < t["full"]:
                probs.append(f"{rd}: mixed full basis {mx['full_right']}/{mx['full_right'] + mx['full_wrong']}")
            if ratio(mx["recall_right"], mx["recall_truth"]) < t["recall"]:
                probs.append(f"{rd}: mixed recall {mx['recall_right']}/{mx['recall_truth']}")
        elif gate in ("client", "works_at"):
            o = Counter()
            for s in SETS[gate]:
                o.update(sets[s].get("orgs", {}))
            if o["clients_as_employer"] or o["vendors_as_employer"]:
                probs.append(f"{rd}: {o['clients_as_employer']} clients, {o['vendors_as_employer']} vendors as employers")
            if gate == "client":
                if o["vendors_as_client"]:
                    probs.append(f"{rd}: {o['vendors_as_client']} vendors as clients")
                if o["clients"] < t["clients_min"] or o["vendors"] < t["vendors_min"]:
                    probs.append(f"{rd}: {o['clients']} clients, {o['vendors']} vendors in the truth (too few to measure)")
                if not o["clients_recorded"]:
                    probs.append(f"{rd}: no client recorded as a client")
            else:
                units = o["works_at_right"] + o["works_at_wrong"]
                if units < t["works_at_units"] or ratio(o["works_at_right"], units) < t["works_at"]:
                    probs.append(f"{rd}: works at {o['works_at_right']}/{units}")
                mo = sets["mixed"].get("orgs", {})
                mu = mo.get("works_at_right", 0) + mo.get("works_at_wrong", 0)
                if ratio(mo.get("works_at_right", 0), mu) < t["works_at"]:
                    probs.append(f"{rd}: mixed works at {mo.get('works_at_right', 0)}/{mu}")
        elif gate in ("timeline", "canary"):
            for s in SETS[gate]:
                tm = sets[s].get("timeline")
                if not tm:
                    probs.append(f"{rd}: {s} has no timeline questions")
                    continue
                at = f"{rd} {s}"
                if tm["wrong_facts"]:
                    probs.append(f"{at}: {tm['wrong_facts']} wrong facts")
                if tm["wrong_dates"] > t["wrong_dates"]:
                    probs.append(f"{at}: {tm['wrong_dates']} wrong dates")
                cov = ratio(tm["right"] + tm["right_gap"], tm["decidable"])
                w = gate == "timeline" and waived("timeline", "decidable_coverage", registry_version)
                # A waived target keeps its floor, never under 40%: a run that answers almost nothing still fails.
                if cov < (max(0.40, w.get("floor", t["decidable"])) if w else t["decidable"]):
                    probs.append(f"{at}: decidable right {tm['right']} + {tm['right_gap']} with a gap told, of {tm['decidable']}")
                if tm["wrong_answers"] or tm["triggered"]:
                    probs.append(f"{at}: {tm['wrong_answers']} wrong answers, {tm['triggered']} negatives triggered")
                if tm["succession_untrusted"] or tm["succession_cross_slot"] or tm["succession_unexplained"]:
                    probs.append(f"{at}: succession from untrusted text {tm['succession_untrusted']}, across slots "
                                 f"{tm['succession_cross_slot']}, without a successor {tm['succession_unexplained']}")
                if s != "mixed" and (tm["decidable"] < t["decidable_min"] or tm["negatives"] < t["negatives_min"]):
                    probs.append(f"{at}: {tm['decidable']} decidable questions, {tm['negatives']} negatives (too few to measure)")
    return probs


# MARK: runs ---------------------------------------------------------------------------------------------------------

def run_problems(manifests, model, group, record=None, dirs=None):
    """Why these runs can't carry a record ([] = they can). `record`: the key every run must have; `dirs`: each
    manifest's directory, to check the output it describes is the one beside it."""
    probs = []
    commits = {m["commit"] for m in manifests}
    if len(commits) != 1 or any(c.endswith("+dirty") or not c for c in commits):
        probs.append(f"commits {sorted(commits)}: one clean commit needed")
    ids = [m.get("run_id") for m in manifests]
    if len(set(ids)) != len(ids) or None in ids:
        probs.append("run ids missing or repeated")
    for k in ("engine",):
        if len({json.dumps(m[k], sort_keys=True) for m in manifests}) != 1:
            probs.append(f"runs disagree on {k}")
    if len({m["prompt_versions"].get(group) for m in manifests}) != 1:
        probs.append(f"runs disagree on the {group} prompt version")
    if len({m["registry_version"] for m in manifests}) != 1:
        probs.append("runs disagree on the registry version")
    model_id = model.split("/", 1)[1]
    for m in manifests:
        at = f"{m.get('label')}/{m.get('set')}"
        if m.get("mode") != "live":
            probs.append(f"{at}: not a live run ({m.get('mode')})")
        if m["engine"]["model"] != model:
            probs.append(f"{at}: engine {m['engine']['model']}")
        if m.get("registry_file") != "bundled":
            probs.append(f"{at}: registry {m.get('registry_file')}")
        if m.get("models_reported") != [model_id]:
            probs.append(f"{at}: the provider reported {m.get('models_reported')}")
        if m.get("responses_without_model", 1) != 0 or not m.get("responses"):
            probs.append(f"{at}: {m.get('responses_without_model')} responses without a model id")
        opts = m.get("options", {})
        if opts.get("only") or opts.get("orders") == "natural":
            probs.append(f"{at}: a partial run ({opts})")
        if m.get("plays") != m.get("plays_expected") or len(set(m.get("plays_list", []))) != m.get("plays_expected"):
            probs.append(f"{at}: {m.get('plays')} plays of {m.get('plays_expected')}")
        if m.get("fixture_sha256") != sha(fixture_path(m["set"])):
            probs.append(f"{at}: the fixture changed since the run")
        if group not in m.get("groups", []):                 # the record's call group was read (Opus reads people only)
            probs.append(f"{at}: groups {m.get('groups')}")
        if m.get("unsettled", 1) or m.get("above_limit_in_payload", 1):
            probs.append(f"{at}: unsettled {m.get('unsettled')}, above the limit {m.get('above_limit_in_payload')}")
        if m.get("limit") not in ("low", "internal", "sensitive"):
            probs.append(f"{at}: cloud limit {m.get('limit')} (a gate run uses the app's: low, internal or sensitive)")
        if record is not None:
            e = m["engine"]
            if (e["model"], e["adapter"], e["batching"], m["prompt_versions"].get(record["callGroup"]), m["registry_version"]) != (
                    record["model"], record["adapter"], record["batching"], record["promptVersion"], record["registryVersion"]):
                probs.append(f"{at}: not the record's key")
    for i, m in enumerate(manifests):
        if dirs is not None:
            f = Path(dirs[i]) / f"{m['set']}.jsonl"
            if not f.exists() or m.get("lines_sha256") != sha(f):
                probs.append(f"{m.get('label')}/{m.get('set')}: the lines aren't the ones the run wrote")
    return probs


def reads_of(out_dir, model):
    """{read: dir} for every gate run of the model (`*-gates-r<N>`): all of them, r1 to rN with none missing or twice."""
    model_id = model.split("/", 1)[1]
    found = {}
    for d in sorted(Path(out_dir).iterdir()):
        mm = re.search(r"-gates-(r\d+)$", d.name)
        if d.is_dir() and mm and d.name.startswith("swift-") and d.name[:mm.start()].endswith(model_id):
            if mm.group(1) in found:
                raise SystemExit(f"qualify.py: two directories for read {mm.group(1)}")
            found[mm.group(1)] = d
    n = len(found)
    if sorted(found) != sorted(f"r{i}" for i in range(1, n + 1)):
        raise SystemExit(f"qualify.py: reads {sorted(found)} aren't r1 to r{n}")
    return found


def blockers():
    """What stops any record now, whatever the scores: the code freeze broken, or an open privacy finding (a test
    recorded as a known issue in the privacy gate)."""
    out = []
    import subprocess
    f = subprocess.run(["sh", str(REPO / "scripts/facts_freeze.sh"), "check"], capture_output=True, text=True)
    if f.returncode != 0:
        out.append("the code changed since the freeze (scripts/facts_freeze.sh check)")
    if "withKnownIssue" in (REPO / "Packages/FunesCore/Tests/FunesCoreTests/FactsPrivacyGateTests.swift").read_text():
        out.append("an open privacy finding (FactsPrivacyGateTests records a known issue)")
    return out


STANDARD_PAIRS = ["main recorded", "astra recorded", "mixed recorded", "main gold", "astra gold", "mixed gold", "persons gold", "h2 convert"]


def pf_problems(pf, commit):
    """Port fidelity's report: passing, complete, and computed at the runs' commit."""
    if not pf:
        return ["port fidelity: no report"]
    out = []
    if not pf.get("pass"):
        out.append(f"port fidelity: failing ({len(pf.get('problems', []))} problem(s))")
    if pf.get("commit") != commit:
        out.append(f"port fidelity: computed at {pf.get('commit')}, the runs at {commit}")
    pairs = {f"{x['set']} {x['mode']}": x for x in pf.get("pairs", [])}
    for name in STANDARD_PAIRS:
        x = pairs.get(name)
        if x is None or x.get("plays") != x.get("expected_plays"):
            out.append(f"port fidelity: {name} missing or incomplete")
    return out


# The timeline is measured, not recorded, in 13a.2 (the author's decision: works at ships linked only).
RECORD_SHAPE = {"persons": ("people", None, ["recorded", "linked"]), "client": ("work", "client", ["recorded"]),
                "works_at": ("work", "works_at", ["recorded", "linked"]), "timeline": ("work", "works_at", ["timeline"])}


def cmd_scores(a):
    reg = registry()
    reads = reads_of(a.harness_out, a.model)
    if not reads:
        raise SystemExit(f"qualify.py: no '*-gates-rN' runs of {a.model} in {a.harness_out}")
    all_sets = sorted({s for v in SETS.values() for s in v})
    measures = {rd: measure_read(d, reg, all_sets) for rd, d in reads.items()}
    inputs, manifests = {}, {}
    for rd, d in reads.items():
        for f in sorted(d.glob("*.jsonl")) + sorted(d.glob("*-manifest.json")):
            inputs[str(f.relative_to(d.parent))] = sha(f)
        manifests[rd] = {f.name[:-len("-manifest.json")]: json.loads(f.read_text()) for f in d.glob("*-manifest.json")}
    pf = json.loads(Path(a.port_fidelity).read_text()) if a.port_fidelity else None
    block = blockers()
    gates = {}
    versions = {m.get("registry_version") for ms in manifests.values() for m in ms.values()}
    regv = versions.pop() if len(versions) == 1 else None
    for gate in SETS:
        probs = judge_gate(gate, {rd: measures[rd] for rd in reads}, reg, regv)
        rec = None
        if gate in RECORD_SHAPE:
            group = RECORD_SHAPE[gate][0]
            pairs = [(manifests[rd].get(s), reads[rd], rd, s) for rd in reads for s in SETS[gate]]
            probs += [f"{rd} {s}: no manifest" for m, _, rd, s in pairs if m is None]
            ms = [(m, d) for m, d, _, _ in pairs if m is not None]
            probs += run_problems([m for m, _ in ms], a.model, group, dirs=[d for _, d in ms]) if ms else ["no manifests"]
            probs += pf_problems(pf, ms[0][0]["commit"] if ms else None) + block
            rec = not probs
        gates[gate] = {"sets": SETS[gate], "problems": probs, "record": rec}
        if gate == "timeline" and waived("timeline", "decidable_coverage", regv):
            gates[gate]["waived"] = {"target": "decidable_coverage", "registry_version": regv}
    out = {"format": "funes.facts-gates.v1", "model": a.model, "reads": sorted(reads), "thresholds": THRESHOLDS,
           "measures": measures, "gates": gates, "inputs": inputs,
           "port_fidelity": {"pass": bool(pf and pf.get("pass")), "sha256": sha(a.port_fidelity) if a.port_fidelity else None}}
    Path(a.out).write_text(json.dumps(out, indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    for g, v in gates.items():
        state = "record" if v["record"] else ("measured" if v["record"] is None else "NO RECORD")
        print(f"{g}: {state}" + "".join(f"\n  - {p}" for p in v["problems"]))


def coverage_note(gate, sc):
    """For a timeline record with its coverage target waived: the coverage measured, per read and set."""
    if gate != "timeline" or not sc["gates"]["timeline"].get("waived"):
        return ""
    parts = [f"{rd} {s} {m[s]['timeline']['right'] + m[s]['timeline']['right_gap']}/{m[s]['timeline']['decidable']}"
             for rd, m in sorted(sc["measures"].items()) for s in SETS["timeline"]]
    return "; decidable coverage waived by the author (13e.1), measured " + ", ".join(parts)


def cmd_records(a):
    sc = json.loads(Path(a.scores).read_text())
    reg = registry()
    model = sc["model"]
    if blockers():
        raise SystemExit("qualify.py: " + "; ".join(blockers()))
    records = []
    out_dir = Path(a.harness_out or Path(a.scores).parent)
    for gate, (group, pred, uses) in RECORD_SHAPE.items():
        v = sc["gates"][gate]
        if not v["record"] or v["problems"]:
            print(f"{gate}: no record ({len(v['problems'])} problem(s))")
            continue
        own = [json.loads((out_dir / p).read_text()) for p in sc["inputs"]
               if p.endswith("-manifest.json") and Path(p).name[:-len("-manifest.json")] in v["sets"]]
        keys = {(m["engine"]["adapter"], m["engine"]["batching"], m["prompt_versions"][group], m["registry_version"]) for m in own}
        if len(keys) != 1:
            print(f"{gate}: no record (its runs disagree on the key)")
            continue
        m0 = own[0]
        preds = person_predicates(reg) if pred is None else [pred]
        evidence = [f"spikes/people/results-13a2/gates/{model.replace('/', '_')}/{p}" for p in sc["inputs"]
                    if Path(p).name.split(".")[0].replace("-manifest", "") in v["sets"] and not p.endswith("-summary.txt")]
        evidence += [f"spikes/people/results-13a2/gates/{model.replace('/', '_')}/scores.json",
                     f"spikes/people/results-13a2/gates/{model.replace('/', '_')}/port-fidelity.json"]
        records.append({"predicates": preds, "uses": uses, "basis": "", "callGroup": group, "model": model,
                        "adapter": m0["engine"]["adapter"], "batching": m0["engine"]["batching"],
                        "promptVersion": m0["prompt_versions"][group], "registryVersion": m0["registry_version"],
                        "gate": f"13a.2 {gate}: " + ", ".join(SETS[gate]) + f", reads {', '.join(sc['reads'])}" + coverage_note(gate, sc),
                        "evidence": sorted(evidence), "recordedAt": m0["date"][:10]})
    print(json.dumps(records, indent=1))
    if a.write and records:
        dest = EVIDENCE / model.replace("/", "_")
        dest.mkdir(parents=True, exist_ok=True)
        src = Path(a.harness_out or Path(a.scores).parent)
        for p in sc["inputs"]:
            (dest / p).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src / p, dest / p)
        shutil.copy(a.scores, dest / "scores.json")
        shutil.copy(a.port_fidelity, dest / "port-fidelity.json")
        f = json.loads(RECORDS.read_text())
        f["records"] = [r for r in f["records"] if r["model"] != model] + records
        RECORDS.write_text(json.dumps(f, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {len(records)} record(s) and the evidence in {dest}")


def verify_record(r, reg):
    """Why a shipped record's evidence doesn't hold up ([] = it does)."""
    probs = []
    ev = [REPO / e for e in r["evidence"]]
    missing = [str(e) for e in ev if not e.exists()]
    if missing:
        return [f"missing {m}" for m in missing]
    scores = next((e for e in ev if e.name == "scores.json"), None)
    if scores is None:
        return ["no scores.json in the evidence"]
    sc = json.loads(scores.read_text())
    base = scores.parent
    for p, digest in sc["inputs"].items():
        if not (base / p).exists():
            probs.append(f"{p}: missing")
        elif sha(base / p) != digest:
            probs.append(f"{p}: digest differs from scores.json")
    pf = next((e for e in ev if e.name == "port-fidelity.json"), None)
    if pf is None or sha(pf) != sc["port_fidelity"]["sha256"] or not json.loads(pf.read_text()).get("pass"):
        probs.append("port fidelity: missing, changed or failing")
    gate = next((g for g, (grp, pred, uses) in RECORD_SHAPE.items()
                 if grp == r["callGroup"] and uses == r["uses"]
                 and (r["predicates"] == [pred] if pred else sorted(r["predicates"]) == sorted(person_predicates(reg)))), None)
    if gate is None or r.get("basis"):
        return probs + [f"no 13a.2 gate for {r['predicates']} {r['uses']} {r.get('basis')}"]
    reads = {rd: base / d for rd, d in ((p.split("/")[0].rsplit("-", 1)[-1], p.split("/")[0]) for p in sc["inputs"])}
    recomputed = {rd: measure_read(d, reg, SETS[gate]) for rd, d in reads.items()}
    for rd in recomputed:
        for s in SETS[gate]:
            if json.dumps(recomputed[rd].get(s), sort_keys=True) != json.dumps(sc["measures"].get(rd, {}).get(s), sort_keys=True):
                probs.append(f"{rd} {s}: measures recomputed from the evidence differ from scores.json")
    probs += judge_gate(gate, recomputed, reg, r.get("registryVersion"))
    listed = sorted(e for e in r["evidence"] if e.endswith("-manifest.json"))
    found = sorted(str((d / f.name).relative_to(REPO)) for d in reads.values() for f in d.glob("*-manifest.json") if f.name[:-14] in SETS[gate])
    if listed != found:
        probs.append("the record's manifests aren't the scored ones")
    ms = [(json.loads(f.read_text()), d) for d in reads.values() for f in d.glob("*-manifest.json") if f.name[:-14] in SETS[gate]]
    probs += run_problems([m for m, _ in ms], r["model"], r["callGroup"], record=r, dirs=[d for _, d in ms])
    if pf is not None:
        probs += pf_problems(json.loads(pf.read_text()), ms[0][0]["commit"] if ms else None)
    return probs


# --- Phase 13d: the answer gates (attributes) -------------------------------------------------------------------------
R13D = HERE / "results-13d"
ANSWER_SETS = ["main", "astra", "busy"]
ANSWER_BASES = ["", "sole_known"]


def answer_inputs(engine):
    """The live records, the judge's verdicts, Spike G's records, this gate's hand labels and the author's waivers."""
    files = [f"answers-{engine}/{s}-r3.jsonl" for s in ANSWER_SETS] + [f"answers-{engine}/{s}-r3-judge.jsonl" for s in ANSWER_SETS]
    files += [f"spike-g-{engine}/{s}-{arm}.jsonl" for s in ("main", "astra") for arm in ("P", "F")]
    return files + [f"labels-spikeg-{engine}.json", f"waivers-{engine}.json"]


def replay_files(engine):
    return {"answers": (f"answers-{engine}", [f"{s}-r3.jsonl" for s in ANSWER_SETS]),
            "spikeg": (f"spike-g-{engine}", [f"{s}-{arm}.jsonl" for s in ("main", "astra") for arm in ("P", "F")])}


MARK_FIELDS = ("inferred", "basis", "factIds", "corrections")


def normalized(path, marks=True):
    """A record file without what differs between two fixture vaults (the facts revision's epoch, fact row ids) and
    whether an answer came from the cache; without each claim's marking too unless `marks`."""
    out = []
    for line in Path(path).read_text().splitlines():
        r = {k: v for k, v in json.loads(line).items() if k != "reused"}
        if r.get("factsRevision"):
            r["factsRevision"] = r["factsRevision"].split(".", 1)[1]
        r["claims"] = [{**c, "factIds": len(c["factIds"])} if "factIds" in c else c for c in r.get("claims", [])]
        if not marks:
            r["claims"] = [{k: v for k, v in c.items() if k not in MARK_FIELDS} for c in r["claims"]]
        out.append(r)
    return out


def replay_marks(engine, replay):
    """Where the code that ships marks a claim differently from the live run (the same answer, marked again): the
    replay's marks by (set, id, arm, rep), and each change in words."""
    marks, changes = {}, []
    sub = f"answers-{engine}"
    for s in ANSWER_SETS:
        live = [json.loads(l) for l in (R13D / sub / f"{s}-r3.jsonl").read_text().splitlines()]
        again = [json.loads(l) for l in (replay / sub / f"{s}-r3.jsonl").read_text().splitlines()]
        for a, b in zip(live, again):
            la = [bool(c.get("inferred")) for c in a["claims"]]
            lb = [bool(c.get("inferred")) for c in b["claims"]]
            if la != lb:
                marks[(s, a["id"], a["arm"], a["rep"])] = lb
                for i, (x, y) in enumerate(zip(la, lb)):
                    if x != y:
                        changes.append(f"{s} {a['id']} {a['arm']}{a['rep']} claim {i + 1}: {'marked' if y else 'unmarked'} at the shipped code")
    return marks, changes


def model_identified(m, model):
    """Every answer by exactly `model` ("<provider>/<id>"): the provider named that id on every response (Claude Code), or
    it names none (Codex's events carry no model) and the run asked for that full id itself, not an alias."""
    provider, mid = model.split("/", 1)
    if m.get("modelsReported") == [mid] and not m.get("responsesWithoutModel"):
        return True
    return m.get("modelsReported") == [] and m.get("engine") == {"provider": provider, "model": mid}


def replay_problems(engine, model, replay):
    """Why the replay doesn't tie the live records to one clean commit's code ([] = it does); and its manifests."""
    probs, manifests = [], {}
    for gate, (sub, names) in replay_files(engine).items():
        mp = replay / sub / f"manifest-{gate}.json"
        if not mp.exists():
            probs.append(f"{gate}: no replay manifest")
            continue
        m = manifests[gate] = json.loads(mp.read_text())
        if m.get("mode") != "replay" or m.get("uncached") != 0:
            probs.append(f"{gate}: not a full replay ({m.get('mode')}, {m.get('uncached')} uncached)")
        if m.get("dirty") or not m.get("commit"):
            probs.append(f"{gate}: replayed on a dirty tree")
        if not model_identified(m, model):
            probs.append(f"{gate}: the provider reported {m.get('modelsReported')}, asked for {m.get('engine')}")
        opts = m.get("options", {})
        if opts.get("only") or opts.get("sets") or opts.get("arms") or opts.get("index") == "keyword" or opts.get("engine") != engine:
            probs.append(f"{gate}: a partial replay ({opts})")
        if sorted(m.get("records", {})) != sorted(names):
            probs.append(f"{gate}: records {sorted(m.get('records', {}))}")
        for name in names:
            f = replay / sub / name
            if not f.exists() or sha(f) != m.get("records", {}).get(name):
                probs.append(f"{sub}/{name}: the replay's file isn't the one it wrote")
            elif normalized(f, marks=False) != normalized(R13D / sub / name, marks=False):
                probs.append(f"{sub}/{name}: the replay's records differ from the live ones")
            elif gate == "spikeg" and normalized(f) != normalized(R13D / sub / name):
                probs.append(f"{sub}/{name}: the replay marks Spike G's answers differently")
    if len({m.get("commit") for m in manifests.values()}) > 1 or len({m.get("answerPromptVersion") for m in manifests.values()}) > 1:
        probs.append("the two replays disagree on the commit or the answer prompt version")
    return probs, manifests


def answer_gates(engine, marks=None):
    """Both 13d gates recomputed from the evidence in results-13d/ (score_13d.py), with the author's waivers and the
    shipped code's marks (`replay_marks`)."""
    import score_13d
    score_13d.OUT = R13D
    ok_a, _ = score_13d.answers_gate(engine, ANSWER_SETS, marks)
    ok_g, _ = score_13d.spikeg_gate(engine)
    return {"answers": ok_a, "spikeg": ok_g}


def persons_record(model):
    return next((r for r in json.loads(RECORDS.read_text())["records"]
                 if r["model"] == model and r["callGroup"] == "people" and r["uses"] == ["recorded", "linked"]), None)


def sole_known_problems(persons):
    """13a.2's sole_known measure on the persons record's own scores (verified with that record)."""
    sc = json.loads((REPO / next(e for e in persons["evidence"] if e.endswith("/scores.json"))).read_text())
    return judge_gate("sole_known", sc["measures"], registry())


def cmd_answer_scores(a):
    model, engine = a.model, a.engine
    dest = R13D / "gates" / model.replace("/", "_")
    probs, manifests = replay_problems(engine, model, Path(a.replay))
    if probs:
        raise SystemExit("qualify.py: " + "; ".join(probs))
    for gate, (sub, names) in replay_files(engine).items():
        (dest / "replay" / sub).mkdir(parents=True, exist_ok=True)
        for name in names + [f"manifest-{gate}.json"]:
            shutil.copy(Path(a.replay) / sub / name, dest / "replay" / sub / name)
    missing = [p for p in answer_inputs(engine) if not (R13D / p).exists()]
    if missing:
        raise SystemExit("qualify.py: missing " + ", ".join(missing))
    marks, changes = replay_marks(engine, dest / "replay")
    gates = answer_gates(engine, marks)
    m0 = manifests["answers"]
    out = {"engine": engine, "model": model, "factsModel": a.facts_model, "inputs": {p: sha(R13D / p) for p in answer_inputs(engine)},
           "replay": {"commit": m0["commit"], "answerPromptVersion": m0["answerPromptVersion"], "registryVersion": m0["registryVersion"],
                      "files": {str(f.relative_to(dest)): sha(f) for f in sorted((dest / "replay").rglob("*")) if f.is_file()}},
           "marksChanged": changes, "gates": gates, "date": m0["date"][:10]}
    Path(a.out).write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps(gates, indent=1, ensure_ascii=False))


def answer_record_problems(sc, persons):
    probs = []
    if persons is None:
        return ["no persons record for this model to rest on"]
    for gate, ok in sc["gates"].items():
        bad = [k for k, v in ok.items() if not v]
        if bad:
            probs.append(f"{gate}: {', '.join(bad)}")
    if sc["replay"]["registryVersion"] != persons["registryVersion"]:
        probs.append("the replay's registry isn't the persons record's")
    return probs


def cmd_answer_records(a):
    path = Path(a.scores)
    sc = json.loads(path.read_text())
    persons = persons_record(sc.get("factsModel", sc["model"]))
    probs = answer_record_problems(sc, persons)
    if probs:
        raise SystemExit("qualify.py: no record: " + "; ".join(probs))
    rel = lambda p: str(Path(p).resolve().relative_to(REPO))
    dest = path.parent
    evidence = sorted([rel(path)] + [rel(R13D / p) for p in sc["inputs"]] + [rel(dest / p) for p in sc["replay"]["files"]])
    records = []
    for basis in ANSWER_BASES:
        if basis == "sole_known" and sole_known_problems(persons):
            print("sole_known: no record (" + "; ".join(sole_known_problems(persons)) + ")")
            continue
        ev = evidence + ([next(e for e in persons["evidence"] if e.endswith("/scores.json"))] if basis else [])
        records.append({"predicates": persons["predicates"], "uses": ["attributes"], "basis": basis, "callGroup": "people",
                        "model": persons["model"], "adapter": persons["adapter"], "batching": persons["batching"],
                        "promptVersion": persons["promptVersion"], "registryVersion": persons["registryVersion"],
                        "gate": "13d answers on linked questions (main, astra, busy; P/F/W, 3 samples, blind Opus judge; one "
                                "sample waived by the author) and Spike G with the feature on (main, astra)"
                                + ("; 13a.2 sole_known ≥ 90%, reads r1, r2" if basis else ""),
                        "evidence": sorted(ev), "recordedAt": sc["date"],
                        "answerModels": [sc["model"]], "answerPromptVersion": sc["replay"]["answerPromptVersion"]})
    print(json.dumps(records, indent=1, ensure_ascii=False))
    if a.write and records:
        f = json.loads(RECORDS.read_text())
        f["records"] = [r for r in f["records"] if not (r.get("answerModels") == [sc["model"]] and r["uses"] == ["attributes"])] + records
        RECORDS.write_text(json.dumps(f, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {len(records)} record(s)")


def verify_answer_record(r, reg):
    """Why a shipped attributes record's evidence doesn't hold up ([] = it does)."""
    scores = next((REPO / e for e in r["evidence"] if e.endswith("/scores-13d.json")), None)
    if scores is None or not scores.exists():
        return ["no scores-13d.json in the evidence"]
    missing = [e for e in r["evidence"] if not (REPO / e).exists()]
    if missing:
        return [f"missing {m}" for m in missing]
    sc = json.loads(scores.read_text())
    probs = [f"{p}: digest differs from scores-13d.json" for p, d in sc["inputs"].items() if sha(R13D / p) != d]
    probs += [f"replay {p}: digest differs" for p, d in sc["replay"]["files"].items() if sha(scores.parent / p) != d]
    listed = {str((R13D / p).relative_to(REPO)) for p in sc["inputs"]} | {str((scores.parent / p).relative_to(REPO)) for p in sc["replay"]["files"]}
    if not listed <= set(r["evidence"]):
        probs.append("the record's evidence isn't what the scores were computed from")
    rp, manifests = replay_problems(sc["engine"], sc["model"], scores.parent / "replay")
    probs += rp
    if manifests.get("answers", {}).get("answerPromptVersion") != r.get("answerPromptVersion"):
        probs.append("answer prompt version isn't the replay's")
    if r.get("answerModels") != [sc["model"]]:
        probs.append(f"answer models {r.get('answerModels')}")
    marks, changes = replay_marks(sc["engine"], scores.parent / "replay")
    if changes != sc.get("marksChanged"):
        probs.append("the replay's mark changes aren't the scored ones")
    gates = answer_gates(sc["engine"], marks)
    for gate, ok in gates.items():
        bad = [k for k, v in ok.items() if not v]
        if bad:
            probs.append(f"{gate}: {', '.join(bad)} (recomputed)")
    persons = persons_record(r["model"])
    if sc.get("factsModel", sc["model"]) != r["model"]:
        probs.append("not the Facts engine the scores were computed with")
    if persons is None or any(persons[k] != r[k] for k in ("model", "adapter", "batching", "promptVersion", "registryVersion", "predicates")):
        probs.append("not on the facts key of a shipped persons record")
    elif r.get("basis") == "sole_known":
        probs += sole_known_problems(persons)
    elif r.get("basis"):
        probs.append(f"no 13d gate for basis {r['basis']}")
    return probs


def cmd_verify(a):
    reg = registry()
    recs = json.loads(RECORDS.read_text())["records"]
    bad = 0
    for r in recs:
        probs = verify_answer_record(r, reg) if r["uses"] == ["attributes"] else verify_record(r, reg)
        bad += bool(probs)
        print(f"{r['callGroup']} {r['uses']} {r['model']}: " + ("ok" if not probs else "; ".join(probs)))
    print(f"qualify.py verify: {len(recs)} record(s), {bad} failing")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scores")
    s.add_argument("harness_out")
    s.add_argument("--model", required=True)
    s.add_argument("--port-fidelity")
    s.add_argument("--out", required=True)
    r = sub.add_parser("records")
    r.add_argument("scores")
    r.add_argument("--harness-out")
    r.add_argument("--port-fidelity")
    r.add_argument("--write", action="store_true")
    sub.add_parser("verify")
    s13 = sub.add_parser("answer-scores")
    s13.add_argument("--engine", required=True)
    s13.add_argument("--model", required=True)
    s13.add_argument("--replay", required=True)
    s13.add_argument("--out", required=True)
    s13.add_argument("--facts-model", default="claude-code/claude-haiku-5-5")
    r13 = sub.add_parser("answer-records")
    r13.add_argument("scores")
    r13.add_argument("--write", action="store_true")
    a = ap.parse_args()
    if a.cmd == "answer-scores":
        return cmd_answer_scores(a)
    if a.cmd == "answer-records":
        return cmd_answer_records(a)
    if a.cmd == "scores":
        return cmd_scores(a)
    if a.cmd == "records":
        if a.write and not a.port_fidelity:
            ap.error("--write needs --port-fidelity")
        return cmd_records(a)
    return cmd_verify(a)


if __name__ == "__main__":
    sys.exit(main() or 0)
