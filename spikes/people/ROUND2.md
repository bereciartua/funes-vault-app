# Spike H search and answers, round 2: plan

Round 1 (RESULTS.md, "Search and answers") ran but didn't pass plan §15. Fable 5.2's review found three problems. The fixture has no headroom: plain search already ranks targets in the top 3. The answers were scored by regex and sampled once. And there were bugs. This round fixes those and measures again.

## 1. Bugs
**Query side (`search.py`):**
- Name links the read left `ambiguous`, and `candidates` role links, are admitted for every candidate person, at the candidates weight.
- Query names skip people.py's `STOP_NAMES` unless they're capitalized mid-sentence ("in may" never matches May).
- A possessive chain in a query ("my partner's sister", "my sister's kids") matches the first person at the candidates weight, not full.
- The rest of a Spanish query drops Spanish function words.

**Pipeline (`people.py`, `vault_run.py`):**
- A relation's evidence keeps only memories that *state* the relation (a pair, "X is my R", or a model relation with a quote). Role-only memories resolved to it are links, not evidence. A bridge is chosen only from trusted stating evidence, and only when no stating memory is already in the input.
- A nameless role group isn't renamed into a person. A name for a group member creates a person with that relation; the group keeps its count.
- `since` (when a relation started) doesn't make an older year cue ("in 2019") go to the group. A year cue before `since` falls back to the holders at a weak basis, not to the group.
- Memories above the cloud limit get code links. Role phrases resolve through known relations at the basis those allow, and names link `named` for aliases of at least two words (plan §6).

## 2. The answer knows who people are
- **The user's name:** the user's own names in memory text become "the user" before the answer call, the same rule as the People call (§13). "Sam mentioned that their partner…" then reads as the user's partner.
- **Who a role is:** each memory that came through a link gets an `about="Jordan, your partner"` attribute (the why line), built from the link, its basis and the relation. A weak basis says so: "probably Lucía, the only sister known".
- **The prompt** gains one sentence: an `about` attribute is Funes's inference, not part of the memory, and a claim that relies on it says so.

## 3. A fixture with headroom ("busy vault", written blind by GPT-6-Astra)
- **Vault:** Spike G's vault plus about 150 new memories. Two heavy people, the sister (60) and the partner (50), with competing topics: food, drinks, gifts, health, travel, work, all spread over 2 years. Role-only memories ("my sister …") make up about a quarter of each. Twenty or more decoys: the same topics about other people (friends, colleagues, parents). People named May, Will and Mark, plus common-word name collisions in queries. One shared first name, with both people within the cloud limit. Spanish, and agent-written third-person memories.
- **Ground truth per memory:** the people it's about (link truth).
- **Queries:** about 40, each with targets, decoys and facts in plain words. Half are written so that plain search shouldn't find the target, like the motivating case. Astra marks these, but the measure doesn't rely on its marks. Name-collision queries that must not match a person. A few with no answer.
- **Split:** queries with odd ids tune the weights, even ids test. The main set and the Spike G and bench regression sets are also measured. The tuning choice is recorded (a hash and timestamp in `results-search/locked.json`) before the test half is scored.

## 4. Measures
- **Rank:** best target in the top 3 and in the top 8, and every target kept in the top 8 (per target, not only the best), without and with people. Decoys above the best target and in the top 3. For a name-only query, the share of memories about the person that are returned.
- **Robustness:**
  - link precision and recall against the ground truth;
  - an injected missed link (each target's link removed in turn) and an injected wrong link (a decoy linked to the queried person), with the rank change under each.
- **Regression:** per target, on queries that match no person (identical by construction) and on those that do. Name-collision queries must match no one.
- **Answers:** Haiku answers each query 3 times per arm. A judge (Opus 5.5, `claude -p`) labels each claim: states a fact · denies or doubts a true fact · wrong person · unsupported or invented · other. It's given the query's facts and the memories sent. I read a 20% sample of the judged claims to check the judge.
- **Tuning grid:** boost × others × admitted-memory cap. Picked on the tune half by:
  1. no per-target losses;
  2. then the most targets in the top 3;
  3. then robustness to a missed link.

## 5. Not in this round
Re-running the matrix with `since` and `is_role_name`, and the harness through `ModelRouter`.

## 6. Changes after GPT-6-Astra's review of this plan
- **Privacy of `about`:** an attribute is sent only when a memory that *states* the relation is within the cloud limit. Otherwise nothing about the person is sent; a name alone can reveal a restricted link. The fixture gets cases with an eligible name and an ineligible relation, and the outgoing prompts are checked.
- **User name:** the user's names are replaced in titles and bodies in all arms. A memory naming a different Sam is a known limit, shared with the People call (§13).
- **Split by query family** (Astra tags each query with the fact or story it tests), never odd/even. Frozen and hashed in `results-search/locked.json` before the test half is scored: the fixture, the code, the prompts, the grid and the selection rule.
- **Arms:**
  - A: plain search;
  - B: people ranking only;
  - C: people ranking plus bridges and `about`.
  - All three use the user-name replacement and send exactly 8 memories; bridges replace the lowest-ranked results.
- **Answers:**
  - **Samples:** 3 independent per arm; a reuse requires an identical request hash.
  - **The judge** scores per question: required facts covered, the right abstention, citations that support each claim, wrong person, and denial of a true fact. A justified "probably" isn't a denial. It doesn't see the arm, and it gets the truth separately from the input, so `about` can't prove itself.
  - **By hand:** every gain, regression and wrong-person case, plus a random 20%.
- **Challenge set:** reported apart from ordinary queries, with real queries about May, Will and Mark as well as false matches. Frozen before any baseline run.
- **Robustness:** a whole missing relation, as well as single links. Two backfills. A few answers run on injected wrong or missing links.
- **Losses** are reported separately: any rank worse; crossing out of the top 3; leaving the top 8. The grid includes the exact baseline. Name-only queries are measured with precision and recall in the top 10.
- **Rule changes:**
  - a possessive chain ("my partner's sister") matches no one;
  - a bridge must state the same relation type as the role link;
  - links left unresolved (`ambiguous`, `candidates`) are admitted for a candidate the query names, at the candidates weight, and the `about` attribute keeps the ambiguity ("your sister: Maria or Lucía").
- **Found while running round 2:**
  - **Pairs:** a role phrase that code paired with a name ("my sister Lucía", "Lucía is my sister"), which the model left as a group or unknown, is applied as that name. In one read of the held-out vault, Haiku missed Lucía as the sister in both rounds, which hid her role-only memories. The denial rule still runs after this.
  - **Plural roles:** "my parents", "my kids" and "my siblings" always resolve to the group, never to one holder, in memories and in queries.
