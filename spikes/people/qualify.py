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


def trusted_memory(mm):
    """A fixture memory's trust as the harness stores it: its `trust`, else untrusted for an agent's (13e.2: the scorer
    reads trust, not the source, so an import or a shared note marked untrusted counts as untrusted)."""
    return (mm.get("trust") or ("untrusted" if mm.get("source") == "agent" else "trusted")) == "trusted"


def labelled_names(st, org):
    """Every name a trusted memory of the story labels as this employer (13e.2, a scorer correction): the timeline's
    org, an organization surface with relation employer or self_employed that the labels map to it ("Marlin Metrics" →
    "Marlin Analytics"), and a job's also_called. A stated rename is one entity on the timeline (ADR-0032, amended
    2026-11-20), so the old name's facts are that stint's; only the story's own labels say so, never an agent's."""
    names = {org}
    for mm in st["memories"]:
        if not trusted_memory(mm):
            continue
        for o in mm.get("organizations", []):
            if o.get("org") == org and o.get("relation") in ("employer", "self_employed") and o.get("surface"):
                names.add(o["surface"])
        for j in mm.get("jobs", []):
            if j.get("org") == org and j.get("polarity") != "negative" and j.get("also_called"):
                names.add(j["also_called"])
    return names


def check_labels(st, emp):
    """A labelled name that two stints' organizations, or a stint's and a client's or vendor's, share (normalised as
    the matching normalises it, legal suffixes stripped) would make the scorer's rename rule ambiguous: stop rather
    than score it (13e.2)."""
    import facts as F
    kind = F.R.kind_of(emp)
    owner = {}
    for t in st.get("timeline", []):
        names = labelled_names(st, t["org"]) if t["kind"] in ("employee", "self_employed") else {t["org"]}
        for n in names:
            k = F.norm_name(n, kind)
            if owner.get(k, t["org"]) != t["org"]:
                raise SystemExit(f"qualify.py: {st['id']}: {n!r} is labelled for both {owner[k]!r} and {t['org']!r}")
            owner[k] = t["org"]


