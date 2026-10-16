# ADR-0005: On-device intelligence only (NaturalLanguage embeddings, Foundation Models)

**Status:** Superseded by [ADR-0014](0014-user-selectable-models.md) · 2026-10-16 (originally accepted the same day)

**Context.** The web version used OpenAI for embeddings, chat and extraction, which requires keys, costs money and sends text to a third party.

**Decision.**

Semantic search uses Apple **NaturalLanguage** embeddings (`NLContextualEmbedding` or `NLEmbedding`, chosen in Spike 2) computed on the Mac. Capture classification uses the **Foundation Models** on-device model when available, falling back to rules. Private Cloud Compute is opt-in only.

**Consequences.**

- No API keys, no cost, no third-party processor to disclose.
- Quality may be lower than the best cloud models. Mitigated by hybrid FTS5 ranking and by keeping classification as review-only proposals.
- Classification needs Apple Intelligence hardware and OS. The fallback rules always work.

**Alternatives considered.**

- **OpenAI or Anthropic embeddings with the user's own key:** better quality, but breaks the "nothing leaves the Mac" promise. Could be an advanced opt-in later.
- **A local open-source model via Core AI or MLX:** a possible later upgrade.
