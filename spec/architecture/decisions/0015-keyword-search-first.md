# ADR-0015: Keyword search in v0.1; semantic search later, as an embedding model the user chooses

**Status:** Accepted · 2026-10-16 · **Amends** [ADR-0014](0014-user-selectable-models.md) (its embeddings half moves after v0.1)

**Context.**
- **Phase 0 Spike 2** (results in [spike results](../../plans/spike-results.md#spike-2-search-quality-and-speed)) measured search over 200 synthetic memories and 30 agent-style queries, against a target of recall@5 ≥ 0.85:
  - FTS5 with the spec's `unicode61` tokenizer: 0.46. With the `porter` stemmer: **0.57**.
  - The best hybrid with Apple's on-device embeddings (`NLContextualEmbedding` + FTS5 porter): **0.58**. `NLEmbedding` sentence vectors are worse than keyword alone.
  - Foundation Models query expansion raises every method by about 0.10 (best 0.74), but costs about 3.7 s per query. Foundation Models re-ranking adds nothing.
  - Speed isn't the problem: about 3 ms for keyword search and about 18 ms for the hybrid at 10,000 memories.
- **So Apple's on-device embeddings barely beat keyword search.** They would add a 512-float vector per memory, a re-embedding job, per-model thresholds and calibration, for about +0.02 recall.
- **The misses need inference** ("plan dinners" → *vegetarian*, *peanut allergy*). Stronger embedding models are the likely fix, but every option has a cost that shouldn't block v0.1:
  - a bundled open model adds a third-party asset;
  - Ollama needs a local server;
  - a cloud model sends memory text off the Mac.

**Decision.**
1. **v0.1 search is keyword-only:** FTS5 BM25 over title and body, with the tokenizer **`porter unicode61 remove_diacritics 2`**. Both vault search and agent retrieval use it, with `score = keyword`.
2. **No embeddings in v0.1:**
   - no Apple embedding default;
   - no `embedding` table in schema v1;
   - no re-embedding job;
   - no Embeddings row in Settings ▸ AI Models.

   ADR-0014's per-task model choice still applies to **classification** in v0.1.
3. **Semantic search comes later, as an opt-in the user chooses.** Settings ▸ AI Models gains an **Embeddings** row. Its options:
   - **Off** (keyword only), the default;
   - a **local server** (Ollama, LM Studio);
   - a **cloud model** (OpenAI, Gemini, OpenRouter, custom), behind the cloud sensitivity limit and disclosure (FR-AI-07, FR-AI-08, FR-AI-09);
   - possibly a **small open model bundled as Core ML**, if a Spike 2b shows it clears the bar.

   Then the hybrid formula (`0.45 × keyword + 0.55 × semantic`), per-model thresholds, calibration and re-embedding, as already specified, apply when an embedding model is chosen.
4. **The ranking rules keep their shape.** `semantic` is 0 when no embedding model is active, which the spec already allowed. Adding embeddings later changes scores only for users who turn them on.
5. **Regression baseline:** the Spike 2 fixtures (`memories-200.json`, `queries-30.json`) become a FunesCore test with FTS5 porter **recall@5 ≥ 0.56** (re-measured inside FunesCore before freezing). Any embedding option offered later must beat it on the same benchmark.

**Consequences.**
- **v0.1 gets smaller:**
  - no `EmbeddingIndex`;
  - no Apple embedder;
  - no re-embedding, thresholds or calibration UI.

  The OpenAI-compatible client still ships, for classification.
- **v0.1 retrieval is weaker on inference-heavy tasks.** Agents asking "plan a week of dinners" may not get the allergy memory unless the words overlap. Mitigations:
  - the Share panel shows exactly what's offered;
  - agents can pass `categories` to steer retrieval;
  - users can write memories with the words agents will use.
- **The privacy story stays simple:** with the defaults, search never sends anything anywhere, and v0.1 has no embedding disclosure to explain.
- **English stemming:** `porter` stems English only. Other languages still tokenize correctly through `unicode61`, without stemming. Revisit with localization.
- **Schema:** the `embedding` table arrives in the migration that adds semantic search.

**Alternatives considered.**
- **Ship Apple's on-device embeddings as the hybrid default (the original plan):** +0.02 recall over keyword alone, for real complexity.
- **Foundation Models query expansion for agent retrieval:** +0.10 recall, but 3.7 s per request, macOS 26+ with Apple Intelligence only, and guardrail refusals on sensitive text. It's a candidate to add later for agent retrieval only, cached per task for the 15-minute request window.
- **Bundle an open embedding model (bge-small, e5-small) in v0.1:** promising but unmeasured, and a new third-party asset. Do it as Spike 2b when semantic search is picked up.
