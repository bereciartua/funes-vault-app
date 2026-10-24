# ADR-0020: Every new memory is split into atomic pieces and linked to the vault

**Status:** Accepted · 2026-10-23 · **Amends** [ADR-0014](0014-user-selectable-models.md) (v0.1 classifies captures only; "a model can never apply anything") and the [access policy](../../domain/access-policy.md) §5.3 and §6

**Context.**
- **Today a model has one small job:** proposing a title, kind, categories and sensitivity for a capture. One capture becomes one suggestion. Agent suggestions, imports and seed answers never reach a model ([memory processing §5](../../domain/memory-processing.md#5-new-memories-split-classify-link)).
- **Input is rarely atomic.** A capture often says several things. Agents send long summaries: asked to send its memories to Funes, ChatGPT sent one long paragraph covering a dozen unrelated facts. Imports have the same problem. Large memories are worse for retrieval (one Share row carries unrelated text), for the access policy (one category and one sensitivity for many claims), and for spotting updates.
- **Funes Vault (web)** extracted atomic claims with an LLM, but only from chat and voice turns, and its extractor never saw existing memories: updates and merges were left to a chat agent with tools ([ADR-0010](0010-start-from-scratch.md): reference only). Its prompt rules and evidence check are a good start; its pipeline isn't.
- **A review of the first draft** (2026-10-23) found that auto-applying model output could let agent-written or pasted text change the user's memories, and that grouping categories could widen an agent's access. The decision below includes those rules.
- **There are no external users yet**, so settings, schema and the companion protocol can change without compatibility work.

**Decision.**
1. **One pipeline for every source.** Captures (Mac and iPhone), seed answers, agent suggestions (queued or saved directly) and imports (ChatGPT, Claude, Markdown) go through **New memories** processing: split into atomic pieces, classify each, link each to related memories. Not split: an agent's correction (`target_memory_id`) and a Funes export being restored.
2. **Nothing waits on a model.** Input is stored at once, as today (a rules-classified suggestion, or a memory for an agent's direct write). A durable processing queue then splits it in the background. With no model, or splitting off, behaviour is today's.
3. **Agents' direct writes: save, then split.** The agent still gets `saved` and a `memory_id`; the MCP contract doesn't change. The split then either replaces the original automatically (§6) or becomes a **Split this memory** card.
4. **Code validates what the model returns:** every piece quotes its evidence verbatim from the input; secrets are scanned; a piece's sensitivity is never lower than the highest of the model's value, the category default, the user's hint, the on-device pre-screen, the agent's declared level and the original memory's level. If every piece fails, the original stays.
5. **Linking.** Each piece is compared, locally (FTS5 + bge-small), with related memories, never with itself or its siblings. One decision call per input proposes, per piece: new, update of a memory, already saved, or retracts a memory. Updates and retractions use the existing correction and archive suggestions.
6. **Auto-apply is the user's choice** (Settings ▸ AI Models: Off by default · Duplicates only · Everything except conflicts), and every automatic change can be undone for 30 days. Three rules hold at every level:
   - **Trust:** changes to existing memories (updates, retractions) are auto-applied only from text the user typed or dictated. Shared and Services captures and imports can at most auto-create new pieces.
   - **Agents follow their own access, never the auto-apply setting.** A Suggest-only agent, or one that asks before saving, always goes through the Inbox. An agent with Write and Ask before saving off gets its pieces saved within its write scope (create only), as its original was.
   - **Only the chosen engine,** never a fallback, and never a result that would let an agent read something it couldn't read before (checked with the policy engine).
7. **Pieces of an agent's input outside that agent's scope** (a category it can't suggest in, above its ceiling) go to the Inbox flagged "Outside <agent>'s scope", never auto-applied and left out of Apply all. Access policy §5.3 is amended: an agent can't *save* outside its scope, but its input can be *proposed* to the user. When extraction finds an agent's directly saved memory more sensitive than declared, its sensitivity is raised at once.
8. **The cloud guard covers every item in a call,** using the highest sensitivity among them, and agent and import text is pre-screened on the device instead of trusting the declared level ([ADR-0022](0022-cloud-limit-and-daily-cap.md)).

**Consequences.**
- **Smaller, single-claim memories:** better retrieval, more precise Share panels, and updates that become corrections instead of near-duplicates.
- **More text goes to the chosen provider:** agent suggestions, imports and related existing memories, not only captures. The disclosure line says so, within the cloud limit.
- **New foundations first** ([Phase 6.1](../../plans/phase-6-1-foundations.md)): per-action apply (today only `update` + Replace really applies; everything else inserts a new memory), version-checked targeted suggestions, a durable processing queue, a multi-item cloud guard, `memory.trust`, the `split` suggestion status, provenance links, the undo log.
- **The Inbox gets group cards;** the iPhone shows pieces as ordinary suggestions and new card types as "Review on your Mac" until it gets its own cards.
- **Apple on-device only classifies** ([Spike E](../../plans/spike-results.md#spike-e-extraction-linking-and-tidy-up-quality)): it fits its ~4k-token window and refused nothing, but found 64% of the claims and 12% of its pieces were wrong. Splitting needs a local server or a cloud model; with Apple on-device, input stays one classified suggestion.
- **`confidence` gates nothing** (Spike E: 0.9–1.0 for nearly every piece). Auto-apply uses `atomic`, the support check and the trust rule, and a level is offered only for engines that reached 95% on the fixtures. For New memories none did (Spike E, two fixture authors and the user's own labels), so it starts disabled and every piece is reviewed in the Inbox.
- **Quality depends on the model,** measured on a synthetic fixture set (the repo is public), including injection attempts.

**Alternatives considered.**
- **Split captures only** (the first draft): leaves the messiest input, agent dumps, as it is.
- **Split agent writes inside the MCP call** and return several ids: agents wait up to the generation timeout, and the tool contract changes.
- **Queue all agent writes while splitting is on:** quietly takes away Write.
- **Auto-apply everything confident, whatever its source:** an agent or a pasted page could rewrite the user's memories.
- **Drop out-of-scope pieces:** loses information the user may want; the user reviews them anyway.
