# ADR-0023: Provider embeddings are a second index next to the bundled one

**Status:** Accepted · 2026-10-23 · **Amends** [ADR-0014](0014-user-selectable-models.md) decision 5 ("one embedding model at a time") and [ADR-0016](0016-bundled-bge-small-embeddings.md) (choosing another embedding model, "later")

**Context.**
- **Choosing another embedding model is specified but deferred:** switching re-embeds the vault, search uses one model's vectors, and memories above the cloud limit get no vector, so they're found by keyword only ([model providers §7–8](../model-providers.md#7-choosing-a-provider-embedding-model)).
- **That makes search worse for sensitive memories** at the recommended limit (Internal): "peanut allergy" is Health, so Sensitive, and would lose semantic search, which the bundled bge-small gives it today.
- **bge-small is already strong on the benchmark:** recall@5 0.94 with agent keywords, 0.69 on raw tasks. Provider models mostly help on raw tasks and non-English text (Spanish against English memories falls to about 0.40).
- **Anthropic has no embeddings API;** OpenAI, Gemini, OpenRouter (where offered), Ollama and LM Studio do.
- **New memories and the tidy-up** ([ADR-0020](0020-atomic-extraction-for-every-source.md), [ADR-0021](0021-daily-tidy-up.md)) need a related-memories finder that's local, free and stable.

**Decision.**
1. **bge-small vectors stay on every memory, always.** A provider model, when chosen, adds a second vector for memories within the cloud limit.
2. **Scoring:** `semantic` is computed per index, each min-max normalized over its own candidate pool; a memory uses its provider score when it has a provider vector, and its bge score otherwise. Candidate thresholds are per index. The fusion formula (`0.30 × keyword + 0.70 × semantic`) is unchanged.
3. **The related-memories finder** for New memories and the tidy-up always uses bge-small.
4. **A provider vector is deleted** when the limit drops or a memory's sensitivity rises above it.
5. **Shipping needs a benchmark gain** over bge-small (raw tasks or a Spanish set), as ADR-0016 already requires, including a check that mixing the two indexes doesn't reorder results badly where some memories have only a bge vector.

**Consequences.**
- **No semantic regression for sensitive memories,** and search falls back to bge at once if the provider is down (instead of keyword-only).
- **Storage:** two vectors for memories within the limit, about 75 MB at 10,000 memories with 1,536-dimension provider vectors.
- **More code:** two indexes, per-index thresholds and calibration, re-embedding only for the provider index.
- **Embeddings aren't in the daily cap;** vault search embeds once per search, not per keystroke.

**Alternatives considered.**
- **One model at a time (today's spec):** simpler, but sensitive memories lose semantic search at the recommended limit.
- **Embed sensitive memories locally into the provider index:** vectors from two models can't share one index.
- **Decide after the benchmark:** the benchmark gates shipping either way; the structure is decided now so the finder and storage can be built once.
