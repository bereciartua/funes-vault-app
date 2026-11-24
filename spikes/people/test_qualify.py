#!/usr/bin/env python3
"""qualify.py's checks on synthetic manifests and measures (no model, no run): a good set of runs passes, and each
fail-open path fails. scripts/test.sh runs it.

    python3 -m unittest spikes/people/test_qualify.py
"""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualify as Q  # noqa: E402

MODEL = "claude-code/claude-haiku-5-5"
REG = Q.registry()


def manifest(s, rd="r1", **kw):
    m = {"set": s, "label": f"swift-claude-claude-haiku-5-5-gates-{rd}", "mode": "live", "commit": "a" * 40,
         "run_id": f"{s}-{rd}", "engine": {"model": MODEL, "adapter": "claude-code/1;effort=low", "batching": "one-memory;pipeline=1"},
         "prompt_versions": {"people": "p1", "work": "w1"}, "registry_version": "v1-x", "registry_file": "bundled",
         "models_reported": ["claude-haiku-5-5"], "responses": 10, "responses_without_model": 0, "options": {"set": s},
         "plays": 2, "plays_expected": 2, "plays_list": ["a#0", "a#1"], "fixture_sha256": Q.sha(Q.fixture_path(s)),
         "groups": ["people", "work"] if s in ("mixed", "work13") else ["people"], "unsettled": 0, "above_limit_in_payload": 0,
         "limit": "internal", "date": "2026-11-20T00:00:00Z"}
    m.update(kw)
    return m


def runs(sets=("main", "astra", "mixed", "persons")):
    return [manifest(s, rd) for rd in ("r1", "r2") for s in sets]


PLAYS = {"expected": 10, "missing": 0, "extra": 0}


def people(full=(100, 1), recall=(95, 100), per=25, sole=(9, 1)):
    return {"plays": dict(PLAYS), "people": {"full_right": full[0], "full_wrong": full[1], "full_by_predicate": {p: per for p in Q.person_predicates(REG)},
                       "recall_right": recall[0], "recall_truth": recall[1], "outside_lexicon": 0,
                       "sole_known_right": sole[0], "sole_known_wrong": sole[1], "forbidden": 0}}


def timeline(**kw):
    t = {"right": 30, "right_gap": 2, "decidable": 34, "negatives": 8, "wrong_answers": 0, "triggered": 0, "wrong_facts": 0,
         "wrong_dates": 1, "succession_untrusted": 0, "succession_cross_slot": 0, "succession_unexplained": 0, "inferred_ends": 2, "malformed": 0}
    t.update(kw)
    return t


def orgs(**kw):
    o = {"works_at_right": 60, "works_at_wrong": 0, "clients": 4, "clients_as_employer": 0, "clients_recorded": 3, "vendors": 4,
         "vendors_as_employer": 0, "vendors_as_client": 0}
    o.update(kw)
    return o


def reads(**sets):
    return {rd: copy.deepcopy(sets) for rd in ("r1", "r2")}