def stint_entities(state, emp, st, org):
    """The holders of `emp` for `org`: as entity_matches finds the org itself (the registry's match rule), plus those
    with an alias exactly equal (normalised) to another name the story's trusted labels give it, never by containment
    ("Marlin Metrics" labelled admits Marlin Metrics, not "Marlin Metrics Consulting")."""
    import facts as F
    kind = F.R.kind_of(emp)
    found = set(F.entity_matches(state, emp, org))
    extra = {F.norm_name(n, kind) for n in labelled_names(st, org) if n != org}
    holders = {f.entity for f in state.facts if f.type == emp and not f.negated}
    for e in state.named(kind):
        if e.id in holders and any(F.norm_name(a, kind) in extra for a in e.aliases):
            found.add(e.id)
    return found


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
        check_labels(st, emp)
        state = load_state(r["state"])
        orgs = {t["org"]: t for t in st.get("timeline", [])}
        mention_rel = {(mm["id"], o["org"]): o["relation"] for mm in st["memories"] for o in mm.get("organizations", [])}
        stint_mems = defaultdict(set)
        for t in st.get("timeline", []):
            if t["kind"] in ("employee", "self_employed"):
                stint_mems[t["org"]] |= set(t.get("memories", []))
        match = {o: stint_entities(state, emp, st, o) if t["kind"] in ("employee", "self_employed") else set(F.entity_matches(state, emp, o))
                 for o, t in orgs.items()}
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
        check_labels(st, emp)
        held = [stint_entities(state, emp, st, t["org"]) for t in stints]
        # The story's own trusted denials: a negative job label in a memory that isn't an agent's.
        denied = set()
        for mm in st["memories"]:
            if not trusted_memory(mm):
                continue
            for j in mm.get("jobs", []):
                if j.get("polarity") == "negative" and j.get("org"):
                    denied |= set(F.entity_matches(state, emp, j["org"]))
        for f in r["state"]["facts"]:
            if f["type"] != emp or f.get("negated"):
                continue
            if any(f["entity"] in held[i] for i in range(len(stints))):
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
        # organization by a loose rule (one name inside the other) or a name the story's trusted labels give it
        # (`labelled_names`, 13e.2), so a merge the story doesn't make leaves it unassigned, a wrong fact.
        group_of = {x: set(g) for g in r["state"].get("timeline_groups", []) for x in g}

        def norm(n):
            n = F.fold(n or "")
            for suf in (" inc.", " inc", " ltd.", " ltd", " llc", " gmbh", " s.a.", " sa", " s.l.", " sl"):
                if n.endswith(suf):
                    n = n[: -len(suf)]
            return n.strip()

        def loose(ent, i):
            # The stint's org once its legal suffix is gone ("X" / "X Ltd."), or a name the story's trusted labels give
            # it; never one name inside another ("X" and "X Consulting" stay two employers: 13e.2).
            al = (names.get(ent) or {}).get("aliases") or [(names.get(ent) or {}).get("name")]
            labelled = {norm(n) for n in labelled_names(st, stints[i]["org"])}
            return any(x and norm(x) == norm(stints[i]["org"]) for x in al) or any(norm(x or "") in labelled for x in al)
        assign = {}
        for trust_pass in (True, False):
            group = [e for e in eps if bool(e.get("trusted", True)) == trust_pass]
            taken = set()
            def options(e):
                ids = group_of.get(e["entity"], {e["entity"]})
                mine = [i for i, t in enumerate(stints) if ids & held[i] and (len(ids) == 1 or all(loose(x, i) for x in ids))]
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
                    if len(ids) > 1 and any(ids & held[i] for i in range(len(stints))):
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
            # A later stint of the same kind follows an undated one (the timeline lists each kind in order): its blank
            # end is "not recorded", not "still held".
            # Only for a stint with no dates at all: a dated one, or two businesses running at once, keeps "still held".
            followed = not t["start"] and not t["end"] and any(x["kind"] == t["kind"] for x in stints[assign[id(e)] + 1:])
            # 13e.2: the episode's slot is its stint's kind (a freelance business read as employment is a wrong fact).
            if e.get("slot") not in (None, "", "_") and e["slot"] != t["kind"]:
                (wrong_facts if e.get("trusted", True) else untrusted_facts).add((r["story"], t["org"], "slot"))
            sink = wrong_dates if e.get("trusted", True) else untrusted_dates
            for bound, truth in (("start", t["start"]), ("end", t["end"])):
                got, want = e[bound], _range(truth)
                if got is None or got[2] == "handover":
                    continue                                   # unknown isn't wrong; a hand-over start is for role resolution only
                if want is None:
                    # A current stint given an end. Fix round 3 (r2): a blank end is "still held" only for a stint
                    # nothing follows; "I worked at X immediately before Y. I did not keep the dates" bounds X by the day
                    # the memory was written, which is true and no date made up.
                    if bound == "end" and not (followed and got[2] == "bound"):
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


def revision_counter(rev):
    """A facts revision without what differs between two fixture vaults or registries: "<epoch>.<counter>.<digest>",
    where the epoch is the vault's and the digest hashes the facts index key (the registry fingerprint among it). The
    author's decision of 2026-11-24 ("Go with A"): 13d's replay at a later registry sends byte-identical requests (every
    answer from the cache) and gives the same records and marks, so only the counter is compared."""
    parts = rev.split(".")
    return parts[1] if len(parts) > 1 else rev


MARK_FIELDS = ("inferred", "basis", "factIds", "corrections")


def normalized(path, marks=True):
    """A record file without what differs between two fixture vaults (the facts revision's epoch, fact row ids) and
    whether an answer came from the cache; without each claim's marking too unless `marks`."""
    out = []
    for line in Path(path).read_text().splitlines():
        r = {k: v for k, v in json.loads(line).items() if k != "reused"}
        if r.get("factsRevision"):
            r["factsRevision"] = revision_counter(r["factsRevision"])
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


# --- 13e.2: the timeline gate (works at {timeline}, per answer engine) --------------------------------------------------
R13E2 = HERE / "results-13e2"
GATE_SET = HERE / "fixtures" / "gate-13e2"
VOLATILE = ("durationMs", "providerMs", "answerMs", "cached", "tries", "commit", "dirty")


