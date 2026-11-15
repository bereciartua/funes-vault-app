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
| The time model | Spike H3's and H3b's 60 counterexamples, ported · an adversarial review of the Swift code by GPT-6-Astra and Fable 5.2 | all pass · a final round finds no wrong answer or link | 13a.1 |
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
- [ ] **Amend every document in ADR-0032's Amends table:**
  - **product:** the vision's non-goal, FR-AI-05, FR-AI-08, FR-AI-15 (the one-time backfill exemption), FR-AI-17, FR-V-10, FR-iOS-07, FR-U-01, new FRs for learned facts, and both UX documents;
  - **domain:** the domain model (Entity, Fact, Predicate; Profile), memory processing (§4, §10, a new §11 for facts and the time model), access policy, the glossaries;
  - **architecture:** storage (the migration, purge §4, backups and exports), security and privacy (§3 the trust threat, §5 the Facts row, the Search answers row, the rest-of-query embedding), model providers §1 and §7, companion protocol §3, §4 and §9;
  - **ADRs 0022, 0023, 0026, 0028, 0030,** as notes; and `PRIVACY.md`.
- [ ] **Memory processing §11** carries the time model as H3b settled it ([`spikes/people/RESULTS.md`](../../spikes/people/RESULTS.md)):
  - dates as ranges;
  - episodes from assertion intervals;
  - trust per date, order edge and status;
  - one resolver;
  - the intent rules;
  - the matching cases: shared names, stop names, common-word names, possessive chains.
- [ ] Reviewed by GPT-6-Astra and Fable 5.2.

