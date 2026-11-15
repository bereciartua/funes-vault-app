#!/usr/bin/env python3
"""Spike H3: deterministic tests of facts.py's generic rules (no model calls). Canned extractions go through
facts.apply, then resolution and the timeline run as they would on a model's output.

    python3 test_facts.py            (or: python3 -m pytest test_facts.py)
"""
import json
import re
import tempfile
from pathlib import Path

import facts as F

HERE = Path(__file__).resolve().parent
DATED = F.R.timeline_preds()[0]                          # the registry's dated predicate (works at in v1)
SLOT = F.R.preds[DATED]["slot"]
SLOT_VALUES = F.R.preds[DATED]["qualifiers"][SLOT]["values"]


def fact(pred, name, start=None, end=None, status="unknown", slot=None, preceded_by=None, followed_by=None, label=None):
    quals = {k: None for k in F.group_qualifiers([pred])}
    if slot and SLOT in quals:
        quals[SLOT] = slot
    return {"quote": name, "predicate": pred, "entity": "name", "name": name, "label": label, "polarity": "positive",
            "status": status, "deceased": False, "only": False, "count": None, "time": None, "start": start, "end": end,
            "preceded_by": preceded_by, "followed_by": followed_by, "also_called": None, "qualifiers": quals}


def state_with(rows, trust="trusted"):
    s = F.State([])
    for i, (r, tr) in enumerate([(r, trust) if not isinstance(r, tuple) else r for r in rows]):
        mem = {"id": f"m{i}", "text": r["name"], "sent": r["name"], "written": "2026-01-01", "source": "capture", "trust": tr}
        s.memories[mem["id"]] = mem
        F.apply(s, mem, [], [], [r], [], {}, [])
    return s


def ent(s, name):
    return F.entity_matches(s, DATED, name)[0]


def name(s, eid):
    return s.entities[eid].name if eid else None


def test_side_business_does_not_end_day_job():
    emp, own = SLOT_VALUES
    s = state_with([fact(DATED, "Acme", "2018", slot=emp), fact(DATED, "MyShop", "2020", slot=own),
                    fact(DATED, "Initech", "2021", slot=emp)])
    eps = {name(s, e.entity): e for e in F.episodes(s, DATED)}
    assert eps["Acme"].inferred_end and eps["Acme"].end == 2021 * 12      # ended by the next job in its slot
    assert eps["MyShop"].end is None                                      # nothing in its slot followed it
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Acme" and basis == "inferred"


def test_successive_jobs_chain_but_concurrent_ones_end_nothing():
    emp = SLOT_VALUES[0]
    s = state_with([fact(DATED, "Acme", "2018", slot=emp), fact(DATED, "Globex", "2019", slot=emp),
                    fact(DATED, "Initech", "2021", slot=emp)])
    eps = {name(s, e.entity): e for e in F.episodes(s, DATED)}
    assert eps["Acme"].end == 2019 * 12 and eps["Globex"].end == 2021 * 12      # A, then B, then C
    s = state_with([fact(DATED, "Acme", "2018", status="current", slot=emp), fact(DATED, "Globex", "2019", slot=emp),
                    fact(DATED, "Initech", "2021", slot=emp)])
    eps = {name(s, e.entity): e for e in F.episodes(s, DATED)}
    assert eps["Globex"].end is None          # Acme was still open when Initech started: which one ended is unknown
    assert F.before(s, DATED, ent(s, "Initech")) == (None, "ambiguous")


def test_succession_never_ends_a_fact_stated_as_former():
    emp = SLOT_VALUES[0]
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former", slot=emp), fact(DATED, "Globex", "2016", status="former", slot=emp),
                    fact(DATED, "Initech", "2019", slot=emp)])
    eps = {name(s, e.entity): e for e in F.episodes(s, DATED)}
    assert eps["Globex"].end is None and not eps["Globex"].inferred_end    # ended, but when isn't known
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Acme" and basis == "ordered"