def timeline_blockers():
    """The gate's own freeze (spikes/people/freeze-13e2.txt) and the shared blockers."""
    import os
    import subprocess
    out = [b for b in blockers() if "freeze" not in b]
    f = subprocess.run(["sh", str(REPO / "scripts/facts_freeze.sh"), "check"], capture_output=True, text=True,
                       env=dict(os.environ, FACTS_FREEZE="spikes/people/freeze-13e2.txt"))
    if f.returncode != 0:
        out.append("the code changed since the timeline gate's freeze (FACTS_FREEZE=spikes/people/freeze-13e2.txt)")
    return out


def timeline_inputs(engine, tag, waiver=None):
    """The evidence a timeline record rests on, repo-relative under results-13e2/ and the set."""
    files = [f"answers-{engine}/answers.jsonl", f"answers-{engine}/manifest.json", f"answers-{engine}/judge-opus.jsonl",
             f"answers-{engine}/judge-astra.jsonl", f"answers-{engine}/adjudicated.jsonl",
             f"read-{tag}/stories.jsonl", f"read-{tag}/manifest.json", f"read-{tag}/calls.jsonl"]
    files += ["labels-corrected.json"] + [f for f in ("relabels.jsonl", "fact-disputes.jsonl") if (R13E2 / f).exists()]
    if waiver:
        files.append("waivers.json")
    return files


def normalized_answers(path):
    out = []
    for line in Path(path).read_text().splitlines():
        r = {k: v for k, v in json.loads(line).items() if k not in VOLATILE}
        if r.get("factsRevision"):
            r["factsRevision"] = r["factsRevision"].split(".", 1)[1]
        out.append(r)
    return out


FROZEN_PATHS = ["Packages", "Apps", "scripts", "FunesVault.xcodeproj", "spikes/people/*.py", "spikes/people/swift",
                "spikes/people/registry.json", "spikes/people/port_fidelity_known.json"]


