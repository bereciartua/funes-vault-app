#!/usr/bin/env python3
"""Spike H3b: every counterexample GPT-6-Astra and Fable 5.2 found in H3's time model, as a test. No model calls.

    python3 test_temporal.py
"""
import facts as F
from test_facts import DATED, SLOT_VALUES, ent, fact, name, state_with

EMP, OWN = SLOT_VALUES
PERSON_EXCLUSIVE = next(p for p in F.R.preds if F.R.kind_of(p) == "person" and F.R.preds[p].get("exclusive"))
PERSON_SUCC = next(p for p in F.R.preds if F.R.kind_of(p) == "person" and F.R.preds[p].get("succession")
                   and not F.R.preds[p].get("exclusive"))


def word(pred):
    return next(w for e in F.R.preds[pred]["lexicon"] if e.get("cls") is None and not e.get("plural") for w in e["words"])


def before(s, x, q=""):
    got, basis = F.before(s, DATED, ent(s, x), q)
    return name(s, got), basis


def after(s, x, q=""):
    got, basis = F.after(s, DATED, ent(s, x), q)
    return name(s, got), basis


# --- dates are ranges ---------------------------------------------------------------------------------------------------
def test_same_year_hand_over_is_not_skipped():           # Fable H1
    s = state_with([fact(DATED, "Globex", "2015", "2018", "former"), fact(DATED, "Acme", "2019", "2019", "former"),
                    fact(DATED, "Initech", "2019")])
    assert before(s, "Initech")[0] != "Globex"              # Acme may sit in between: told, not Globex


def test_a_competitor_that_may_end_later_counts():       # Astra 4
    s = state_with([fact(DATED, "Acme", "2018", "March 2020", "former"), fact(DATED, "Globex", "2017", "2020", "former"),
                    fact(DATED, "Initech", "April 2020")])
    assert before(s, "Initech") == (None, "ambiguous")


def test_half_dated_former_competitor_counts():          # Astra 4, Fable M2
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Globex", "2016", status="former"),
                    fact(DATED, "Initech", "June 2019")])
    assert before(s, "Initech") == (None, "ambiguous")


def test_months_are_not_read_from_prose():               # Fable M3
    assert F.parse_date("married in 2015") == F.parse_date("2015")
    assert F.parse_date("separated in 2019") == F.parse_date("2019")
    assert F.parse_date("decided in 2018") == F.parse_date("2018")
    assert F.parse_date("2019-20") == F.parse_date("2019")
    assert F.parse_date("March 2019") != F.parse_date("2019")
    assert F.parse_date("marzo de 2019") == F.parse_date("March 2019")