def test_untrusted_never_triggers_succession():
    emp = SLOT_VALUES[0]
    s = state_with([fact(DATED, "Acme", "2018", slot=emp), (fact(DATED, "Initech", "2021", slot=emp), "untrusted")])
    eps = {name(s, e.entity): e for e in F.episodes(s, DATED)}
    assert eps["Acme"].end is None


def test_gap_is_told():
    s = state_with([fact(DATED, "Acme", "2015", "January 2016", "former"), fact(DATED, "Initech", "June 2016")])
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Acme" and basis == "gap"


def test_tie_at_written_precision_is_ambiguous():
    s = state_with([fact(DATED, "Acme", "2015", "2019", "former"), fact(DATED, "Globex", "2016", "March 2019", "former"),
                    fact(DATED, "Initech", "2020")])
    assert F.before(s, DATED, ent(s, "Initech")) == (None, "ambiguous")   # "2019" may be before or after March 2019


def test_month_precision_decides():
    s = state_with([fact(DATED, "Acme", "2015", "February 2019", "former"), fact(DATED, "Globex", "2016", "December 2019", "former"),
                    fact(DATED, "Initech", "January 2020")])
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Globex" and basis == "ordered"


def test_current_or_overlapping_never_before():
    s = state_with([fact(DATED, "Acme", "2015", status="current"), fact(DATED, "Initech", "2020")])
    assert F.before(s, DATED, ent(s, "Initech"))[0] is None


def test_stated_edge_wins_and_contradictions_fall_back_to_dates():
    s = state_with([fact(DATED, "Acme", "2015", "2017", "former"), fact(DATED, "Globex", "2016", "2017", "former"),
                    fact(DATED, "Initech", "2018", preceded_by="Globex")])      # the dates tie; the stated edge decides
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Globex" and basis == "stated"
    s = state_with([fact(DATED, "Acme", "2015", "June 2017", "former", followed_by="Initech"),
                    fact(DATED, "Initech", "July 2017", preceded_by="Acme"), fact(DATED, "Acme", followed_by=None, preceded_by="Initech")])
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Acme" and basis == "ordered"                    # the cycle is dropped; dates decide


def test_conflicting_end_is_ambiguous():
    s = state_with([fact(DATED, "Acme", "2015", "March 2019", "former"), fact(DATED, "Acme", end="May 2019", status="former"),
                    fact(DATED, "Initech", "June 2019")])
    assert F.before(s, DATED, ent(s, "Initech")) == (None, "ambiguous")


def test_same_date_at_two_precisions_is_not_a_conflict():
    s = state_with([fact(DATED, "Acme", "2015", "2019", "former"), fact(DATED, "Acme", end="June 2019", status="former"),
                    fact(DATED, "Initech", "July 2019")])
    got, basis = F.before(s, DATED, ent(s, "Initech"))
    assert name(s, got) == "Acme" and basis == "ordered"


