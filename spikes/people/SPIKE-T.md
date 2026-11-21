# Spike T: answers over the facts with a model reading the question (21 November 2026)

**The question** (drafts/facts-llm-first §5): does a model reading the question, with the time model answering (arm 3), beat today's grammar on the same stores, without more wrong answers? It runs on Claude Haiku 5.5 (claude-code) and GPT-5.6-Terra (codex), with prompts frozen (`15335ddeb8c9`) before any held-out label was read. The harness is `spike_t.py`, and the full table is `results-spike-t/report.md`.

## Setup
- **Stores:**
  - work13, from its own labels (gold);
  - mixed, from Spike H3b's recorded Haiku calls (a real model read);
  - workt, from its own labels: 10 new stories by GPT-6-Astra, weighted to undecidable questions.

  13e.1's live reads didn't record their calls, so no arm runs on them (the draft's arm 5).
- **Questions:**
  - development: work13's and mixed's own (54 decidable, 5 undecidable, 16 negative);
  - held out: 88 new wordings over those stories, plus workt's 55, all by GPT-6-Astra (67 decidable, 38 undecidable, 38 negative or title questions).

  A fresh Astra checked every question any arm got wrong and found 3 of 25 labels wrong (workt rehire stories): those 3 use its answer.
- **Arms:**
  1. a model reads all the story's memories (5–9) and answers;
  2. today's grammar and time model, with "2+1" falling back to arm 1 when the grammar reads nothing, as the app does;
  3. a model reads the question into a typed intent, code turns it into the one wording the grammar reads, and the time model answers (2 samples);
  4. arm 1 plus the store's work rows (trusted episodes, dates, kinds, renames).

  Answers on title and someone-else questions were graded by Opus, blind (216; 1 wrong).
- **Calls:** about 2,250 (1,744 answers and intents, 286 refusal intents, 216 judge calls) and 0 failures.

## Results (held out; development in the report)

| | Decidable right (of 67) | Decidable wrong | Undecidable "not sure" (of 38) | Undecidable wrong |
|---|---|---|---|---|
| 1 model alone, Haiku / Terra | 67 / 67 | 0 / 0 | 28 / 24 | 10 / 14 |
| 4 model with rows, Haiku / Terra | 67 / 67 | 0 / 0 | 29 / 24 | 9 / 14 |
| 2 grammar | 9 | 0 | 38 | 0 |
| 2+1 grammar, else model (≈ today), Haiku / Terra | 58 / 58 | 0 / 0 | 34 / 30 | 4 / 8 |
| 3 model intent → time model, Haiku / Terra | 42 / 42 | 1 / 0 | 38 / 35 | 0 / 3 |
| 1 with the time model's veto, Haiku / Terra | 43 / 43 | – | 37 / 37 | 1 / 1–2 |

- **Negatives and title questions:**
  - arms 1 and 4 answered them right (Opus found 1 wrong of 216);
  - arm 3 read 0–2 of 38 as timeline questions.
- **Should-refuse questions** (13e.1's 143 adversarial probes, labelled independently by Astra): the intent step read **47 (Haiku) and 20 (Terra) of the 102 non-work questions as "where did I work" questions**. Some are fair readings ("Where was my job in 2019?"); many aren't: "What did I get after leaving Copper Delta?", "Who was on my payroll in 2019?", yes/no questions.
- **Latency** (p50 / p95):
  - one answer call: Haiku 4.3 / 6.7 s, Terra 5.3 / 9.0 s;
  - one intent call: Haiku 2.6 / 3.7 s, Terra 3.4 / 5.1 s.

## What it shows
1. **A model alone answers decidable work-history questions very well**: every held-out decidable question right, in English and Spanish, however worded. The grammar got 9 of 67.
2. **A model alone guesses when the memories can't decide**: it answered 9 to 14 of 38 undecidable questions confidently, mostly rehires, possible overlaps and same-year hand-overs. Rows didn't make it more careful.
3. **The time model is what says "not sure"**: arm 3 told 35 to 38 of 38. Used as a veto on the model's answers, it keeps that and loses coverage.
4. **Arm 3 loses coverage to plumbing more than to the idea.** The time model's 40 "can't tell" answers on decidable questions are mostly:
   - **rehires:** the intent has no "first stint / my return" field, so "before Hush Audio" matches two stints;
   - **untrusted competitors:** an agent's claim of another current job makes the user's own answer ambiguous;
   - **dates:** the canonical wording passed "mayo de 2015" and "summer 2023" through as written, and the grammar doesn't read them.
5. **The intent step over-reads adversarial questions,** Haiku much more than Terra. On natural held-out wordings it was fine (0–2 of 38).
6. **Not tested:**
   - retrieval: each story's 5–9 memories all fit in the prompt, the best case for arm 1, while the author's vault has 365 memories and the original failure was the answering memory at rank 34;
   - live extraction (no recorded live read);
   - the answer wording on top of arm 3;
   - Spike G's gates.

## Against the draft's pass criteria
| Criterion | Result |
|---|---|
| Arm 3 no more wrong answers than arm 2 on held-out questions | **No:** 1 (Haiku) and 3 (Terra) against 0 |
| Arm 3 answers ≥ 80% of decidable questions | **No:** 63% (42 of 67), against the grammar's 13% |
| Undecidable "not sure" ≥ 90% | **Yes:** 100% and 92% |
| p95 ≤ 15 s | Likely: an intent call plus an answer call is about 10–14 s at p95 |

Neither arm passes as built. Arm 1 has the coverage and arm 3 has the caution.

# Round 2: the model answers, the time model checks (21 November 2026)

**The question:** with round 1's three fixes, and with retrieval and a live read in play, does "model answers, time model checks" get the model's coverage and the time model's caution? The harness is `spike_t2.py` (prompts frozen `57cdfc7982fd` before any label was read), and the table is `results-spike-t2/report.md`.

## Setup
- **Fresh held-out set** `workr`, by GPT-6-Astra: 12 stories and 144 memories, about half of them everyday notes that mention work. 84 questions: 28 decidable, 28 undecidable, 28 negative or title. It passed the checks on the first pass.
- **Search:** each story's memories plus 40 shared filler memories (Astra, no organizations), BM25 keyword, top 10.
- **Live store:** one recorded Haiku read of workr (run_facts.py, both call groups, 289 calls, 0 failed), replayed through the Swift pipeline. The gold store is there for comparison.
- **Arms:**
  - **A:** top 10 only.
  - **B:** the store's trusted work rows, plus the top 10, plus the memories the rows cite (at most 16). The model also states the comparison it made.
  - **B checked:** B's comparison goes through the time model, with three fixes: a stint field, normalised dates, and a second check on the store without agents' notes. If the time model agrees, the answer stands. If it can't tell, the answer becomes "not sure", unless the store without agents' notes agrees. If it disagrees, the answer is dropped.
  - **C:** today's grammar on the live store, else A.
- **Judging:** a fresh Astra upheld all 19 labels any arm got wrong. Opus graded the negative and title answers, blind (107; 2 wrong).
- **Calls:** 289 extraction, 336 answers and 107 judge calls.

## Results

| Arm | Haiku: decidable right | Haiku: undecidable not sure | Terra: decidable right | Terra: undecidable not sure | Negatives wrong (H / T) |
|---|---|---|---|---|---|
| A top 10 only | 23 / 28 | 26 / 28 | 25 / 28 | 12 / 28 | 0 / 0 |
| B facts, unchecked | 28 / 28 | 27 / 28 | 28 / 28 | 18 / 28 | 2 / 0 |
| **B checked, live store** | **26 / 28** | **27 / 28** | **25 / 28** | **27 / 28** | 2 / 0 |
| B checked, gold store | 28 / 28 | 27 / 28 | 27 / 28 | 27 / 28 | 2 / 0 |
| C today's app | 20 / 28 | 27 / 28 | 23 / 28 | 13 / 28 | 0 / 0 |

- **No arm gave a wrong answer to a decidable question, as scored.** The score compares the organization the answer names (the model's own `answer_org` field, matched loosely), not the claim's full text. The remaining "undecidable wrong" in B checked is a rehire question in each engine, two different ones: r08 q3 (Haiku) and r02 q3 (Terra). There the model picked a stint that the question doesn't name, the check confirmed that stint's predecessor, and the answer text says it depends on the stint. The check verifies the comparison the model stated, not that it's the one the question asked. Two of Haiku's right decidable answers stated no comparison, so they went unchecked. 17 of the 28 undecidable questions ask about an exact day inside a year-precision range, and all 9 of Terra's answers the check turned into "not sure" were of that kind. For Haiku, the check turned none into "not sure" and lost 2 decidable answers on the live store. The spike ran on 13e.1's code (ceb9d97: its time model, store and grammar), not main's.
- **The check, on the live store:**
  - Haiku's decidable answers: 23 agreed, 1 agreed without the agent's note, 2 "can't tell" (lost) and 2 unchecked.
  - Terra's undecidable answers: 9 "can't tell", which turned confident answers into "not sure".
  - The live store lost 2 decidable answers to the gold store, an extraction effect.
- **The facts rows add coverage:** B over A is +5 (Haiku) and +3 (Terra) decidable answers, from the rows and the memories they cite reaching the model when the top 10 misses them.
- **Latency:** one B call is 5.3 / 8.2 s (Haiku, p50 / p95) and 6.1 / 9.9 s (Terra). The check runs in code, with no extra call.

## Against the pass criteria
| Criterion | B checked, live store |
|---|---|
| Decidable right ≥ 80% | **Yes:** 93% (Haiku), 89% (Terra); today's app 71% and 82% |
| Wrong answers no more than today's | **Yes:** 0 decidable. Undecidable 1 per engine (the nuanced rehire answer), against today's 1 (Haiku) and 15 (Terra) |
| Undecidable "not sure" ≥ 90% | **Yes:** 96% both |
| p95 ≤ 15 s | **Yes:** about 8–10 s, one call |
| Inferred claims marked | Not measured: the marking code isn't built |

## Limits
- One sample per arm, 12 stories, and one live read.
- The live read used the spike's Python extraction, not Swift's extractor.
- Search is keyword BM25, not the app's hybrid.
- The check reaches the time model through canonical questions; the product would call it directly.
- "Without agents' notes" dropped memories whose source is an agent; the spec also counts imports and shared text as untrusted.
- The fillers name no organization, and top 10 of about 52 memories plus the cited ones gives arm B nearly the whole story, so retrieval was only lightly tested.
- The raw records are in `results-spike-t/raw/` and `results-spike-t2/raw/`.
- Haiku answered 2 of 28 negative and title questions wrongly (Opus). One was "¿Qué guardé después de salir de Fern Press?".
