# ADR-0032: Funes learns the people your memories mention and your work history, for your own search and answers

**Status:** Proposed · 2026-11-14 (revised the same day after GPT-6-Astra and Fable 5.2 reviewed the first draft).

**Amends** (the documents change with Phase 13a, after acceptance):

| Area | Documents |
|---|---|
| Product | [vision](../../product/01-vision.md) (the "knowledge graph" non-goal); [requirements](../../product/03-requirements.md): FR-AI-05 (a new task, restricted to qualified models), FR-AI-08 (disclosure), FR-AI-15 (the cap), FR-AI-17 and FR-V-10 (search and answers), FR-iOS-07 (iPhone search), FR-U-01 (About you), plus new FRs for People; [UX: Mac](../../product/04-ux-mac.md) and [UX: iPhone](../../product/05-ux-iphone.md) |
| Domain | [domain model](../../domain/domain-model.md) (new entities; Profile); [memory processing](../../domain/memory-processing.md) (vault search §4, answers §10, a new §11); [access policy](../../domain/access-policy.md) (who reads the profile; no change to agent retrieval); the glossaries |
| Architecture | [storage](../storage.md) (a migration; purge §4; backups and exports); [security and privacy](../security-and-privacy.md) §3 (a trust threat) and §5 (a People row, the Search answers row, the rest-of-query embedding); [model providers](../model-providers.md) §1 and §7; [companion protocol](../companion-protocol.md) §3, §4 and §9 |
| ADRs | [ADR-0022](0022-cloud-limit-and-daily-cap.md) (the limit extends to derived facts); [ADR-0023](0023-provider-embeddings-second-index.md) (a second query embedding); [ADR-0026](0026-about-you-profile.md) (an owner-only use of the profile); [ADR-0028](0028-search-answers.md) (what the model reads, the card, the held answer, bridges, inferred claims); [ADR-0030](0030-settings-window.md) (a Features row) |
| Other | `PRIVACY.md` |