def test_rejoin_is_a_second_episode():
    s = state_with([fact(DATED, "Acme", "2014", "2016", "former"), fact(DATED, "Globex", "2017", "2019", "former"),
                    fact(DATED, "Acme", "2020", "2021", "former")])
    assert len([e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"]) == 2
    got, _ = F.before(s, DATED, ent(s, "Acme"), "before I returned to Acme")
    assert name(s, got) == "Globex"
    assert F.before(s, DATED, ent(s, "Acme"), "before Acme")[0] is None      # which Acme? told, not guessed


def _person_pred(exclusive):
    return next(p for p in F.R.preds if F.R.kind_of(p) == "person" and F.R.preds[p].get("exclusive", False) == exclusive
                and any(not e.get("plural") for e in F.R.preds[p]["lexicon"]) and F.R.preds[p]["lexicon"])


def _role_state(pred, word):
    s = F.State([])
    text = f"My {word} Robin called."
    mem = {"id": "m1", "text": text, "sent": text, "written": "2026-01-01", "source": "capture"}
    s.memories["m1"] = mem
    phrases = F.role_phrases(text, [])
    p = {"name": "Robin", "quote": "Robin", "person": "new"}
    r = {**fact(pred, "Robin"), "entity": "name", "label": word, "quote": f"My {word} Robin"}
    F.apply(s, mem, phrases, [p], [r], [], {}, [])
    text2 = f"My {word} likes tea."
    m2 = {"id": "m2", "text": text2, "sent": text2, "written": "2026-02-01", "source": "capture"}
    s.memories["m2"] = m2
    return s, m2, F.role_phrases(text2, [])[0]


def test_exclusive_predicate_resolves_stated_unique_others_sole_known():
    ex = _person_pred(True)
    word = next(w for e in F.R.preds[ex]["lexicon"] if not e.get("plural") and e.get("cls") is None for w in e["words"])
    s, m, ph = _role_state(ex, word)
    assert s.resolve(m, ph)[1] == "stated_unique"
    other = next(p for p in F.R.preds if F.R.kind_of(p) == "person" and not F.R.preds[p].get("exclusive")
                 and any(e.get("cls") and not e.get("exclusive") and not e.get("plural") for e in F.R.preds[p]["lexicon"]))
    word2 = next(w for e in F.R.preds[other]["lexicon"] if e.get("cls") and not e.get("exclusive") and not e.get("plural") for w in e["words"])
    s, m, ph = _role_state(other, word2)
    assert s.resolve(m, ph)[1] == "sole_known"


def test_date_cue_needs_the_timeline_use():
    words = [w for w, v in F.R.lex.items() if v[0] == DATED]
    cue = F.R.lang["date_cue_words"][0]
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Initech", "2019", status="current")])
    text = f"At my {cue} {words[0]} I used Emacs."
    mem = {"id": "mx", "text": text, "sent": text, "written": "2020-06-01", "source": "capture"}
    ph = F.role_phrases(text, [])[0]
    pid, basis = s.resolve(mem, ph)
    assert name(s, pid) == "Acme" and basis == "inferred"
    reg = json.loads((HERE / "registry.json").read_text())
    for p in reg["predicates"]:
        if p["id"] == DATED:
            p["uses"] = [u for u in p["uses"] if u != "timeline"]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(reg, f)
    try:
        F.set_registry(f.name)
        pid, basis = s.resolve(mem, F.role_phrases(text, [])[0])
        assert basis != "inferred"                       # without the use, the cue is only a status cue (former)
    finally:
        F.set_registry(HERE / "registry.json")


def test_intent_negatives_and_positives():
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Initech", "2019", status="current")])
    assert F.intent("What was my job before Initech?", s)[:2] == (DATED, "before")
    assert F.intent("What was I doing right before joining Initech?", s)[:2] == (DATED, "before")
    assert F.intent("What was my title at Initech before the promotion?", s) is None
    assert F.intent("What did we use before Initech moved to Slack?", s) is None
    assert F.intent("What do I need to do before the Initech demo?", s) is None


def test_no_code_names_a_predicate():
    src = (HERE / "facts.py").read_text()
    src = src.replace('"enum": ["pet", "organization", "place", "product", "other"]', "")   # the things' kind, not a predicate
    strings = set(re.findall(r'"([a-z_]+)"', src)) | set(re.findall(r"'([a-z_]+)'", src))
    named = strings & set(F.R.preds)
    assert not named, f"facts.py names predicates: {named}"


if __name__ == "__main__":
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_")]
    bad = 0
    for n, f in tests:
        try:
            f()
            print("ok  ", n)
        except AssertionError as e:
            bad += 1
            print("FAIL", n, e)
    print(f"{len(tests) - bad}/{len(tests)} passed")
    raise SystemExit(1 if bad else 0)
