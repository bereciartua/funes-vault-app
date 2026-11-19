# Phase 13: Facts about you

**Goal:** Funes learns facts about you that your memories state, on one timeline. That means the people in your life and how they relate to you, and where you've worked and when. It uses them in your own search and answers:
- "What does Lucía drink?" finds "my sister drinks mate";
- "What was my job before …?" is answered from your work history.

**Duration:** about 11–13 weekends, plus two weeks of use (an estimate; a failed gate adds a round). **Depends on:** nothing unfinished. **Decision:** [ADR-0032](../architecture/decisions/0032-facts-about-you.md). **Evidence:** [Spikes H, H2, H3 and H3b](spike-results.md#spike-h-people-and-work-history); the harness, fixtures and results are in [`spikes/people/`](../../spikes/people/), and the H3b time model (`facts.py`, `registry.json`, `test_temporal.py`) is the reference for the Swift port. That is evidence for the design, not a qualification of the Swift code: every gate below runs again on Swift. **Specs** (amended in 13.1): every document in ADR-0032's Amends table.

**Order:**
- 13.0 → 13.1 → 13a.1 → 13a.2 → 13b → 13c and 13d (in either order) → 13e → 13f.
- One PR per step, the spec first.
- **Cloud runs on fixtures, and any run on the author's vault, need the author's go-ahead.** The vault runs only on private copies outside the repo; only counts and yes/no answers are recorded.

**Acceptance** (ADR-0032's table, each row assigned to a step; a row is ticked in the step that runs it):

| Measure | Dataset | Target | Step |
|---|---|---|---|
| Full-basis links right | person predicates pooled (≥ 20 per predicate) and works at, fixtures, two reads · a fresh reviewed sample of 50 on the author's vault | ≥ 98% · ≤ 1 wrong | 13a.2 |
| `sole_known` links right | fixtures · every `sole_known` link on the author's vault | ≥ 90% on fixtures, which decides whether `sole_known` attributes ship · ≤ 1 wrong, reviewed | 13a.2 · 13e |
| Recall of resolvable references | fixtures · the author's vault, two reads | ≥ 90% · ≤ 5% differ between reads | 13a.2 |
| Recorded predicates (client) | a fixture with clients, employers and vendors | 0 clients as employers, 0 vendors as clients | 13a.2 |
| Mixed predicates | a fresh fixture, people and jobs in the same memories | every gate above still met | 13a.2 |
| Each *timeline* predicate (works at) | a fresh blind fixture by GPT-6-Astra · the author's reviewed timeline | every fact right, ≤ 1 wrong date; on decidable wordings: right entity ≥ 90% (right with a gap told counted apart); ambiguous on the others; 0 wrong answers, gap answers included; 0 negative triggers; 0 succession from untrusted text or across slots | 13a.2 |
| The time model | Spike H3's and H3b's 60 counterexamples, ported · an adversarial review of the Swift code by GPT-6-Astra and Fable 5.2 | all pass · a final round finds no wrong answer or link from the core model, and no confident misread from the language layer, which fails closed (narrowed in 13a.1; not met in round 18 and waived by the author, see 13a.1's Gates) | 13a.1 |
| The registry canary | the partner timeline: entry and fixture written blind by GPT-6-Astra after the Swift code freeze, with negatives, concurrency, untrusted text, privacy and corrections, reported as distinct questions | no source file changed (checked mechanically); the deterministic part passes in CI; the model run meets the timeline gates (if it does, it may ship) | 13a.2 |
| Search with links on | people and work fixtures, Spike G, the search benchmark; with bge-small and with the provider index | 0 targets worse, out of the top 3, or out of the top 10 | 13b |
| Search latency with links | 50 queries on the author's vault | FR-V-10's 150 ms at p95 | 13b |
| Answers on linked questions | answer fixtures incl. nameless traps, on Haiku and on GPT-5.6-Terra; 3 samples, a blind judge, every gain and loss read by hand | coverage ≥ plain search on every family; 0 wrong entity with correct links; with an injected wrong link, ≤ 1 unmarked claim per 30 answers | 13d |
| Spike G's gates with the feature on | Spike G, both sets | correct claims ≥ 95%, right "no answer" ≥ 90%, answered ≥ 80%, no new wrong claims | 13d |
| Inferred claims code fails to mark | answer fixtures (attributes, labels, neighbouring attributes, bridges) | 0 | 13d |
| Privacy payload tests | facts, orders and decisions stated only above the limit | 0 in any cloud input, including which memories are selected | 13a.2, 13d |
| Port fidelity | Spike H's matrix and Spike H2's timeline, through `ModelRouter` | within 1 point of the Python harness | 13a.2 |
| Two weeks of use | a fixed sample of 30 links and 10 timeline answers on the author's vault | any wrong one turns that predicate's use, and everything downstream of it, off until fixed | 13e |

**If the timeline gate's coverage misses ≥ 90%** (H3b reached 89% on the mixed fixture and 60% on the work fixture, with 0 wrong):
- works at ships *linked* only, with no *timeline* use: a registry change, no code;
- a 13a.2 round fixes the known limits first: intervals written as one string ("March to June 2019"), and dates the work prompt misses.

## 13.0 The Terra answer check · ¼ weekend
- [x] **Spike H's answer arms on GPT-5.6-Terra,** the author's Search answers model, with the Python harness (`spikes/people/search_answers.py`): plain, with attributes, and with a wrong attribute (including the nameless trap), 3 samples, the blind judge, every gain and loss read by hand. Run before 13.1 because it can change decision 7, which 13.1 writes into the specs.
- [x] **If Terra ignores attributes, or follows wrong ones more than Haiku did,** amend decision 7 first (bridges only, or attributes only at full basis). Record a "Spike H4" section in [spike results](spike-results.md).
- *Done (15 Nov 2026): attributes held up on Terra; decision 7 stands, with a marking case added for claims that cite an attributed memory without naming anyone. See [Spike H4](spike-results.md).*

## 13.1 Spec · 1 weekend
- [x] **Amend every document in ADR-0032's Amends table:**
  - **product:** the vision's non-goal, FR-AI-05, FR-AI-08, FR-AI-15 (the one-time backfill exemption), FR-AI-17, FR-V-10, FR-iOS-07, FR-U-01, new FRs for learned facts, and both UX documents;
  - **domain:** the domain model (Entity, Fact, Predicate; Profile), memory processing (§4, §10, a new §11 for facts and the time model), access policy, the glossaries;
  - **architecture:** storage (the migration, purge §4, backups and exports), security and privacy (§3 the trust threat, §5 the Facts row, the Search answers row, the rest-of-query embedding), model providers §1 and §7, companion protocol §3, §4 and §9;
  - **ADRs 0022, 0023, 0026, 0028, 0030,** as notes; and `PRIVACY.md`.
- [x] **Memory processing §11** carries the time model as H3b settled it ([`spikes/people/RESULTS.md`](../../spikes/people/RESULTS.md)):
  - dates as ranges;
  - episodes from assertion intervals;
  - trust per date, order edge and status;
  - one resolver;
  - the intent rules;
  - the matching cases: shared names, stop names, common-word names, possessive chains.
- [x] Reviewed by GPT-6-Astra and Fable 5.2.
- *Done (15 Nov 2026): every document in the Amends table amended, with memory processing §11 as the core. GPT-6-Astra and Fable 5.2 reviewed the change; the fixes include the user's names replaced in the Facts call, cloud selection from sendable facts only, tombstones for corrections, correction targets with tokens, five gated uses, gap answers and the 12-memory limit with bridges. ADR-0032 records the substantive changes as an amendment.*

## 13a.1 Storage, registry, lifecycle and the time model (no model calls) · 3 weekends
- [x] **The registry:** `Resources/facts-registry.json`, ported from `spikes/people/registry.json`: v0.10's 12 predicates, call groups and uses. The language data includes month names and function words, which H3b still had in code. `FactsRegistry` loads and validates it.
  - Each run records the registry and prompt versions it used.
  - **Tests:** no Swift source names a predicate or carries registry vocabulary (the spike's test, extended to month words and function words); a test-only predicate added through the registry alone works end to end.
- [x] **Storage:** `v9_facts`. Tables:
  - entities and aliases, with alias evidence;
  - facts;
  - one evidence table for facts, qualifiers and order edges, with the value each memory asserts, its precision, whether it states the fact, its sensitivity and trust; the user's own dates, orders and qualifiers are rows there too (`source` = user), with episode selectors;
  - mention decisions and their dependencies;
  - manual overrides;
  - the two-week review's off-switches, as local qualification rows (the records themselves ship as `Resources/facts-qualification.json`: model, call-group prompt, registry version, adapter, batching, an optional basis, and the gate each use passed);
  - facts runs.

  No stored start or end dates: episodes are derived. Backups and `funesvault.export.v1` (optional sections) round-trip the learned facts; qualification rows aren't exported.
- [x] **Lifecycle, with a test each:**
  - a memory edit drops its evidence and decisions at the old version, and a status-only change carries them forward;
  - an archive's effect depends on why it was archived;
  - **purge:** an inferred name, label or qualifier goes with its last supporting memory, in every table and in undo snapshots; what a manual entry, an override or a correction references stays as a tombstone (its id, predicate, the user's own values and the normalised alias the user confirmed or typed), and re-attaches when a memory again supports the same predicate and alias;
  - a decision is invalidated when a fact or memory it depends on changes;
  - a correction keyed to the memory and the quoted span survives an edit that keeps the span, and tidy-up merges and splits;
  - manual overrides win over inference;
  - Remove learned facts keeps manual entries, corrections and their tombstones, and leaves qualification rows alone;
  - a user's date or order on one episode follows the episode overlapping its selector, or goes to To check.
- [x] **The time model** in FunesCore `Facts/`, ported from H3b:
  - `DateRange` (the parser: month and day words next to a year only);
  - `Episodes` (intervals; combining with trust; bounds after the last held day; uncertain departures; succession for trusted stale currents only, within a slot);
  - `FactResolver` (holders as of a range; time cues next to the phrase; "former" against the written date; paired decisions);
  - `Timeline` (one ordering rule both ways; stated edges checked against dates; same-year hand-overs; date anchors; years, current, previous);
  - `TimelineIntent` (the anchor ends the operator phrase; someone else's subject; questions about one fact).
- [x] **Trust rule tests:** untrusted evidence never resolves a trusted memory, never ends an episode that has trusted evidence or triggers succession, never orders anything at full basis, and never changes a trusted decision; an episode with only untrusted evidence gives its dates at `inferred` at most and its links at `untrusted`; a link's basis is the weakest in its chain.
- [x] **Gates:** `test_temporal.py`'s 44 and `test_facts.py`'s 16, ported as table-driven Swift tests. Then an adversarial review of the Swift time model by GPT-6-Astra and Fable 5.2, round after round, until one finds no wrong answer or link; every case becomes a test. Budget: H3b took three rounds. **Closed by the author's decision after round 18, without a clean round (see the status).**
  - **Status (16 November 2026):**
    - The 60 spike tests pass, and so do every review case (rounds 1–17) and five differential fuzzes at full size (one or two untrusted rows, user rows, store round trips and purges, reading order, contained names).
    - Findings per round fell from 29 to 4–7 and stayed there. The core model (trust, episodes, ordering, storage) converged: Fable 5.2 found no wrong answer or link in rounds 15 and 17. The language layer (role-phrase quotes and chains, timeline intent) didn't: each fix exposed a neighbouring phrasing, which an adversarial review of open text will always find.
    - **The gate, narrowed after round 17:** the language layer now fails closed (memory processing §11.3, §11.7: a question outside the grammar gets plain search; a phrase that may be quoted is skipped). Round 18 is the last: a wrong answer or link from the core model fails it, and so does a confident misread from the language layer; a missed answer doesn't. A core failure in round 18 means revisiting the design. The language layer's coverage is measured by 13a.2's fixture gates (decidable wordings, recall).
    - **Round 18 wasn't clean.** Core model: Fable 5.2 found nothing (with two new core fuzzes, clean at 6,000 iterations and 100 vaults); GPT-6-Astra found one restore bug: a restore that skips a duplicate memory didn't re-validate the decisions resting on what that memory supported. It was the second bug in two rounds in that one path. Language layer: five confident misreads of wordings the grammar still accepted ("before leaving Acme", a lowercase or sentence-initial unknown subject, "since 2016", guillemets and quotes across lines). All six are fixed, the language ones by refusing more.
    - **Closed on 16 November 2026 by the author's decision; the gate wasn't met.** The author waived the narrowed criterion after round 18 rather than run more rounds; the box is ticked for that decision, not for a clean round. The design revisit that a core failure called for was limited to that path: a follow-up, bereciartua/funes-vault-app#108, rewrites the core finding's path (restoring part of a backup) to restore everything and then purge the skipped memories, reusing the purge path the fuzzes cover. ADR-0032 records the narrowing and the waiver as an amendment. 13a.2's timeline and recall gates still apply.
    - The `facts-qualification.json` records ship with 13a.2's gates.

## 13a.2 Extraction, qualification and the backfill · 3–3½ weekends
- [x] **A fixture harness** that runs the spike fixtures through the Swift pipeline and `ModelRouter`, and writes `score.py`- and `score_facts.py`-compatible output (port fidelity needs it).
- [x] **Extraction:**
  - **The task:** a `facts` task in `ModelRouter`, with two call groups, people and work, as separate calls (H3: one merged call lost 7–9 points of relation recall). The prompt and schema are generated per group from the registry.
  - **Validation:** quotes; names; times only from the text; the predicate's object kind; roles from the lexicon; code-applied pairs and denials; the secret scanner.
  - **Apply** in one transaction, only if the memory and the roster entries it used are unchanged.
  - **Memories the model can't read** (above the limit, no model, cap reached) get code-only links after the model calls, and never appear in a roster.
  - **Activity** records ids and counts only.
- *Status (16 November 2026), harness and extraction:*
  - The `facts` task is `FactsExtractor` with `ModelRouter`'s Facts model. The prompt wording is `Resources/facts-prompt.json` (the vocabulary test keeps it out of Swift); its instructions and schema equal the spike's for both groups, with roster ids as `e…`. Migration `v10_alias_provenance` records which call gave each alias.
  - Nothing in the app calls it yet. A cloud Facts model was refused (code-only links instead) until the privacy step built rosters from sendable items only (lifted on 17 November 2026, below).
  - **Replay** of the spike's recorded Haiku calls (`spikes/people/export_replay.py`) through the Swift pipeline: validation equals the spike's `validate` on all 437 calls. `score.py` gives the same numbers on the astra and mixed sets. On the main set there are two more misses, no wrong links:
    - a stale decision is replaced by the re-read's answer ("unknown"), where the spike kept its earlier one;
    - an agent's memory named the partner first, so the trusted memories' partner is another entity (§11.4's alias trust), and "my partner" has two holders.
  - With Swift's time model on the mixed set: 0 wrong answers, 0 negative triggers, 16 right; 11 questions get no intent, which is 13a.1's grammar failing closed (coverage for the gates).
  - Reviewed by GPT-6-Astra and Fable 5.2: the plan, and the diff in three rounds (the last found nothing high).
  - **Live run** (16 November 2026, the author's go-ahead): the mixed fixture with Claude Haiku, all orders, both groups ([`spikes/people/results-13a2/report.md`](../../spikes/people/results-13a2/report.md)). Full-basis links 31/31 right; relation recall 95% (the spike's fresh run: 93%); 0 wrong timeline answers on the Swift time model. But two wrong `sole_known` links in one play: a reconciliation re-read whose quotes didn't validate replaced a good first reading, which erased the manager it had found. And 230 calls against the spike's 177, since 13a.1 invalidates decisions on any change to their predicate. The queue step must scope a reconciliation call to what it re-asks (roles or names), as the spike did, before the gates run.
- [x] **Privacy:**
  - a roster or decision is sent only if every memory behind it, decision dependencies included, is within the cloud limit;
  - *recorded* facts too;
  - manual entries use the sensitivity the user picked;
  - the profile's names are matched locally to *you*, replaced by "the user" in the memory text sent (with an offset map for quotes), never added and never in a roster; another person sharing the name keeps it.

  **Payload tests** with sentinel strings at each sensitivity.
- *Status (17 November 2026), privacy:*
  - **The sendable graph** (`FactStore.load(sendable:)`, memory processing §11.9): a cloud Facts call's roster comes from the graph read as if what's above the cloud limit didn't exist, in the same read as the call, so adding something above the limit changes nothing a cloud call sees or which memories reconciliation sends. A fact is what its sendable evidence says; it's withheld whole when a correction of it is above the limit. A person is withheld whole only when a reading above the limit introduced one of their names (sendable names may have been joined through it), or their own correction or typed name is above it; a merge spreads it. Dependencies are judged at the time each was made, as decisions' are, so something above the limit added later changes nothing: a name link when someone the name could mean was partly hidden as it was read, a statement about someone the memory doesn't name when that person or any holder of its predicate was, repeated until nothing more is dropped; a decision unless all it depended on was sendable. Confirmed aliases count only with sendable evidence; code-only links hide nothing.
  - **Typed items:** each roster line goes to `ModelRouter.send` with the highest sensitivity behind it, as the memory and the quoted memories already did. A memory above the limit makes no request (code-only links).
  - **The cloud refusal is lifted** (`unfilteredRostersAllowed` is gone); a local model still gets the whole roster. Validation and the apply use the whole graph. A cloud answer about someone the call couldn't see isn't decided: a name that could also mean a withheld person is kept as ambiguous with nothing attached to them, and a role answer or a statement about someone the memory doesn't name is dropped when a holder of the predicate was unseen.
  - **The queue's call sites:** full and partial re-reads share `prepare`. Reconciliation records and compares what a reading knew on the graph it saw (`sendable` through `FactStore.apply`, `FactsReconciler.reconcile` and `sweep`, from `FactsQueueWorker`), so a change above the limit selects no memory for a cloud re-read and a memory above it isn't reconciled; a decision is revalidated in code on unchanged knowledge only when that graph has every holder (named or counted), and one a holder above the limit invalidated stays invalidated for code to resolve.
  - **Your names:** the profile matcher in `FactsSentText` (§11.3): a namesake keeps their name inside a known full name, or as the start of an unknown one (a title-case word on an ordinary line, not a stop name, month, weekday or known thing's word; weekdays added to the registry's language); a bare name is *you*. Longer profile names match in any case. Validation drops a person named exactly like you; a roster lists no alias that is one, and its names and labels go through the matcher. Phrases and pairs are sent as the text sent has them.
  - **Group provenance:** a group a memory states without a count is now evidence on the group's fact, as counts were (a denial isn't), so it has a memory behind it for the sendable rule, and a purge takes it (before, such a group outlived its memory).
  - **Payload tests** (`FactsPrivacyTests`): sentinel names, quoted words, labels, group labels, things and manual entries at every sensitivity, a fact stated only above the limit about a sendable person, and the user's name; at every limit, none above it reaches any cloud input and all within it do, the quoted memories and roster lines are within it, and `.never` makes no request. Unit tests cover each rule above, including a restricted restatement that changes nothing a cloud call sees or selects, a sensitivity raised after a statement came through the roster, merges, and decisions not revalidated without an unseen holder.
  - **Replays** (`facts_harness.sh` mixed, main, astra): reports and `score_facts.py` output identical to main, calls 181, 122 and 143, no wrong links; Swift's own schedule on mixed 180 calls.
  - **Accepted:** a namesake known by one word alone can't be learned through a cloud model, and a title-case common word after your name on an ordinary line ("Dani Madrid flight is booked") still reads as a surname, so your name is sent there; a decision a holder above the limit invalidated isn't decided again (code resolves its phrase), so it's missing from the sendable graph; when a memory above the limit is deleted, what other memories' readings rested on it is no longer dropped (a later step should re-read those readings after a purge); the snapshot's sensitivities are checked at send, as in every other task; the sendable load doubles a cloud `prepare`'s reads, and reconciliation's (fine for fixtures, not yet for the backfill); count-less groups read before this step get their evidence when re-read.
  - Reviewed by GPT-6-Astra and Fable 5.2: the plan (narrower name rules, per-fact rather than per-person withholding, namesake dependencies, typed lines, reconciliation on the sendable graph, answers about unseen people), and the diff (facts as their sendable evidence says rather than withheld whole, so a restatement above the limit changes nothing a cloud call sees; dependencies on any hidden fact of a holder, judged at the time each was made (a source dated no later than its memory, a statement by its own reading), and transitive; revalidation only with every holder seen, named or counted; role answers through an ambiguous namesake dropped; labels through the matcher; short lines and non-names after your name; merges; partial-to-full promotion keeping the limit).
- [x] **`ProcessingQueue`:** a low-priority lane that pauses while New memories or the tidy-up wait. Today it runs one job at a time and dedupes by subject and kind, so it gains revision- and call-group-aware scheduling. It also runs reconciliation (a new holder, a new fact about a candidate, a name shared). 13a.1's graph reopens an earlier bare-name mention as `ambiguous` when a second trusted entity shares the name (`reopenSharedNames`); through the store, the queue finds these from alias evidence (a one-word alias whose normalised form now matches several trusted entities) and re-reads that memory, and its link reads as ambiguous until then.
- *Status (17 November 2026), the queue:*
  - **The lane:** `facts` jobs, one per memory and call group, run only while no New memories or tidy-up job is queued or running and no tidy-up run is open. A newer version or a reconciliation asks for a job again; one asked for while it runs (`processing_job.generation`) runs again whatever its outcome. The job reads in full when the model hasn't read that version in that group; otherwise it asks only what's due, or makes no call.
  - **Reconciliation** (`FactsReconciler`): every change to learned facts queues one sweep in the same transaction (`bumpRevision`), run after the memories' jobs. Migration `v11_facts_asked` records what each reading was asked knowing (holders and candidates as the call saw them, no timestamps). The sweep finds undecided phrases whose holders changed, names that read as ambiguous (the model's, or reopened from alias evidence when a namesake came since the reading) whose candidates changed, and decisions 13a.1 invalidated. It revalidates those in code when what they rest on stands: a `named` decision whose memory still names the person, or unchanged knowledge.
  - **Partial re-reads** (the fix the live run called for): a reconciliation call applies only the phrases and names it re-asked. A phrase whose answer fails validation keeps its decision; a name moved to someone else replaces the reading only if validation dropped nothing. A test replays the live run's x09#0 failure on scripted answers: Elise Vale and her fact stay, and m1's "My manager" isn't Karim Rook (a whole re-read with the same answers still loses her).
  - **Replays of the spike's recorded Haiku calls** (`facts_harness.sh`): no wrong links on any set (mixed: links the story forbids 0, full basis 37/37, `sole_known` 4/4; main one more decidable reference right than before, 75/80). Calls: mixed 206 → 181, main 145 → 122, astra 175 → 143; Swift-only re-asks 27 → 2 on mixed.
  - **Call count against the spike's 177** on the mixed fixture: Swift's own schedule (the lane, reconciling after each memory), answered from the recording (`facts_harness.sh mixed schedule`), makes 180 calls, against #110's live 230 (main 120 against the spike's 118, astra 135 against 140, people group only). That replay counts calls; its answers were made knowing other rosters, so it isn't a link measure. Every play reaches a fixpoint: after the lane drains, reconciliation finds nothing due.
  - **Live rerun** (17 November 2026, the author's go-ahead): the mixed fixture with Claude Haiku, all orders, both groups, through the queue ([`spikes/people/results-13a2/report.md`](../../spikes/people/results-13a2/report.md)). Links the story forbids 0 (2 before); full basis 37/37, `sole_known` 4/4; decidable references 49/50 right, as the spike's fresh run; names 48/48; relation recall 93%; 0 wrong timeline answers. **178 calls against the spike's 177** (230 before), 0 Swift-only re-asks, every play settled. x09#0's manager stays Elise Vale.
  - **Not yet:** memory commits queueing facts jobs (with *Learn from memories*, the Settings step), the Mac runner dispatching facts jobs and the tidy-up gate, and asked records in exports. (The first three landed in the Settings step; asked records in exports moved to the backfill step.)
  - Reviewed by GPT-6-Astra and Fable 5.2: the plan (no stored scope, a generation for work asked for mid-run, the sweep queued with every change, fingerprints rather than holder ids), and the diff. Fixed from the diff review: the generation checked in the outcome's own transaction; a partial answer for a version the model hasn't read applies whole; any change in who a re-asked name means (to or from ambiguous included) replaces the reading only when clean; a decision whose re-ask failed isn't asked again until its knowledge changes; the fingerprint has every fact the roster shows about a holder; a partial re-read never falls back to code-only links, and an unavailable model or the cap leaves the read for later.
- [x] **Qualification and gating:**
  - each use of each predicate (recorded, linked, timeline, attributes, bridges) is on only with a qualification record for the current model, call-group prompt, registry version, adapter and batching;
  - turning a use off turns off everything downstream of it, with no code change. A test turns linking off and checks that attributes and bridges go too.
  - Opus 5.5 is offered for the people group; the work group is qualified separately (Haiku only so far).
- *Status (17 November 2026), qualification and gating:*
  - **The records** (`FactsQualification`, memory processing §11.10): `Resources/facts-qualification.json` ships records that pool predicates and uses, each for one engine (the model's full id, never an alias; the adapter with its revision and settings, `claude-code/1;effort=low`; the batching with the pipeline's revision, `one-memory;pipeline=1`), one call group's prompt version and one registry version. The registry version is now a digest of the whole registry except each predicate's uses list (the hand label "v1" hadn't moved when the privacy step added weekdays). The two-week review's off-switches are `fact_qualification` rows (`passed = 0`, `FactsQualification.turnOff`), read with the graph at each call; a local row never turns anything on.
  - **What each use needs is registry data** (`uses` in the registry: linked ← recorded, timeline and attributes ← linked, bridges ← timeline), checked by `validate()`; no Swift names the relations. `FactsUses` is what's on for a configuration: a matching record, no off-switch, and everything the use needs on, transitively. The tests turn linking off and attributes and bridges go; they also use a registry where attributes need the timeline, so the cascade changes with no code change. The registry now declares *attributes* for the person predicates and works at, and *bridges* for works at (ADR-0032 decision 7). Declared isn't on.
  - **Fail closed everywhere:** no graph, load, apply or reconciliation in Sources has a default for what's on; the harness and the time model's tests pass every declared use explicitly (`FactsUses.everyDeclared`, a test-target extension keeps their old calls).
    - *recorded* gates the write side: a group's model is asked only while some predicate of the group is recorded with it (else code-only, `unqualified`). An answer's facts of a predicate that isn't recorded are dropped (`unqualified_predicate`, which doesn't make a reading unclean), and earlier ones are hidden from every path but stay stored, the user's own entries excepted. Its role phrases aren't detected, so they're neither sent nor due. The prompt and schema stay the declared group's, so the prompt version never depends on the gate.
    - *timeline* gates every entry: the intent, the answer, before / after / in range, "previous as of", and the time cue, which resolves to nothing even over a stored decision.
    - *linked*, *attributes* (and its `sole_known` basis) and *bridges* are for 13b and 13d to check.
  - **The model per call group:** `ModelRouter.factsModels`, and `FactsQualification.resolve(chosen:fallback:)`: the chosen model where it qualified for that group, else Haiku where that did, else none, so Opus reads people only once an Opus people record exists. The roster and the sweep are built under the cloud limit when any group's model is a cloud one.
  - **A CI check:** every shipped record must match the current prompt versions, registry version and pipeline revision, and name evidence that exists, so an unqualified change fails a test instead of silently turning Facts off. A stale synthetic record shows the check isn't vacuous.
  - **The harness writes a manifest** per run (`<set>-manifest.json`: the engine, each group's prompt version, the registry version, the models the provider said answered (Claude Code's `modelUsage`, now `ProviderUsage.model`), the fixture's digest, the commit), so a gate run's evidence carries every field of a record's key.
  - **Fixed from the diff review:** a full re-read of a memory replaced its hidden predicate's evidence and role decisions, so the facts went with the next garbage collection; now a re-read keeps what it wasn't asked. Role groups, counts and deaths learned for a hidden predicate alone reached rosters; now they're hidden with it. A retry after invalid output could still call a model whose use was turned off meanwhile; now it starts the job over. The constructors that turn everything on are internal. Runs record the registry's fingerprint. The registry digest leaves out notes. The CI check also covers the adapter revision, and checks that a record turns on what it lists. The harness's default model is a full id. ADR-0032 decision 3 now says a new group re-runs every group's gates.
  - **What's qualified: nothing.** No engine has run the gate datasets. The 17 November live Haiku rerun is one read of the mixed set: full basis 37/37, `sole_known` 4/4, decidable references 49/50, 0 misfiled organizations and 0 wrong timeline answers, but 11 timeline questions got no intent, so it doesn't show the timeline's coverage. It wasn't recorded with its prompt version or the model the alias resolved to, and it predates the privacy step's registry change. So the file ships empty, every use is off, and no model is offered until the Gates step writes records.
  - **Replays** (`facts_harness.sh` mixed, main, astra, and mixed's schedule; every declared use on): score.py reports and score_facts.py output identical to main; calls 181, 122 and 143, Swift's schedule on mixed 180; every line identical up to list order. Gating changes no replay, since what's read, asked and stored doesn't depend on the read-side uses.
  - Reviewed by GPT-6-Astra and Fable 5.2: the plan, then the diff (nothing high from Fable; one high from Astra, fixed). Taken from the plan reviews: fail closed with no default uses; *recorded* off hides earlier rows at load, not just new answers; the timeline checked before stored decisions; the registry version as a whole-registry digest without uses lists (the lexicon is read globally, so per-predicate scoping was unsound); the pipeline and adapter revisions in the key; per-group models with the strictest roster limit; qualification read per call; a pass table that doesn't pool works at with persons or invent criteria.
  - **Not yet:**
    - **Records.** The Gates step runs the gates and writes them, each needing the author's go-ahead for its live runs:
      - Haiku, both groups: main, astra and mixed, two reads, about 2 × (122 + 143 + 180) ≈ 900 calls;
      - the fresh blind work fixture, once GPT-6-Astra writes it, about 100–150 calls;
      - the canary, one read;
      - Opus 5.5, people group only: main, astra and mixed, two reads, about 2 × (120 + 140 + 95) ≈ 700 calls.
    - **A person fixture first:** across main, astra and mixed, child has 3 role references, other 1, parent 15, care 17 and other family 17, every order counted. That's short of "≥ 20 per predicate" before any read, so the Gates step needs a fixture with more of them, or the threshold revisited with the author.
    - ~~Settings uses `resolve` and `ModelRouter.factsModels` (the next step).~~ Done in the Settings step.
    - Re-reading a group when its qualified coverage grows (the backfill step's registry rule).
    - Search and answers check *linked*, *attributes* and *bridges* (13b, 13d).
    - The Gates step makes the harness's manifest part of each record's evidence check (today the CI check only sees that the evidence exists).
- [x] **Settings ▸ AI ▸ Features ▸ Facts** (working name):
  - off by default;
  - a qualified model (Claude Haiku 5.5 by default);
  - *Learn from memories* and *Use in search and answers*;
  - Remove learned facts;
  - the disclosure line.
- *Status (18 November 2026), Settings:*
  - **The page** (`FactsPage`, `ai.features/facts`; 04-ux-mac.md ▸ Page: Facts): *Learn from memories*, *Use in search and answers*, the Model pop-up, its status and disclosure, and Remove Learned Facts…; the Features row ("Not available yet", "Off", "Learning from memories · Used in search and answers", the model and badge or "Choose a model"), Models & Accounts' "Used by: Facts", Privacy & Limits' "Facts: …" line while learning is on. Stored in `AISettings.facts` (user defaults, never exported), off by default; an older settings file reads as off.
  - **What ships: no model, and Facts can't be turned on.** `facts-qualification.json` is still empty, so the page says "No model has passed Funes's tests for Facts yet, so Facts can't be turned on.", the Model row says "None available", both switches are off and disabled (one already on stays enabled so it can be turned off), there's no disclosure and nothing in Privacy & Limits. The qualified states are tested with synthetic records in tests, and shown in the UI review build from review-only records (`@_spi(FactsReview)`, under `FUNES_UI_REVIEW`; that build starts no runner, and the app and runner read only `.bundled`).
  - **Offers** (`AISettings.factsOffers`, `FactsClients`): an account or plan and a full model id whose engine, as this app builds it, a record covers for some call group. One factory builds the picker's engines and the runner's clients; a test checks each provider kind against a built client, and the runner drops a client whose engine isn't its offer's. HTTP accounts count only at their preset's own address. The default is Claude Haiku 5.5 on the first account that can run it; a model that qualified for part of what Facts learns falls back to Haiku on the same account (one destination, one disclosure), and the page says who reads the rest, without naming call groups.
  - **Memory commits queue facts jobs** while learning is on (`ProcessingQueue.enqueueFactsForCommit`, from `MemoryStore.insert`, `update` and `setStatus`, in the commit's transaction), for every version left active or archived. The switch is in-process (`VaultStore.factsLane`, read in the transaction through `funes_facts_learning()`), set from user defaults at launch and on every change, off by default, so tests, the harness and the MCP test server queue nothing.
  - **The Mac runner dispatches facts jobs** with a configuration built per job (`FactsConfiguration`: the chosen client and its fallback, the cloud limit, `Profile.factsAliases`, the shipped records with the local off-switches); a group no model resolves for waits (`no_model`) until the Facts settings change, instead of being consumed code-only.
  - **The gates** (`FactsLane`): a facts job is admitted only while learning is on and nothing closes the lane, inside the claim's transaction (the old `factsPaused` read before it, a race the reviews found). The tidy-up (a run and Tidy Up on one memory) closes the lane and waits for a running facts job; Remove Learned Facts turns learning off, waits, then removes everything inferred and every facts job in one transaction. `FactsExtractor.permit` is checked before every request, retries included, and again at `ModelRouter.send`'s boundary after the cap's write (`SendNotPermitted`): learning off, a closure, or a change to anything a call depends on (the choice, the cloud limit, an account or key, a plan's sign-in, your name) stops a running job before its next request, with nothing sent and no facts written. Every queue in the app is gated (only the harness and the lane-ordering tests opt out, `ungatedFacts`), and a claim whose commit fails releases the lane. A known account problem waits like no model, and a settings change made while a job was deciding "no model" wakes it once its outcome is recorded. Turning learning on stores the default model as the choice, and removing the chosen account leaves "Choose a model", so learning never moves to another account unasked.
  - **Remove's message** says "turning it on again learns from new and changed memories" until the backfill step can re-read them.
  - **Replays** (`facts_harness.sh` mixed, main, astra, and mixed's schedule): score.py rows and score_facts.py output identical to main; calls 181, 122 and 143, Swift's schedule on mixed 180; every line identical up to list order. The harness's queue opts out of the gate (`ungatedFacts`) and adds memories with learning off, so commits queue nothing of their own.
  - **Tests:** `FactsSettingsTests` (offers from synthetic records, engine parity per provider kind against a built client, HTTP accounts only at their preset's address, the default and the same-account fallback, problems, the router dropping a mismatched client, settings round trip and old files reading as off, removing the chosen account, Facts inputs, Used by and What leaves this Mac, your names) and `FactsLaneSwitchTests` (commits queue only while learning is on, every version left active or archived asks again and a delete or confidence change doesn't, admission only while learning is on and the lane open, the tidy-up waiting for a running job, a job stopped before a request and at the send boundary with nothing sent, a claim whose commit fails releasing the lane, Remove waiting then taking every facts job, waking jobs that waited for a model, a name change stopping a job). `test.sh` green.
  - Reviewed by GPT-6-Astra and Fable 5.2: the plan (admission inside the claim's transaction rather than a pause read before it, a permit before every request, Remove as a barrier, a configuration per job, one client factory with an engine check, the canonical address, Haiku's fallback on the same account, no consuming a job code-only when no model resolves, an honest empty state, asked records in exports moved to the backfill step), then the diff. Fixed from the diff review: the permit checked again at the send boundary, after the cap's write (Astra's one high); a claim whose commit fails releasing the lane; a settings change made while a job decided "no model" waking it; a known account problem waiting rather than failing; every app queue gated by default; removing the chosen account no longer moving learning to another account (the choice is pinned when learning turns on); both switches disabled while Remove runs, and its failure shown; the queue kicked when the tidy-up reopens the lane; usage counted when a job throws; the canonical address compared normalised. A second round (Astra) found the permit still checked before the timeout's child task started the request; it's checked again inside that task, right before the request, and a test holds the cap's write while learning turns off. Also from it: Remove's state is shared, so leaving the page doesn't re-enable learning mid-removal, and a plan's sign-in change is told at once rather than after every plan's check.
  - **Not yet:**
    - **Asked records in exports** (the backfill step, before the Gates): a restored vault re-reads every restored memory in full once learning is on, and until a model reads a memory again the sweep can't reconcile it (it selects model-read memories through `facts_asked`).
    - **The backfill step:** the sheet, Read Existing Memories…, progress and the cap-waiting status; re-reading memories that have no model reading after the cloud limit rises or a model comes back (a version only asks again when the memory changes); Remove's original message.
    - **13b and 13d read *Use in search and answers*** (`AISettings.facts.use` is stored; nothing reads it yet, and it can't be turned on while nothing qualifies).
    - A running facts job isn't cancelled when New memories arrive (it finishes its request, up to 60 s per try).
    - Codex's file-read switch isn't part of its adapter (for the Gates step, if Codex is ever measured).
    - The sweep doesn't run while learning is off, so a decision a correction invalidated stays invalid until learning is on again (fails closed).
    - The page offers from the shipped records without the local off-switches (the runner applies them, so a model turned off there waits as "no model" while the page says Ready); the off-switches come with 13e's review.
    - Every launch and every Facts settings change wakes all jobs waiting for a model, which run one at a time back to their day's wait: fine at this vault's size.
- [ ] **Backfill and cost:**
  - **The first backfill** is the one-time exemption from the daily cap: started by the user, with its call count and cost shown first, resumable; one exemption in total, for both call groups. For the author's vault that's about 800 calls, about $0.25 API-equivalent, under an hour.
  - **After it,** new and changed memories count against the cap, in the agents' 40% share when an agent wrote them.
  - **A registry change:** language-only changes apply at once with no re-read. An extraction change re-reads only the affected call group, in the low-priority lane under the cap, batched per release.
- [ ] **Gates** (the acceptance rows assigned to 13a.2): links, `sole_known` on fixtures, recall, client, mixed, the fresh blind work fixture, the canary, port fidelity, privacy payloads.

## 13b Mac search · 1–2 weekends
- [ ] **Matching:** names, aliases and role phrases in the query map to entities, with no model call. A shared name matches everyone who has it; stop names, common-word names and possessive chains follow §11's cases.
- [ ] **Admission without a boost:**
  - a matched entity admits its memories, each scored by the better of the query and the rest of the query (the query without the matched names);
  - a memory linked only to entities the query doesn't name drops 0.1;
  - a timeline query admits the answer fact's stating memories, and the anchor's own memories drop 0.1;
  - a query that names no known entity is unchanged.

  Each result records how it was admitted, for 13d's privacy selection.
- [ ] **The rest of the query** is embedded locally with bge-small; with the provider index (ADR-0023), it's a second embedding request, only when every matched name comes from sendable facts.
- [ ] **Why lines** on results ("my sister → Maria (only sister Funes knows)", "worked at Acme until 2023"), with **Not <name>** and **Not this** on the Mac. A correction recomputes dependent links at once (13a.1's lifecycle).
- [ ] **Older phones:** link-admitted results reach the phone as ordinary results until 13d's protocol fields; nothing inferred is shown there before then.
- [ ] **Owner side only:** agent retrieval, the related-memories finder and the tidy-up never use links, with regression tests that prove it.
- [ ] **Gates:** search with links (both indexes) and latency.

## 13c The People & history section · 2 weekends
- [ ] **Vault sidebar ▸ People & history** (working name): entities by how many memories mention them, role groups, filters by kind.
- [ ] **An entity's page:** name, aliases, kind, the facts about you that involve it with their basis, every memory that mentions it with its why line. *Recorded* facts (clients) are shown and can be removed. Actions: rename, change kind, set predicate and label, mark deceased or former, merge, hide, Not <name>.
- [ ] **Your timeline:** dated facts with title history, stating memories and basis ("probably former"). Conflicting dates and undecidable orders are shown as such. Actions: set or clear dates, mark current or former, add an order, add a fact yourself.
- [ ] **To check:** only candidates the model couldn't settle, suggested merges, and corrections or manual dates whose episode no longer matches one episode.
- [ ] After the backfill: "Funes found N people, N employers and N other names".
- [ ] VoiceOver; the string catalog; UI snapshots `people-list`, `people-entity`, `people-timeline`, `people-to-check` (light and dark).

## 13d Answers and the iPhone · 2 weekends
- [ ] **`SearchAnswerer`:**
  - **Attributes** from the registry's phrases, as 13.0 decided: "Lucía, your sister"; "probably…" for `sole_known` when its fixture gate passed; "your sister; Funes isn't sure which" for `candidates`, without names. Attributes are never quotable text.
  - **Bridges** for timeline answers: up to 2 on top of the 10 results ("Read 10 results and 2 from your history"), as `m11` and `m12`, within 15,000 + 3,000 characters. None on Apple on-device. An undecidable order gets plain search and a note, with no bridges; a `gap` answer may carry them.
  - **Your own names** become "the user", with an offset map so `QuoteLocator` still highlights the original; a namesake isn't replaced.
- [ ] **Privacy selection:**
  - a cloud answer reads the search re-ranked as if only sendable facts existed (admission, the demotions, the rest-of-query score, the timeline's choice and bridges), restricted to the results shown;
  - a shown result outside that set stays in your list, isn't sent, is counted as not read on the card, and its slot isn't refilled;
  - an answer fact decided only above the limit gets plain search.

  Tests cover which memories are selected and the card's counts.
- [ ] **Inferred, by code:** a claim is marked inferred, and carries the fact, link or order ids it rests on (and a bridge's order basis), when it:
  - names an entity its cited text doesn't name;
  - states a predicate, label, qualifier or date that text doesn't state;
  - cites a bridge;
  - or cites a memory carrying an attribute, when the search names the attributed entity (by name or role phrase) and the cited text doesn't (Spike H4: it marked all 5 wrong-person claims).

  Each marked claim carries its correction targets.
- [ ] **The Mac's answer card:** inferred claims marked, with their corrections (**Not <name>**, **Not this**). An answer in flight is dropped when the facts revision changes (only the iPhone holds one).
- [ ] **The companion protocol:**
  - the why line on results;
  - an inferred flag, ids, basis and correction targets on claims;
  - `facts.reject`, taking one correction target;
  - a capability flag: for an older phone the Mac sends neither attributes nor bridges and drops every claim it would mark inferred, tested; `memories.answer` recomputes admission from the query, never trusting ids alone;
  - a facts revision in `status.get`, with an epoch that a restore renews, which drops the phone's held or in-flight answer.
- [ ] **iPhone:** why lines and corrections on results; inferred claims marked, with Not <name> and Not this.
- [ ] **Gates:** answers on Haiku and Terra; Spike G's gates with the feature on; 0 unmarked inferred claims; privacy payloads, including selection.

## 13e Two weeks of use
- [ ] **Review a fixed sample after two weeks:** 30 links, 10 timeline answers, and every `sole_known` link on the author's vault, reviewed privately. Any wrong one turns that predicate's use, and everything downstream of it, off until fixed.
- [ ] **Exit:** the sample passes, or the failing uses are off and a fix is planned. The default stays off (ADR-0032 decision 3); changing it would be an ADR amendment.

## 13f Ship · ¼ weekend
- [ ] README, PRIVACY.md (what the Facts task sends, and what answers now send), docs, CHANGELOG.
- [ ] `sh scripts/test.sh` green; the iPhone app builds; a TestFlight build with the author's go-ahead.

**Later (not Phase 13), each a registry entry with a fixture and gates, or a generic capability by an ADR amendment:**
- **the partner timeline:** H3b's canary had 0 wrong answers but 88% coverage, below the gate;
- **lives in;**
- object classes ("which phone"), implicit anchors ("before this one"), scope to another fact ("my manager at Acme"), cross-predicate anchors;
- agents' use, a separate decision.
