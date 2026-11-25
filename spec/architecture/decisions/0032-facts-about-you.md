# ADR-0032: Funes learns facts about you from your memories, on one timeline, for your own search and answers

**Status:** Accepted · 2026-11-15 (proposed 2026-11-14).
- Revised the same day after GPT-6-Astra and Fable 5.2 reviewed the first draft.
- Reworked on 2026-11-15 around one generic model (the first draft had separate structures for people and for work history), then revised after both reviewed the rework.
- Revised again on 2026-11-15 with Spike H3's results and both reviews of it, then with Spike H3b's.
- **Amended on 2026-11-15** when the spec was amended (Phase 13.1), after both reviewed it. The changes in substance:
  - a same-year hand-over with nothing else in the window is answered at `inferred`, from Spike H3b;
  - a gap answer names the entity and tells the gap;
  - the user's names are replaced in the Facts call's input too, not only in answers;
  - corrections and manual entries keep tombstones (the user's own values and confirmed alias) instead of ids only;
  - untrusted evidence never ends an episode *that has trusted evidence*. An episode with only untrusted evidence keeps its dates at `inferred` at most and its links at `untrusted`, because dates and links have separate bases.
- **Amended on 2026-11-16** to record two decisions about the adversarial review gate for the time model during Phase 13a.1: it was narrowed after round 17, and the author closed it after round 18 although round 18 didn't meet it.
  - **Why:** after 17 rounds the core model (trust, episodes, ordering, storage) seemed to have converged, but the language layer (role-phrase quotes and chains, timeline intent) hadn't. Each fix exposed a neighbouring phrasing, which a review of open text will always find.
  - **The narrowing (after round 17):** the language layer fails closed. A question outside the grammar gets plain search, and a phrase that may be quoted is skipped. The final round counts a wrong answer or link from the core model, and a confident misread from the language layer; a missed answer doesn't count there. The language layer's coverage is measured by 13a.2's fixture gates instead.
  - **The closure (after round 18):** the narrowed criterion wasn't met. Round 18 found one core bug, in restoring part of a backup, and five confident misreads; all six were fixed, the misreads by refusing more. The design revisit that a core failure called for was limited to that path. The author waived the criterion and closed the review rather than run more rounds. A follow-up, bereciartua/funes-vault-app#108, rewrites that restore path to restore everything and then purge the skipped memories. The timeline and recall gates in 13a.2 still apply.
- **Amended on 2026-11-20** with Phase 13e.1, the timeline round, after GPT-6-Astra and Fable 5.2 reviewed its plan; each change is the author's decision:
  - **A stated rename is one entity on the timeline.** A trusted statement that gives, as another name, exactly the trusted name of one other holder ("Renamed Lattice Harbor Labs in 2020") reads both as one entity for episodes and timeline answers, at `inferred` at most. Never for a return, an order edge between them, a trusted job of the same kind between them, or the user's Not the Same. Links and search keep both; loose matches ("Fenwick Lab", "Fenwick Laboratories") stay a suggestion and are told. This reverses "a merge suggestion, never a merge" for the timeline only, by the author's rule that names and relations are inferred and correctable rather than asked.
  - **A trusted never-denial reaches an agent's claim.** "I never worked at Orlin Labs" negates the facts of that predicate held by an entity only untrusted memories named, under exactly the same name; an untrusted claim after it doesn't start a new one, a trusted one does. It adds that entity no alias, evidence or link (decision 4's trust rule).
  - **An answer resting only on untrusted text is told.** The user's own memories may say otherwise and not have been read (above the cloud limit): the 13a.2 canary's wrong "current" answer.
  - **The timeline gate's measures** judge untrusted-only facts and episodes apart, as the linked gate does for links (Your Timeline marks them "from text you didn't write"); an untrusted fact the story's own labels deny stays wrong, and answers count whatever they rest on.
  - **The timeline's coverage target is waived** (≥ 90% of decidable wordings right). Fresh wordings by writers the grammar wasn't tuned on were answered about 45–55% right, with 0 wrong answers and 0 negatives triggered; a hand grammar chases an open-ended tail of wordings. A floor of 40% stays, the waiver holds only for the registry version frozen for these runs, every other timeline target still gates, the measured coverage goes in the record, and 13e's review of 10 timeline answers checks it on the author's vault. A grammar that generalizes (a model reading the question into an intent code checks) is later work. *Lapsed by the 2026-11-21 amendment below: timeline answers no longer go through the grammar.*
- **Amended on 2026-11-21** after Spike T, the author's decision ("embrace LLMs more"), and GPT-6-Astra's and Fable 5.2's reviews: **timeline answers are read and worded by the answer model, and checked by the time model** (Phase 13 plan, 13e.2).
  - **Why:**
    - The fail-closed intent grammar was inadequate on every wording set tested: about 40% of fresh wordings in 13e.1, and 9 of 67 held-out questions in Spike T.
    - A model answering from the memories named the right organization on every decidable held-out question, but named one on 10 to 14 of 38 undecidable ones.
    - The time model said "not sure" on nearly all of those.
    - Combined, in Spike T round 2 (28 decidable and 28 undecidable questions per engine, one sample, search among filler memories, a recorded live read, 13e.1's time model and store): the answer model with the work rows, checked by the time model, named the right organization on 26 (Haiku) and 25 (Terra) of 28 decidable questions, a wrong one on none, and held back on 27 of 28 undecidable ones. These are organization-selection scores, and the spike's rule differed from this amendment's. Two of Haiku's 26 stated no comparison and went unchecked, and this rule makes them "not sure" (24 of 28). The full graph decided, with the trusted store (agents' notes dropped) as a rescue. The extraction was the spike's Python, the check went through canonical questions, marking wasn't measured, and Haiku answered 2 of 28 negative questions wrongly with rows, against 0 without. The gate judges the claims, under this amendment's rules.
  - **The changes** (decisions 4, 5, 7 and 9):
    - the answer model reads the question;
    - the grammar stays only in plain search's ranking, frozen at 13e.1's vocabulary;
    - the answer's input gains the *timeline* predicates' trusted rows and the trusted memories they cite;
    - code decides when a claim owes a check, and checks it against the time model on trusted evidence;
    - code words the checked line;
    - *bridges* are folded into *timeline*;
    - the *timeline* gate judges answers end to end, per answer engine.
  - **The base:** 13e.1's time model and store, the code Spike T ran on: the strict trust rule, the slot pool, anchor dates and stints, stated renames, the never-denial, an import's "current" and the placeholder fold.
  - **Unchanged:** extraction and its gates, trust, corrections, the cloud limit's rules for derived facts, owner-only use.
  - **Plain search's timeline uses** (the grammar's demotion and admission, why lines, and "my previous job" cues) need an engine-free record of their own, not yet defined, and stay off until one exists.
  - **Known exception, outside the check's guarantee until it's modelled:** a stated possible overlap ("I can't remember if they overlapped"), which the same-year hand-over still answers at `inferred` (13a.2's canary c04).
- **Clarified on 2026-11-22** (13e.2, before the timeline gate): the timeline gate's scorer counts a name the story's own trusted labels give an employer (a stated rename) as that stint's, as the 2026-11-20 amendment already treats it; it had matched one name only. The correction was made before any new read and is recorded with its effect on Phase A's lines (Phase 13 plan, 13e.2 step 3b).
- **Amended on 2026-11-24** (13e.2, after the timeline gate's fourth blind set), by the author's decisions ("Let's finish round 4 first but after that no more rounds and let's ship everything on, timeline and answers"; then "Yes, go ahead" on the records step's rules):
  - **The gate's result.** Four blind sets by GPT-6-Astra, each with a fix round between them; r1 to r3 failed and were retired. On r4, GPT-5.6-Terra passed every target. Claude Haiku 5.5 gave no wrong answer (decidable right 60 of 60, 0 wrong; undecidable "not sure" 58 of 60; negatives R 1 vs P 5; 0 someone-else claims; the facts and Spike G pass; p95 8.1 s) but missed two targets: 2 owed checks skipped (a right answer and a right "not established", each unchecked) and 1 unmarked inferred claim (a true statement).
  - **The waiver.** Those two Haiku targets are waived, capped at the measured values (2 and 1), bound to Haiku, answer prompt `a13e2-3`, the registry version, r4 and the digests of r4's read calls and Haiku's answers (`spikes/people/results-13e2/waivers.json`). Only owed checks and marking can be waived; wrong answers, the facts, completeness, Spike G and latency always gate. Haiku's record names the waiver in its gate text.
  - **The records step's rules.** A live run that wrote its results inside the tree counts at its commit when its own code-only flag is clean. The "code unchanged since the live run" check covers product code only, because the replays at one clean commit must reproduce the live read and answers exactly. 13d's replay compares the facts revision's counter, not its digest of the registry: on 13e.1's registry it sent byte-identical requests (0 calls) and gave the same records and marks, so the person *attributes* records were rewritten from 13d's judged runs rather than a live rerun. The gate's freeze was rewritten for that record code.
  - **What ships in the Facts release (0.6.0):** works at's *timeline* use and timeline answers, and the person *attributes*, for both answer engines (Claude Haiku 5.5 and GPT-5.6-Terra) at that answer prompt; no more gate rounds. The two weeks' review of 10 timeline answers on the author's vault still applies: any wrong one turns the timeline off until fixed.
- **Amended again on 2026-11-24** (13e.2, after the records step), by the author's decision: **tested models are recommendations, not a gate.** "I don't like this idea of not allowing the user to enable the feature just because we didn't test the models. We can recommend models if we want, but if the user wants to use whatever model they want, they can do it. It's fine. It's a decision that any user can make; we don't have to make the decision for the user." GPT-6-Astra and Fable 5.2 reviewed the plan.
  - **Why now:** after a full re-scan with the tested Haiku, Your Timeline stayed empty. Both shipped *timeline* records name answer models, and a record with answer models counted only for an answer, so every reader without one (Your Timeline, plain search) had the timeline off. The gate kept hiding what the user had chosen to turn on.
  - **The rule:** a qualification record now says only that Funes tested an engine (model, adapter, batching) for a call group at a prompt and registry version. Such an engine is marked *Recommended* in the Facts picker. With any configured model, tested or not, every use the registry declares runs, for every reader: *recorded*, *linked*, *timeline*, *attributes* (with the `sole_known` basis) and *bridges*, for the Facts task, plain search, People & history and answers, whatever the answer model and answer prompt version.
  - **What still holds:** the registry's prerequisites between uses (and a basis-scoped use needs the unscoped one), and the local off-switches. An off-switch now holds for every model, matched on the predicate, use, basis, the call group's prompt version and the registry version. Switching models doesn't lift it; a new prompt or registry version (the fix) does. The trust rules, the cloud limit, the cap, corrections and owner-only use are unchanged.
  - **The model:** the chosen model reads every call group. There's no per-group fallback. Claude Haiku 5.5 through the Claude plan, the tested engine, is only the default suggestion when no model is chosen. Any account's models can be chosen, a custom or proxy address included; only a preset's own address can be *Recommended*. An untested choice shows one quiet line ("Funes hasn't tested this model for Facts; results may vary.").
  - **What it supersedes:** decision 9's "a use is on only with a record" and "a change re-runs the gates" (a change now only takes away the recommendation); the 2026-11-21 line that plain search's timeline uses "stay off until [an engine-free record] exists" (they're on, with Your Timeline and answers: one switch for all three); the 13e.2 coupling that an answer's *timeline* needs some *attributes* use; and the "only qualified models are offered" lines in model providers §4 and memory processing §11.10. The decisions' text is left as written above; this amendment wins where they differ.
  - **Newly on without a gate, accepted:** plain search's *timeline* uses (the grammar's demotion and admission, why lines and "my previous job" cues, frozen at 13e.1's vocabulary; 13b's work set lost ranks with every use on, a known cost); works at's *attributes*; *attributes* and timeline rows for every answer model, Apple on-device included (local, so no disclosure line). *Bridges* stays declared but inert: 13e.2 folded it into the timeline's rows.
  - **Known limits:** a change of model doesn't re-read memories already read (a reading is current while its extraction key and recorded predicates are), and a job that failed on one model isn't retried on another until the memory changes. Remove Learned Facts, then Read Existing Memories, starts over with the new model.
  - **The gates and records stay** as evidence and as what *Recommended* means: CI still checks every shipped record against what runs now, and the 13e review of 10 timeline answers still applies (a wrong one switches the timeline off until fixed).
- **Clarified on 2026-11-15:** cloud selection uses sendable facts only, the five gated uses, correction targets, and older phones.
- **Clarified on 2026-11-17** with 13a.2's qualification step, after GPT-6-Astra and Fable 5.2 reviewed its plan:
  - the registry declares *attributes* for the person predicates and works at, and *bridges* for works at (decision 7). Declared isn't on;
  - a record's registry version covers the whole registry except each predicate's uses list. Every group's validation and parsing read the shared language and the whole lexicon, so a new predicate re-reads only its own group (decision 3) but re-runs every group's gates;
  - the batching in a record's key carries the pipeline's revision, so a code change that could move a gate's result re-runs it.
- **Amended on 2026-11-20:** People & history reaches the iPhone (Phase 13 plan, 13d.2), read live from the Mac with corrections only, for the two weeks of use. Decision 10 is unchanged (owner side only). The phone shows what the Mac's section shows, read by the same FunesCore code with the same uses, stores nothing, and corrects only through `facts.reject` (**Not <name>** on a memory, **Not this** on a fact). Every other action stays on the Mac until a later step. The companion protocol gains the `people` capability and four read methods.

**Amends** (the documents change with Phase 13a, after acceptance):

| Area | Documents |
|---|---|
| Product | [vision](../../product/01-vision.md) (the "knowledge graph" non-goal); [requirements](../../product/03-requirements.md): FR-AI-05 (a new task, restricted to qualified models), FR-AI-08 (disclosure), FR-AI-15 (the cap, and a one-time backfill exemption), FR-AI-17 and FR-V-10 (search and answers), FR-iOS-07 (iPhone search), FR-U-01 (About you), plus new FRs for learned facts; [UX: Mac](../../product/04-ux-mac.md) and [UX: iPhone](../../product/05-ux-iphone.md) |
| Domain | [domain model](../../domain/domain-model.md) (Entity, Fact, Predicate; Profile); [memory processing](../../domain/memory-processing.md) (vault search §4, answers §10, a new §11); [access policy](../../domain/access-policy.md) (who reads the profile; no change to agent retrieval); the glossaries |
| Architecture | [storage](../storage.md) (a migration; purge §4; backups and exports); [security and privacy](../security-and-privacy.md) §3 (a trust threat) and §5 (a Facts row, the Search answers row, the rest-of-query embedding); [model providers](../model-providers.md) §1 and §7; [companion protocol](../companion-protocol.md) §3, §4 and §9 |
| ADRs | [ADR-0022](0022-cloud-limit-and-daily-cap.md) (the limit extends to derived facts); [ADR-0023](0023-provider-embeddings-second-index.md) (a second query embedding); [ADR-0026](0026-about-you-profile.md) (an owner-only use of the profile); [ADR-0028](0028-search-answers.md) (what the model reads, the card, the held answer, bridges, inferred claims); [ADR-0030](0030-settings-window.md) (a Features row) |
| Other | `PRIVACY.md` |

The evidence is Spike H and Spike H2 ([spike results](../../plans/spike-results.md#spike-h-people-and-work-history)). The detailed design becomes the Phase 13 plan, which keeps the acceptance table below.

**Context.**
- **Answers can't tell who a role-only memory is about.**
  - Plain search usually finds "my sister drinks her mate bitter" for "What does Lucía drink?".
  - In Spike H the answer model then said the vault doesn't record it, or gave no answer: 0 of 15 answers on such questions named the person.
  - It named her 15 of 15 times once the memory carried who "my sister" is.
- **Search can't follow a sequence.** The author asked the iPhone "What was my job before [current employer]?".
  - With the app's real ranking (bge-small plus the qwen3 provider index), the 29 memories naming the current employer filled ranks 1–29, and the memory that answers ranked 34th.
  - The one answering memory in the top 10 doesn't say what came before.
  - On the author's Search answers model, the app's real top 10 answered 0 of 18 times.
- **Both failures have the same shape:** a fact about you that no single result carries. Others will have it too ("Where did I live before Lisbon?", "Who was I seeing before Jordan?").
- **The first draft solved each shape separately.** It had people relations with their own bases, and job "stints" with job kinds, job-only bases and a job-word rule. A third shape would have needed a third structure.
  - Spike H's two harnesses (`people.py` and `work_history.py`) were also written separately.
  - Yet most of the rules aren't about jobs: dates at their written precision, "before" from stated order or the latest end, ties left ambiguous, a new one probably ending the old one.
- **The author's vault is mostly work:** 365 memories, 3 role phrases and 9 employers, much of it written by agents.
- **A full knowledge graph was rejected for agents** in the memory-graph exploration. This is narrower: facts whose subject is you, over your memories and your corrections, for you first.
- **The evidence is uneven.**
  - **Person links are well tested:** four engines, two fixture authors, and the author's reviewed vault.
  - **Answers aren't passed:** the gains rest on 5 questions of one shape, with Haiku only.
  - **Work history rests on one real question** (6 wordings × 3 samples) and one reviewed vault, plus a fixture that is now a development set (3 right and 5 wrong blind; 7 right, 0 wrong and 8 ambiguous after the fixes).
  - **Ranking** was measured on bge-small only, outside `ModelRouter`.
  - **The unified code hasn't run.** The spikes tested people and jobs through two harnesses. Their results are baselines for this design, not passes it inherits. Never run anywhere:
    - one prompt over several predicates;
    - time cues for people ("my ex");
    - partner succession;
    - dated titles.

**Decision.**
1. **One model: entities, and facts about you.**
   - **An entity** is a person, organization, place or thing your memories mention, with its aliases. A role group ("your sisters", count optional) is an entity until its members are named. One entity is *you*, with no stored name. A pet, a company or an app is an entity of its own kind, so it's never made a person.
   - **A fact** is you → predicate → entity. Its episodes (a job held twice is two) are derived from its evidence (decision 5); a new episode starts only when text says so ("rejoined", "back together") or the dates are disjoint. A fact has:
     - a status (`current`, `former`, `unknown`) and a start and end at the precision written;
     - **typed qualifiers** with their own dates: your word for it (`label`: "girlfriend", later "wife"), your title at a job (a promotion changes the title, not the job), and a job's `kind` (employee or self-employed);
     - evidence: the memory versions that state it or only mention it, with the value each asserts, its sensitivity and its trust;
     - whether you entered it yourself.
   - **Order edges** between facts ("I was at Acme before Initech"), as stated, with evidence.
   - **Only you → entity facts in v0.10.** Not modelled yet:
     - facts between other people ("my sister's husband") or other people's jobs;
     - facts whose object is a value (a birthday, a diet);
     - facts with no object (unemployed);
     - one fact scoped to another ("my manager at Acme").

     Each would be a generic extension, made through an amendment to this ADR, never a per-predicate rule. That keeps this the narrow index the memory-graph exploration allowed, not the graph it rejected.
2. **Predicates are data; the mechanisms are code.** One implementation of extraction, validation, resolution, the timeline, search and answers serves every predicate, and none of it names one. A versioned registry, shipped with the app and not user-editable, defines each predicate:
   - **its object's kind** (person, organization, place, thing);
   - **`exclusive`:** at most one current at a time, which lets "my partner" resolve to the one partner Funes knows (tested for partner in Spike H). It's a claim about the world, so it ships only with its gate;
   - **`succession` and its slot:** whether a new fact probably ends an open one *in the same slot*. The slot is a qualifier, such as a job's `kind`. A new holder of a predicate with succession starts at the memory that says so ("my new boss"). Spike H3 found manager needs this, though it isn't exclusive.
     - A side business doesn't end a day job.
     - With several open facts in the slot, or untrusted evidence, nothing is ended, and the case is `ambiguous`.
   - **`gap_months`:** a gap longer than this is told. Empty means gaps aren't meaningful for that predicate.
   - **its qualifiers**, each typed and either single-valued (a new value ends the old one) or multi-valued;
   - **its language data, English and Spanish:**
     - a definition for the prompt;
     - role phrases and labels in memories, with time cues ("my ex" means former);
     - statement templates with a first-person subject ("I joined X", "X is my R");
     - query cue words;
     - attribute and note phrases;
   - **its call group** (decision 3);
   - **its uses** (decision 9's five paths):
     - *recorded*: stored, shown and correctable, used only so nothing is misread;
     - *linked*: search admission and why lines;
     - *timeline*: "before / after" answers, and resolving time cues as of a memory's date;
     - *attributes*: the inference carried on an answer's memories (decision 7);
     - *bridges*: memories added to a timeline answer (decision 7). Folded into *timeline* on 2026-11-21.

   **What a registry entry can add:** a predicate whose facts are you → entity, found by a supported template, anchored by a named entity or a date, and decidable on the timeline. Adding one takes a registry entry, a fixture, its gates and a re-read of one call group.

   **What it can't add:** an object class within a kind ("which *phone*"), an implicit anchor ("before *this one*"), scope to another fact, or a new sentence pattern. Each needs a generic capability first, built and tested once for every predicate.

   **v0.10's registry:**
   - ten person predicates, *linked* with *attributes*: partner (exclusive), parent, child, sibling, other family, friend, manager, colleague, care, other;
   - **works at**, *linked*, *timeline*, *attributes* and *bridges*, with `kind` as its slot and `title` as a qualifier;
   - **client**, *recorded*, so a client is never read as an employer (Spike H2 found 4).

   The partner timeline is the registry canary (acceptance). Lives in waits for its fixture.
3. **A Facts task** (working name), off by default, with two switches and a removal action:
   - **Learn from memories** makes the model calls;
   - **Use in search and answers** shows what's known;
   - **Remove learned facts** deletes everything inferred and keeps your corrections and manual entries.

   **What it reads:** each committed memory version within the cloud limit, in its own low-priority lane.

   **Call groups:** the registry assigns predicates to call groups, and each group has its own prompt version and its own gates. A new group re-reads memories in that group only. It still re-runs every group's gates, since every group reads the whole lexicon and the shared language (clarified on 2026-11-17). People and jobs are separate groups. On Spike H3's blind mixed fixture, one merged call lost 7 to 9 points of relation recall (91% and 89% against 98% and 98%), with links and the timeline otherwise equal. That confirms Spike E's finding that combined work does worse.

   **Which models:**
   - Only models that qualified on the fixtures are offered: Claude Haiku 5.5 (the default) and Opus 5.5 for person predicates. Works-at extraction was tried on Haiku only.
   - Apple on-device isn't offered.
   - Memories the model can't read still get code-only links, never sent anywhere.
4. **The model learns facts and reads questions; code computes and checks everything else** (amended 2026-11-21; it was "the model learns facts; code computes everything else").
   - **Code recomputes, from the memory text, the facts, the timeline and stored decisions,** including which entity a mention means ("my sister", "Alex", "my previous job").
   - **The answer model reads which fact a question means** (until 2026-11-21, code did, through the grammar). Code checks every claim that depends on the timeline (decision 5, "Questions and the check"). Code verifies the comparison the model states, not that the model understood the question; the gate measures that.
   - Only what code can't decide is stored: a decision with the facts and memories it relied on, invalidated when any of them changes.
   - **Resolution bases** (which entity a mention means): `confirmed`, `named`, `stated_unique`, `context`, `sole_known`, `candidates`, `ambiguous`, `untrusted`, `rejected`.
     - `stated_unique` needs text saying there's only one, or an exclusive predicate whose gate is met.
     - "I have a sister, Maria" isn't `stated_unique`, and a manager never is by default.
   - **Time bases**, derived per date and per order edge of each episode, and not stored:
     - `stated`: from stated dates or a stated "before / after";
     - `ordered`: from the timeline rule;
     - `inferred`: from succession, a same-year hand-over (decision 5) or an untrusted date;
     - `ambiguous`.
   - **Trust:** a basis is the weakest in its chain, and trust belongs to each date and order edge, not to the fact. Spike H3 found that per-fact trust lets one trusted memory make an untrusted date decide. Untrusted evidence (an agent's or an import's text) never:
     - resolves a trusted memory;
     - ends an episode that has trusted evidence, or triggers succession;
     - orders anything at full basis;
     - changes a trusted decision.

     An episode with only untrusted evidence gives its dates at `inferred` at most and its links at `untrusted`. Untrusted links carry no attribute in v0.10.
5. **One time model and one timeline rule, for every predicate with the timeline use.**
   - **Dates are ranges at the precision written:** "2019" is January to December, "March 2019" is that month. Every comparison is over the possible ranges. An order holds only if it holds for every possible value, and anything else is `ambiguous`.
     - "Left Acme in 2019, joined Initech in 2019" leaves the two in either order. The one exception (Spike H3b): a hand-over in the same year or month is answered at `inferred` when the earlier episode certainly started before X and nothing else could fit in the window; otherwise it's told.
     - A competitor that could have ended later still counts.
   - **Episodes come from what memories assert, interval by interval:** a start and the end it was stated with, before dates are refined. Evidence, trust, order edges and status belong to an episode, so a rejoin reopens without touching the earlier episode.
   - **One resolver serves:**
     - role phrases as of a memory's date ("my partner" in a 2021 memory);
     - "previous";
     - before / after.

     There are no stored start and end dates beside it. Spike H3 kept role resolution's own dates and got wrong links when the two disagreed.
   - **"Before X":** X is an anchor, either a named entity's episode ("before Acme") or a date. The answer is an episode of the predicate asked about:
     - one with a stated order edge to X, if the dates allow it;
     - otherwise the one that certainly ended latest, at or before X's start.
     - An episode that is current or may overlap X never qualifies.
   - **Other operators:** "after X" mirrors it, "in 2021" means the episodes covering it, "current" means every current episode, and "previous" means before the current one (`ambiguous` if several are current).
   - **"Current" holds as of the memory's date, not today.**
   - **Succession ends stale currents only:** within a slot, an episode with no end, that was the only open one there when the next started, ends at the next one's start, at `inferred` ("probably former"). Never when:
     - a later memory says it still held;
     - the fact was stated as ended at an unknown time;
     - the evidence is untrusted.

     On the author's vault, without the first rule the timeline picked the wrong job, and without the second, it did again.
   - **Ambiguity is told, never guessed.** The answer gets plain search plus a note ("Funes can't tell which job came before Acme"), and no bridges, when there is the following. From 2026-11-21, a checked claim becomes "not sure" with that note instead (decision 5):
     - a possible tie;
     - conflicting dates, or contradictory or cyclic order edges (the edges are then dropped, and the dates may still decide);
     - an undated or half-dated fact of the predicate that could sit in a non-contiguous gap;
     - an anchor matching several episodes.

     On the author's vault a year-only rule guessed a tie and picked the wrong job.
   - **Gaps are told, with the answer.** A gap longer than the predicate's `gap_months`, measured over the possible ranges, gives a `gap` answer: it names the entity and tells the gap ("there's a gap of about 6 months"), and may carry bridges. A stated order still tells a gap that the dates show.
   - **Questions and the check** (amended 2026-11-21; it replaced the Intent paragraph, under which a fail-closed grammar decided timeline answers):
     - **Plain search** (no answer model) keeps the fail-closed grammar for ranking only: the "before X" demotion, why lines, admission (memory processing §11.7). It's frozen at 13e.1's vocabulary. A question outside it gets plain search.
     - **When a claim owes a check:** code decides, never the model. Given rows (decision 7), a claim owes one when any of these holds:
       - its comparison says `made`;
       - it cites a memory that came in only through the rows;
       - it names an entity of a *timeline* predicate, and the search or the claim has a registry operator or time cue (before, after, since, until, now, previous, a year or date).

       Any other claim (a title, a coworker, how long, a list) follows the ordinary marking rules (decision 7).
     - **What it carries:** a structured comparison:
       - the subject (the user, or someone else) and the predicate;
       - the operator: before, after, in, between (both endpoints) or current;
       - the anchor: an entity id from the rows with a stint (first, second or any), or a date normalised to its written precision;
       - the slot, if the question asks about one;
       - the answer entity id: one claim per answer, so concurrent jobs are two claims.

       Entity ids are sent as aliases (`e1`…), as memories are. It must validate against the registry and the graph; fields an operator doesn't use are empty.
     - **The check runs the time model directly, on two graphs:**
       - the trusted graph, which leaves out untrusted evidence (agents' notes, imports, shared text) and keeps corrections and manual entries;
       - the full graph.

       Both are built from the sendable projection for a cloud answer.
       - The trusted graph agrees, and so does the full graph: the claim stands, with the basis and the ids behind it.
       - The trusted graph agrees, but the full graph disagrees or can't tell: it stands, marked inferred, "text you didn't write says otherwise".
       - The trusted graph can't tell (a tie, a possible overlap, an ambiguous anchor): "not sure", worded from the reason ("Funes can't tell which job came before Acme"), even when the full graph agrees, since that answer would rest on untrusted text.
       - The trusted graph disagrees: the claim is dropped.
       - A check is owed but there's no comparison, or it doesn't validate: "not sure".
     - **Above the limit:** for a cloud answer, the same check also runs locally on all of the owner's trusted facts. If its outcome or answer differs from the sendable one, the claim is "not sure". Nothing more is sent.
     - **An anchor with several stints** and no stint cue in the search (the registry's return and episode cues), when the stints give different answers: "not sure", naming the stints ("You worked at Drift Games twice; Funes can't tell which you mean").
     - **The checked line is worded by code** from the validated fields (the answer, the anchor, the basis, a gap, "as of" for current). It replaces the claim's own text, and the claim's quotes stay under it.
     - **Someone else:** a comparison whose subject is someone else isn't checked, and the claim is ordinary. A claim about someone else that cites a memory that came in only through the user's rows is dropped.
     - **In v0.10, unchanged:** the anchor is of the same predicate, and a question about one fact's qualifiers ("my title at Acme before the promotion") isn't checked as a timeline comparison.
   - **Time cues in memories:**
     - Cues of status ("my ex", "my old boss") select former facts for every *linked* predicate.
     - Resolving a cue as of the memory's date ("my previous job" written in 2022) uses the timeline, so it needs the *timeline* use, and gives `inferred` at most.
6. **Links admit search results; they don't boost them.**
   - An entity matched in the query admits its memories, ranked by the better of their score for the query and for the rest of the query.
   - A memory linked only to entities the query doesn't name drops 0.1. For "before X", X's own memories drop 0.1 too.
   - A query that names no known entity is unchanged.
   - Before 13b ships, this is re-measured with the provider index on.
7. **Answers carry the inference, and code marks it.**
   - **The attribute:** each memory that came through a link carries the fact behind it, from the registry's phrases.
     - A full basis gives "Lucía, your sister" or "Acme, where you worked until March 2021".
     - `sole_known` gives "probably Lucía…". It ships when its gate is met on the fixtures (the author's vault has too few role phrases to measure it), always worded "probably", marked inferred with a correction. The two-week review on the author's vault turns it off at the first wrong one.
     - `candidates` gives "your sister; Funes isn't sure which", without names.
     - Attributes aren't quotable text.
   - **Inferred, from structured data, never from the model's wording.** A claim is marked inferred when it:
     - names an entity its cited text doesn't name;
     - states a predicate, label, qualifier or date its cited text doesn't state;
     - cites a bridge (from 2026-11-21, a memory that came in only through the rows; it then carries the order's basis);
     - cites a memory that carries an attribute, when the search names the attributed entity (by name, or by a role phrase that resolves to it) and the cited text doesn't. In Spike H4 this marked all 5 wrong-person claims from a wrong attribute, including the claims about a memory that names nobody.

     Each marked claim carries the fact, link or order ids behind it.
   - **Rows and cited memories** (amended 2026-11-21; they replaced *bridges*, up to 2 memories stating the target fact on top of the 10 results):
     - **When:** for a question whose entities or cue words match a *timeline* predicate loosely, the input gains that predicate's trusted episodes from the sendable projection as rows: at most 12, those of the search's entities first, then the most recent. Each row has an entity alias and name, slot, dates at their precision, inferred ends and stated renames. A boundary only untrusted text states is shown as unknown.
     - **The memories they cite:** trusted ones within the cloud limit, up to 6 beyond the 10 results (16 in all), each by §10.3's passage rule at up to 1,000 characters, 6,000 in all, in the rows' order.
     - **What's never sent:** untrusted-only episodes and untrusted memories.
     - **The card** says "Read 10 results and N from your history".
     - **Marking** adds the check's outcomes (decision 5). Each checked or marked claim carries the fact and order ids behind it as correction targets (**Not this**, keyed to its memory and span), as before.
     - **Engines without rows:** Apple on-device and local engines get none, as they got no bridges.

   - **Your own names**, from About you, become "the user" in the answer's input, as in the Facts call (decision 8), with a map back so quotes still highlight in the original. Another person sharing the name isn't replaced.
8. **About you, used locally and for the owner only.**
   - The profile's names identify *you* in memories, by local matching.
   - Before any memory text is sent (a Facts call or an answer), they're replaced by "the user", with a map of offsets back for quotes; a namesake in the same memory keeps the name. They're never added to a call, never in a roster, and never affect agent retrieval.
   - Access policy §3.10 is unchanged. This is the separate decision ADR-0026 called for.
9. **Every path is gated, by the same tests for every predicate.**
   - **What's gated:** extraction (with recording), linking, timeline resolution, attributes and bridges (folded into the timeline on 2026-11-21). Each is a separate use per predicate, and a use can't turn on before the ones it depends on.
   - **What a pass covers:** the model, call-group prompt, registry version, adapter and batching it was measured with. Changing any of them re-runs the gates.
   - **When a gate fails, or the 13e review finds a wrong one:** that use and everything downstream of it turn off, with no code change. The predicate stays *recorded* or off.
   - **The person predicates are gated as one pool,** with a minimum count per predicate. The author's vault has too few role phrases to gate them one by one.
   - Adding a predicate is cheap; trusting it takes evidence.
   - **The *timeline* gate** (amended 2026-11-21) judges answers end to end, per answer engine, on top of the predicate's *linked* record.
     - **Fixed before the run:** code, prompts, the scoring script, the denominators and the rule for changing a label.
     - **The set:**
       - a fresh blind set by GPT-6-Astra: 24 stories, at least 50 decidable, 50 undecidable (with at least 4 each of rehire, possible overlap, same-year hand-over, agent competitor, rename and exact day in a year) and 40 negative questions (including first job, how long, "did I work at A before B", lists, yes/no);
       - about 300 filler memories, some naming the stories' organizations;
       - the app's own search;
       - one recorded live read through the Swift extractor.
     - **Judging:** every answer's text, blind; the plain arm (no rows) is the baseline.
     - **Targets:**
       - decidable: right ≥ 85%, 0 unmarked wrong, at most 1 marked wrong;
       - undecidable: "not sure" ≥ 90%;
       - negatives wrong: no more than the plain arm's plus 1;
       - 0 claims naming someone else's fact as the user's, and 0 owed checks skipped;
       - 0 claims code fails to mark;
       - the facts behind the rows: every fact right, ≤ 1 wrong date, 0 succession from untrusted text or across slots (on the gate's live read and Phase A's two reads);
       - Spike G's gates;
       - p95 ≤ 15 s.
     - **Labels:** Astra's set labels each question's class and answer. A rehire question whose stints give different answers is undecidable unless it names one. *(Amended 2026-11-22, before the gate's freeze, after GPT-6-Astra's and Fable 5.2's reviews of its harness: whether a claim is time-relative or inferred is judged per claim, blind, by Opus and GPT-6-Astra with an adjudicator, instead of labelled per question; "owed checks skipped" also counts, without a judge, every unchecked claim §10.4's rule owes a check; a disputed label is relabelled from scratch once, and the corrected set must still meet the minimums.)*
     - **Owed checks** *(amended 2026-11-22, the author's decision after the first gate set failed)*: a claim the judges call time-relative owes a check only when it answers the question's ask (right, wrong or "not sure"). A context claim (an agent's note reported, an exclusion, a dated list item, a client's years) owes none; the wrong-claim and marking targets still count it. The judge-free count of §10.4's rule is unchanged.
     - **A record's key** adds the answer model and the answer prompt version. The person *attributes* share the answer prompt, so their 13d gates re-run with it.
10. **Owner side only, in v0.10.**
    - Links are used in your own Vault search, iPhone search and search answers.
    - Agent retrieval, the related-memories finder and the tidy-up never use them, with regression tests that prove it.
    - Agents' use is a later, separate decision.
11. **Corrections are first-class and durable.**
    - **Not <name>** and **Not this** (a fact) appear on every why line and inferred claim, and anything that depends on them recomputes at once.
    - **Manual entries win over inference.** Manual entities, facts and qualifiers carry the sensitivity you pick, and are never purged with memories.
    - **A correction is keyed to the memory and the quoted span.** It survives edits that keep the span, and tidy-up merges and splits.
    - **The section has a page per entity and your timeline of dated facts.** *Recorded* facts are shown there too, so you can see and remove them. No question is ever required of you.

**Consequences.**
- **The cloud limit covers derived facts, conservatively.** A fact, qualifier, date, order or decision may be sent, or may shape which memories a cloud answer gets, only if every memory behind it is within the limit. Manual entries use their own sensitivity.
  - A cloud answer reads the results as re-ranked if only sendable facts existed (admission, demotions, the rest-of-query score, the timeline's choice and bridges; from 2026-11-21, the rows and their cited memories), restricted to the results you see. A shown result outside that set appears in your results but not in the cloud answer. The card counts it as not read, and the slot isn't refilled.
  - The rest of the query goes to a cloud embedding index only when every matched name comes from sendable facts.
  - If the answer fact is decided only by a fact above the limit, the cloud answer gets plain search; from 2026-11-21, the claim about it is "not sure" instead (decision 5's local cross-check). Rows carry their provenance and go through the secret scanner and send-time revalidation, as attributes do.
  - *Recorded* facts enter the model's roster only under the same rule.
  - Per-label sensitivity is deferred.
- **New data, owner-side:**
  - **A GRDB migration** with:
    - entities and aliases;
    - facts, with typed, dated qualifiers and order edges;
    - one evidence table for facts, qualifiers and edges, recording the value each memory asserts (so conflicting dates are kept) and whether it states it;
    - decisions with their dependencies;
    - manual overrides;
    - the registry and prompt versions each run used.
  - **In backups and exports.**
  - **Purge:** every inferred name, label and qualifier goes when its last supporting memory is deleted. Manual entries and corrections stay, and what they reference is never deleted: with nothing else supporting it, it's a tombstone with its id, its predicate, your own values and the normalised alias you confirmed or typed, never an inferred name or quote. Remove learned facts keeps them the same way.
  - **Activity** records ids and counts only.
- **What a registry change costs:**
  - **Language-only changes** (query cues, attribute phrases) take effect at once, with no re-read.
  - **A change to a call group's extraction** (a new predicate, a new template, a new definition) re-reads that group, in the low-priority lane under the cap. A whole group on the author's vault is about 400 calls.
  - Registry changes are batched per release.
- **What stays per predicate is data and evidence:** language, flags, a fixture and gates. One-off code for one predicate isn't added. If a predicate seems to need one, the model is missing a generic capability, and that's an amendment to this ADR.
- **New provider traffic:**
  - the Facts task sends memories within the limit, with the entities and facts they mention, to its provider;
  - the Search answers provider, which may be a different one, now also receives attributes and bridge memories;
  - with a provider embedding index, the rest of the query is a second embedding request.

  These need rows in security and privacy §5, PRIVACY.md and the Settings disclosure line. A new threat, an agent steering your answers through untrusted text, is answered by the trust rule (decision 4) and gets a row in §3.
- **ADR-0028 changes:**
  - **what the model reads:** attributes, your names replaced, bridges on top of "results as shown";
  - **the card:** "inferred" claims with their corrections, and shown results not read because a cloud answer reads the results as ranked with sendable facts only;
  - **the held-answer key**, which gains a facts revision.
- **The companion protocol** gains:
  - the why line on results;
  - an inferred flag, fact ids and correction targets on claims;
  - `facts.reject`;
  - **a capability flag:** for older phones the Mac sends neither attributes nor bridges and drops every claim it would mark inferred, so they never show an inferred claim unmarked;
  - a facts revision in `status.get`.
- **The cap:** the task's calls count against FR-AI-15's daily cap, and calls caused by agent-written memories count in the agents' 40% share.
  - **The first backfill is exempt, once:** started by the user, with its call count and cost shown first. It runs outside the daily cap, in the low-priority lane, and is resumable if interrupted. It's one exemption in total, for both call groups. For the author's vault that's about 800 calls (two call groups), about $0.25 API-equivalent, under an hour. This amends FR-AI-15. (Clarified on 2026-11-18: the exemption covers one request of a full read of each memory and call group it counted, at the version counted, spent once sent, so it never exceeds the count shown; the reconciliation that follows counts, and a change of model or a wider cloud limit pauses it until the new count is shown. Amended on 2026-11-20, at the author's request: Remove learned facts starts Facts over, so it resets the exemption. The next time learning is turned on, the backfill is offered again with a fresh count and cost, as the first time. A backup restore keeps the live vault's state, or its absence, so a restore never grants one.)
  - Every other call counts against the cap: new and changed memories, and re-reads after a registry change.
  - Measured cost, API-equivalent: $0.13 on Haiku for 365 memories, and $0.09 for a separate jobs call, about $0.25 in all. The author pays through a plan. These are estimates for the unified prompt.
  - Searches and the timeline make no model call.
- **The main risk is a wrong link or a wrong order.** In Spike H a wrong timeline turned 18 of 18 answers wrong, and a wrong attribute led to wrong-person claims. Each path ships only once its gate is met, and every inferred claim offers a correction.

**Acceptance** (in Phase 13a–13d; each test names its dataset, runs on the one Swift implementation through `ModelRouter`, and applies to every predicate with that use):

| Measure | Target |
|---|---|
| Full-basis links right, person predicates pooled (minimum 20 per predicate on fixtures) and works at: fixtures, two reads · a fresh reviewed sample of 50 on the author's vault | ≥ 98% · ≤ 1 wrong |
| `sole_known` links right: fixtures · every `sole_known` link on the author's vault, reviewed | ≥ 90% on fixtures, which decides whether `sole_known` attributes ship · ≤ 1 wrong on the vault, reviewed in 13e |
| Recall of resolvable references: fixtures · the author's vault, two reads | ≥ 90% · ≤ 5% differ between reads |
| Recorded predicates (client): a fixture with clients, employers and companies the user buys from | 0 clients read as employers, 0 vendors recorded as clients |
| A fresh mixed-predicate fixture, people and jobs in the same memories | every gate above still met, so one prompt (or the chosen groups) doesn't lose accuracy |
| Search with links on, on the people and work fixtures, Spike G and the search benchmark: targets worse, out of the top 3, or out of the top 10 | 0 |
| Search latency with links, 50 queries on the author's vault | FR-V-10's 150 ms at p95 |
| Answers on linked questions, on Haiku and on the author's Search answers model (3 samples, a blind judge, every gain and loss read by hand) | coverage ≥ plain search on every question family. 0 wrong entity with correct links. With an injected wrong link, ≤ 1 unmarked claim per 30 answers |
| Spike G's gates with the feature on | correct claims ≥ 95%, right "no answer" ≥ 90%, answered ≥ 80%, no new wrong claims |
| Inferred claims code fails to mark (attributes, labels, neighbouring attributes, bridges; from 2026-11-21, checked claims) | 0 |
| Each *timeline* predicate (works at in v0.10), amended 2026-11-21: decision 9's answer gate, per answer engine · the author's reviewed timeline | decision 9's targets: decidable right ≥ 85% with 0 unmarked and ≤ 1 marked wrong; undecidable "not sure" ≥ 90%; negatives no worse than the plain arm + 1; 0 someone-else claims and 0 owed checks skipped; 0 unmarked; every fact right, ≤ 1 wrong date, 0 succession from untrusted text or across slots; Spike G's gates; p95 ≤ 15 s. It replaced the grammar-measured row (≥ 90% of decidable wordings, 0 wrong answers) |
| The registry canary: the partner timeline, entry and fixture written blind by GPT-6-Astra after the code freeze, with negatives, concurrency, untrusted text, privacy and corrections, reported as distinct questions | the change touches no source file (checked mechanically). A deterministic part (canned extractions through resolution, timeline and intent) runs in CI. With a model run, it meets the timeline gates above; if it does, it may ship *(Its timeline gate is redefined when person rows come, after the 2026-11-21 amendment.)* |
| Adversarial review of the Swift time model: two independent reviewers try to produce a wrong answer or link with canned inputs; every case found becomes a test | none found in a final round: a wrong answer or link from the core model, or a confident misread from the language layer, which fails closed (narrowed after round 17; not met in round 18 and waived by the author, see the amendment of 2026-11-16; a missed answer counts in the timeline and recall gates instead) |
| Privacy payload tests: facts and orders stated only above the limit | 0 in any cloud input, including which memories are selected |
| Port fidelity: Spike H's matrix and Spike H2's timeline | within 1 point of the Python harnesses |
| After two weeks of use: a fixed sample of 30 links and 10 timeline answers on the author's vault | any wrong one turns that predicate's use, and everything downstream of it, off until fixed |

The vault gates have small denominators: the author's vault has 3 role phrases, so the fixtures carry the `sole_known` gate and the pooled person gate. Spike H measured the top 8; the top-10 gate is new.

**Spike H3 (done, 2026-11-15): a partial validation** ([results](../../../spikes/people/RESULTS.md)). One implementation over a registry ran Spike H's people matrix and Spike H2's timeline. Two blind fixtures by GPT-6-Astra followed: a mixed-predicate fixture, and the partner-timeline canary, run after a code freeze.
- **The model's shape held:**
  - people links matched the baseline (0 wrong; recall within 1 point combined);
  - the generic timeline reproduced H2 exactly on H2's extraction;
  - the author's reviewed job was picked from both extractions;
  - the canary ran on data-only registry changes, with 0 wrong timeline answers on the frozen code;
  - nothing ever needed predicate-specific code.
- **The temporal core didn't hold as built.** Each run found a rule the first design lacked; they're written into decisions 2, 4 and 5 above. The reviews then broke what was built with small counterexamples: trust per fact, same-year hand-overs, episodes erased by merging, uncertain competitors, longer cycles, role resolution's own dates, and months read from prose. Hence decision 5's range-based time model.
- **Coverage** of decidable job questions was 71% on the mixed fixture, mostly from the 2-month gap rule and year padding. The acceptance row now counts gap answers separately.

**Spike H3b (done, 2026-11-15): the range-based time model meets the gate.** It rebuilt the harness's time model as decision 5 describes, then re-applied every saved model output through it and re-ran the fixtures fresh.
- **Every counterexample from the H3 reviews passes as a test,** and so does every counterexample from three further review rounds of H3b itself.
- **No wrong answer or wrong link remains** on the people, mixed, work or canary fixtures.
- **Coverage of decidable job questions rose:** 25 of 28 on the mixed fixture (against 20), and 9 of 15 on the work fixture (against 6).
- **Both choices on the author's vault are safe:** facts.py's own extraction picks the reviewed job, hedged as "probably". H2's older extraction is now told rather than answered, because of a stray date.
- **The lesson:** the fixtures never exposed a temporal bug; adversarial review by two independent reviewers found every one. The acceptance table now requires that for 13a.

**Decided before acceptance** (2026-11-15, by the author):
1. **The backfill:** a one-time exemption from the daily cap, started by the user (an FR-AI-15 amendment, above).
2. **`sole_known` attributes:** they ship, hedged, when their gate is met on the fixtures (decision 7).

3. **The answer check on the author's model comes first** (the Phase 13 plan's step 13.0, before the spec is amended). Spike H tested attributes only on Haiku, and H2 tested only bridges on GPT-5.6-Terra, the author's Search answers model. It runs Spike H's answer arms on Terra: plain, with attributes, and with a wrong attribute. If Terra ignores attributes, or follows wrong ones more than Haiku did, decision 7 changes before the spec is amended: bridges only, or attributes only at full basis. **Done (Spike H4, 15 Nov 2026):** attributes held up on Terra (0 wrong-person claims and 0 denials with correct attributes; 5 wrong-person claims to Haiku's 10 with a wrong one), so decision 7 stands, with the marking case above added.

Nothing else is open; the remaining measures are 13a–13e's acceptance tests.

**Alternatives considered.**
- **A structure per question shape** (the first draft: people relations, and job stints with their own bases and rules): each new shape would have needed new tables, bases and code. Replaced by one model. The spikes' results are its baselines; its own evidence is the acceptance table.
- **A full knowledge graph** (entities and relations between anything): rejected, as in the memory-graph exploration. Facts here are only about you, and predicates come from a gated registry.
- **Open predicates the model invents:** nothing to test or gate, and labels drift between reads. Rejected. Your own word is kept as a label within a registry predicate.
- **Promising that every future question is registry-only:** object classes, implicit anchors, scope and values need generic capabilities first. The registry's reach is stated (decision 2) rather than overclaimed.
- **Smarter retrieval alone** (several queries per question, more varied results): generic, but it costs model calls on every search, and it can't order facts that no single memory orders. Kept as a possible later complement.
- **Boosting linked memories:** every boost tried (0.1–0.5) made a missed link rank the right memory below plain search, and added nothing to the top 3. Admission without a boost has a smaller cost of the same kind: 2 of 28 injected missed links did worse than plain search on the held-out set.
- **Asking the user to confirm links:** the gold standard, but a stream of questions is the fatigue Funes avoids elsewhere. Links are inferred, honest about their basis, and correctable.
- **Leaving inference to the answer model:** with the role-only memory in its input, Haiku named the person 0 of 15 times until the memory carried who it was about. And no answer model can order jobs whose memories it never sees. *(2026-11-21: the answer model now reads timeline questions and states its comparison, and code checks it against the time model; decision 5.)*
- **A prompt sentence telling the model to hedge:** it changed how often the model hedged, not what it got right. Code marks inference instead.
- **Apple on-device or a local model:** not offered until one qualifies on the same fixtures; none has.
- **The model alone over the rows** (Spike T, 2026-11-21): best coverage, but it named an organization on a quarter to a third of undecidable questions. Code checks it instead.
- **A model writing an intent, and the time model answering** (Spike T): cautious, but it lost coverage to its schema, and it read 20–47 of 102 adversarial non-work questions as timeline questions.
- **Widening the grammar further** (13e.1): inadequate on every wording tested.