def code_changed_since(commit):
    """Frozen code that differs between `commit` and the working tree (the records file aside); None if unknown."""
    import subprocess
    p = subprocess.run(["git", "-C", str(REPO), "diff", "--name-only", commit, "--", *FROZEN_PATHS], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return [f for f in p.stdout.split() if not f.endswith("Resources/facts-qualification.json")]


def measured_commit(x):
    """The commit a run measured. FactsHarness stamps "<sha>+dirty" when anything in the tree changed, results included;
    the run's own `dirty` flag covers code only, so with it false the code was the commit's (a run that wrote its
    results inside the tree, as r4 did). A run whose code was dirty, or that names no flag, keeps the suffix. The flag
    covers every path `swift test` builds or reads (Packages; Apps and scripts too), not the Xcode project or the spike's
    registry copy, which the harness never reads (the manifest's registryVersion covers the bundled registry). Live runs
    only: a replay must be at a clean commit."""
    c = x.get("commit") or ""
    if c.endswith("+dirty") and x.get("dirty") is False:
        return c[: -len("+dirty")]
    return c


def is_product_code(f):
    """Code that ships: not the test support and harnesses (Packages/*/Tests), nor the spike's scripts and Swift."""
    return not (re.match(r"Packages/[^/]+/Tests/", f) or re.fullmatch(r"spikes/people/[^/]+\.py", f)
                or f.startswith("spikes/people/swift/"))


def product_code_changed_since(commit):
    """The timeline gate's code check (the author's decision of 2026-11-24): product code changed since `commit`; None
    if unknown. Test support and scoring scripts may change after a live run, because the replays at one clean commit
    must reproduce its read and answers exactly (`timeline_replay_problems`)."""
    changed = code_changed_since(commit) if commit else None
    return None if changed is None else [f for f in changed if is_product_code(f)]


TIMELINE_WAIVERS = HERE / "results-13e2" / "waivers.json"
# The targets a waiver may name, each with the measure it caps. Wrong answers (decidable wrong, someone else, negatives),
# the facts, completeness, Spike G and latency are never waived.
TIMELINE_WAIVABLE = {"owed_checks": "owed_skipped", "marking": "unmarked_inferred"}


def timeline_waiver(model, answer_prompt_version, registry_version, tag, engine):
    """The author's waiver for one answer model's timeline gate (results-13e2/waivers.json), or None. It holds only for
    the answer model, answer prompt version, registry version and gate read it names, and for the very read calls and
    answers it was given on (their digests)."""
    if not TIMELINE_WAIVERS.exists():
        return None
    calls, answers = R13E2 / f"read-{tag}" / "calls.jsonl", R13E2 / f"answers-{engine}" / "answers.jsonl"
    return next((w for w in json.loads(TIMELINE_WAIVERS.read_text())["waivers"]
                 if w.get("gate") == "timeline-answers" and w.get("answerModel") == model
                 and w.get("answerPromptVersion") == answer_prompt_version and w.get("registryVersion") == registry_version
                 and w.get("tag") == tag and calls.exists() and answers.exists()
                 and w.get("readCallsSha256") == sha(calls) and w.get("answersSha256") == sha(answers)), None)


def unwaived_failures(gates, measures, waiver):
    """The failing gates a waiver doesn't cover: it names the target, caps its measure, and the measure is within it."""
    out = []
    for k, ok in gates.items():
        if ok:
            continue
        t = (waiver or {}).get("waived", {}).get(k)
        if t and TIMELINE_WAIVABLE.get(k) == t.get("measure") and isinstance(measures.get(t["measure"]), int) \
                and measures[t["measure"]] <= t.get("max", -1):
            continue
        out.append(k)
    return out


def scores_waiver(sc):
    return timeline_waiver(sc["model"], sc["replay"]["answerPromptVersion"], sc["replay"]["registryVersion"], sc["tag"], sc["engine"])


def timeline_replay_problems(engine, model, replay, tag, facts_record=None, check_code=True):
    """Why the evidence doesn't tie the live read and answers, and their replays, to one set and the frozen code
    ([] = it does)."""
    import score_13e2
    probs = []
    set_sha = {"storiesSha256": sha(GATE_SET / "stories.json"), "fillersSha256": sha(GATE_SET / "fillers.json")}
    read_calls = R13E2 / f"read-{tag}" / "calls.jsonl"
    manifests = {
        "read": R13E2 / f"read-{tag}" / "manifest.json",
        "answers": R13E2 / f"answers-{engine}" / "manifest.json",
        "read replay": Path(replay) / f"replay-read-{tag}" / "manifest.json",
        "answers replay": Path(replay) / f"answers-{engine}" / "manifest.json",
    }
    m = {}
    for name, mp in manifests.items():
        if not mp.exists():
            probs.append(f"{name}: no manifest at {mp}")
            continue
        m[name] = json.loads(mp.read_text())
        x = m[name]
        if x.get("dirty") or not x.get("commit"):
            probs.append(f"{name}: on a dirty tree")
        if "replay" in name and (x.get("commit") or "").endswith("+dirty"):
            probs.append(f"{name}: not at a clean commit")
        if check_code:
            changed = product_code_changed_since(x.get("commit") if "replay" in name else measured_commit(x))
            if changed is None or changed:
                probs.append(f"{name}: product code changed since its commit ({(changed or ['unknown'])[:3]})")
        if any(x.get(k) != v for k, v in set_sha.items()):
            probs.append(f"{name}: not on the set's current files")
        if x.get("options", {}).get("only") or x.get("options", {}).get("index") == "keyword":
            probs.append(f"{name}: a partial or keyword-only run ({x.get('options')})")
    if len(m) < 4:
        return probs
    rd, ans, rrep, arep = m["read"], m["answers"], m["read replay"], m["answers replay"]
    if rd.get("mode") != "live" or rd.get("problems") or rd.get("unsettled"):
        probs.append(f"read: not a clean live read ({rd.get('mode')}, {rd.get('problems')}, unsettled {rd.get('unsettled')})")
    if rd.get("callsSha256") != sha(read_calls):
        probs.append("read: its calls file isn't the one it wrote")
    lines = R13E2 / f"read-{tag}" / "stories.jsonl"
    if rd.get("linesSha256") != sha(lines):
        probs.append("read: its stories file isn't the one it wrote")
    else:
        got = [json.loads(l)["story"] for l in lines.read_text().splitlines()]
        want = [s["id"] for s in json.loads((GATE_SET / "stories.json").read_text())["stories"]]
        if got != want or sorted(rd.get("digests", {})) != sorted(want):
            probs.append("read: not every story of the set, once, in order")
    if rrep.get("mode") != "replay" or rrep.get("calls", {}).get("misses") or rrep.get("problems"):
        probs.append(f"read replay: {rrep.get('mode')}, misses {rrep.get('calls', {}).get('misses')}, {rrep.get('problems')}")
    if rrep.get("digests") != rd.get("digests"):
        probs.append("read replay: its stories' states differ from the live read's")
    for name, x in (("answers", ans), ("answers replay", arep)):
        if x.get("readCallsSha256") != sha(read_calls) or x.get("readDigests") != rd.get("digests"):
            probs.append(f"{name}: not on the live read {tag}")
        if x.get("reps") != score_13e2.GATE_REPS:
            probs.append(f"{name}: {x.get('reps')} samples of R, the gate fixed {score_13e2.GATE_REPS}")
    if ans.get("mode") != "live":
        probs.append(f"answers: not a live run ({ans.get('mode')})")
    provider, mid = model.split("/", 1)
    seen = ans.get("modelsReported")
    if not (seen == [mid] or (seen == [] and ans.get("engine") == {"provider": provider, "model": mid})):
        probs.append(f"answers: the provider reported {seen}, for {ans.get('engine')}")
    if arep.get("mode") != "replay" or arep.get("calls", {}).get("uncached"):
        probs.append(f"answers replay: not a full replay ({arep.get('mode')}, {arep.get('calls')})")
    f = Path(replay) / f"answers-{engine}" / "answers.jsonl"
    live_file = R13E2 / f"answers-{engine}" / "answers.jsonl"
    if not f.exists() or normalized_answers(f) != normalized_answers(live_file):
        probs.append("answers replay: its records differ from the live ones")
    if check_code:
        for c in sorted({(json.loads(l).get("commit"), json.loads(l).get("dirty")) for l in live_file.read_text().splitlines()}, key=str):
            if c[1] or not c[0]:
                probs.append(f"answers: records made on a dirty tree or without a commit ({c})")
            else:
                changed = product_code_changed_since(measured_commit({"commit": c[0], "dirty": c[1]}))
                if changed is None or changed:
                    probs.append(f"answers: records made at {c[0][:8]}, and product code changed since")
    if rrep.get("commit") != arep.get("commit"):
        probs.append("the two replays aren't at one commit")
    sg = Path(replay) / f"spike-g-{engine}-timeline" / "manifest-spikeg.json"
    if sg.exists():
        g = json.loads(sg.read_text())
        if g.get("commit") != arep.get("commit"):
            probs.append("Spike G's replay isn't at the replays' commit")
        if g.get("answerPromptVersion") != arep.get("answerPromptVersion") or g.get("registryVersion") != arep.get("registryVersion"):
            probs.append("Spike G's replay isn't at the answers' prompt and registry versions")
    if facts_record:
        e = rd.get("engine", {})
        if f"{e.get('provider')}/{e.get('model')}" != facts_record["model"] or e.get("adapter") != facts_record["adapter"]:
            probs.append(f"read: engine {e} isn't the works at record's ({facts_record['model']}, {facts_record['adapter']})")
        if rd.get("batching") != facts_record["batching"] or rd.get("registryVersion") != facts_record["registryVersion"] \
                or rd.get("promptVersions", {}).get(facts_record["callGroup"]) != facts_record["promptVersion"]:
            probs.append("read: batching, registry or prompt version isn't the works at record's")
    probs += spikeg_timeline_problems(engine, model, replay, check_code)
    return probs


def spikeg_timeline_problems(engine, model, replay, check_code=True):
    """The Spike G run with the rows on (FactsAnswerLiveTests timeline=1): live, full, clean, the model, and replayed at
    a clean commit with the same records."""
    probs = []
    live_dir, rep_dir = R13D / f"spike-g-{engine}-timeline", Path(replay) / f"spike-g-{engine}-timeline"
    for name, d, mode in (("Spike G", live_dir, "live"), ("Spike G replay", rep_dir, "replay")):
        mp = d / "manifest-spikeg.json"
        if not mp.exists():
            probs.append(f"{name}: no manifest")
            continue
        x = json.loads(mp.read_text())
        o = x.get("options", {})
        if x.get("mode") != mode or (mode == "replay" and x.get("uncached")):
            probs.append(f"{name}: mode {x.get('mode')}, uncached {x.get('uncached')}")
        if o.get("timeline") != "1" or o.get("engine") != engine or o.get("only") or o.get("sets") or o.get("arms") or o.get("index") == "keyword":
            probs.append(f"{name}: options {o}")
        if x.get("dirty") or not x.get("commit"):
            probs.append(f"{name}: on a dirty tree")
        if mode == "replay" and (x.get("commit") or "").endswith("+dirty"):
            probs.append(f"{name}: not at a clean commit")
        if check_code:
            changed = product_code_changed_since(x.get("commit") if mode == "replay" else measured_commit(x))
            if changed is None or changed:
                probs.append(f"{name}: product code changed since its commit")
        if mode == "live" and not model_identified(x, model):
            probs.append(f"{name}: the provider reported {x.get('modelsReported')}")
    for n in ("main-P.jsonl", "main-F.jsonl", "astra-P.jsonl", "astra-F.jsonl"):
        a, b = live_dir / n, rep_dir / n
        if not a.exists() or not b.exists() or normalized(a) != normalized(b):
            probs.append(f"Spike G {n}: the replay's records differ from the live ones")
    return probs


def phase_a_lines(model):
    """Phase A's reads behind the works at record: its work13 and mixed lines, r1 and r2 (the record's evidence)."""
    rec = next((r for r in json.loads(RECORDS.read_text())["records"]
                if r["model"] == model and r["uses"] == ["recorded", "linked"] and "works_at" in r["predicates"]), None)
    if rec is None:
        return None, []
    return rec, sorted(e for e in rec["evidence"] if re.search(r"-gates-r\d+/(work13|mixed)\.jsonl$", e))


def timeline_gates(engine, answer_model, facts_model, tag):
    import score_13e2
    import score_13d
    import judge_13e2 as J
    J.SET, J.RESULTS = GATE_SET, R13E2
    score_13d.OUT = R13D
    sc = score_13e2.score_engine(R13E2, engine, score_13e2.GATE_REPS)
    orig = score_13e2.score_engine(R13E2, engine, score_13e2.GATE_REPS, J.original_labels(), check_minimums=False)
    sc["original_labels"] = {"measures": orig["measures"], "gates": orig["gates"]}
    rec, lines = phase_a_lines(facts_model)
    reads = [("gate read", str(R13E2 / f"read-{tag}" / "stories.jsonl"), str(GATE_SET / "stories.json"))]
    reads += [(l, str(REPO / l), str(HERE / "fixtures" / f"stories-{'work13' if 'work13' in l else 'mixed'}.json")) for l in lines]
    sc["facts"] = score_13e2.facts_gate(R13E2, reads)
    sc["gates"]["facts"] = len(lines) >= 4 and all(v["pass"] for v in sc["facts"].values())
    ok_g, _ = score_13d.spikeg_gate(engine, "-timeline")
    sc["gates"]["spike_g"] = all(ok_g.values())
    return sc, rec, lines


def cmd_timeline_scores(a):
    rec0, _ = phase_a_lines(a.facts_model)
    probs = timeline_replay_problems(a.engine, a.model, Path(a.replay), a.tag, rec0) + timeline_blockers()
    if probs:
        raise SystemExit("qualify.py: " + "; ".join(probs))
    sc, rec, lines = timeline_gates(a.engine, a.model, a.facts_model, a.tag)
    dest = R13E2 / "gates" / a.model.replace("/", "_")
    (dest / "replay").mkdir(parents=True, exist_ok=True)
    for sub in (f"replay-read-{a.tag}", f"answers-{a.engine}", f"spike-g-{a.engine}-timeline"):
        (dest / "replay" / sub).mkdir(parents=True, exist_ok=True)
        for f in Path(a.replay, sub).iterdir():
            if f.is_file():
                shutil.copy(f, dest / "replay" / sub / f.name)
    m0 = json.loads((Path(a.replay) / f"answers-{a.engine}" / "manifest.json").read_text())
    inputs = timeline_inputs(a.engine, a.tag, timeline_waiver(a.model, m0["answerPromptVersion"], m0["registryVersion"], a.tag, a.engine))
    m = json.loads((dest / "replay" / f"answers-{a.engine}" / "manifest.json").read_text())
    out = {"engine": a.engine, "model": a.model, "factsModel": a.facts_model, "tag": a.tag,
           "inputs": {p: sha(R13E2 / p) for p in inputs}, "set": {f: sha(GATE_SET / f) for f in ("stories.json", "fillers.json")},
           "spikeG": {f"spike-g-{a.engine}-timeline/{n}": sha(R13D / f"spike-g-{a.engine}-timeline" / n)
                      for n in ("main-P.jsonl", "main-F.jsonl", "astra-P.jsonl", "astra-F.jsonl")},
           "phaseA": {l: sha(REPO / l) for l in lines},
           "replay": {"commit": m["commit"], "answerPromptVersion": m["answerPromptVersion"], "registryVersion": m["registryVersion"],
                      "files": {str(f.relative_to(dest)): sha(f) for f in sorted((dest / "replay").rglob("*")) if f.is_file()}},
           "measures": sc["measures"], "facts": sc["facts"], "gates": sc["gates"], "problems": sc["problems"],
           "originalLabels": sc.get("original_labels"),
           "date": m["date"][:10]}
    path = dest / f"scores-13e2-{a.engine}.json"
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps({"gates": sc["gates"], "measures": sc["measures"]}, indent=1, ensure_ascii=False))