## 13a.1 Storage, registry, lifecycle and the time model (no model calls) · 3 weekends
- [ ] **The registry:** `Resources/facts-registry.json`, ported from `spikes/people/registry.json`: v0.10's 12 predicates, call groups and uses. The language data includes month names and function words, which H3b still had in code. `FactsRegistry` loads and validates it.
  - Each run records the registry and prompt versions it used.
  - **Tests:** no Swift source names a predicate or carries registry vocabulary (the spike's test, extended to month words and function words); a test-only predicate added through the registry alone works end to end.
- [ ] **Storage:** `v9_facts`. Tables:
  - entities and aliases, with alias evidence;
  - facts;
  - one evidence table for facts, qualifiers and order edges, with the value each memory asserts, its precision, whether it states the fact, its sensitivity and trust;
  - mention decisions and their dependencies;
  - manual overrides;
  - qualification records (model, call-group prompt, registry version, adapter, batching, and the gate each use passed);
  - facts runs.

  No stored start or end dates: episodes are derived. Backups and `funesvault.export.v1` (optional sections) round-trip every table.
- [ ] **Lifecycle, with a test each:**
  - a memory edit drops its evidence and decisions at the old version, and a status-only change carries them forward;
  - an archive's effect depends on why it was archived;
  - **purge:** an inferred name, label or qualifier goes with its last supporting memory, in every table and in undo snapshots; a correction with nothing left keeps only ids;
  - a decision is invalidated when a fact or memory it depends on changes;
  - a correction keyed to the memory and the quoted span survives an edit that keeps the span, and tidy-up merges and splits;
  - manual overrides win over inference;
  - Remove learned facts keeps manual entries and corrections.
- [ ] **The time model** in FunesCore `Facts/`, ported from H3b:
  - `DateRange` (the parser: month and day words next to a year only);
  - `Episodes` (intervals; combining with trust; bounds after the last held day; uncertain departures; succession for trusted stale currents only, within a slot);
  - `FactResolver` (holders as of a range; time cues next to the phrase; "former" against the written date; paired decisions);
  - `Timeline` (one ordering rule both ways; stated edges checked against dates; same-year hand-overs; date anchors; years, current, previous);
  - `TimelineIntent` (the anchor ends the operator phrase; someone else's subject; questions about one fact).
- [ ] **Trust rule tests:** untrusted evidence never resolves a trusted memory, never ends a fact or triggers succession, never changes a trusted decision; a link's basis is the weakest in its chain.
- [ ] **Gates:** `test_temporal.py`'s 44 and `test_facts.py`'s 16, ported as table-driven Swift tests. Then an adversarial review of the Swift time model by GPT-6-Astra and Fable 5.2, round after round, until one finds no wrong answer or link; every case becomes a test. Budget: H3b took three rounds.

## 13a.2 Extraction, qualification and the backfill · 3–3½ weekends
- [ ] **A fixture harness** that runs the spike fixtures through the Swift pipeline and `ModelRouter`, and writes `score.py`- and `score_facts.py`-compatible output (port fidelity needs it).
- [ ] **Extraction:**
  - **The task:** a `facts` task in `ModelRouter`, with two call groups, people and work, as separate calls (H3: one merged call lost 7–9 points of relation recall). The prompt and schema are generated per group from the registry.
  - **Validation:** quotes; names; times only from the text; the predicate's object kind; roles from the lexicon; code-applied pairs and denials; the secret scanner.
  - **Apply** in one transaction, only if the memory and the roster entries it used are unchanged.
  - **Memories the model can't read** (above the limit, no model, cap reached) get code-only links after the model calls, and never appear in a roster.
  - **Activity** records ids and counts only.
- [ ] **Privacy:**
  - a roster or decision is sent only if every memory behind it, decision dependencies included, is within the cloud limit;
  - *recorded* facts too;
  - manual entries use the sensitivity the user picked;
  - the profile's names are matched locally to *you*, never sent in a roster, and another person sharing the name keeps it.

  **Payload tests** with sentinel strings at each sensitivity.
- [ ] **`ProcessingQueue`:** a low-priority lane that pauses while New memories or the tidy-up wait. Today it runs one job at a time and dedupes by subject and kind, so it gains revision- and call-group-aware scheduling. It also runs reconciliation (a new holder, a new fact about a candidate, a name shared).
- [ ] **Qualification and gating:**
  - each use of each predicate (recorded, linked, timeline) is on only with a qualification record for the current model, call-group prompt, registry version, adapter and batching;
  - turning a use off turns off everything downstream of it, with no code change. A test turns linking off and checks that attributes and bridges go too.
  - Opus 5.5 is offered for the people group; the work group is qualified separately (Haiku only so far).
- [ ] **Settings ▸ AI ▸ Features ▸ Facts** (working name):
  - off by default;
  - a qualified model (Claude Haiku 5.5 by default);
  - *Learn from memories* and *Use in search and answers*;
  - Remove learned facts;
  - the disclosure line.
- [ ] **Backfill and cost:**
  - **The first backfill** is the one-time exemption from the daily cap: started by the user, with its call count and cost shown first, resumable. For the author's vault that's about 800 calls.
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
- [ ] **The rest of the query** is embedded locally with bge-small; with the provider index (ADR-0023), it's a second embedding request.
- [ ] **Why lines** on results ("my sister → Maria (only sister Funes knows)", "worked at Acme until 2023"), with **Not <name>** and **Not this** on the Mac. A correction recomputes dependent links at once (13a.1's lifecycle).
- [ ] **Older phones:** link-admitted results reach the phone as ordinary results until 13d's protocol fields; nothing inferred is shown there before then.
- [ ] **Owner side only:** agent retrieval, the related-memories finder and the tidy-up never use links, with regression tests that prove it.
- [ ] **Gates:** search with links (both indexes) and latency.

## 13c The People & history section · 2 weekends
- [ ] **Vault sidebar ▸ People & history** (working name): entities by how many memories mention them, role groups, filters by kind.
- [ ] **An entity's page:** name, aliases, kind, the facts about you that involve it with their basis, every memory that mentions it with its why line. *Recorded* facts (clients) are shown and can be removed. Actions: rename, change kind, set predicate and label, mark deceased or former, merge, hide, Not <name>.
- [ ] **Your timeline:** dated facts with title history, stating memories and basis ("probably former"). Conflicting dates and undecidable orders are shown as such. Actions: set or clear dates, mark current or former, add an order, add a fact yourself.
- [ ] **To check:** only candidates the model couldn't settle, and suggested merges.
- [ ] After the backfill: "Funes found N people, N employers and N other names".
- [ ] VoiceOver; the string catalog; UI snapshots `people-list`, `people-entity`, `people-timeline`, `people-to-check` (light and dark).

## 13d Answers and the iPhone · 2 weekends
- [ ] **`SearchAnswerer`:**
  - **Attributes** from the registry's phrases, as 13.0 decided: "Lucía, your sister"; "probably…" for `sole_known` when its fixture gate passed; "your sister; Funes isn't sure which" for `candidates`, without names. Attributes are never quotable text.
  - **Bridges** for timeline answers: up to 2 on top of the 10 results ("Read 10 results and 2 from your history"). None on Apple on-device. An undecidable order gets plain search and a note, with no bridges.
  - **Your own names** become "the user", with an offset map so `QuoteLocator` still highlights the original; a namesake isn't replaced.
- [ ] **Privacy selection:**
  - admission, the demotion, the timeline's choice and bridges use only sendable facts and edges;
  - a result admitted only through an unsendable link stays in your list, isn't sent, is counted as not read on the card, and its slot isn't refilled;
  - an answer fact decided only above the limit gets plain search.

  Tests cover which memories are selected and the card's counts.
- [ ] **Inferred, by code:** a claim is marked inferred, and carries the fact, link or order ids it rests on (and a bridge's order basis), when it:
  - names an entity its cited text doesn't name;
  - states a predicate, label, qualifier or date that text doesn't state;
  - cites a bridge;
  - or cites a memory carrying an attribute, when the search names the attributed entity (by name or role phrase) and the cited text doesn't (Spike H4: it marked all 5 wrong-person claims).
- [ ] **The Mac's answer card:** inferred claims marked, with **Not <name>** and **Not this**. The held answer is dropped when the facts revision changes.
- [ ] **The companion protocol:**
  - the why line on results;
  - an inferred flag, ids and basis on claims;
  - `facts.reject`;
  - a capability flag: an older phone gets neither attributes nor bridges, tested;
  - a facts revision in `status.get`, which drops the phone's held or in-flight answer.
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
