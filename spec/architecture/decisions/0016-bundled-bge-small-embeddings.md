# ADR-0016: Bundled bge-small embeddings (Core ML) and agent keywords in v0.1

**Status:** Accepted · 2026-10-17 · **Supersedes** [ADR-0015](0015-keyword-search-first.md) · **Amends** [ADR-0014](0014-user-selectable-models.md) (the default embedding model) · **Amended by** [ADR-0023](0023-provider-embeddings-second-index.md) (provider embeddings are added as a second index; bge-small stays on every memory)

**Context.**
- **Spike 2** showed Apple's on-device embeddings are too weak (recall@5 0.58 hybrid, about the same as keyword search). ADR-0015 then made v0.1 keyword-only.
- **But agent retrieval is the product.** An agent asking "plan a week of dinners" has to get the peanut-allergy memory. Keyword-only search misses exactly those cases.
- **Spike 2b** ([results](../../plans/spike-results.md#spike-2b-local-open-source-embeddings)) measured open embedding models locally on the same 200 memories and 30 queries, plus an agent-expanded version of each query:

  | Search | Raw task | Task + agent keywords |
  |---|---|---|
  | FTS5 porter (keyword only) | 0.57 | 0.83 |
  | **bge-small-en-v1.5 (Core ML) + FTS5, min-max 0.30/0.70** | 0.69 | **0.94** |
  | nomic v1.5, multilingual-e5-small, Qwen3-0.6B | up to 0.78 | 0.93–0.96 |

  - bge-small via Core ML on the CPU: 3.6 ms per query, 4.7 ms per memory, and **10.5 ms per search end to end at 10,000 memories** on an M1.
  - The biggest single gain is the agent saying what context it wants (+0.26 for keyword search).
  - The spec's `0.45 × keyword + 0.55 × cosine` underperforms with modern models, because their cosines are compressed. Unrelated memories score around 0.45 and relevant ones around 0.64.

**Decision.**
1. **The v0.1 embedding model is `bge-small-en-v1.5`** (BAAI, MIT licence), **bundled in the Mac app as Core ML**:
   - **Format:** ML Program with int8 weights and fp16 compute, 384 dims, about 32 MB (see the Phase 1 update below). CLS pooling and L2 normalization are inside the model.
   - **Runtime:** `MLComputeUnits.cpuOnly`. It's faster than the Neural Engine or GPU for this model, which re-specialize between input lengths.
   - **Tokenizer:** a WordPiece tokenizer in FunesCore (about 100 lines, no dependency), with its 30 KB vocabulary bundled.
   - **Inputs:**
     - Queries get bge's retrieval instruction prefix.
     - Memories are embedded as `title \n kind \n category names \n body`, truncated to 256 tokens.
   - **Model id:** `bge-small-en-v1.5/coreml-int8`.
   - **Locality:** everything stays on the Mac. No API key, no server, no download at runtime.
2. **Fusion** for vault search and agent retrieval: `score = 0.30 × keyword + 0.70 × semantic`, where:
   - `keyword` is FTS5 BM25 (`porter unicode61 remove_diacritics 2`), normalized by the best score in the pool;
   - `semantic` is the cosine **min-max normalized over the candidate pool, per query**.

   Candidates are kept if `keyword` reaches the keyword floor (0.15, set in Phase 1) or the **raw** cosine ≥ the model's threshold: **vault 0.50, retrieval 0.55** for this model id. Retrieval takes the top 30. Phase 1 tunes a keyword floor on the benchmark, because broad agent keywords match many memories.
3. **`request_memory` gets an optional `keywords` field:** up to 20 strings of 1–60 characters. The agent lists the kinds of personal context that would help ("dietary restrictions, food allergies"). The tool description and the server instructions ask for it.
   - **How it's used:** the keywords are appended to the task text **for retrieval only**, both for FTS5 and for the query embedding.
   - **Storage:** like the task text, they're kept in memory only, covered by the stored task hash, and shown on the approval panel with the task.
   - **Decisions:** they can change which memories are retrieved, but never the decision about a retrieved memory (FR-D-01's invariance still holds).
4. **One embedding model in v0.1, the bundled one.**
   - Settings ▸ AI Models shows Embeddings as "Built in (bge-small, on this Mac)", with no choice yet.
   - **Later** (from ADR-0015): choosing Ollama, a local server or a cloud embedding model, re-embedding between models, and calibration, under ADR-0014's guardrails.
   - **When a model version ships** (or on first launch), the vault is embedded in the background: about 47 s for 10,000 memories. Search uses keyword-only scores for memories without a vector until then.
5. **Fallback:** if the model can't load or a vector is missing, `semantic` is 0 for that memory or query, and search continues keyword-only. It never blocks or fails an MCP request.
6. **The weights aren't committed to git.** A script fetches the model at a pinned Hugging Face revision, verifies a SHA-256, converts it with coremltools, and verifies the output's checksum. The `.mlpackage` is cached locally and in CI. The bundled model and its vocabulary are an allowed third-party asset, next to BridgeKit, GRDB and Sparkle, with BAAI's MIT notice in `NOTICE` and the app's acknowledgements.
7. **Apple NaturalLanguage embeddings aren't used.** Mean-centering and the 0.20/0.25 thresholds from Spike 2 are dropped.

**Consequences.**
- **Retrieval clears the bar** on the benchmark (0.94 with agent keywords). It also works far better than keyword search on raw tasks (0.69 against 0.57), for agents that don't send keywords.
- **The app grows by about 32 MB.** Int8 weight quantization halved the 64 MB fp16 model, and recall held (Phase 1 update below).
- **Schema v1 includes the `embedding` table.** At 10,000 memories it holds about 15 MB of vectors. Re-embedding is needed only when the bundled model changes.
- **The model is English-first.** Spanish tasks against English memories fall to about 0.40. multilingual-e5-small (MIT, about 235 MB) is the candidate when Spanish is scoped, after a Spanish-memory benchmark.
- **The agent-keyword numbers may be optimistic.** The expansions were written by a model that had seen the vault. Phase 2's live matrix measures real agents' `keywords`, and the tool description is tuned from that.
- **EmbeddingGemma wasn't measured** (gated). Its Gemma Terms of Use would also be a heavier obligation to bundle than MIT.
- **Privacy is unchanged:** embeddings are computed on the Mac, as ADR-0014's default promised.

**Phase 1 update (2026-10-16).** Measured in FunesCore ([spike results](../../plans/spike-results.md#phase-1-re-measurement-in-funescore)):
- **Int8 weights adopted.** `linear_quantize_weights` (linear symmetric) halves the model to 32 MB with the same recall (R@5 0.939 expanded, 0.689 raw; R@30 raw 0.911 vs 0.894) and the same speed (3.7 ms per query on the CPU). The model id is therefore `bge-small-en-v1.5/coreml-int8`, and the thresholds (0.50 / 0.55) carry over unchanged. The fp16 variant stays available from the fetch script as an experiment.
- **Keyword floor: 0.15** (normalized BM25). It's the highest floor that loses no recall@5 or recall@30 in any of the four benchmark paths, and it cuts the memories kept per agent query by about a fifth (hybrid with keywords: 44.5 → 38.3; keyword-only: 34.4 → 26.0).
- **Fetching:** `scripts/fetch_embedding_model.sh` converts with plain torch over the safetensors checkpoint (no `transformers`), checks the result against committed sentence-transformers reference vectors, and pins the converted weights' SHA-256 (the conversion is byte-stable). CI runs it and caches the result.

**Alternatives considered.**
- **Keyword-only v0.1 (ADR-0015), with `keywords`:** 0.83 with agent keywords, but 0.57 without them, and no help on inference-heavy tasks.
- **nomic-embed-text through Ollama as the default:** similar quality, but needs a separately installed server. It stays the documented opt-in for later.
- **Qwen3-Embedding-0.6B:** best cross-lingually, but 1.1 GB and 86 ms per query.
- **MLX Swift instead of Core ML:** a new package dependency and GPU-bound, with no benefit at this model size.
- **Reciprocal rank fusion:** 0.88 against 0.94 for min-max on agent queries.
