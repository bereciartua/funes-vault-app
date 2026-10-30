# ADR-0014: User-selectable AI models, on-device by default

**Status:** Accepted · 2026-10-16 · **Supersedes** [ADR-0005](0005-on-device-intelligence.md) · **Amended by** [ADR-0016](0016-bundled-bge-small-embeddings.md): the default embedding model is bundled bge-small (Core ML), not Apple NaturalLanguage; choosing another embedding model comes after v0.1 · **Amended by** [ADR-0020](0020-atomic-extraction-for-every-source.md) and [ADR-0021](0021-daily-tidy-up.md) (models split new memories and propose tidy-up changes, which the user may let Funes apply), [ADR-0022](0022-cloud-limit-and-daily-cap.md) (the cloud limit goes up to everything; a daily request cap) and [ADR-0023](0023-provider-embeddings-second-index.md) (provider embeddings are a second index, not a switch) and [ADR-0024](0024-subscription-providers.md) (Claude and ChatGPT subscriptions through the user's own Claude Code and Codex) · **Amended by** [ADR-0030](0030-settings-window.md) (an account offers several models; each task picks an account and a model)

**Context.**
- **Where Funes uses AI:**
  1. **embeddings** for semantic search, of memories and of search and agent-task text;
  2. **text generation** for capture classification, and later consolidation and optional re-ranking.
- **What ADR-0005 said:** on-device only, using Apple NaturalLanguage and Foundation Models. That's private and free, but:
  - Apple's on-device models are small. Some users get noticeably better classification and retrieval from larger models.
  - Some users already run local servers (Ollama, LM Studio) with stronger open models.
  - Some users are happy to use a cloud model they already pay for (Claude, GPT, Gemini) and accept the trade-off.
- **Funes's promise** is control, not a particular model. The user should decide where their text goes, with the trade-off made visible.

**Decision.**
1. **The default is Apple on-device** for both embeddings (NaturalLanguage) and generation (Foundation Models, with a rules fallback). Nothing leaves the Mac unless the user changes it.
2. **The user can pick the model per task** in Settings ▸ AI Models: Embeddings and Classification, and later Consolidation. The choice is a **provider plus a model**:

   | Provider | Kind | Embeddings | Generation |
   |---|---|---|---|
   | Apple on-device | local | ✓ (NaturalLanguage) | ✓ (Foundation Models, macOS 26+ with Apple Intelligence) |
   | Apple Private Cloud Compute | Apple cloud | — | ✓ |
   | Ollama · LM Studio · any local OpenAI-compatible server | local | ✓ | ✓ |
   | OpenAI | cloud | ✓ | ✓ |
   | Anthropic (Claude) | cloud | — (no embeddings API) | ✓ |
   | Google Gemini | cloud | ✓ | ✓ |
   | OpenRouter · any custom OpenAI-compatible endpoint | cloud | ✓ (if the endpoint offers it) | ✓ |

3. **Two adapters cover almost everything:**
   - an **OpenAI-compatible** client (chat completions with JSON-schema structured output, `/v1/embeddings`, `/v1/models`);
   - a **native Anthropic Messages** client.

   Both are written with `URLSession`, so no SDK dependencies. Apple providers use the system frameworks.
4. **Guardrails always apply to cloud providers:**
   - **The secret scanner** runs before any request.
   - **A sensitivity guard** (default: **Internal and below**) stops anything more sensitive from being sent to any non-local provider.
   - **API keys** live only in the Keychain. They never appear in the database, logs or exports.
   - **The UI always shows** which provider receives what.
   - **On provider failure,** Funes falls back to on-device classification or keyword-only search. Capture and MCP never wait on a provider.
5. **One embedding model at a time.** Vectors from different models can't be compared. Switching the embedding model re-embeds the vault in the background, and the old vectors keep working until the new ones are ready.
6. **Agents are unaffected.** Agents use whatever model the agent runs. Funes's settings cover only Funes's own processing.

**Consequences.**
- **Better quality** for users who choose bigger models. Local servers give a middle path: better models, and still nothing leaves the Mac.
- **The privacy story becomes "local by default, your choice".** The vision, the security model and "what leaves the Mac" are updated accordingly.
- **Cloud embeddings send more than memories.** Search queries and **agents' task text** go to the provider too, because they must be embedded with the same model. This is shown in Settings when a cloud embedding model is chosen.
- **More code and testing:** two HTTP adapters, the Keychain key store, a settings UI, re-embedding and fallbacks. That's about 6–8 extra hours, spread over Phases 1 and 3.
- **Search thresholds depend on the model,** so they're calibrated per model id ([memory processing §4](../../domain/memory-processing.md#4-ranking)).
- **Costs belong to the user** (their API keys). Funes shows request and token counts per provider, not prices.

**Alternatives considered.**
- **On-device only (ADR-0005):** simplest and most private, but it limits quality and ignores users' existing setups.
- **Bundle a local open model** (Core AI or MLX): a large download and maintenance burden. It may come later as another "local" provider.
- **Hugging Face `AnyLanguageModel`** or similar wrapper packages: would cover many providers, but adds a dependency for what amounts to two small HTTP clients. Reconsider if the provider list grows.
- **Use the Foundation Models framework's own third-party model support** (WWDC26: one Swift API for Claude, Gemini and others): attractive, but it's tied to macOS 27+ and its terms aren't settled yet. Reconsider once the minimum macOS allows it.