class RunChecks(unittest.TestCase):
    def test_good_runs_pass(self):
        self.assertEqual(Q.run_problems(runs(), MODEL, "people"), [])

    def test_each_fail_open_path_fails(self):
        cases = {
            "dirty": dict(commit="a" * 40 + "+dirty"), "replay": dict(mode="replay"), "alias": dict(models_reported=["claude-haiku-5-5-20261101"]),
            "unidentified": dict(responses_without_model=1), "partial": dict(options={"only": "p01"}),
            "natural": dict(options={"orders": "natural"}), "short": dict(plays=1), "fixture": dict(fixture_sha256="0" * 64),
            "groups": dict(groups=["work"]), "unsettled": dict(unsettled=2), "leak": dict(above_limit_in_payload=1),
            "secret limit": dict(limit="secret"),
            "registry": dict(registry_file="spikes/people/fixtures/canary-13a2/registry.json"),
            "engine": dict(engine={"model": "claude-code/claude-opus-5-5", "adapter": "x", "batching": "y"}),
        }
        for name, change in cases.items():
            rs = runs()
            rs[3].update(change)
            self.assertTrue(Q.run_problems(rs, MODEL, "people"), name)

    def test_disagreeing_or_repeated_runs_fail(self):
        rs = runs()
        rs[0]["prompt_versions"] = {"people": "p2", "work": "w1"}
        self.assertTrue(Q.run_problems(rs, MODEL, "people"))
        rs = runs()
        rs[1]["commit"] = "b" * 40
        self.assertTrue(Q.run_problems(rs, MODEL, "people"))
        rs = runs()
        rs[5]["run_id"] = rs[1]["run_id"]
        self.assertTrue(Q.run_problems(rs, MODEL, "people"))
        rs = runs(("mixed",))
        rs[0]["groups"] = ["work"]
        self.assertTrue(Q.run_problems(rs, MODEL, "people"))
        rs = runs(("mixed",))
        for m in rs:
            m["groups"] = ["people"]                     # a people-only run (Opus) carries a people record
        self.assertEqual(Q.run_problems(rs, MODEL, "people"), [])


    def test_the_record_key_and_the_lines_beside_each_run(self):
        rs = runs()
        rec = {"callGroup": "people", "model": MODEL, "adapter": "claude-code/1;effort=low", "batching": "one-memory;pipeline=1",
               "promptVersion": "p1", "registryVersion": "v1-x"}
        self.assertEqual(Q.run_problems(rs, MODEL, "people", record=rec), [])
        self.assertTrue(Q.run_problems(rs, MODEL, "people", record={**rec, "promptVersion": "p0"}))
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            m = manifest("main")
            (Path(d) / "main.jsonl").write_text("{}\n")
            m["lines_sha256"] = Q.sha(Path(d) / "main.jsonl")
            self.assertEqual(Q.run_problems([m], MODEL, "people", dirs=[d]), [])
            (Path(d) / "main.jsonl").write_text("{}\n{}\n")                  # lines removed or added after the run
            self.assertTrue(Q.run_problems([m], MODEL, "people", dirs=[d]))

    def test_reads_are_r1_to_rn(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            for name in ("swift-claude-claude-haiku-5-5-gates-r1", "swift-claude-claude-haiku-5-5-gates-r3"):
                (Path(d) / name).mkdir()
            with self.assertRaises(SystemExit):
                Q.reads_of(d, MODEL)
            (Path(d) / "swift-claude-claude-haiku-5-5-gates-r2").mkdir()
            self.assertEqual(sorted(Q.reads_of(d, MODEL)), ["r1", "r2", "r3"])

    def test_port_fidelity_report_is_bound(self):
        good = {"pass": True, "commit": "a" * 40, "pairs": [{"set": n.split()[0], "mode": n.split()[1], "plays": 3, "expected_plays": 3}
                                                            for n in Q.STANDARD_PAIRS]}
        self.assertEqual(Q.pf_problems(good, "a" * 40), [])
        self.assertTrue(Q.pf_problems({**good, "pass": False}, "a" * 40))
        self.assertTrue(Q.pf_problems(good, "b" * 40))
        self.assertTrue(Q.pf_problems({**good, "pairs": good["pairs"][1:]}, "a" * 40))
        self.assertTrue(Q.pf_problems({"pass": True}, "a" * 40))


class Thresholds(unittest.TestCase):
    def test_persons(self):
        good = reads(main=people(), astra=people(), mixed=people(), persons=people())
        self.assertEqual(Q.judge_gate("persons", good, REG), [])
        self.assertTrue(Q.judge_gate("persons", {"r1": good["r1"]}, REG))                       # one read
        for bad in (dict(full=(97, 3)), dict(recall=(89, 100)), dict(per=4)):            # pooled over all four sets
            r = reads(main=people(**bad), astra=people(**bad), mixed=people(**bad), persons=people(**bad))
            self.assertTrue(Q.judge_gate("persons", r, REG), bad)
        r = reads(main=people(), astra=people(), mixed=people(full=(9, 1)), persons=people())      # still met on mixed
        self.assertTrue(Q.judge_gate("persons", r, REG))
        r = reads(main=people(), astra=people(), mixed=people())                                    # a set missing
        self.assertTrue(Q.judge_gate("persons", r, REG))

    def test_sole_known_is_measured(self):
        good = reads(main=people(), astra=people(), mixed=people(), persons=people())
        self.assertEqual(Q.judge_gate("sole_known", good, REG), [])
        bad = reads(main=people(sole=(8, 2)), astra=people(sole=(8, 2)), mixed=people(sole=(8, 2)), persons=people(sole=(8, 2)))
        self.assertTrue(Q.judge_gate("sole_known", bad, REG))

    def test_plays_against_the_fixture_and_malformed_lines(self):
        good = reads(main=people(), astra=people(), mixed=people(), persons=people())
        bad = copy.deepcopy(good)
        bad["r1"]["persons"]["plays"]["missing"] = 1
        self.assertTrue(Q.judge_gate("persons", bad, REG))
        t = reads(work13={**people(), "timeline": timeline(malformed=1)}, mixed={**people(), "timeline": timeline()})
        self.assertTrue(Q.judge_gate("timeline", t, REG))

    def test_organizations_and_floors(self):
        good = reads(mixed={**people(), "orgs": orgs()}, work13={**people(), "orgs": orgs()})
        self.assertEqual(Q.judge_gate("client", good, REG), [])
        privacy = Q.REPO / "Packages/FunesCore/Tests/FunesCoreTests/FactsPrivacyGateTests.swift"
        if "withKnownIssue" in privacy.read_text():       # an open privacy finding blocks every record
            self.assertTrue(any("privacy" in b for b in Q.blockers()))
        self.assertEqual(Q.judge_gate("works_at", good, REG), [])
        for gate, bad in (("client", dict(vendors_as_client=1)), ("client", dict(clients=1)), ("client", dict(clients_recorded=0)),
                          ("works_at", dict(clients_as_employer=1)), ("works_at", dict(works_at_right=5)),
                          ("works_at", dict(works_at_right=95, works_at_wrong=5))):
            r = reads(mixed={**people(), "orgs": orgs(**bad)}, work13={**people(), "orgs": orgs(**bad)})
            self.assertTrue(Q.judge_gate(gate, r, REG), (gate, bad))

    def test_timeline_coverage_waiver(self):
        # 13e.1: the author waived the timeline's coverage target only, for one registry version, with a floor.
        import tempfile
        saved = Q.WAIVERS
        self.addCleanup(lambda: setattr(Q, "WAIVERS", saved))
        def waiver(**kw):
            w = {"gate": "timeline", "target": "decidable_coverage", "floor": 0.40, "registry_version": "v1-aaa"}
            w.update(kw)
            f = Path(tempfile.mkdtemp()) / "waivers.json"
            f.write_text(json.dumps({"waivers": [w]}))
            Q.WAIVERS = f
        waiver()
        low = reads(work13={**people(), "timeline": timeline(right=20)}, mixed={**people(), "timeline": timeline(right=16)})
        self.assertEqual(Q.judge_gate("timeline", low, REG, "v1-aaa"), [])
        self.assertTrue(Q.judge_gate("timeline", low, REG, "v1-bbb"))              # another registry: not waived
        none = reads(work13={**people(), "timeline": timeline(right=5, right_gap=0)}, mixed={**people(), "timeline": timeline()})
        self.assertTrue(Q.judge_gate("timeline", none, REG, "v1-aaa"))             # under the waiver's floor
        bad = reads(work13={**people(), "timeline": timeline(right=20, wrong_answers=1)}, mixed={**people(), "timeline": timeline()})
        self.assertTrue(Q.judge_gate("timeline", bad, REG, "v1-aaa"))
        waiver(floor=0.0)
        self.assertTrue(Q.judge_gate("timeline", none, REG, "v1-aaa"))             # a floor is never under 40%
        waiver(registry_version=None)
        self.assertTrue(Q.judge_gate("timeline", low, REG, "v1-aaa"))              # bound to nothing: waives nothing

    def test_timeline_and_floors(self):
        saved = Q.WAIVERS
        Q.WAIVERS = Path("/nonexistent/waivers.json")              # the targets as the table states them
        self.addCleanup(lambda: setattr(Q, "WAIVERS", saved))
        good = reads(work13={**people(), "timeline": timeline()}, mixed={**people(), "timeline": timeline(decidable=34)})
        self.assertEqual(Q.judge_gate("timeline", good, REG), [])
        for bad in (dict(wrong_facts=1), dict(wrong_dates=2), dict(right=25), dict(wrong_answers=1), dict(triggered=1),
                    dict(succession_untrusted=1), dict(succession_cross_slot=1), dict(succession_unexplained=1),
                    dict(decidable=20, right=19, right_gap=0), dict(negatives=2)):
            r = reads(work13={**people(), "timeline": timeline(**bad)}, mixed={**people(), "timeline": timeline()})
            self.assertTrue(Q.judge_gate("timeline", r, REG), bad)
        r = reads(work13={**people(), "timeline": timeline()}, mixed={**people(), "timeline": timeline(right=10)})
        self.assertTrue(Q.judge_gate("timeline", r, REG))                                          # still met on mixed


class LineMeasures(unittest.TestCase):
    """The measures themselves, on synthetic dumps (13e.1): full-basis works-at units, untrusted-only facts and episodes
    apart unless the story denies them, and one-to-one assignment of a rehire's episodes."""
    @staticmethod
    def day(s):
        from datetime import date
        return date.fromisoformat(s).toordinal()

    def ep(self, ent, start, end, mems, trusted=True):
        r = lambda a, b: [self.day(a), self.day(b), "day"] if a else None
        return {"predicate": "works_at", "entity": ent, "start": r(*start) if start else None, "end": r(*end) if end else None,
                "trusted": trusted, "memories": mems}

    def line(self, entities, facts, episodes, story="s1"):
        ents = [{"id": i, "kind": "organization", "name": n, "aliases": [n], "group": None, "count": None, "deceased": False}
                for i, n in entities]
        fs = [{"entity": e, "type": "works_at", "label": None, "cls": None, "only": False, "evidence": ev, "negated": False,
               "stating": [m for m, _ in ev], "assertions": [{"memory": m, "trust": t} for m, t in ev]} for e, ev in facts]
        st = {"user_aliases": [], "entities": ents, "facts": fs, "names": [], "decisions": [], "things": [], "memories": {},
              "episodes": episodes, "succession": {}}
        return {"story": story, "state": st, "swift_judged": {}, "swift_answers": {}}

    def story(self, memories, timeline):
        return {"s1": {"id": "s1", "memories": memories, "timeline": timeline, "queries": []}}

    def test_works_at_counts_full_basis_units_and_reports_untrusted_ones(self):
        st = self.story([{"id": "m1", "source": "capture", "organizations": [{"org": "Acme", "relation": "employer"}]},
                         {"id": "m2", "source": "agent", "organizations": [{"org": "Orlin", "relation": "employer"}]}],
                        [{"org": "Acme", "kind": "employee", "start": "2015", "end": "", "memories": ["m1"]}])
        ln = self.line([("p1", "Acme"), ("p2", "Orlin")], [("p1", [["m1", "trusted"]]), ("p2", [["m2", "untrusted"]])], [])
        o = Q.org_measures([ln], st, REG)
        self.assertEqual((o.get("works_at_right"), o.get("works_at_wrong", 0)), (1, 0))
        self.assertEqual((o.get("works_at_untrusted_right", 0), o.get("works_at_untrusted_wrong")), (0, 1))

    def test_untrusted_only_facts_are_apart_unless_the_story_denies_them(self):
        tl = [{"org": "Acme", "kind": "employee", "start": "2015", "end": "", "memories": ["m1"]}]
        mems = [{"id": "m1", "source": "capture", "jobs": []}, {"id": "m2", "source": "agent", "jobs": []}]
        ln = self.line([("p1", "Acme"), ("p2", "Orlin")], [("p1", [["m1", "trusted"]]), ("p2", [["m2", "untrusted"]])],
                       [self.ep("p1", ("2015-01-01", "2015-01-01"), None, ["m1"]),
                        self.ep("p2", ("2020-01-01", "2020-01-01"), ("2021-01-01", "2021-01-01"), ["m2"], trusted=False)])
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual((t["wrong_facts"], t["untrusted_wrong_facts"]), (0, 1))
        mems[0]["jobs"] = [{"org": "Orlin", "polarity": "negative"}]          # "I never worked at Orlin" in the user's note
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual((t["wrong_facts"], t["untrusted_wrong_facts"]), (1, 0))
        mems[0]["jobs"], mems[1]["jobs"] = [], [{"org": "Orlin", "polarity": "negative"}]   # an agent's denial doesn't count
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual(t["wrong_facts"], 0)

    def test_a_rehire_is_assigned_one_to_one(self):
        tl = [{"org": "Acme", "kind": "employee", "start": "2014", "end": "2016", "memories": ["m1", "m2"]},
              {"org": "Acme", "kind": "employee", "start": "2019-07-01", "end": "2024-04-30", "memories": ["m1", "m3"]}]
        mems = [{"id": m, "source": "capture", "jobs": []} for m in ("m1", "m2", "m3")]
        first = self.ep("p1", ("2014-01-01", "2014-12-31"), ("2016-12-31", "2016-12-31"), ["m2"])
        second = self.ep("p1", ("2019-07-01", "2019-07-01"), ("2024-04-30", "2024-04-30"), ["m1", "m3"])
        ln = self.line([("p1", "Acme")], [("p1", [["m1", "trusted"], ["m2", "trusted"], ["m3", "trusted"]])], [second, first])
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual((t["wrong_facts"], t["wrong_dates"]), (0, 0))       # m1 recalls both: the dates decide
        stray = self.ep("p1", ("2010-01-01", "2010-01-01"), ("2011-01-01", "2011-01-01"), ["m1"])
        ln = self.line([("p1", "Acme")], [("p1", [["m1", "trusted"], ["m2", "trusted"], ["m3", "trusted"]])], [second, first, stray])
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual(t["wrong_facts"], 1)                                # overlaps no stint of its organization
        dup = self.ep("p1", ("2019-07-01", "2019-07-01"), ("2024-04-30", "2024-04-30"), ["m3"])
        ln = self.line([("p1", "Acme")], [("p1", [["m1", "trusted"], ["m2", "trusted"], ["m3", "trusted"]])], [second, first, dup])
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual(t["wrong_facts"], 1)                                # a duplicate takes no stint: a wrong fact

    def test_an_episode_in_the_wrong_slot_is_a_wrong_fact(self):
        tl = [{"org": "Acme", "kind": "self_employed", "start": "2015", "end": "", "memories": ["m1"]}]
        mems = [{"id": "m1", "source": "capture", "jobs": []}]
        ep = {**self.ep("p1", ("2015-01-01", "2015-01-01"), None, ["m1"]), "slot": "employee"}
        ln = self.line([("p1", "Acme")], [("p1", [["m1", "trusted"]])], [ep])
        t = Q.timeline_measures([ln], self.story(mems, tl), REG)
        self.assertEqual(t["details"]["wrong_facts"], ["('s1', 'Acme', 'slot')"])
        ep["slot"] = "self_employed"
        self.assertEqual(Q.timeline_measures([ln], self.story(mems, tl), REG)["wrong_facts"], 0)

    def test_a_rename_the_story_labels_is_one_stint(self):
        """13e.2's scorer correction: a stated rename the story's trusted labels give ("Marlin Metrics" → "Marlin
        Analytics") is that stint's, as one entity or one timeline group; an agent's label, a merge the story doesn't
        make and a duplicate episode stay wrong."""
        tl = [{"org": "Lattice Analytics", "kind": "employee", "start": "2016", "end": "2022-06-30", "memories": ["m1", "m2"]}]
        label = {"id": "m2", "source": "capture", "organizations": [{"surface": "Lattice Metrics", "org": "Lattice Analytics",
                                                                    "relation": "employer"}],
                 "jobs": [{"org": "Lattice Analytics", "polarity": "positive", "also_called": "Lattice Metrics"}]}
        bare = {"id": "m2", "source": "capture", "organizations": [], "jobs": []}
        ep = self.ep("p1", ("2016-01-01", "2016-12-31"), ("2022-06-30", "2022-06-30"), ["m1", "m2"])
        facts = [("p1", [["m1", "trusted"]]), ("p2", [["m2", "trusted"]])]

        def grouped(members, extra=()):
            ln = self.line([("p1", "Lattice Metrics"), ("p2", "Lattice Analytics"), ("p3", "Orlin")], facts + list(extra), [ep])
            ln["state"]["timeline_groups"] = [members]
            return ln
        m1 = {"id": "m1", "source": "capture", "jobs": []}
        t = Q.timeline_measures([grouped(["p1", "p2"])], self.story([m1, label], tl), REG)
        self.assertEqual((t["wrong_facts"], t["wrong_dates"]), (0, 0), t["details"])
        t = Q.timeline_measures([grouped(["p1", "p2"])], self.story([m1, bare], tl), REG)
        self.assertEqual(t["wrong_facts"], 2, t["details"])                   # unlabelled: the old name and the merge
        agent = {**label, "source": "agent"}
        t = Q.timeline_measures([grouped(["p1", "p2"])], self.story([m1, agent], tl), REG)
        self.assertEqual(t["wrong_facts"], 2, t["details"])                   # only an agent's label: still wrong
        marked = {**label, "trust": "untrusted"}
        t = Q.timeline_measures([grouped(["p1", "p2"])], self.story([m1, marked], tl), REG)
        self.assertEqual(t["wrong_facts"], 2, t["details"])                   # an untrusted import's label: still wrong
        t = Q.timeline_measures([grouped(["p1", "p2", "p3"], [("p3", [["m1", "trusted"]])])], self.story([m1, label], tl), REG)
        self.assertIn("merged", " ".join(t["details"]["wrong_facts"]))        # a member the story doesn't rename
        dup = self.ep("p1", ("2016-01-01", "2016-12-31"), ("2022-06-30", "2022-06-30"), ["m1"])
        ln = self.line([("p1", "Lattice Metrics"), ("p2", "Lattice Analytics")], facts,
                       [self.ep("p2", ("2016-01-01", "2016-12-31"), ("2022-06-30", "2022-06-30"), ["m1", "m2"]), dup])
        t = Q.timeline_measures([ln], self.story([m1, label], tl), REG)
        self.assertEqual(t["wrong_facts"], 1, t["details"])                   # two episodes for one stint: one is wrong
        # Never by containment: a labelled "Lattice Metrics" isn't "Lattice Metrics Consulting", and "Lattice Analytics"
        # with "Lattice Analytics Consulting" is a merge the story doesn't make.
        ln = self.line([("p1", "Lattice Metrics Consulting"), ("p2", "Lattice Analytics")], facts, [ep])
        ln["state"]["timeline_groups"] = [["p1", "p2"]]
        t = Q.timeline_measures([ln], self.story([m1, label], tl), REG)
        self.assertEqual(t["wrong_facts"], 2, t["details"])
        ln = self.line([("p1", "Lattice Analytics Consulting"), ("p2", "Lattice Analytics")], facts, [ep])
        ln["state"]["timeline_groups"] = [["p1", "p2"]]
        t = Q.timeline_measures([ln], self.story([m1, bare], tl), REG)
        self.assertIn("merged", " ".join(t["details"]["wrong_facts"]), t["details"])
        # A labelled name a second stint (or a client) also has stops the scorer.
        clash = tl + [{"org": "Lattice Metrics", "kind": "client", "start": "2019", "end": "", "memories": ["m2"]}]
        with self.assertRaises(SystemExit):
            Q.timeline_measures([grouped(["p1", "p2"])], self.story([m1, label], clash), REG)
        suffixed = tl + [{"org": "Lattice Metrics Ltd", "kind": "vendor", "start": "", "end": "", "memories": []}]
        with self.assertRaises(SystemExit):                                   # the same once the legal suffix goes
            Q.timeline_measures([grouped(["p1", "p2"])], self.story([m1, label], suffixed), REG)
        o = Q.org_measures([grouped(["p1", "p2"])], self.story([{**m1, "organizations": [{"org": "Lattice Analytics", "relation": "employer"}]},
                                                                label], tl), REG)
        self.assertEqual((o.get("works_at_right"), o.get("works_at_wrong", 0)), (2, 0))
        o = Q.org_measures([grouped(["p1", "p2"])], self.story([m1, bare], tl), REG)
        self.assertEqual(o.get("works_at_wrong", 0), 1)                       # the old name's unit, unlabelled


class TimelineGateScoring(unittest.TestCase):
    """13e.2's scorer (score_13e2.py): §10.4's owed rule read from the record, and the label rule's minimums."""

    def test_the_owed_rule_from_the_record(self):
        import score_13e2 as S
        names = {"birch labs", "cedar systems"}
        claim = lambda text, made=None, cites=(): {"text": text, "citations": [{"memory": m} for m in cites],
                                                   **({} if made is None else {"comparisonMade": made})}
        self.assertTrue(S.owed(claim("Before Cedar Systems you worked at Birch Labs."), "Where did I work?", names, set()))
        self.assertTrue(S.owed(claim("Birch Labs."), "Where did I work in 2019?", names, set()))            # the search's year
        self.assertTrue(S.owed(claim("Birch Labs.", made=True), "anything", names, set()))
        self.assertTrue(S.owed(claim("A note.", cites=["m3"]), "anything", names, {"m3"}))                  # a rows-only memory
        # made: false: only the claim's own selection cue (a date is a qualifier).
        self.assertFalse(S.owed(claim("You joined Birch Labs in 2018.", made=False), "My title in 2019?", names, set()))
        self.assertTrue(S.owed(claim("After Birch Labs you went to Cedar Systems.", made=False), "?", names, set()))
        self.assertFalse(S.owed(claim("You were a designer.", made=None), "Where did I work in 2019?", names, set()))

    def test_the_corrected_set_must_keep_its_minimums(self):
        import score_13e2 as S
        qs = [{"id": f"q{i}", "traps": ["rehire"]} for i in range(3)]
        stories = {"s1": {"id": "s1", "queries": qs}}
        lab = {("s1", q["id"]): {"class": "undecidable"} for q in qs}
        probs = S.minimums(stories, lab)
        self.assertTrue(any("decidable questions" in p for p in probs) and any("rehire" in p for p in probs))


class TimelineRecordRules(unittest.TestCase):
    """The record step's rules (the author's decision of 2026-11-24): the commit a run measured, product code, and the
    author's waivers of the timeline gate."""

    def test_a_results_only_dirty_stamp_is_the_commit(self):
        sha = "a" * 40
        self.assertEqual(Q.measured_commit({"commit": sha + "+dirty", "dirty": False}), sha)
        self.assertEqual(Q.measured_commit({"commit": sha + "+dirty", "dirty": True}), sha + "+dirty")
        self.assertEqual(Q.measured_commit({"commit": sha + "+dirty"}), sha + "+dirty")     # no code flag: kept
        self.assertEqual(Q.measured_commit({"commit": sha, "dirty": False}), sha)
        self.assertIsNone(Q.product_code_changed_since(""))

    def test_product_code_leaves_out_tests_and_scripts(self):
        for f in ("Packages/FunesCore/Sources/FunesCore/Facts/TimelineCheck.swift", "Apps/FunesMac/App.swift",
                  "scripts/test.sh", "FunesVault.xcodeproj/project.pbxproj", "spikes/people/registry.json"):
            self.assertTrue(Q.is_product_code(f), f)
        for f in ("Packages/FunesCore/Tests/FunesCoreTests/Support/FactsGateEvidence.swift", "spikes/people/qualify.py",
                  "spikes/people/swift/Sources/x.swift"):
            self.assertFalse(Q.is_product_code(f), f)
        self.assertTrue(Q.is_product_code("spikes/people/sub/x.py"))    # only the spike's top-level scripts

    def test_a_replay_compares_the_revision_counter_only(self):
        self.assertEqual(Q.revision_counter("27f68ab7-4bda.27.w95Zpj_5"), "27")
        self.assertEqual(Q.revision_counter("2ceae9cc-df72.27.wDWe0g4F"), "27")
        self.assertNotEqual(Q.revision_counter("2ceae9cc-df72.28.wDWe0g4F"), "27")

    def test_a_waiver_caps_owed_checks_and_marking_only(self):
        w = {"waived": {"owed_checks": {"measure": "owed_skipped", "max": 2}, "marking": {"measure": "unmarked_inferred", "max": 1},
                        "someone_else": {"measure": "someone_else", "max": 5}}}
        gates = {"owed_checks": False, "marking": False, "someone_else": False, "p95": True}
        m = {"owed_skipped": 2, "unmarked_inferred": 1, "someone_else": 1}
        self.assertEqual(Q.unwaived_failures(gates, m, w), ["someone_else"])            # wrong answers are never waived
        self.assertEqual(Q.unwaived_failures(gates, {**m, "owed_skipped": 3}, w), ["owed_checks", "someone_else"])
        self.assertEqual(Q.unwaived_failures(gates, m, None), ["owed_checks", "marking", "someone_else"])
        wrong = {"waived": {"owed_checks": {"measure": "unmarked_inferred", "max": 9}}}  # the cap must be the target's measure
        self.assertEqual(Q.unwaived_failures({"owed_checks": False}, m, wrong), ["owed_checks"])

    def test_a_waiver_is_bound_to_model_prompt_registry_and_read(self):
        w = Q.timeline_waiver("claude-code/claude-haiku-5-5", "a13e2-3", "v1-8338de9d268e", "r4", "haiku")
        self.assertIsNotNone(w)
        self.assertEqual(set(w["waived"]), {"owed_checks", "marking"})
        for args in (("codex/gpt-5.6-terra", "a13e2-3", "v1-8338de9d268e", "r4"), ("claude-code/claude-haiku-5-5", "a13e2-4", "v1-8338de9d268e", "r4"),
                     ("claude-code/claude-haiku-5-5", "a13e2-3", "v1-000000000000", "r4"), ("claude-code/claude-haiku-5-5", "a13e2-3", "v1-8338de9d268e", "r5")):
            self.assertIsNone(Q.timeline_waiver(*args, "haiku"), args)
        # Bound to the answers it was given on: another engine's answers on the same read aren't covered.
        self.assertIsNone(Q.timeline_waiver("claude-code/claude-haiku-5-5", "a13e2-3", "v1-8338de9d268e", "r4", "terra"))


class Verify(unittest.TestCase):
    def test_shipped_records_are_13e2s_records_and_gate(self):
        # 13e.2's records step on 13e.1's code: the person pool, client and works at {recorded, linked}; then 13e.2's gate
        # (r4): attributes (unscoped and sole_known) and works at's timeline for each answer model.
        recs = json.loads(Q.RECORDS.read_text())["records"]
        shipped = sorted((r["callGroup"], tuple(r["uses"]), r.get("basis", ""), tuple(r.get("answerModels", []))) for r in recs)
        answer = [m for m in ("claude-code/claude-haiku-5-5", "codex/gpt-5.6-terra")]
        want = [("people", ("recorded", "linked"), "", ()), ("work", ("recorded",), "", ()), ("work", ("recorded", "linked"), "", ())]
        want += [("people", ("attributes",), b, (m,)) for m in answer for b in ("", "sole_known")]
        want += [("work", ("timeline",), "", (m,)) for m in answer]
        self.assertEqual(shipped, sorted(want))
        preds = {p for r in recs for p in r["predicates"]}
        self.assertTrue({"client", "works_at"} <= preds)
        self.assertEqual(Q.cmd_verify(None), 0)

    def test_a_record_without_a_13a2_gate_fails(self):
        r = {"predicates": ["partner"], "uses": ["attributes"], "basis": "sole_known", "callGroup": "people", "model": MODEL,
             "evidence": ["spikes/people/qualify.py", "spikes/people/missing/scores.json"]}
        self.assertTrue(Q.verify_record(r, REG))

    def test_an_attributes_record_needs_13d_evidence(self):
        r = {"predicates": ["partner"], "uses": ["attributes"], "basis": "", "callGroup": "people", "model": MODEL,
             "evidence": ["spikes/people/qualify.py"]}
        self.assertEqual(Q.verify_answer_record(r, REG), ["no scores-13d.json in the evidence"])

    def test_a_replay_on_a_dirty_tree_or_with_calls_fails(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            for gate, (sub, names) in Q.replay_files("haiku").items():
                (Path(d) / sub).mkdir(parents=True)
                (Path(d) / sub / f"manifest-{gate}.json").write_text(json.dumps(
                    {"mode": "dry", "uncached": 3, "dirty": True, "commit": "abc", "modelsReported": ["haiku"],
                     "responsesWithoutModel": 0, "options": {"engine": "haiku"}, "records": {}, "answerPromptVersion": "a13d-1"}))
            probs, _ = Q.replay_problems("haiku", MODEL, Path(d))
            self.assertTrue(any("not a full replay" in p for p in probs))
            self.assertTrue(any("dirty" in p for p in probs))
            self.assertTrue(any("reported" in p for p in probs))

    def test_a_model_is_identified_by_the_provider_or_by_its_full_requested_id(self):
        named = {"modelsReported": ["claude-haiku-5-5"], "responsesWithoutModel": 0, "engine": {"provider": "claude-code", "model": "haiku"}}
        self.assertTrue(Q.model_identified(named, MODEL))
        self.assertFalse(Q.model_identified({**named, "responsesWithoutModel": 2}, MODEL))
        asked = {"modelsReported": [], "responsesWithoutModel": 627, "engine": {"provider": "codex", "model": "gpt-5.6-terra"}}
        self.assertTrue(Q.model_identified(asked, "codex/gpt-5.6-terra"))
        # An alias that reports nothing identifies no model.
        self.assertFalse(Q.model_identified({**asked, "engine": {"provider": "claude-code", "model": "haiku"}}, MODEL))


if __name__ == "__main__":
    unittest.main()