def timeline_record_problems(sc):
    probs = [f"{k}: fails" for k in unwaived_failures(sc["gates"], sc["measures"], scores_waiver(sc))] + sc.get("problems", [])
    rec, _ = phase_a_lines(sc["factsModel"])
    if rec is None:
        probs.append("no works at {recorded, linked} record for the Facts engine")
    attrs = [r for r in json.loads(RECORDS.read_text())["records"] if r["uses"] == ["attributes"]
             and r.get("answerModels") == [sc["model"]] and r.get("answerPromptVersion") == sc["replay"]["answerPromptVersion"]]
    if not attrs:
        probs.append("no attributes record for this answer model at this answer prompt version (the gate measured them together)")
    if rec and sc["replay"]["registryVersion"] != rec["registryVersion"]:
        probs.append("the replay's registry isn't the works at record's")
    return probs, rec


def cmd_timeline_records(a):
    path = Path(a.scores)
    sc = json.loads(path.read_text())
    probs, rec = timeline_record_problems(sc)
    probs += timeline_blockers()
    if probs:
        raise SystemExit("qualify.py: no record: " + "; ".join(probs))
    rel = lambda p: str(Path(p).resolve().relative_to(REPO))
    dest = path.parent
    evidence = sorted([rel(path)] + [rel(R13E2 / p) for p in sc["inputs"]] + [rel(GATE_SET / f) for f in sc["set"]]
                      + [rel(R13D / p) for p in sc["spikeG"]] + list(sc["phaseA"]) + [rel(dest / p) for p in sc["replay"]["files"]])
    record = {"predicates": ["works_at"], "uses": ["timeline"], "basis": "", "callGroup": rec["callGroup"], "model": rec["model"],
              "adapter": rec["adapter"], "batching": rec["batching"], "promptVersion": rec["promptVersion"],
              "registryVersion": rec["registryVersion"],
              "gate": "13e.2 timeline gate (ADR-0032 decision 9, amended 2026-11-21): a blind set by GPT-6-Astra (24 stories), "
                      "one recorded live read, P/R answers judged blind by Opus and GPT-6-Astra with adjudication, "
                      f"{sc['measures']['samples']} sample(s) of R; Spike G with the rows on; the facts behind the rows",
              "evidence": evidence, "recordedAt": sc["date"], "answerModels": [sc["model"]],
              "answerPromptVersion": sc["replay"]["answerPromptVersion"]}
    waived = [k for k, v in sc["gates"].items() if not v]
    if waived:
        w = scores_waiver(sc)
        record["gate"] += "; waived by the author (" + w["date"] + "): " + ", ".join(
            f"{k} ({w['waived'][k]['measure']} {sc['measures'][w['waived'][k]['measure']]})" for k in waived)
    print(json.dumps(record, indent=1, ensure_ascii=False))
    if a.write:
        f = json.loads(RECORDS.read_text())
        f["records"] = [r for r in f["records"] if not (r.get("answerModels") == [sc["model"]] and r["uses"] == ["timeline"])] + [record]
        RECORDS.write_text(json.dumps(f, indent=2, ensure_ascii=False) + "\n")
        print("wrote 1 record")


