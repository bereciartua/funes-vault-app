# Spike H results

## Spike H3b: the range-based time model (15 Nov 2026)
H3 showed the model's shape holds, but its temporal rules broke on small counterexamples. ADR-0032 decision 5 then required a range-based time model, and H3b rebuilds `facts.py` that way:
- **Dates are ranges** at the precision written ("2019" is the whole year). An order holds only if it holds for every possible date.
- **Episodes come from assertion intervals** (a start with the end it was stated with). Evidence, trust, order edges and status belong to an episode.
- **One resolver** answers role phrases as of a date, "previous", "current", years, and before / after, including date anchors ("before 2019").
- **Code:** `facts.py`; `test_temporal.py` holds every review counterexample as a test (44, plus `test_facts.py`'s 16); `replay.py` and `score_all.sh`.

**Method:**
- **Replay:** `replay.py` re-applies every saved H3 model output, in its recorded order, through the new code, with no model calls. Replaying through H3's own code reproduced H3's published numbers exactly. Limit: the reconciliation calls are the ones the original run made.
- **Fresh runs** check the slightly changed prompts: the mixed fixture, the work fixture and the canary, on Haiku (about 470 calls, $0.25).
- **Reviews, in three rounds:**
  - GPT-6-Astra and Fable 5.2 reviewed the first H3b build, and both again found wrong answers;
  - each became a test and was fixed (round 2);
  - Fable's check of round 2 found 6 more, in narrower cases: a distant year re-dating a role phrase, a rejoined job's other episode, a hand-over assumed despite a stated time, an untrusted "no longer", a date anchor beside a job that may have started, and a missing mirror check in "after". Those were fixed and are tests too (round 3).

  Each round found fewer, narrower cases. Every one came from adversarial probing: the replayed fixtures showed 0 wrong answers throughout.

### Verdict: H3b meets ADR-0032's gate. Every counterexample passes, no set has a wrong answer or a wrong link, and coverage rose

| Set | H3 (final) | H3b (replay) | H3b (fresh run) |
|---|---|---|---|
| People links, main: full-basis right · decidable resolved | 111/111 · 153/160 | 115/115 · 153/160 | — |
| People links, held-out: full-basis right · decidable resolved | 148/148 · 190/198 | 164/164 · 190/198 | — |
| Mixed fixture, separate calls: links · relation recall | 35/35 · 98% | 37/37 · 98% | 35/35 · 93% |
| Mixed timeline: decidable answered (right + right with a gap told) · wrong | 20/28 · 0 | 25/28 · 0 | 25/28 · 0 |
| Work fixture, facts.py's extraction: decidable answered · wrong | 6/15 · 0 | 8/15 · 0 | 9/15 · 0 |
| Work fixture, H2's extraction: decidable answered · wrong | 7/15 · 0 | 7/15 · 0 | — |
| Canary timeline (with the "date" cue): decidable answered, per run · wrong | 33, 31 of 34 · 0 | 30, 29 of 34 · 0 | 30 of 34 · 0 |
| Canary links: weak bases right | 3 wrong on the frozen code | 13/13 | 7/7 |
| Negatives that triggered the timeline (all sets) | 0 after the fixes | 0 | 0 |
| The author's vault (private): facts.py's extraction · H2's extraction | the reviewed job · the reviewed job | the reviewed job (`inferred`) · told, not answered | — |

- **The scorer is stricter than H3's:**
  - answers go through the operator intent actually returned;
  - a "gap" answer naming the wrong entity is wrong;
  - "gap told" is excused only when the truth isn't something the timeline models (a study period);
  - several answers must be exactly the truth;
  - year, current, previous and no-answer questions are scored too.
- **H2's extraction on the author's vault is now told, not answered.** One memory states a stray start date for an old employer, after its end, with no status. The range model can't rule out that episode sitting before the current job, so it refuses rather than guessing. H3 answered it right only through a fact-level "former" rule that per-episode status no longer allows.
- **The canary answers 3 fewer questions than H3's after-freeze run:**
  - "before Avery and I got together again" is refused by the rule that the anchor must end the operator phrase;
  - two questions that H3 answered from a lucky date reading are now told.
- **Relation recall** on the fresh mixed run was 93% (98% on the replay). It's one run of a slightly reworded prompt: within run-to-run variation, but not shown to be.

**What H3b settled:**
1. **Dates are ranges;** a same-year hand-over with nothing else between is answered at `inferred`, and with anything that could fit between, it's told.
2. **Episodes come from intervals:**
   - an end before the first start is kept;
   - a return is a new episode, which never succeeds itself;
   - an assumed hand-over start (for "my new boss") never clusters or bounds anything in the timeline.
3. **Trust per date, edge and status:**
   - untrusted evidence never starts, ends or orders anything at full basis;
   - a link's trust comes from the episode it rests on.
4. **Status per episode:**
   - an undated "no longer" ends the episode it fits; if it fits two, the open one becomes uncertain (neither current nor ended);
   - "current" holds as of the memory's date;
   - succession ends only a stale current, and only on trusted evidence;
   - a present-tense negative ("not back together") ends a relation rather than denying it.
5. **Role resolution uses the same episodes:**
   - a time cue is a range, and needs a preposition ("in February 2019");
   - "my current partner" is evaluated at the memory's date;
   - "my former therapist … in May 2024" means former when written, and holding the role in May 2024;
   - a holder whose stated start is later drops out when someone else certainly held the role then;
   - a name the text pairs with the role, which the model also picked, is a named decision.
6. **Order:**
   - a stated edge loses to a job the dates certainly put between;
   - undated facts block a non-contiguous answer in both directions;
   - contiguity means adjacent at month precision (at most two months could fit).
7. **Intent:**
   - the anchor ends the operator phrase;
   - any person named outside the anchor makes it someone else's question, holders included;
   - a role subject ("my wife") does too, and so does an unknown capitalised name that doesn't start a sentence;
   - a question naming one job with current, previous or a year is about that job;
   - date expressions keep their month and day.

**Known limits** (not fixed; none gives a wrong answer in the tests or fixtures):
- intervals written as one string ("March to June 2019", "2019–2021") and "between X and Y";
- "Did I like my job in 2016?" triggers the year resolver (it lists the job, harmlessly);
- month names and function words are still in code, not the registry;
- the anchor-tail rule refuses some natural wordings;
- replay can't re-decide which reconciliations to ask.

8. **Intent, round 3:**
   - "last year" isn't "previous";
   - "he", "she" and "they" make it someone else's question;
   - "from 2015 to 2019" is one span;
   - an imported note's "my previous job" has no date to resolve against.

**For ADR-0032:**
- Decision 5 holds as written, and the H3b rules above are its implementation detail for the Phase 13 plan.
- **The lesson is in how the bugs were found:** no fixture, blind or not, exposed them; only adversarial probing by two independent reviewers did. So 13a's acceptance needs adversarial review of the Swift time model, not only fixture scores.
- The coverage gate stays a 13a measure on a fresh blind fixture.

## Spike H3: the unified model (15 Nov 2026)
ADR-0032 was reworked around one model: entities, facts about the user, and a predicate registry that is data. H3 tests that model before acceptance, in the Python harness, with Claude Haiku 5.5 (about 2,960 calls, $1.54 API-equivalent). The author's vault stayed in a private folder; only yes/no answers and counts are recorded here.

**Code:**
- `facts.py`: one implementation of extraction (prompt and schema generated per call group), validation, apply, role resolution, the timeline and timeline intent, reading `registry.json`. No code names a predicate; `test_facts.py` checks that mechanically.
- `registry.json` (documented in `REGISTRY.md`): v1's 12 predicates (10 person predicates, works_at, client).
- `run_facts.py`, `score_facts.py`: runners and scorers. Story results keep run.py's format, so `score.py` scores people links unchanged.
- `test_facts.py`: 16 deterministic tests (slots, succession, untrusted text, gaps, precision ties, conflicts, cycles, rejoins, exclusivity, date cues, intent negatives).
- `author_astra_mixed.py`, `author_astra_canary.py`: GPT-6-Astra's blind fixtures. `canary_ci.py`: the canary without a model.

### Verdict: a partial validation. The shared model and the registry hold; the temporal rules need a range-based redesign

*Revised after GPT-6-Astra and Fable 5.2 reviewed the harness and the first write-up. Both reproduced the counts, then broke the generic temporal rules with small counterexamples, and found overclaims, all corrected below.*

- **People through the one implementation match the baseline.** On Spike H's matrix (Haiku, two runs, both sets) facts.py made 0 wrong links and 0 forbidden links, like people.py run the same day. Recall was 95.8% against 96.6% combined: 0.8 points, inside the 1-point fidelity target. On the main set alone it was 1.9 points: two reconciliations where Haiku answered "unknown" (safe misses) in both runs. On the held-out set the two were identical (190 of 198, the same 8 misses).
- **The timeline reproduces H2.** On H2's own extraction the generic rule gives H2's result exactly: 7 right, 0 wrong, 8 ambiguous or told.
- **On the author's vault the timeline picks the reviewed job,** from H2's extraction (basis `ordered`) and from facts.py's own extraction (basis `inferred`, hedged as "probably"). The second needed one fix (below).
- **People and jobs belong in separate calls.** On the blind mixed fixture, one merged call lost relation recall (91% and 89% in two runs, against 98% and 98% with separate calls). Links, the timeline and organization classification were otherwise equal. That decides the ADR's open question: call groups per predicate family.
- **The canary needed no predicate-specific code, but two generic capabilities were missing.** GPT-6-Astra turned on the partner timeline with 8 data-only changes, and wrote a blind fixture, after the code was frozen (`spike-h3-freeze`). The fixture has 17 decidable, 6 undecidable and 8 negative questions; each story is played in two memory orders, so the tables count 34, 12 and 16. On the frozen code it gave 0 wrong timeline answers in two runs, but 3 or 4 negatives triggered and 3 weak-basis links were wrong. It also showed:
  - a data gap: the cue word "date" was missing, and adding it took answered decidable questions from 25 and 23 to 33 and 31 of 34;
  - two code gaps: the anchor must be what follows "before" (3 or 4 of 16 negatives triggered), and role resolution kept its own dates apart from the timeline (3 wrong weak-basis links).

  Both code gaps are generic and were fixed after the freeze. Those fixes don't count toward the canary.
- **No answer was wrong in the saved runs after the fixes,** but the reviewers' counterexamples show wrong answers the fixtures didn't exercise (below).
- **Coverage is limited mostly by the gap policy, not extraction** (corrected; the first write-up blamed extraction). Of the 8 decidable mixed questions not answered, 5 were "gap told" answers naming the right job. Gaps of 3–4 months exist in Astra's truth, and bare years are padded to December. The other 3 were ambiguous: 2 from a conflict the extraction created, 1 from dates it missed.

**People matrix** (Haiku, 2 runs; Spike H's scorer):

| | people.py (baseline, same day) | facts.py, round 1 | facts.py, final |
|---|---|---|---|
| Main: full-basis links right | 126/126 | 115/119 | 111/111 |
| Main: decidable references resolved | 156/160 | 150/160 | 153/160 |
| Held-out: full-basis links right | 153/153 | 146/146 | 148/148 |
| Held-out: decidable references resolved | 190/198 | 185/198 | 190/198 |
| Links a story forbids | 0 | 0 | 0 |
| Names not recorded (both sets) | 8 | 2 | 1 |

**What round 1 found** (each a consequence of the ADR's own decisions, fixed generically):
- **Manager isn't exclusive any more,** so a new boss no longer started at the memory that announced them, and earlier "my boss" memories went to the new one. Fix: a new holder of a predicate with succession starts at the memory that says so. Manager gets succession in the registry; it stays non-exclusive.
- **"Deceased" read as "former".** The new status field ("former: no longer…") led Haiku to mark "my late father" as former, which hid him from later "my dad" memories. Fix: the prompt says a death isn't an end, and code never ends a fact of a deceased person.

**Work history:**

| Set | Result |
|---|---|
| H2's extraction, generic timeline (anchor by name, as H2's scorer) | 7 right, 0 wrong, 8 told: identical to H2 |
| The same, with the ADR's intent rule | 4 of 15 wordings had no job word ("after leaving Pampa", "before joining Mosaic"); with join/leave verbs added to the registry, 7, 0, 8 |
| facts.py's own extraction of the work fixture (one run) | 6 right, 0 wrong, 9 told; 0 negatives triggered; 1 of 3 clients recorded as works_at |
| The author's vault, H2's extraction | the reviewed job, basis `ordered` |
| The author's vault, facts.py's extraction (379 calls, $0.18) | the reviewed job, basis `inferred`; 12 employers against the 9 reviewed (3 undated extras that don't affect the timeline) |

**The mixed fixture** (GPT-6-Astra, blind: 10 stories, 55 memories mixing people with the user's jobs, clients and vendors, 30 queries; one run per setup on the frozen code):

| | Separate calls (people, work) | One merged call |
|---|---|---|
| Full-basis links right | 35/35 | 35/35 |
| Decidable role references resolved | 49/50 | 49/50 |
| Relation precision · recall | 96% · 98% | 95% · 91% |
| Timeline: decidable answered · wrong · undecidable told | 20/28 · 0 · 4/4 | 19/28 · 0 · 4/4 |
| Clients or vendors recorded as employers · vendors as clients | 0 · 0 | 0 · 0 |
| Negatives that triggered the timeline | 0 (3 before a fix tuned on this set) | 0 |
| Calls | 179 | 90 |

**The canary** (partner timeline; GPT-6-Astra wrote the registry change and a blind fixture of 8 stories, 36 memories, 34 decidable and 12 undecidable questions, after the freeze):

| | Frozen code, Astra's registry | Frozen code, + the cue "date" | After the fixes (not blind) |
|---|---|---|---|
| Source change needed | none | none | anchor position; one time model |
| Decidable answered (two runs; the last column one run) | 25, 23 of 34 | 33, 31 of 34 | 31 of 34 |
| Wrong answers | 0, 0 | 0, 0 | 0 |
| Undecidable told | 12/12 | 12/12 | 12/12 |
| Negatives that triggered | 4, 3 of 16 | 4, 3 of 16 | 0 |
| Wrong links (all weak bases) | 3 | 3 | 0 |
| Deterministic part (`canary_ci.py`, Astra's truth as canned extractions) | 13 right, 0 wrong, 2 negatives triggered | 17 of 17 decidable, 0 wrong, 2 negatives | 17 of 17, 0 wrong, 0 negatives |

**Generic rules added during H3** (no predicate named; each found by a run, and each has a test or a fixture case):
1. **Dates compare at the precision both state:** "2014" and "September 2014" agree. A year-only end against "March 2019" is a tie, not an order.
2. **Conflicting starts or ends make the episode ambiguous on that side.** A start after an open episode is a conflict, not a rejoin. This cost 2 mixed answers, where the extraction attached a client's dates to the user's own business.
3. **Contradictory or cyclic order edges are dropped, and dates decide.** H2's extraction reversed the direction of "before / after" in 3 of 4 memories. The fields are now `preceded_by` and `followed_by`, named by direction.
4. **A stated order still tells a gap the dates show.**
5. **Succession is for stale currents only:**
   - "current" holds as of the memory's date, not today;
   - a fact stated as ended at an unknown time is never ended by succession;
   - a later memory saying it still held is evidence of overlap.

   Without the first point, facts.py's own extraction of the author's vault picked the wrong job. Without the second, H2's extraction did.
6. **Several open facts in a slot end nothing; untrusted text never triggers succession.**
7. **Undated facts of the predicate make a non-contiguous answer ambiguous.** Found when a canary run lost one partner's dates.
8. **Intent:**
   - the anchor is what follows the operator;
   - a known person other than the anchor in the query means someone else's fact ("Where did Ada work before Acme?");
   - join and leave verbs are cue words (registry data).
9. **Deceased isn't former;** a new holder of a predicate with succession starts at its memory.

**Known bugs the reviews found** (reproduced with canned inputs; not fixed in H3, because each needs the temporal redesign rather than another rule):
- **Trust is per fact, not per date or edge.** One trusted memory makes every date of the fact usable. An untrusted start can trigger succession of another fact; an untrusted order edge returns `stated`, and `episodes(untrusted_dates=…)` is unused (`facts.py` `episodes`, `_stated`).
- **Same-year hand-over.** "Left Acme in 2019, joined Initech in 2019" drops Acme, because a bare-year end is December and a bare-year start is January; `before(Initech)` names the job before Acme at `ordered`.
- **Merging erases an episode.** Starts are merged apart from their ends: Acme 2020–March 2020, rejoined September 2020, becomes one September episode.
- **Uncertain competitors drop out.** A competitor with a year-only end in the anchor's year, or a former fact with a start but no end, isn't considered; only the winner's conflicts are checked. Succession also ignores "still current" when it's within the month the next fact starts.
- **Order edges are per entity, not per episode,** and only two-way contradictions are detected: a longer cycle returns `stated`, and a stated predecessor that overlaps the anchor wins.
- **Role resolution keeps its own time model** (`holders` reads stored `valid_from`, `valid_to` and `status`). A rejoined job or reunited partner stays `former`; starts are truncated to January ("September 2021" resolves March 2021 memories); `previous_as_of` skips the precision, conflict and gap checks.
- **Month names are read from prose:** "married" parses as March, "separated" as September, "decided" as December, "2019-20" as month 20.
- **Intent holes:**
  - the other-person check runs only for before / after, and only for known people ("Where did Zoe work before Initech?", "Where does Ada work now?" trigger);
  - role subjects slip through ("Where did my wife work before Acme?");
  - a cue anywhere counts ("What did I work on before the Initech demo?");
  - year, current and previous have no resolver.
- **Deceased overrides an explicit end** ("my former boss, who later died" becomes current).
- **The scorer dispatches on the gold operator, not the one intent returned,** and never counts a "gap" answer naming the wrong entity as wrong. Neither changed a saved result, but both would hide errors. `canary_ci.py` exits successfully on failures.
- **Predicate-flavoured content remains in code** despite the mechanical test: `person_nouns`, the "ex" class, prompt examples ("sister, mom, boss", "left a job"), and person fields (deceased, only, count) on every fact's schema. These belong in the registry; the test only greps predicate ids.

**What this means for ADR-0032:**
- **The model's shape holds.** People and jobs ran through one implementation, people links matched the baseline, and a new predicate's timeline ran on data-only changes. It lacked generic capabilities, never predicate code, which is the ADR's rule for when code changes.
- **The temporal core doesn't hold as built.** Rule-by-rule patching found real cases but left others (above). The time model needs a design, not more rules:
  - every date is a range at its written precision ("2019" is January to December), and comparisons are over possible ranges;
  - evidence, trust and order edges belong to an episode, not to the whole fact;
  - episodes are built from assertion intervals before dates are refined;
  - one resolver serves role resolution, "previous", and before / after;
  - status is per episode.
- **Decided by H3:**
  - separate call groups for people and work;
  - one time model is required, but **not built in H3**: the after-freeze fix only made stated dates replace assumed ones in `apply`; role resolution still reads the fact's stored dates and status;
  - the intent and succession rules above;
  - order fields named by direction;
  - manager has succession and stays non-exclusive.
- **Not met:** the ADR's coverage target (≥ 90% of decidable wordings) on job fixtures, mostly because of the gap policy and year padding (above).
- **Limits:**
  - one or two runs per set, Haiku only;
  - the mixed fixture became development data for one intent rule, and the work fixture for the cue words;
  - the after-freeze fixes were checked on the canary they came from;
  - the port to Swift through `ModelRouter` is still 13a's gate.

## Spike H2: work history (14 Nov 2026)
Plan v5 §16 required this half-day spike before 13a: a reviewed timeline on the author's vault, real answer calls, a diagnosis of the 1st-ranked memory, and a blind fixture. The author's data stayed in a private folder outside the repo; only counts and choice numbers are recorded here. Code: `work_history.py` (extraction, stints, the resolver, intent) and `author_astra_work.py` (the fixture).

**The author's review of the probe** (a private terminal tool; verdicts only):
- 43 of the 44 job facts right, 1 partly;
- the 9 employers right and complete, and every stated date right;
- **the probe's pick of the employer before the current one was wrong.** Its rule compared years only. Two employers ended in the year the current one started, and the tie went to whichever came first in a list. The author's answer was the other one, a short job that also started that year.
- **Plan v5's stint rule picks the right one.** It uses months where the memory states them (both did), and a real tie is ambiguous, never a guess. The probe's naive name-merging had also attributed the author's answer memory to the wrong employer; the stint version attributes it to the right one.

**The 1st-ranked answer memory, diagnosed:**
- The app ranks with a second embedding index, qwen3-embedding:0.6b through Ollama, not bge-small alone. Rebuilt from the vault copy's stored vectors, its ranking puts the memory that answers 34th (110th for "Where did I work before …").
- The other answering memory ranks 3rd–9th, inside the 10 the answer reads. It's about the current employer but doesn't name the earlier job, so on its own it can't answer the question.

**Real answer calls** (the author's Search answers model, GPT-5.6-Terra through Codex, as the app; 6 wordings including one in Spanish × 3 samples; code checks whether a claim names the earlier employer):

| Input | Answers naming the earlier employer | No answer |
|---|---|---|
| The app's real top 10 | 0 of 18 | 18 of 18: the iPhone failure, reproduced |
| Top 10 + 2 bridges picked by the probe's year-only rule | 18 of 18, **all naming the wrong employer** | 0 |
| Top 10 + 2 bridges picked by v5's stint rule | **18 of 18, the right employer** | 0 |

- Bridges turn the failure into an answer every time.
- **A wrong timeline produces confident wrong answers,** in all 18. The order is the risk (D11), and a tie must never be guessed.

**The blind fixture** (GPT-6-Astra: Spike G's vault plus 60 work-history memories, 13 true stints, 35 queries, including negatives and questions about roles within one job):

| | First run, blind (employer-level timeline, years only) | After stints, months, job kinds and gaps (now a development set) |
|---|---|---|
| Before / after answers right | 3 | 7 |
| Wrong | **5** | **0** |
| Ambiguous, or a gap told | 7 | 8 |
| Negative and in-job questions that triggered the timeline | 0 of 11 | 0 of 11 |
| True employers found · extra "employers" | 6 of 7 · 6 | 7 of 7 · 4 (clients still labelled employers) |

- The blind run failed on exactly what the reviews predicted: rehiring, a rename ("Kiteworks Ltd, also called Blue Kite"), a study gap skipped confidently, and clients counted as employers.
- The stint version fixes these. Its remaining ambiguous answers are honest misses: a role end read as a job end ("through December 2020", then promoted), questions that name no employer ("my first freelance period"), and overlapping jobs.
- Since the fixture was used to fix the code, it's no longer blind: 13a needs a fresh blind fixture for its acceptance test.
- Cost: extraction $0.06 per fixture run, and $0.09 on the author's vault.

**Verdict: Spike H2 passes,** with three things for 13a:
- the stint rule with month precision and ties left ambiguous, as v5 specifies; the year-only rule failed on the real vault;
- role history inside a stint, so a promotion isn't read as a job end;
- client classification, which was still imperfect (4 clients labelled employers).

## Search and answers, round 3 (14 Nov 2026)
**Fable 5.2 checked this round** (read-only, offline). The tables reproduce from the saved records, and the re-judge was fair: it removed an advantage for C, and the headline is the same in both judgings. The corrections below are Fable's. **§15's answer targets aren't passed.**

Round 3 fixed what Fable's round-2 check found and separated the treatments. The ranking rule is round 2's (no boost, −0.1 for other people's memories), unchanged. One Haiku read per vault (round 2's two reads were identical), plus a privacy read of the busy vault whose People call may read up to Sensitive while answers stay at Internal. Outputs: `results-search/answers3/`, `report-answers2-*-r3_b.md`, `report-search2.md`.

**Fixes:**
- **Stating evidence:** a memory states a relation only when its quote holds both the person's name and a role word for that relation, or code paired them. Lucía's sister relation now has one stating memory ("My sister Lucía…"), not six.
- **The privacy gate** now has a case: in the Sensitive read, the half-brother and aunt relations have only a Sensitive stating memory.
- **Code marks "inferred":** a claim that names a person only through a hint is tagged by code, as plan §10 says the card should be. The model no longer has to hedge. Code misses inferences drawn from neighbouring hints (see M) and relation labels taken from a hint ("Erik Lund, your current manager").
- **Matching:** "mi pareja" is a role phrase (link recall 157 of 159, up from 155). A common-word name matches at the start of a query as "May's …" or alone ("May").

**Arms** (Haiku, 3 samples each, 1,527 answers; 348 are reused samples of an identical request):
- A plain;
- B people ranking;
- C1 the hint only;
- C2 the hint plus the prompt sentence;
- C3 C2 plus bridges;
- W a wrong hint naming the queried person, on a trap memory;
- M C2 without the answer memory's hint.

**The judge** (Opus 5.5, arm hidden) gets code notes on every claim in every arm: "[the cited memory names X]" when the person is named outside the quote, and "[Funes marks this as inferred]". The first judging, with only the second note, marked correct plain answers unsupported and favoured C. Those numbers were discarded, and this table is the re-judge (`*_b`). The "inferred" note can only occur in hinted arms, and the judge is told to accept such claims when the truth agrees (178 of 181 were). On the 5 gain queries, plain text matching gives the same result without the judge: answers that name the person and cite the target are A 0/15, B 1/15, C1 15/15. No hand-read of the judge was done this round.

| Required fact covered | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Busy challenge, test (8 queries) | 18/24 | 18/24 | **24/24** | 23/24 | 24/24 | 24/24 | 24/24 |
| Busy challenge, tune (6) | 9/18 | 9/18 | **18/18** | 18/18 | 18/18 | 17/18 | 9/18 |
| Busy ordinary, collision, privacy (24 queries) | 72/72 | 72/72 | 72/72 | 71/72 | 71/72 | 45/45 | 46/48 |
| Held-out, round 1 (16) | 38/45 | 44/45 | 43/45 | 44/45 | 44/45 | – | 42/42 |
| Main people (18) | 51/51 | 51/51 | 51/51 | 51/51 | 51/51 | 15/15 | 27/27 |
| Spike G person questions (5) | 9/12 | 12/12 | 12/12 | 12/12 | 12/12 | – | 12/12 |

Claims, busy challenge test:

| | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Denies a true fact | 1 | 0 | 1 | 0 | 0 | 4 | 2 |
| Wrong person | 0 | 0 | 0 | 0 | 0 | **7** | 0 |
| Claims code marks inferred (model hedged) | – | – | 18 (10) | 16 (15) | 14 (12) | 32 (20) | – |

**What it shows:**
- **The hint helps on one query shape.** On the 5 busy queries that name a person whose memory says only "my sister" or "my partner" (wq01, wq03, wq06 tune; wq10, wq11 test), the hint alone takes Haiku from 0/15 to 15/15. The other 9 challenge queries are 3/3 in every arm, and their targets were already in A's top 8. On held-out and Spike G the gain comes from admission (B: 38 → 44 of 45, 9 → 12 of 12), not the hint; there, admission brings in the memory that names the role holder ("My partner is Jordan").
- **The prompt sentence only changes hedging** (main set: 8 of 17 inferred claims hedged without it, 10 of 18 with it; held-out: 3 of 28 and 14 of 25). Code can render "inferred" instead.
- **Bridges aren't shown to add anything, but they weren't tested alone.** Bridges fired on 11 of 14 challenge queries, but only on top of a hint, where coverage was already at the ceiling, and Haiku cited the bridge in 4 of 42 answers. A bridge without a hint wasn't run. The one sign is held-out a01, where the stating memory alone fixed the answer with a fully quoted claim.
- **Neighbouring hints are enough, and that's a product gap.** In M, with hints on other memories of the same person, Haiku makes the link itself in 15/15 answers on the gain queries, on both halves. Code marks none of them inferred, because the cited memory has no hint. With the prompt sentence, 11 of those 15 credit "Funes" with a link it didn't make. The judge scored M inconsistently (24/24 test and 9/18 tune; the first judging gave 18/24 and 15/18), so M's coverage numbers mean little.
- **A wrong link reaches the answer.** When the trap names someone else ("Nia Okafor told me…"), Haiku usually flags the mismatch, giving false "your notes conflict" claims. **The one trap with no name** (the user's own coffee order hinted as Erik's, main s18) **was misattributed 3/3 without a hedge.** The wrong hint pulled the trap into 19 of 24 busy test answers, against 3 without it. Real wrong links (sole-known role links, pronouns) will mostly be nameless. The busy count of 7 wrong-person claims depends on the judge, which labelled near-identical claims differently.
- **The privacy gate held on the 3 queries that exercise it** (busy-r3p; name links, 2 relations): no hint naming those relations was sent in any arm. Not exercised: an Internal role-only memory admitted through a relation stated only at Sensitive, where the admission itself would reveal the link. And the gate is per relation, not per label, so a label learnt from a Sensitive memory ("half-brother") passes if any Internal memory states the same relation type.
  - My own wrong-hint arm first built its hint without the gate. It sent "your half-brother" or "your aunt" in 9 requests (3 prompts × 3 samples; invented data). The gate was added there too, and those rows deleted: W then isn't built for those queries.
- **Ranking:** unchanged from round 2. No target got worse in any set, and links still don't move the top 3. The ranking files changed after round 2's lock, and the test half was already scored in round 2, so tune/test is only a label in round 3.
- **Judge artefact:** held-out "wrong person" (3/3/3/1/1 in A/B/C1/C2/C3) is all a15, where the judge reads the user's own coffee order as someone else's.

**Blocking §15's answer targets:**
- wrong links reach answers, confidently when the trap names no one, so the target depends on real-vault link precision, which is unmeasured;
- code doesn't mark relation labels taken from a hint, or inferences drawn from neighbouring hints;
- no bridge-only arm;
- the a15 judge artefact;
- the evidence is 5 queries (2 test), one fixture author, one answer model and one read, on a fixture already seen in round 2;
- no hand-read of the judge.

**Still open:**
- one author (Astra) wrote both the busy vault and its "challenge" queries, and the gains are on that construction;
- an agent's "their partner";
- the matrix re-run with the round 2–3 pipeline changes;
- the harness doesn't run through `ModelRouter`.

## A real query: "What was my job before [the current employer]?" (14 Nov 2026, the author's vault)
The author asked this on the iPhone, and the answer couldn't find the information. The diagnosis ran privately on a fresh read-only copy, with FunesCore's real search and bge-small; only ranks and counts are recorded here. The author picked the two answering memories in a terminal picker that saved only their ids.
- **The employer's name takes over the search:** the 29 memories that mention it fill ranks 1–29. Every other job memory starts at rank 30.
- **The two answer memories:**
  - one doesn't mention the current employer, and it ranks **33rd** (50th for "Where did I work before …");
  - the other mentions it and ranks 1st. It's Sensitive, within the Mac's cloud limit (Restricted). Why the answer didn't use it isn't known from here: it may not answer the question on its own, or the iPhone's answer may have taken a different input.
- **The rest of the query alone** ("What was my job") puts the first memory 8th among job memories. A top 10 of 2 memories naming the employer plus 8 from the rest of the query would hold both. That's fragile: for "Where did I work before …" the rest-of-query rank is 40th.
- **Hypothesis (one query; extraction untested): a work-history relation** (you → organization, works at / worked at, with start and end dates) would turn "before X" into a code lookup: the employer whose end meets X's start. That employer's memories would then be admitted, as a person's are. This is plan 13f's "works at", using the start and end dates and former status that People relations already have.
- **The work-history probe (run privately, same day).** Haiku read every memory of the copy within the cloud limit (365; 1 call failed; $0.09) and extracted the user's own jobs: organization, role, status, start, end, and "before / after", each with a quote. Validation required the quote and the organization to be in the memory, and dropped nothing. Results:
  - 43 memories state a job of the user's: 44 facts, 9 organizations;
  - the query's organization was found as current, with a stated start year;
  - code found the employer before it from the end years (8 candidates ended by that start; the latest was picked). Answer memory 1 is one of that employer's 7 stating memories and names it;
  - **ranking alone isn't enough.** Admitting the earlier employer's memories (no boost, the query's organization demoted 0.1) moves answer memory 1 from 33rd to 11th for "What was my job before …", and from 50th to 33rd for "Where did I work before …";
  - **adding the earlier job's stating memories works.** Two stating memories added to the answer's input as bridges (plain top 8 plus the 2 best by the rest of the query) holds both answer memories for the first wording. For the second, the 2 added still state the earlier job, so the answer can name it with a citation; answer memory 1 is 3rd of the 7 there.
  - **What this shows:** for "before / after X" questions, a timeline of the user's employers answers the question in code, and its stating memories are what the answer needs. Here the bridge does matter, unlike in the people fixtures.
  - **Limits:** one query and one read. No answer call was run, and the pick of the earlier employer was checked only through the author's answer memory.

## Search and answers, round 2 (14 Nov 2026)
**Fable 5.2 checked this round** (read-only, offline). The figures reproduce from the saved outputs, and all 240 prompts rebuild to the same request hashes, so the post-lock edit changed nothing that was sent. The corrections below come from that check. **§15's answer targets are not passed.**

Round 1 (below) didn't pass §15. Fable 5.2's review found three problems: no headroom, regex-scored single-sample answers, and bugs. Round 2's plan (`ROUND2.md`) was reviewed by GPT-6-Astra before it ran, and its main points were adopted: the privacy of the `about` hint, a split by query family, three separate arms, a blind judge, and request-hash reuse.

**What changed:**
- **Pipeline:**
  - a code-found pair ("my sister Lucía") is applied when the model leaves it loose or skips the relation;
  - plural roles ("my parents") always go to the group;
  - a group isn't renamed after one member;
  - a stated start date only weakens older references;
  - only memories that state a relation were meant to be its bridge evidence. **This isn't fixed:** a memory counts as stating when the model's relation quote merely contains the name. In the busy read, 23 of 39 "stating" memories don't state the relation ("Lucía wants me to proofread her emails"), and all 6 bridges sent were of that kind;
  - memories above the cloud limit get code-only links, after every model call and never in a roster.
- **Query matching:** an ambiguous name or `candidates` link is admitted for a named candidate; the stop list of common words that are also names applies ("in may"); possessive chains ("my partner's sister") match no one; Spanish function words are dropped from the rest of the query.
- **The answer:**
  - the user's names become "the user" in every arm;
  - arm C adds an `about="Lucía, your sister"` hint (or "probably …") to memories that came through a link, but only if a memory stating that relation is within the cloud limit;
  - arm C also adds one prompt sentence saying such claims must say they're inferred.

**Fixtures:**
- the main set and Astra's round-1 held-out set, unchanged;
- a new **busy vault** written blind by GPT-6-Astra (`author_astra_busy.py`): 160 memories (Lucía 55, Jordan 45, about a quarter of each role-only; traps; May, Will and Mark; two Alexes; two people whose relation only a sensitive memory states) and 44 queries in 43 families, kinds as Astra labelled them;
- per-memory truth (who each memory is about).

Busy families are split by hash: 18 queries tune and 26 test. 43 families for 44 queries makes this effectively a per-query split, and wq10 (test) is built the same way as wq01 (tune). Each vault was read twice by Haiku ($0.39 for the final six reads); the two busy reads produced identical links, so "summed over two reads" doubles counts without adding evidence.

**Links against the busy vault's truth** (both reads, identical): 155 of 159 found; every link right (126 `named`, 14 `sole_known`, 9 `stated_unique`, 6 `untrusted`). All 156 `about` hints on busy memories named the right person.
- **Not a held-out link figure.** The pipeline was last edited 20 minutes after the busy vault was written, and the paired-name rule came from a round-1 held-out read.
- **Two of the 4 misses are systematic:** Spanish "mi pareja" isn't in the lexicon. The other two are "my parents", which goes to the group by design.

**The ranking rule, picked on the main set and the busy tune families by a rule fixed beforehand** (no target worse, then most in the top 3, then fewest losses under a missed link), and locked with file hashes in `results-search/locked.json` at 18:40:
- admission plus max(query score, rest-of-query score);
- **no boost**;
- −0.1 for a memory linked only to people the query doesn't name.

Every boost from 0.1 up made 2 targets worse, and when a link was missing it ranked the right memory below plain search (22–30 of 74 cases). `search_answers.py` changed after the lock: the change added the 5 Spike G questions that match a person and made the script read the locked weights. It doesn't touch ranking, and Fable confirmed the prompts are unchanged.
- **The lock proves files didn't change; it can't prove the test half was unseen.** Plans and scores for the whole busy set existed a minute before it.
- **The rule tied four grid cells** (others 0 or 0.1, cap none or 5). The −0.1 was chosen on traps, which the rule doesn't name, and it raises harm from a wrong link (36 → 40 of 116). Boost 0, the least fitted option, makes overfitting unlikely for ranking.

**Search** (`report-search2.md`, counts summed over the two reads):

| | Main (tune) | Busy tune | Busy test | Held-out (round 1) |
|---|---|---|---|---|
| Best target in the top 3, plain → people | 146 → 146 of 162 (incl. Spike G, bench) | 30 → 30 of 32 | 44 → 44 of 44 | 30 → 30 of 30 |
| Targets worse · out of top 3 · out of top 8 | 0 · 0 · 0 | 0 · 0 · 0 | 0 · 0 · 0 | 0 · 0 · 0 |
| Better (best target) | s12 2→1; q31 – → 6 | wq01, wq03 2→1 | wq11, wq33 3→1 | a01 3→1, a03 2→1, a06 3→2 |
| Traps in the top 3 | 6 → 6 of 18 | 18 → 13 of 98 | 38 → 32 of 106 | – |
| Name-only, about the person in the top 10 | 26 → 34 of 40 | – | 46 → 46 of 60 | 12 → 12 |
| Collision queries ("when may I…", "will", "mark") matching a person | – | 0 | 0 | – |
| Missed link worse than plain · missing relation worse than plain | 0 · 0 | 0 · 0 | 0 · 0 | 2 of 28 · 0 |
| Wrong link (a trap linked to the queried person) puts the trap in the top 3 | 8 of 18 | 32 of 98 | 52 of 106 (plain: 38) | – |

- **Plain search already finds the answer even in the busy vault.** Astra's "challenge" queries reach the top 3 without people in 16 of 16 test cases. With 55 memories about one person, topic words still carry search at this scale.
- **Ranking changes are small and never losses.** A few targets move up, traps move down, and name-only queries improve on the main set. With no boost, "a missed link is never worse than plain" is close to true by construction. A wrong link does push traps up.

**Answers** (Haiku, 3 samples per arm, 720 answers, judged blind by Opus 5.5 for $2.69). I read every case the judge flagged, every coverage difference between arms, and a random fifth of the answers it counted as correct; that sample was right throughout.

| Required fact covered | A plain | B people ranking | C ranking + `about` |
|---|---|---|---|
| Busy challenge, **test** families | 18/24 | 18/24 | **24/24** |
| Busy challenge, tune families | 9/18 | 9/18 | 15/18 (18/18 counting true but unhedged claims) |
| Busy ordinary, collision, privacy | 72/72 | 72/72 | 71/72 (72 lenient) |
| Held-out (round 1) | 39/45 | **45/45** | **45/45** |
| Main set people queries | 51/51 | 51/51 | 50/51 (51 lenient) |
| Spike G questions that match a person (5) | 9/12 | **12/12** | **12/12** |
| No-answer queries abstained right | all | all | all |

- **The `about` hint helps on one shape of query.** On the 6 busy queries that name a person whose answer memory uses only the role ("What subtitle format does Lucía need?" answered by "my sister needs…"), the hint turned 5 from abstention into an answer, and one (wq07) into an attribution without a citation.
  - **The test-half 18/24 → 24/24 is two queries** (wq10, wq11) × 3 samples. The other 6 test challenge queries say "my sister" or "my partner" in the query and pass in every arm.
  - Without the hint, A failed 15 of 42 challenge answers: 12 abstentions and 3 denials. The answer memory was in every arm's input.
  - All 5 gains are the brief's own example shape. The author's real vault had 3 role phrases in 365 memories.
  - C differs from B in the hint, the prompt sentence and bridges at once. No arm separates them; on wq10 and wq11 no bridge was sent, so the cause is the hint plus its sentence.
- **B's gains are mostly admission.** On the held-out a01 and a03, and on q31, B's top 8 gained the memory that names the role holder (m041, h03). On a01 the target also moved from rank 3, where A denied it, to 1.
- **The budget isn't equal.** Each arm takes 8 results and then the cloud limit withholds some, so arms send 2–8 memories. On q31, A sent 3.
- **Errors added by C:**
  - one trap framed as a conflict ("Rafael proposed a picnic… the place conflicts");
  - one doubt about a true budget;
  - one invented detail (a green thermos).
  - Of C's 28 "unsupported" claims (A 16, B 14), 4–7 are true attributions made without the required "probably" (wq07 ×3, s02, perhaps wq16 ×2 and wq12). The rest are details lost to quote truncation, which also happen in A and B, plus side claims about traps (wq08 ×3, wq14). C made 29 hedged claims.
  - **The judge is only nominally blind for C.** 39 of 240 C answers say "Funes infers" or mention the hint, against 1 each in A and B. It's also inconsistent: a named attribution with only a role-only quote is "fact" in a01 C3 but "unsupported" in wq07 and s02. A code check (cites a stating memory, or hedges) would be steadier.
- **Wrong person named:** judged once in C (the Rafael case). The held-out a15 "wrong person" is a judge mistake about the user's own coffee order, and it appears in all three arms.
- **Privacy: the gate was never exercised.** No hint named the two privacy people, but only because their relation was never recorded: the sensitive memories are unread. The gate also relies on the faulty `stating` list, so an internal memory that merely names a person would satisfy it.
- **Answers were never run with a wrong or missing hint,** though ROUND2 §6 planned a few. Every hint sent was right.

**What it shows:**
- On these fixtures, people links don't move search's top 3 (plain search gets 44/44 on the test half). With no boost they cost nothing in rank: record this as "no regression", not as links helping ranking.
- Telling the answer model who a role-only memory is about turned abstentions into answers on 5 constructed queries, with the hint and its prompt sentence together. Bridges weren't working.
- A boost isn't needed and makes missed links hurt.
- The hedging rule needs work. Either require it only for weak bases (`sole_known`, `untrusted`), or have code render "inferred" from the bases, as plan §10 already says for the card.

**Still open (blocking §15's answer targets):**
- fix `stating`: require the role word or a code-found pair;
- re-test the privacy gate with a relation whose only stating memory is above the limit;
- settle the hedging rule, checked by code;
- arms that separate the hint, the prompt sentence and bridges;
- answers under a wrong or missing hint;
- C's one wrong-person framing (wq14) and its two new doubting or invented claims;
- "mi pareja";
- a stop-list name at the start of a query or in lowercase ("May's café order?") matches no one;
- "their partner" in an agent's memory isn't a role phrase;
- the rest of a Spanish query relies on a small stop list;
- the matrix hasn't been re-run with round 2's pipeline changes;
- the harness doesn't run through `ModelRouter`;
- one author wrote the busy vault, and it's synthetic.

## Search and answers round 1 (14 Nov 2026)
People in vault search and in search answers (plan §10), on invented fixtures. Outputs are in `results-search/round1/`. `search.py` ranks on top of FunesCore's real vault search (`swift/`, `search-scores`, with the bundled bge-small; Fable 5.2 checked that the Python score equals FunesCore's on all 9,660 hits). The links come from a Haiku People backfill of the same fixture vault (`vault_run.py --vault-json`), read twice. A Fable 5.2 review corrected the first write-up; the figures below are the corrected ones.

**Fixtures:**
- **Main set** (`build_search.py`): Spike G's 208-memory vault (the persona Sam: partner Jordan, sister Lucía, parents, Erik at Nordwind) plus 22 people memories. Among them: facts said only through a role ("my sister drinks her mate bitter"), the same fact about someone else (Ana drinks matcha), a contact who changed, Spanish, an agent's memory. 20 people queries with targets, traps and answer facts, plus Spike G's 42 questions and Spike 2's 30 benchmark tasks as the regression sets.
- **Held-out set** (`author_astra_search.py`): GPT-6-Astra wrote 16 memories and 18 queries blind on Spike G's vault. It's blind but primed: the brief's example is the Lucía-and-mate case, and its queries are topic-word heavy (plain search already gets 15/15). The weights were picked before its results were read, but that order isn't recorded.

**The ranking** (code, no model):
- **Matching:** names and aliases in the query, and role phrases resolved from relations.
- **Admission:** every memory linked to a matched person is a result.
- **Score:** an admitted memory scores max(query score, score for the rest of the query) + 0.3 (0.21 for `sole_known` and `untrusted`, 0.09 for candidates). A memory linked only to people the query doesn't name loses 0.1.
- **How the weights were picked:** the only grid point on the main set with 0 traps in the top 3 and 0 queries worse. Every other measure is flat across the grid. It's a corner, not a safe middle: boost 0.5 makes 2–3 main and 4–5 held-out queries worse, and on the held-out set others 0.2 makes 2 worse.

**Search, without → with people** (by the best target's rank):

| Measure | Main set (both reads) | Held-out set (both reads) |
|---|---|---|
| Right memory in the top 3 (target: top 3) | 16/17 → 16/17; s06 fails either way | 15/15 → 15/15 |
| Best target better · worse | 2 · 0 | 2 · 0 |
| Any target lost from the top 8 (the answer's input) | 1: s07's second target 5 → 9 | 0 |
| Someone else's similar fact in the top 3 | 3 → 0 (6 → 0 over both reads) | not marked by Astra |
| Person-only queries, every memory about the person returned | "Lucía" 5/8 → 8/8, "Jordan" 8/10 → 9/10 | 3/3 → 3/3 |
| Regression sets: 72 queries, 65 identical by construction; the 7 that match a person | 0 worse | not run |

- **The top-3 measure can't see the feature.** It's the same in every grid cell, including boost 0, and no "better" query crosses the top-3 line (2 → 1, 3 → 2). The held-out baseline has no headroom.
- **"Same counts on both reads" hides link errors that score margins absorbed:**
  - held-out read 1 missed Lucía as the sister, so three role-only targets weren't admitted and were demoted, and one stayed first by 0.05;
  - main read 2 linked "my manager" to Priya Raman, which nothing states.

**Answers** (Spike G's prompt and validation, Haiku answering once per arm, read 1's links). Without people → with people, plus bridges, every claim read by hand:
- **Required fact stated:**
  - Main: 16/17 → 16/17. With people, s13 surfaces the quiet anniversary dinner, then doubts it: "it names someone called Sam".
  - Held-out: 11/15 → 13/15. Both gains came from the memory that names the role holder entering the input.
  - Spike G: 35/38 → 36/38. q31 gained "your sister lives in Montevideo".
  - The regex scorer had counted three denials as answers, which is how the first write-up got 17/17 and 15/15.
- **Wrong person named: 0** in either arm.
- **A new kind of false claim.** With people, a18 says Elena's app memory "may not be about her" because it names "Sam's mum": it denies a true link. Without people, the answer had no claims.
- **Agent-written third-person memories fail every time** (s13, a16, a18: 3 of 3). The answer prompt never says the user is Sam, and the link itself isn't passed, only memories.
- **Spike G's 42 questions:** 37 had identical inputs. The 5 that name a person were re-run: no new wrong claims there.
- **Bridges:** 7 answers got one, and none of them was the memory that establishes the relation. Every real gain came from admission.
- **One sample per arm,** and the people arm sees up to 9 memories against 8, so single-question differences are noise-prone.

**What it shows:**
- On a vault this size, plain search already ranks role-only memories well. For "What does Lucía drink?", "My sister drinks her mate" is first without any link.
- What links measurably add:
  - traps out of the top 3;
  - every memory about a person for a name-only query;
  - the memory that says who a role is, in the answer's input (two held-out answers and q31).
- **Links have a real downside.** The +0.3 boost outweighs relevance: other admitted memories end at a median of 0.85, against 0.4–0.7 for plain runners-up. A single missing or wrong link moves a target down several places:
  - Fable removed one target's link at a time: 1 → 4, 1 → 7, 3 → 7;
  - the flawed read gave 1 → 4, 1 → 3, 3 → 5.
  - At 80 memories per person, any memory the read missed would leave the answer's input.
- **§15's "end to end" and "answer" targets aren't passed yet:** the fixture has no headroom, the answers aren't sampled enough, and the bugs below are still open.

**Bugs (Fable 5.2's review, confirmed):**
- **Fixed during the run:**
  - a start year ended a relation (`since` field, plan §4);
  - a role phrase was taken as a name (`is_role_name`);
  - "Marta" didn't match Marta Silva.
- **Open:**
  - links with an ambiguous name are never admitted (plan §10 says both people match);
  - `candidates` role links are never admitted;
  - the query matcher ignores the stop list of common words that are also names, so "in may", "mark a task" and "will" match people;
  - in queries, "my partner's sister" matches the partner;
  - a bridge should be the memory that establishes the relation and never an untrusted one; today role-only memories are stored as a relation's evidence;
  - a role group can be renamed as a person ("my parents" became Elena);
  - `since` combined with a year cue sends "my partner … in 2019" to the nameless group when the partnership started in 2022;
  - memories above the cloud limit get no links at all, though plan §6 says code still resolves them, so the two-Ana case never ran;
  - the rest of a Spanish query is mostly function words, because FunesCore's stop words are English.

**Needed before §15 can pass:**
- A fixture with headroom: one person with 50–80 memories and competing topics, where plain search fails the motivating query.
- Link ground truth for the search vaults, and an injected missed or wrong link.
- Answers read by hand or by a judge, with 3 samples per arm.
- Who a role is (the why line) or the user's name passed to the answer.
- Per-target regression (every target in the top 8), and name-collision queries.
- Traps in the held-out set, and the Spike G regression run on it.

## The author's vault (14 Nov 2026)
This is a People backfill on a private, read-only copy of the author's vault, with Opus 5.5 and the v3 pipeline (`vault_run.py`), oldest memory first. The author then checked the links in a terminal (`review.py`). Memory text, names and verdicts stayed in a private folder outside the repo; only counts are recorded here.

- **Read:** all 365 active memories, every one within the cloud limit (Restricted). 366 calls, none failed; $4.37 API-equivalent; 21 minutes; about 3,100 input tokens and 3.4 seconds a call. Each prompt's roster held only the people relevant to that memory (§6).
- **Found:**
  - 37 people and 4 role groups;
  - 13 relations (9 other, 2 child, 1 parent, 1 colleague);
  - 173 named things (93 products, 53 organizations, 17 places, 10 other);
  - 50 links to a person: 48 from names, and 2 from role phrases (1 `named`, 1 `context`). One more role phrase was left as `candidates`.
- **Review:** the 50 random links were the whole population of links to a person, 6 of them about family. **All 50 right: 0 wrong** (the bar is at most 1 wrong strong link). This measures precision only: references the system missed weren't counted.
- **What the vault says about the feature:** only 3 role phrases ("my sister", "my boss") in 365 memories. The vault is mostly about the author's work, tools and preferences, much of it saved by agents in the third person. Relation inference has little to work on here, while named things (173) are common. So the entity chips (13f) may be worth more for this vault than relations.
- **Haiku 5.5 on the same copy:**
  - 366 calls, none failed; $0.13; 16 minutes; 2.6 seconds a call.
  - Found 38 people, 14 relations and 135 named things.
  - Its 51 links to a person include all 50 of Opus's reviewed links (same memory, same person), so it missed none. The author checked the one extra link: right.
  - **Haiku: 51/51 right, 0 wrong**, at about a thirtieth of Opus's cost.
- **Bug found and fixed:** validation required named things to start with a capital, so it dropped "iPhone", "macOS" and the like (30 drops with Opus, 15 with Haiku).
  - **The fix:** a thing is kept when its quote checks out, whatever its case; role words are still rejected. Only a thing written with a capital somewhere can stop a person of that name, so "a rose" never drops "Rose".
  - **Re-run with Haiku:** thing drops 15 → 1 (a role word); 9 lowercase-start things kept; $0.11.
  - **Link check:** of the 51 reviewed links, 49 came back identical. The other 2 weren't caused by the fix: Haiku didn't list two people who are each named in a single memory. That's run-to-run variation, about 4% of name links in one run; Opus and the first Haiku run both found them.

## Second matrix: the v3 pipeline (14 Nov 2026)
This run uses the same sets, engines, orders and two runs per engine as the first matrix, on the pipeline from plan v3 (§19). All 2,082 calls succeeded. Results are in `results/`; `python3 compare.py` prints both matrices side by side. "Held-out, adj." leaves out the two denial phrases that Astra counts as references (see "Fixture conventions").

| Both sets combined (first → second matrix) | Opus 5.5 | Haiku 5.5 | Terra | Luna |
|---|---|---|---|---|
| Strong links right (target ≥ 98%) | 100% → 100% | 99.3% → **100%** | 98.6% → 99.3% | 99.2% → **100%** |
| Wrong links, any basis | 0 → 0 | 2 → **0** | 4 → 2 | 2 → **0** |
| Recall (target ≥ 85%) | 97.4% → 96.9% | 94.5% → 96.1% | 94.2% → 95.3% | 88.7% → **94.4%** |
| Held-out recall, adj. | 100% → 98.9% | 96.0% → **100%** | 96.0% → 97.4% | 89.8% → **98.4%** |
| Undecidable references kept ambiguous | 100% → 100% | 100% → 100% | 96.6% → 98.3% | 100% → 100% |
| Ambiguous names kept ambiguous | 6/10 → 7/10 | 6/10 → 9/10 | 6/10 → 7/10 | 6/10 → 6/7 |
| Links a story forbids | 0 → 0 | 2 → **0** | 4 → **0** | 3 → **0** |
| Things made into people | 4 → 2 | 7 → 2 | 3 → **0** | 11 → 4 |
| Role phrases the code step missed | 14 → **0** | 14 → **0** | 14 → **0** | 14 → **0** |
| Relation precision | 92% → 96% | 90% → 95% | 92% → 97% | 85% → 93% |
| Invented labels | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |
| Calls · mean seconds · cost | 518 · 4.3 · $5.59 | 520 · 3.9 · $0.21 | 518 · 6.2 · plan | 526 · 4.4 · plan |

The denominators differ a little between matrices. The second matrix counts the 14 role references the code step now finds, and the first had more "things made into people". The recall figures for both matrices use the corrected scorer.

**What v3 changed, measured:**
- **No forbidden links.** Haiku, Terra and Luna had 2–4 each. The denial rule did it ("my manager" in "Sasha is not my manager" now refers to nobody).
- **The code step finds every role phrase in both sets**, with no new false phrases. All 81 name pairs it proposes match the truth.
- **Named things.** "Morgan, the insurer" no longer becomes a person when the company is known first.
- **Luna improved the most** (recall 88.7% → 94.4%). Its misses came mostly from a nameless group that competed with the named sister, and that's fixed.
- **Every engine now meets every fixture target.** Haiku and Luna made no wrong link in either set; Terra made 2.

**Harness bugs found and fixed during the run.** Each was fixed and the matrix re-run from scratch; all numbers above are from the final code.
- **The scorer** didn't count correct links to a never-named role group as resolved, in either matrix.
- **The denial rule** first covered every phrase in the denial's quote: "Marta is not my sister, she's my cousin" also blocked "my cousin". It now has to be the same relation type.
- **Group relations.** When the model attached a relation to a nameless group's id, the group became a second "sister" next to Sara. Now such a relation only updates the group, and the roster stops showing a group once named people fill its count ("my only sister, Sara").
- **Group decisions.** A decision pointing at a nameless group is now kept as unresolved. Once the group is named, the reference resolves from the holders as §7 says (at most `sole_known`).

**Still failing (model behaviour, order-dependent):**
1. **A bare name before its namesakes.** In a15, order 1, "Alex sent me a photo" arrives before "Alex Kim" and "Alex Reed". Name reconciliation re-asks it, but the roster showed the memory itself as known about Alex Kim, which is circular evidence. A last fix leaves the asked memory out of its own roster. It's in the code, but probed only on a15 (`results-probe/`), not in the matrix: Opus and Haiku then get both memories right in both orders; Terra still links one to Alex Kim; Luna drops the names.
2. **A company seen first as a person.** In a18, order 1, "Morgan, the insurer, approved the claim" arrives before "Morgan is the company…". The model gives the person Morgan an "insurer" relation. The re-ask fires, but the model keeps the person (Opus and Haiku in both runs, Luna always). The harm is small: one extra person with one memory, which hide or merge on the People page fixes.
3. **Leftover misses**, mostly "my sister" in s02 and s04 where context decides, left as a group or as candidates. These are safe: nothing wrong is linked.
4. **Terra's two wrong links:** "My brother" taken as Pavel (a02), and "my only therapist" taken as Jo (a09).

**Recommendation (after the vault sample):** Haiku 5.5 by default. It made no wrong link in the v3 matrix or on the author's vault, it matched every link of Opus's that the author checked, and it costs about a twentieth to a thirtieth as much. Opus 5.5 stays offered as the strongest option: its edge on the fixtures is small (arrival-order cases). Terra is acceptable but slow; Luna is acceptable now, but drops names.

## First matrix: the v2 pipeline (14 Nov 2026)

These results are kept in `results-v2/`. Note: the recall figures in this section leave out correct links to a never-named role group ("my dad" when the dad is never named), because of a scorer gap that was fixed later. `compare.py` recomputes them.

Four engines, two independent runs each, on two story sets:
- **Main:** 26 stories, 93 memories, written by Claude.
- **Held-out:** 20 stories, 89 memories, written blind by GPT-6-Astra.

Every story was also replayed in its extra arrival orders. In total: 2,092 calls, none failed. Raw scores are in `results/report-main.md` and `results/report-astra.md`.

### Scores against plan v2 §15 targets

"Adj." is the held-out set without the two denial phrases (see "Fixture conventions"). Targets: strong links ≥98% right, hedged links ≥90% right, recall ≥85%, ambiguity kept ≥90%, no invented labels.

| | Haiku | Opus | Luna | Terra |
|---|---|---|---|---|
| Strong links right (main · held-out) | 100% · 99% | 100% · 100% | 100% · 99% | 100% · 97% (adj. 99%) |
| Hedged (sole_known) links right | 100% · 100% | 100% · 100% | 100% · 100% | 100% · 100% |
| Decidable references resolved (main · adj.) | 95% · 96% | 97% · **100%** | 89% · 90% | 94% · 96% |
| Undecidable references kept ambiguous | 100% · 100% | 100% · 100% | 100% · 100% | 100% · 96% |
| Links the story forbids (held-out) | 2 | **0** | 3 | 4 |
| Things made into people (main + held-out) | 7 | 4 | 11 | 3 |
| Relations: precision · recall (held-out) | 88% · 95% | 91% · 94% | 86% · 93% | 92% · 94% |
| Invented labels | 0 | 0 | 0 | 0 |
| Measured cost per call | $0.0005 | $0.011 | subscription | subscription |
| Mean seconds per call | 3.6–4.0 | 3.9 | 3.8–3.9 | 5.6–6.2 |

Every engine passes the precision targets on both sets, apart from Terra's strong links on the raw held-out set.

Across 2,092 calls, no engine was fooled by quoted speech, a possessive chain ("my sister's husband"), a negation, or the planted instruction in an agent note.

**Opus** is the only engine with no wrong strong link and no forbidden link on either set.

**Haiku** is close, at a twentieth of the cost. Its errors are mostly misses, not wrong links: misses leave a reference ambiguous, which is safe.

**Luna** has the weakest recall. It tends to keep a nameless "sister" group apart from the named sister.

### Real findings (all engines unless noted)

1. **Names need reconciling, just like roles.** In order a15#1, a bare "Alex" arrives before we know there are two Alexes. It gets linked to the first Alex and stays linked after Alex Reed appears. All engines failed this, which is why ambiguous names were kept at 4/8. The fix: when a new person shares a first name with a known one, re-ask the earlier name-only references, the same way `needs_reconcile` already re-asks role references.
2. **Companies and pets with names need memory of their own.** "Morgan is the company that insures my bike" yields nothing. A later "Morgan, the insurer, approved the claim" then becomes a person in every engine. "Bruno is my dog" did the same with Luna and Terra. The pipeline needs a small register of things that aren't people: name, kind, evidence. The roster shows it, and validation rejects those names as people. This is also the seed of the non-person name chips you asked for (places, pets, organizations).
3. **A role pointing to a group should stay a group.** Sometimes the model answers a role with the id of a nameless group, such as "the three brothers". Today that's stored as a `context` link, which looks fully trusted but resolves nothing. It should be stored as the `group` basis. The scores aren't affected: these are already counted as misses.
4. **Denials need an explicit rule.** In "Sasha is not my manager", Opus correctly links "my manager" to nobody (`someone_else`). Luna and Terra in every run, and Haiku once, linked it to Yuki, the actual manager. That's harmless for search, but the story forbids it. Plan rule: a role phrase inside a denial is never linked. The code step can enforce this from the model's `negative` relation on the same quote.
5. **The code step misses some words.** It misses 6 of the held-out set's 91 role references, and none in the main set. They're five distinct phrases: "my migraine doctor", "my skin doctor" (twice), "my ex-partner", "My stepsister", "My desk-sharing colleague". Most are fixed by two changes: let a free modifier stand before a lexicon noun, and handle the ex- and step- prefixes. The rest argue for letting the model propose role phrases the code didn't find, with the code checking the span.
6. **A role and a name in the same sentence.** Take "Elena is Noa Bergman's friend; Mateo is also Noa Bergman's friend." It has two identical role phrases, each belonging to the name before it. Opus resolved both. Haiku, Luna and Terra answered "unknown" in every run. That's safe, but it's a clear miss. A deterministic rule for "X is my R" could settle it before the model is asked.

### Fixture conventions (not system errors)

- **Denials.** Astra counted "my manager" in "Sasha is not my manager", and "my spouse" in "Kai is not my spouse", as references to Sasha and Kai. My main set treats a role phrase in a denial as no reference. All of Opus's held-out misses are these two phrases. Adjusted, Opus resolves 176/176.
- I kept Astra's set exactly as written, so the raw tables keep the raw numbers.

### Cost at vault scale

A backfill takes about 1.1 calls per memory, counting reconciliation. For 1,000 memories:
- **Opus:** about $12, or about 70 minutes with 1 worker.
- **Haiku:** about $0.50.

The daily tidy-up of a few new memories costs well under a cent on either engine. Luna and Terra ran on the ChatGPT subscription, so I couldn't measure a dollar cost, and Terra is about 50% slower.

### Changes to fold into plan v2

- §8 and §9: name reconciliation (finding 1); the register of things that aren't people (finding 2); the denial rule (finding 4).
- §5: a role that points to a group is stored as `group` (finding 3).
- §6: a time counts only when the text states it, and a relation's validity starts only from a stated time or a role changing hands. Both were found and fixed during the spike.
- §15: the engine choice. Opus by default for quality; Haiku is an acceptable cheaper option, since its errors are misses rather than wrong links. Luna is not recommended, because of its recall.
