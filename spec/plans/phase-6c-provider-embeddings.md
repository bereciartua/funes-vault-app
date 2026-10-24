# Phase 6c: Provider embeddings (second index)

**Goal:** let a user add a provider's embedding model for search, as a second index next to the bundled bge-small, when it beats bge-small on the benchmark ([ADR-0023](../architecture/decisions/0023-provider-embeddings-second-index.md), FR-AI-09, FR-AI-11).

**Duration:** about 2 weekends. **Depends on:** Phase 6.1 (the multi-item guard and the cloud limit). Independent of 6a and 6b, but planned after them: they help every user with any key, while this helps only providers with embeddings (not Anthropic), mostly on raw agent tasks and other languages. Specs: [model providers §7–8](../architecture/model-providers.md#7-choosing-a-provider-embedding-model), [memory processing §2, §4](../domain/memory-processing.md#2-embeddings-and-semantic-search).

## Tasks
### 6c.1 Benchmark first · 3 h
- [x] Run the 200-memory / 30-query benchmark (raw and agent-expanded) and a new Spanish set against `text-embedding-3-small`, `-3-large`, a Gemini embedding model and `nomic-embed-text`, alone and fused with bge-small as a second index. *(2026-10-24: Gemini left out at the author's choice; multilingual-e5-small and Qwen3-Embedding-0.6B added.)*
- [x] Record in [spike results](spike-results.md#phase-6c1-provider-embeddings-as-a-second-index). Go on only for models with a gain on raw tasks or Spanish, and no loss where some memories have only a bge vector. *(Qwen3-0.6B, local, passes; `text-embedding-3-small` and `-large` at Internal pass barely, with net −1 of 182 bge-only label slots; nomic and multilingual-e5-small fail.)*

### 6c.2 Adapter and index · 4 h
- [x] `/v1/embeddings` in `OpenAICompatibleClient` (OpenAI, Gemini's compatible endpoint, OpenRouter, Ollama, LM Studio), with query and document roles for models that use prefixes. *(`OpenAICompatibleEmbedder`, a separate type next to the chat client; prefixes from `EmbeddingCatalog`; every call through `ModelRouter.embed`, enforced by test.sh.)*
- [x] A second vector per memory within the cloud limit; per-index candidate thresholds and min-max normalization; provider score where present, bge otherwise.
- [x] Deletion when the limit drops, a memory's sensitivity rises above it, or the provider model is removed.

### 6c.3 Re-embedding and calibration · 3 h
- [x] Background job: batched, resumable, rate-limit aware, progress and cancel; search stays bge-only until the set is complete.
- [x] Built-in thresholds for the benchmarked models; top-K plus **Calibrate…** for others (synthetic data only, after confirmation). *(Qwen3-0.6B 0.24 / 0.28, 3-small 0.20 / 0.25, 3-large 0.18 / 0.22; Calibrate's rule gives bge-small its own thresholds back.)*
- [x] "Embed agent requests with the cloud model" (FR-AI-09) and the disclosure line.

### 6c.4 Tests and docs · 2 h
- [x] Adapter contract tests, guardrail tests (nothing above the limit embedded by the provider), re-embedding switch, cancel and resume, fallback to bge when the provider is down. *(`ProviderEmbeddingTests`, plus an opt-in live OpenAI test; Ollama's GGUF build of Qwen3 not measured.)*
- [x] When the code lands: PRIVACY.md, README, docs, CHANGELOG.

## Exit criteria
- A benchmark gain recorded for each built-in model; sensitive memories keep semantic search at the recommended limit.