def verify_timeline_record(r, reg):
    """Why a shipped timeline record's evidence doesn't hold up ([] = it does): digests, the replay, and every gate
    recomputed from the evidence."""
    scores = next((REPO / e for e in r["evidence"] if re.search(r"/scores-13e2-\w+\.json$", e)), None)
    if scores is None or not scores.exists():
        return ["no scores-13e2-<engine>.json in the evidence"]
    missing = [e for e in r["evidence"] if not (REPO / e).exists()]
    if missing:
        return [f"missing {m}" for m in missing]
    sc = json.loads(scores.read_text())
    probs = [f"{p}: digest differs" for p, d in sc["inputs"].items() if sha(R13E2 / p) != d]
    probs += [f"{p}: digest differs" for p, d in sc["phaseA"].items() if sha(REPO / p) != d]
    probs += [f"replay {p}: digest differs" for p, d in sc["replay"]["files"].items() if sha(scores.parent / p) != d]
    probs += [f"{p}: digest differs" for p, d in sc["set"].items() if sha(GATE_SET / p) != d]
    probs += [f"{p}: digest differs" for p, d in sc["spikeG"].items() if sha(R13D / p) != d]
    rec0, _ = phase_a_lines(sc["factsModel"])
    probs += timeline_replay_problems(sc["engine"], sc["model"], scores.parent / "replay", sc["tag"], rec0, check_code=False)
    again, _, _ = timeline_gates(sc["engine"], sc["model"], sc["factsModel"], sc["tag"])
    probs += [f"{k}: fails (recomputed)" for k in unwaived_failures(again["gates"], again["measures"], scores_waiver(sc))]
    if again["measures"] != sc["measures"]:
        probs.append("the measures recomputed from the evidence differ from the scores")
    p2, rec = timeline_record_problems(sc)
    probs += p2
    if rec and any(rec[k] != r[k] for k in ("model", "adapter", "batching", "promptVersion", "registryVersion", "callGroup")):
        probs.append("not on the facts key of the works at record")
    if r.get("answerModels") != [sc["model"]] or r.get("answerPromptVersion") != sc["replay"]["answerPromptVersion"]:
        probs.append("answer model or prompt version isn't the scores'")
    return probs


def cmd_verify(a):
    reg = registry()
    recs = json.loads(RECORDS.read_text())["records"]
    bad = 0
    for r in recs:
        probs = (verify_answer_record(r, reg) if r["uses"] == ["attributes"]
                 else verify_timeline_record(r, reg) if r["uses"] == ["timeline"] and r.get("answerModels") else verify_record(r, reg))
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
    t13 = sub.add_parser("timeline-scores")
    t13.add_argument("--engine", required=True)
    t13.add_argument("--model", required=True, help="the answer model, <provider>/<id>")
    t13.add_argument("--replay", required=True, help="the replay's out= (replay-read-<tag>/, answers-<engine>/)")
    t13.add_argument("--tag", required=True, help="the live read's tag (results-13e2/read-<tag>/)")
    t13.add_argument("--facts-model", default="claude-code/claude-haiku-5-5")
    tr13 = sub.add_parser("timeline-records")
    tr13.add_argument("scores")
    tr13.add_argument("--write", action="store_true")
    a = ap.parse_args()
    if a.cmd == "timeline-scores":
        return cmd_timeline_scores(a)
    if a.cmd == "timeline-records":
        return cmd_timeline_records(a)
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