# --- episodes come from assertion intervals ----------------------------------------------------------------------------
def test_merging_doesnt_erase_an_episode():              # Astra 3
    s = state_with([fact(DATED, "Acme", "2020", "March 2020", "former"), fact(DATED, "Globex", "April 2020", "August 2020", "former"),
                    fact(DATED, "Acme", "September 2020", status="current")])
    assert len([e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"]) == 2


def test_an_end_before_the_first_start_is_kept():        # Fable M1
    s = state_with([fact(DATED, "Acme", end="December 2016", status="former"), fact(DATED, "Acme", "2020", status="current"),
                    fact(DATED, "Globex", "January 2017", "2019", "former")])
    acme = sorted([e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"], key=lambda e: e.sort_key())
    assert len(acme) == 2 and acme[0].end is not None


def test_a_rejoin_reopens_the_fact_for_role_resolution():   # Astra 2, Fable H3
    s = state_with([fact(DATED, "Acme", "2014", "2016", "former"), fact(DATED, "Globex", "2017", "2019", "former"),
                    fact(DATED, "Acme", "2020", status="current")])
    text = f"At my {word(DATED)} I use Emacs."
    mem = {"id": "mx", "text": text, "sent": text, "written": "2021-06-01", "source": "capture"}
    pid, basis = s.resolve(mem, F.role_phrases(text, [])[0])
    assert name(s, pid) == "Acme"


# --- trust per date and edge -------------------------------------------------------------------------------------------
def test_an_untrusted_start_never_drives_succession():   # Astra 1
    s = state_with([fact(DATED, "Acme", "2018", slot=EMP), fact(DATED, "Globex", slot=EMP),
                    (fact(DATED, "Globex", "2020", slot=EMP), "untrusted")])
    acme = [e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"][0]
    assert not acme.inferred_end


def test_an_untrusted_edge_is_never_stated():            # Fable H2
    s = state_with([fact(DATED, "Acme", "2015", "2017", "former"), fact(DATED, "Globex", "2016", "2017", "former"),
                    (fact(DATED, "Initech", "2018", preceded_by="Globex"), "untrusted")])
    assert before(s, "Initech")[1] != "stated"


# --- succession --------------------------------------------------------------------------------------------------------
def test_still_current_in_the_successors_month_blocks_succession():   # Astra 4
    s = state_with([fact(DATED, "Acme", "2018", slot=EMP)])
    late = {"id": "late", "text": "Acme", "sent": "Acme", "written": "2021-06-30", "source": "capture", "trust": "trusted"}
    s.memories["late"] = late
    F.apply(s, late, [], [], [fact(DATED, "Acme", status="current", slot=EMP)], [], {}, [])
    s2 = {"id": "next", "text": "Initech", "sent": "Initech", "written": "2021-07-01", "source": "capture", "trust": "trusted"}
    s.memories["next"] = s2
    F.apply(s, s2, [], [], [fact(DATED, "Initech", "June 2021", slot=EMP)], [], {}, [])
    acme = [e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"][0]
    assert not acme.inferred_end


def test_an_assumed_handover_start_never_bounds_an_end():   # found replaying the mixed fixture (x07)
    s = state_with([fact(DATED, "Amber", "2016", "2018", "former"), fact(DATED, "Kelp", "February 2023", status="current"),
                    fact(DATED, "Slate", status="former")])     # undated, ended: could sit between Amber and Kelp
    assert before(s, "Kelp")[0] != "Amber"


# --- order edges per episode, with cycles ------------------------------------------------------------------------------
def test_a_longer_cycle_is_not_stated():                 # Astra 5
    s = state_with([fact(DATED, "Acme", followed_by="Globex"), fact(DATED, "Globex", followed_by="Initech"),
                    fact(DATED, "Initech", followed_by="Acme")])
    assert before(s, "Globex")[1] != "stated"


def test_a_stated_predecessor_that_overlaps_doesnt_win():   # Astra 5
    s = state_with([fact(DATED, "Acme", "2015", status="current"), fact(DATED, "Initech", "2019", preceded_by="Acme")])
    assert before(s, "Initech")[1] != "stated"


# --- one resolver for roles, previous, before / after ------------------------------------------------------------------
def test_a_reference_before_a_stated_start_is_not_certain():   # Astra 2
    s = F.State([])
    for i, (text, written, r) in enumerate([
            ("Sky is my partner since September 2021.", "2021-10-01",
             {**fact(PERSON_EXCLUSIVE, "Sky", "September 2021", status="current"), "quote": "Sky is my partner since September 2021."})]):
        mem = {"id": f"m{i}", "text": text, "sent": text, "written": written, "source": "capture"}
        s.memories[mem["id"]] = mem
        F.apply(s, mem, F.role_phrases(text, []), [{"name": "Sky", "quote": "Sky", "person": "new"}], [r], [], {}, [])
    text = f"My {word(PERSON_EXCLUSIVE)} loves jazz."
    mem = {"id": "old", "text": text, "sent": text, "written": "2021-03-01", "source": "capture"}
    assert s.resolve(mem, F.role_phrases(text, [])[0])[1] != "stated_unique"


def test_previous_uses_the_same_safeguards():            # Fable M4
    s = state_with([fact(DATED, "Acme", "2015", "2019", "former"), fact(DATED, "Globex", "2016", "March 2019", "former"),
                    fact(DATED, "Initech", "2020", status="current")])
    assert F.previous_as_of(s, DATED, "2020-06-01") is None


def test_deceased_doesnt_override_an_explicit_end():     # Astra 7
    s = F.State([])
    text = "Robin was my former boss and later died."
    mem = {"id": "m1", "text": text, "sent": text, "written": "2025-01-01", "source": "capture"}
    s.memories["m1"] = mem
    r = {**fact(PERSON_SUCC, "Robin", status="former"), "deceased": True, "quote": text}
    F.apply(s, mem, F.role_phrases(text, []), [{"name": "Robin", "quote": "Robin", "person": "new"}], [r], [], {}, [])
    assert s.facts[0].status == "former"


def test_a_present_negative_ends_rather_than_denies():   # found replaying the canary (c08)
    s = F.State([])
    for i, (text, r) in enumerate([("Petra was my girlfriend.", fact(PERSON_EXCLUSIVE, "Petra", status="unknown")),
                                   ("Petra and I have not resumed our relationship.", {**fact(PERSON_EXCLUSIVE, "Petra", status="current"), "polarity": "negative"})]):
        mem = {"id": f"m{i}", "text": text, "sent": text, "written": f"2025-0{i + 1}-01", "source": "capture"}
        s.memories[mem["id"]] = mem
        F.apply(s, mem, [], [{"name": "Petra", "quote": "Petra", "person": "new" if i == 0 else "p1"}], [{**r, "quote": text}], [], {"p1": s.entities.get("p1")} if i else {}, [])
    assert not s.facts[0].negated and s.facts[0].status == "former"


# --- intent -----------------------------------------------------------------------------------------------------------
def _state():
    return state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Initech", "2019", status="current")])


def test_someone_elses_fact_for_every_operator():        # Astra 6, Fable M5
    s = _state()
    ada = {"id": "ma", "text": "Ada Pell is a friend.", "sent": "Ada Pell is a friend.", "written": "2025-01-01", "source": "capture"}
    s.memories["ma"] = ada
    F.apply(s, ada, [], [{"name": "Ada Pell", "quote": "Ada Pell", "person": "new"}], [], [], {}, [])
    assert F.intent("Where does Ada work now?", s) is None
    assert F.intent("What was Ada's previous job?", s) is None
    assert F.intent("Where did Zoe work before Initech?", s) is None     # an unknown name is someone else too
    assert F.intent("Where did my wife work before Initech?", s) is None


def test_the_anchor_ends_the_operator_phrase():          # Fable M5
    s = _state()
    assert F.intent("What did I work on before the Initech demo?", s) is None
    assert F.intent("What was my job before Initech moved offices?", s) is None
    assert F.intent("What was my job before Initech?", s)[:2] == (DATED, "before")
    assert F.intent("Where did I work after leaving Acme the first time?", s)[:2] == (DATED, "after")


def test_date_anchors_and_year_current_previous():       # Astra 6, Fable M5
    s = _state()
    it = F.intent("What job did I have before 2019?", s)
    assert it and it[1] == "before"
    assert F.answer(s, it, "What job did I have before 2019?")[0] == ent(s, "Acme")
    it = F.intent("Where was I working in 2016?", s)
    assert it and it[1] == "year" and F.answer(s, it, "Where was I working in 2016?")[0] == ent(s, "Acme")
    it = F.intent("What is my current job?", s)
    assert it and it[1] == "current" and F.answer(s, it, "What is my current job?")[0] == ent(s, "Initech")
    it = F.intent("What was my previous job?", s)
    assert it and it[1] == "previous" and F.answer(s, it, "What was my previous job?")[0] == ent(s, "Acme")


# --- round 2: counterexamples from the reviews of H3b ---------------------------------------------------------------------
PERSON_PLAIN = next(p for p in F.R.preds if F.R.kind_of(p) == "person" and F.R.preds[p].get("succession")
                    and not F.R.preds[p].get("exclusive"))


def people_state(rows):
    """rows: (name, start, end, status, written) for PERSON_PLAIN facts."""
    s = F.State([])
    for i, (nm, st, en, status, written) in enumerate(rows):
        text = f"{nm} memory {i}"
        mem = {"id": f"m{i}", "text": text, "sent": text, "written": written, "source": "capture", "trust": "trusted"}
        s.memories[mem["id"]] = mem
        known = [e for e in s.entities.values() if e.name == nm]
        p = {"name": nm, "quote": nm, "person": known[0].id if known else "new"}
        ids = {known[0].id: known[0]} if known else {}
        F.apply(s, mem, [], [p], [{**fact(PERSON_PLAIN, nm, st, en, status), "quote": nm}], [], ids, [])
    return s


def resolve_text(s, text, written):
    mem = {"id": "q", "text": text, "sent": text, "written": written, "source": "capture"}
    pid, basis = s.resolve(mem, F.role_phrases(text, [])[0])
    return name(s, pid), basis


def test_current_cue_is_evaluated_at_the_memory_date():      # Astra H1
    s = people_state([("Ana", "2015", "2019", "former", "2020-01-01"), ("Bo", "2021", None, "current", "2021-06-01")])
    w = word(PERSON_PLAIN)
    assert resolve_text(s, f"My current {w} likes tea.", "2018-06-01")[0] != "Bo"


def test_a_month_cue_is_a_range_and_needs_a_preposition():   # Fable 1
    s = people_state([("Ana", "2015", "March 2019", "former", "2019-04-01"), ("Bo", "March 2019", None, "current", "2019-04-02")])
    w = word(PERSON_PLAIN)
    assert resolve_text(s, f"In February 2019 my {w} approved the plan.", "2019-05-01")[0] != "Bo"
    assert resolve_text(s, f"My {w} approved the 2030 roadmap.", "2018-06-01")[0] != "Bo"


def test_an_undated_departure_with_two_possible_episodes_is_uncertain():   # Astra H2
    s = state_with([fact(DATED, "Acme", "2010", "2012", "former"), (fact(DATED, "Acme", "2020", status="current"), "trusted", "2020-06-01"),
                    (fact(DATED, "Acme", status="former"), "trusted", "2023-06-01")])
    it = F.intent("What is my current job?", s)
    got, basis = F.answer(s, it, "What is my current job?")
    assert got is None or basis != "ordered"


def test_untrusted_status_never_enables_succession():        # Astra H3
    s = state_with([(fact(DATED, "Acme", "2018", slot=EMP), "trusted", "2018-06-01"),
                    (fact(DATED, "Initech", "2020", status="current", slot=EMP), "trusted", "2020-06-01"),
                    (fact(DATED, "Acme", status="current", slot=EMP), "untrusted", "2018-07-01")])
    acme = [e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"][0]
    assert not acme.inferred_end


def test_another_holder_as_subject_is_someone_else():        # Astra H4
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Initech", "2019", status="current")])
    ada = {"id": "ma", "text": "Ada Pell", "sent": "Ada Pell", "written": "2025-01-01", "source": "capture"}
    s.memories["ma"] = ada
    F.apply(s, ada, [], [{"name": "Ada Pell", "quote": "Ada Pell", "person": "new"}], [], [], {}, [])
    assert F.intent("Where did Ada work before Initech?", s) is None


def test_a_holder_as_subject_is_someone_else():           # Astra H4, with the canary's partner timeline
    F.set_registry(F.HERE / "registry-canary-datafix.json")
    try:
        part = next(p for p in F.R.timeline_preds() if F.R.kind_of(p) == "person")
        s = F.State([])
        for i, (nm, st, en, status) in enumerate([("Ada", "2018", "2019", "former"), ("Bea", "2020", None, "current")]):
            mem = {"id": f"m{i}", "text": nm, "sent": nm, "written": "2021-01-01", "source": "capture"}
            s.memories[mem["id"]] = mem
            F.apply(s, mem, [], [{"name": nm, "quote": nm, "person": "new"}], [{**fact(part, nm, st, en, status), "quote": nm}], [], {}, [])
        assert F.intent("Who was Ada dating before Bea?", s) is None
        assert F.intent("Who was I dating before Bea?", s)
    finally:
        F.set_registry(F.HERE / "registry.json")


def test_a_month_in_a_year_question_is_kept():               # Astra H5, Fable 3
    s = state_with([fact(DATED, "Acme", "2018", "January 2019", "former"), fact(DATED, "Initech", "February 2019", status="current")])
    q = "Where was I working in March 2019?"
    assert F.answer(s, F.intent(q, s), q)[0] == ent(s, "Initech")


def test_previous_and_before_agree():                        # Astra M
    s = state_with([(fact(DATED, "Acme", "2018", status="current", slot=EMP), "trusted", "2018-06-01"),
                    (fact(DATED, "Globex", "2020", status="current", slot=EMP), "trusted", "2020-06-01"),
                    (fact(DATED, "Initech", "2022", status="current", slot=EMP), "trusted", "2022-06-01")])
    q = "What was my previous job?"
    assert F.answer(s, F.intent(q, s), q)[0] == F.before(s, DATED, ent(s, "Initech"))[0] == ent(s, "Globex")


def test_day_dates_keep_their_day():                         # Astra M
    assert F.parse_date("March 15, 2019").precision == "day"


def test_a_date_anchor_answers_with_the_job_held_then():     # Fable 2
    s = state_with([fact(DATED, "Old", "2005", "2009", "former"), fact(DATED, "Acme", "2010", "2020", "former"),
                    fact(DATED, "New", "2021", status="current")])
    for q in ("What job did I have before 2019?", "What job did I have after 2012?"):
        assert F.answer(s, F.intent(q, s), q)[0] == ent(s, "Acme")


def test_a_stated_edge_loses_to_a_job_certainly_between():   # Fable 4
    s = state_with([fact(DATED, "Acme", "2014", "April 2016", "former"), fact(DATED, "Globex", "May 2016", "May 2016", "former"),
                    fact(DATED, "Initech", "June 2016", preceded_by="Acme")])
    assert before(s, "Initech")[0] != "Acme"


def test_a_bound_end_starts_after_the_last_held_day():       # Fable 5
    s = people_state([("Ana", None, None, "current", "2016-06-01"), ("Ana", None, None, "former", "2020-06-01")])
    w = word(PERSON_PLAIN)
    assert resolve_text(s, f"My former {w} called.", "2015-06-01")[0] != "Ana"


def test_a_time_value_isnt_an_end():                         # Fable 6
    s = people_state([("Ana", None, None, "current", "2020-01-01"), ("Bo", None, None, "current", "2020-01-02")])
    mem = {"id": "t", "text": "In 2019 Ana gave me a raise", "sent": "In 2019 Ana gave me a raise", "written": "2021-01-01", "source": "capture"}
    s.memories["t"] = mem
    ana = [e for e in s.entities.values() if e.name == "Ana"][0]
    F.apply(s, mem, [], [{"name": "Ana", "quote": "Ana", "person": ana.id}],
            [{**fact(PERSON_PLAIN, "Ana", status="unknown"), "time": "2019", "quote": "Ana"}], [], {ana.id: ana}, [])
    w = word(PERSON_PLAIN)
    assert resolve_text(s, f"My {w} is on leave.", "2022-01-01")[1] == "candidates"


def test_after_and_before_treat_undated_facts_alike():       # Fable 8
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Initech", "2019", status="current"),
                    fact(DATED, "Mystery", status="former")])
    assert after(s, "Acme")[0] is None and before(s, "Initech")[0] is None


def test_a_return_doesnt_succeed_itself():                   # Fable 9
    s = state_with([(fact(DATED, "Acme", "2010", status="current"), "trusted", "2011-01-01"),
                    ({**fact(DATED, "Acme", "2015", status="current"), "quote": "I rejoined Acme in 2015"}, "trusted", "2015-06-01")])
    first = sorted([e for e in F.episodes(s, DATED) if name(s, e.entity) == "Acme"], key=lambda e: e.sort_key())[0]
    assert not first.inferred_end


def test_a_same_year_hand_over_with_nothing_else_is_answered():   # Fable 10
    s = state_with([fact(DATED, "Acme", "2015", "2019", "former"), fact(DATED, "Initech", "2019", status="current")])
    assert before(s, "Initech")[0] == "Acme" and after(s, "Acme")[0] == "Initech"


def test_sentence_initial_capitals_dont_kill_intent():       # Fable 11
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Initech", "2019", status="current")])
    assert F.intent("Quick one. What was my job before Initech?", s)


# --- round 3: Fable's final check of round 2 ---------------------------------------------------------------------------
def test_a_distant_year_doesnt_redate_the_phrase():          # 1
    s = people_state([("Ana", "2015", "2020", "former", "2020-12-01"), ("Bo", "2021", None, "current", "2021-06-01")])
    w = word(PERSON_PLAIN)
    assert resolve_text(s, f"My {w} said sales dropped in 2019.", "2022-03-01")[0] == "Bo"
    assert resolve_text(s, f"My {w} in 2019 was strict.", "2022-03-01")[0] == "Ana"


def test_an_entity_holds_through_any_episode_covering_the_date():   # 2
    s = state_with([fact(DATED, "Initech", "2010", "2018", "former"), fact(DATED, "Acme", "2014", "2016", "former"),
                    (fact(DATED, "Acme", "2020", status="current"), "trusted", "2020-06-01")])
    text = f"At my {word(DATED)} I use Emacs."
    mem = {"id": "q", "text": text, "sent": text, "written": "2015-06-01", "source": "capture"}
    assert s.resolve(mem, F.role_phrases(text, [])[0])[1] == "candidates"


def test_no_handover_when_the_memory_gives_a_time():          # 3
    s = people_state([("Ana", None, None, "current", "2020-01-01")])
    mem = {"id": "t", "text": "Bob", "sent": "Bob", "written": "2022-01-01", "source": "capture"}
    s.memories["t"] = mem
    F.apply(s, mem, [], [{"name": "Bob", "quote": "Bob", "person": "new"}],
            [{**fact(PERSON_PLAIN, "Bob", status="unknown"), "time": "2015", "quote": "Bob"}], [], {}, [])
    assert not any(e.handover for e in F.episodes(s, PERSON_PLAIN))


def test_an_untrusted_departure_doesnt_hide_a_current_job():   # 4
    s = state_with([fact(DATED, "Acme", "2014", "2016", "former", slot=EMP), (fact(DATED, "Acme", "2020", status="current", slot=EMP), "trusted", "2020-06-01"),
                    (fact(DATED, "MyShop", "2021", status="current", slot=OWN), "trusted", "2021-06-01"),
                    (fact(DATED, "Acme", status="former"), "untrusted", "2023-01-01")])
    got, basis = F.answer(s, F.intent("Where do I work now?", s), "Where do I work now?")
    assert got is None or (isinstance(got, list) and ent(s, "Acme") in got)


def test_a_date_anchor_with_a_job_that_may_have_started_is_told():   # 5
    s = state_with([fact(DATED, "Acme", "2015", "February 2019", "former"), fact(DATED, "Globex", "March 2019", status="current")])
    q = "Where did I work before March 20, 2019?"
    assert F.answer(s, F.intent(q, s), q)[0] is None
    assert F.parse_date("15 March 2019").precision == "day"


def test_after_and_before_dont_contradict():                  # 6
    s = state_with([fact(DATED, "Acme", "2015", "December 2018", "former"), fact(DATED, "Hooli", end="January 2019", status="former"),
                    fact(DATED, "Globex", "2019-02-01", status="current")])
    b, a = before(s, "Globex")[0], after(s, "Acme")[0]
    assert not (b == "Hooli" and a == "Globex")


def test_intent_round_3():
    s = state_with([fact(DATED, "Acme", "2015", "2018", "former"), fact(DATED, "Globex", "2019", "2021", "former"),
                    fact(DATED, "Initech", "2022", status="current")])
    assert F.intent("Where did I work last year?", s) is None or F.intent("Where did I work last year?", s)[1] != "previous"
    assert F.intent("Where did she work before Globex?", s) is None
    it = F.intent("Where did I work from 2015 to 2019?", s)
    assert it is None or it[1] != "year" or F.answer(s, it, "Where did I work from 2015 to 2019?")[0] != ent(s, "Acme")


if __name__ == "__main__":
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_")]
    bad = 0
    for n, f in tests:
        try:
            f()
            print("ok  ", n)
        except Exception as e:   # noqa: BLE001
            bad += 1
            print("FAIL", n, type(e).__name__, e)
    print(f"{len(tests) - bad}/{len(tests)} passed")
    raise SystemExit(1 if bad else 0)
