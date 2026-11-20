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

    def test_timeline_and_floors(self):
        good = reads(work13={**people(), "timeline": timeline()}, mixed={**people(), "timeline": timeline(decidable=34)})
        self.assertEqual(Q.judge_gate("timeline", good, REG), [])
        for bad in (dict(wrong_facts=1), dict(wrong_dates=2), dict(right=25), dict(wrong_answers=1), dict(triggered=1),
                    dict(succession_untrusted=1), dict(succession_cross_slot=1), dict(succession_unexplained=1),
                    dict(decidable=20, right=19, right_gap=0), dict(negatives=2)):
            r = reads(work13={**people(), "timeline": timeline(**bad)}, mixed={**people(), "timeline": timeline()})
            self.assertTrue(Q.judge_gate("timeline", r, REG), bad)
        r = reads(work13={**people(), "timeline": timeline()}, mixed={**people(), "timeline": timeline(right=10)})
        self.assertTrue(Q.judge_gate("timeline", r, REG))                                          # still met on mixed


class Verify(unittest.TestCase):
    def test_what_ships_verifies(self):
        # 13a.2's Gates step shipped Haiku's person pool {recorded, linked} and client {recorded}; works at missed.
        shipped = {(tuple(r["predicates"]), tuple(r["uses"])) for r in json.loads(Q.RECORDS.read_text())["records"]}
        self.assertEqual({p for ps, _ in shipped for p in ps} & {"works_at"}, set())
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