The evidence is Spike H and Spike H2 ([spike results](../../plans/spike-results.md#spike-h-people-and-work-history)). The detailed design becomes the Phase 13 plan, which keeps the acceptance table below.

**Context.**
- **Answers can't tell who a role-only memory is about.** Plain search usually finds "my sister drinks her mate bitter" for "What does Lucía drink?". In Spike H the answer model then said the vault doesn't record it, or gave no answer: 0 of 15 answers on such questions named the person. It did name her 15 of 15 times once the memory carried who "my sister" is.
- **Search can't follow a sequence.** The author asked the iPhone "What was my job before [current employer]?".
  - With the app's real ranking (bge-small plus the qwen3 provider index), the 29 memories naming the current employer filled ranks 1–29, and the memory that answers ranked 34th.
  - The one answering memory in the top 10 doesn't say what came before.
  - On the author's Search answers model, the app's real top 10 answered 0 of 18 times.
- **The author's vault is mostly work:** 365 memories, 3 role phrases and 9 employers, much of it written by agents.
- **A full knowledge graph was rejected for agents** in the memory-graph exploration. This is narrower: an index over memories and the owner's corrections, for the owner first.
- **The evidence is uneven.**
  - **Links are well tested:** four engines, two fixture authors, and the author's reviewed vault.
  - **Answers aren't passed:** the gains rest on 5 questions of one shape, with Haiku only.
  - **Work history rests on one real question** (6 wordings × 3 samples) and one reviewed vault, plus a fixture that is now a development set (3 right and 5 wrong blind; 7 right, 0 wrong and 8 ambiguous after the fixes).
  - **Ranking** was measured on bge-small only, outside `ModelRouter`.

**Decision.**
1. **A People task**, off by default, with two switches:
   - **Learn from memories** makes the model calls;
   - **Use in search and answers** shows what's known;
   - **Remove People data** deletes everything inferred and keeps the user's corrections and manual entries.

   It reads each committed memory version within the cloud limit, in its own low-priority lane. It records:
   - the people mentioned, and their aliases;
   - the user's relations to them: ten gender-neutral types, with the user's own word as the label;
   - the user's own jobs: employer, role, start and end as written, and the job's kind (employee, self-employed or client);
   - named things, so a company or a pet isn't made a person.

   Only models that qualified on the Spike H fixtures are offered: Claude Haiku 5.5 (the default) and Opus 5.5 for people; job extraction was tried on Haiku only. Apple on-device isn't offered. Memories the model can't read still get code-only links, never sent anywhere.
2. **The model learns facts; code computes links.**
   - Which person "my sister" means, and which job came "before X", are recomputed by code from the memory text, the relations, the timeline and stored decisions.
   - Only what code can't decide is stored: a decision with the facts and memories it relied on, invalidated when any of them changes.
   - **People bases:** `confirmed`, `named`, `stated_unique`, `context`, `sole_known`, `candidates`, `ambiguous`, `untrusted`, `rejected`. "I have a sister, Maria" isn't `stated_unique`, and neither is a manager.
   - **Work-history bases**, per field of each stint (start, end, role):
     - `stated`: from stated dates or a stated "before / after";
     - `ordered`: from the timeline rule;
     - `inferred`: from a stale current or an untrusted date;
     - `ambiguous`.
   - **Trust:** a link's basis is the weakest in its chain. Untrusted evidence (an agent's or an import's text) never resolves a trusted memory, never ends a relation or a stint, and never changes a trusted decision.
3. **Work history is a timeline of stints.**
   - **Stints:** each has an employer, a role history (a promotion is a new role in the same stint), and start and end at the precision written. Rehiring is a new stint, and clients aren't employers in v1.
   - **"Before X"** is a stated order; otherwise the stint that ended latest at or before X's start. A stint that is current or overlaps X never qualifies.
   - **Precision:** months are compared where both sides state them; anything not strictly decidable at the written precision is `ambiguous`.
   - **Stale currents:** "I joined Y" doesn't end X by text. If X has no end and no evidence of overlap, it's treated as ended by Y's start, at `inferred` ("probably former").
   - **Ambiguity:** a tie, conflicting dates or order edges, a cycle, a gap, a missing date, or X matching several stints makes the answer get plain search plus a note ("Funes can't tell which job came before Acme"), never a guess and never bridges. On the author's vault a year-only rule guessed a tie and picked the wrong job.
   - **Intent:** a timeline query needs a job or employer word with "before / after X", "previous", "current" or a year. A question about roles inside one job ("my title at Acme before the promotion") isn't a timeline query, and neither is "what did we use before Acme moved to Slack". Role-only work phrases in memories ("at my previous job") resolve as of the memory's date, at `inferred` at most.
4. **Links admit search results; they don't boost them.**
   - A person or employer matched in the query admits its memories, ranked by the better of their score for the query and for the rest of the query.
   - A memory linked only to people the query doesn't name drops 0.1, and so do the named employer's own memories for "before X".
   - A query with no person or employer is unchanged.
   - Before 13b ships, this is re-measured with the provider index on.
5. **Answers carry the inference, and code marks it.**
   - **The attribute:** each memory that came through a link carries who it's about: "Lucía, your sister"; "probably Lucía…" for `sole_known`; "your sister; Funes isn't sure which" for `candidates`, without names. Attributes aren't quotable text.
   - **Inferred, from structured data, never from the model's wording.** A claim is marked inferred when it:
     - names a person or employer its cited text doesn't name;
     - states a relation or label its cited text doesn't state;
     - cites a bridge (it then carries the order's basis).

     Each marked claim carries the link, stint or order ids behind it.
   - **Bridges** (timeline questions only): up to 2 memories that state the target stint are added on top of the 10 results ("Read 10 results and 2 from your work history"). Apple on-device answers get no bridges.
   - **The user's own names**, from About you, become "the user" in the answer's input, with a map back so quotes still highlight in the original. Another person sharing the name isn't replaced.
6. **About you, used locally and for the owner only.** The profile's names identify *you* in memories, by local matching. They're never sent in a roster or an answer input, and never affect agent retrieval. Access policy §3.10 is unchanged; this is the separate decision ADR-0026 called for.
7. **Owner side only, in v0.10.** Links are used in the user's own Vault search, iPhone search and search answers. Agent retrieval, the related-memories finder and the tidy-up never use them, with regression tests that prove it. Agents' use is a later, separate decision.
8. **Corrections are first-class and durable.**
   - **Not <name>** and **Not this job** appear on every why line and inferred claim, and dependent links recompute at once.
   - Manual people, relations and jobs win over inference, carry the sensitivity the user picks, and are never purged with memories.
   - A correction is keyed to the memory and the quoted span, so it survives edits that keep the span and tidy-up merges and splits.
   - The People section has each person's page and the work timeline. No question is ever required of the user.

**Consequences.**
- **The cloud limit covers derived facts, conservatively.** A relation, label, date, order or decision may be sent, or may shape which memories a cloud answer gets, only if every memory behind it is within the limit; manual facts use their own sensitivity.
  - A memory admitted only through a link that isn't sendable appears in the user's results but not in a cloud answer. The card counts it as not read, and the slot isn't refilled.
  - If the earlier stint is decided only by a fact above the limit, the cloud answer gets plain search.
  - Per-label sensitivity is deferred.
- **New data, owner-side:**
  - a GRDB migration with people, aliases, relations, named things, stints with role histories and order edges, evidence rows that record which memories state a fact, decisions with their dependencies, and manual facts;
  - in backups and exports;
  - every inferred name, label and role goes when its last supporting memory is deleted, while manual facts and corrections stay (keeping only ids where nothing else remains);
  - Activity records ids and counts only.
- **New provider traffic:**
  - People sends memories within the limit, with the names, relations and employers they mention, to its provider;
  - the Search answers provider, which may be a different one, now also receives attributes and bridge memories;
  - with a provider embedding index, the rest of the query is a second embedding request.

  These need rows in security and privacy §5, PRIVACY.md and the Settings disclosure line. A new threat, an agent steering the owner's answers through untrusted text, is answered by the trust rule (decision 2) and gets a row in §3.
- **ADR-0028 changes:**
  - what the model reads: attributes, the user's names replaced, bridges on top of "results as shown";
  - the card: "inferred" claims, results not read because of an unsendable link;
  - the held-answer key, which gains a people revision.
- **The companion protocol** gains:
  - the why line on results;
  - an inferred flag and link ids on claims;
  - `people.reject`;
  - a capability flag: older phones get neither attributes nor bridges, so they never show an inferred claim unmarked;
  - a people revision in `status.get`.
- **The cap:** People calls count against FR-AI-15's daily cap, and calls caused by agent-written memories count in the agents' 40% share.
  - The author's backfill (about 400 calls, and more if jobs are a separate call) takes two to three days, or longer when other work uses the cap.
  - Measured cost, API-equivalent: $0.13 on Haiku for 365 memories, and $0.09 for a separate jobs call. The author pays through a plan.
  - Searches and the timeline make no model call.
- **The main risk is a wrong link or a wrong order.** In Spike H a wrong timeline turned 18 of 18 answers wrong, and a wrong attribute led to wrong-person claims. Attributes and bridges ship for a basis only if its gate below is met, and every inferred claim offers a correction.

**Acceptance** (in Phase 13a–13d; each test names its dataset):

| Measure | Target |
|---|---|
| Full-basis links right: fixtures, two reads · a fresh reviewed sample of 50 on the author's vault | ≥ 98% · ≤ 1 wrong |
| `sole_known` links right: fixtures · every `sole_known` link on the author's vault, reviewed | ≥ 90% · ≤ 1 wrong; otherwise no `sole_known` attributes |
| Recall of resolvable references: fixtures · the author's vault, two reads | ≥ 90% · ≤ 5% differ between reads |
| Search with links on, on the people and work fixtures, Spike G and the search benchmark: targets worse, out of the top 3, or out of the top 10 | 0 |
| Search latency with links, 50 queries on the author's vault | FR-V-10's 150 ms at p95 |
| Answers on people questions (3 samples, a blind judge, every gain and loss read by hand) | coverage ≥ plain search on every question family. 0 wrong person with correct links. With an injected wrong link, ≤ 1 unmarked claim per 30 answers |
| Spike G's gates with People on | correct claims ≥ 95%, right "no answer" ≥ 90%, answered ≥ 80%, no new wrong claims |
| Inferred claims code fails to mark (attributes, labels, neighbouring attributes, bridges) | 0 |
| Work history: a fresh blind fixture · the author's reviewed timeline | every stint right, ≤ 1 wrong date. "Before / after / in <year>" right on ≥ 90% of wordings whose truth is decidable, and ambiguous on the others. 0 wrong answers. 0 timeline triggers on negative wordings |
| Privacy payload tests: facts and orders stated only above the limit | 0 in any cloud input, including which memories are selected |
| Port fidelity: the matrix on the Swift pipeline through `ModelRouter` | within 1 point of the Python harness |
| After two weeks of use: a fixed sample of 30 links and 10 timeline answers on the author's vault | any wrong one turns that basis's attributes off until fixed |

The vault gates have small denominators: the author's vault has 3 role phrases, so the fixtures carry the `sole_known` gate.

**Open before acceptance:**
1. The backfill: under the cap, or a one-time, user-started exemption (an FR-AI-15 amendment).
2. Jobs in the People call or a separate call: decided in 13a by reproducing Spike H2's reviewed timeline.
3. Whether `sole_known` attributes ship if their gate is met only on fixtures.

**Alternatives considered.**
- **A full knowledge graph** (entities and relations between anything): rejected, as in the memory-graph exploration. People, the user's relations and the user's work history cover the failures seen. Places, products, projects and clients can follow as people-like entities later.
- **Boosting linked memories:** every boost tried (0.1–0.5) made a missed link rank the right memory below plain search, and added nothing to the top 3. Admission without a boost has a smaller cost of the same kind: 2 of 28 injected missed links did worse than plain search on the held-out set.
- **Asking the user to confirm links:** the gold standard, but a stream of questions is the fatigue Funes avoids elsewhere. Links are inferred, honest about their basis, and correctable.
- **Leaving inference to the answer model:** with the role-only memory in its input, Haiku named the person 0 of 15 times until the memory carried who it was about. And no answer model can order jobs whose memories it never sees.
- **A prompt sentence telling the model to hedge:** it changed how often the model hedged, not what it got right. Code marks inference instead.
- **People only, work history later** (the plan's v3 order): the author's one real failed question was about work history, and the vault has three times as many employers as role phrases. Moved into v0.10, with thinner evidence than people.
- **Apple on-device or a local model for People:** not offered until one qualifies on the same fixtures; none has.
