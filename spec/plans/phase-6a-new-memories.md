# Phase 6a: New memories (split, classify, link)

**Goal:** every new input (captures, seed answers, agent suggestions and direct writes, ChatGPT, Claude and Markdown imports) is split into atomic pieces, each classified and linked to related memories, with optional auto-apply ([ADR-0020](../architecture/decisions/0020-atomic-extraction-for-every-source.md), FR-AI-13, FR-AI-14).

**Duration:** 3–4 weekends. **Depends on:** Spike E (prompt shape, thresholds, Apple on-device's role) and Phase 6.1. Specs: [memory processing §5](../domain/memory-processing.md#5-new-memories-split-classify-link), [access policy §5.3](../domain/access-policy.md#53-scope-check-for-the-proposed-memory), [UX: Mac](../product/04-ux-mac.md#inbox), [model providers](../architecture/model-providers.md).

## Tasks
### 6a.1 Extraction · 4 h
- [ ] Chunking (about 2,000 characters on paragraph or sentence boundaries, previous chunk as context), per-provider token budgets, up to 30 pieces per chunk and 40 per input. Apple on-device classifies only, no split ([Spike E](spike-results.md#spike-e-extraction-linking-and-tidy-up-quality)).
- [ ] The extraction request and schema ([§5.3](../domain/memory-processing.md#53-extraction)), with the first-person and about-the-user variants, through `ModelRouter` with typed items; start from Spike E's [`prompts.py`](../../spikes/memory-processing/prompts.py).
- [ ] Validation ([§5.4](../domain/memory-processing.md#54-validation-code)): evidence quotes (delimiter tags stripped, empty quotes ignored), the support check (a flag keeps the piece out of auto-apply), secret scan, the sensitivity floor (model, category default, hint, pre-screen, agent's declared level, original memory), length, categories, dedupe within the input; the original stays if everything fails.

### 6a.2 Linking · 4 h
- [ ] The related-memories finder (bge-small and FTS5, related at cosine ≥ 0.70 or a keyword hit, top 5), excluding the original and sibling pieces; shared with 6b.
- [ ] One decision call per input with dates; `create` / `update` / `duplicate` / `retract`; targets validated and version-pinned.
- [ ] Agent input: Inbox proposals link against all memories; anything auto-applied for an agent only against memories it can read.

### 6a.3 Replacing suggestions with groups · 3 h
- [ ] The job replaces a suggestion with its group in one transaction, only if it's pending, unedited and has no Save panel or iPhone approval open; otherwise it attaches a "Split into N?" offer. The original row becomes `split` and its id the group id.
- [ ] Capture receipts and idempotency unchanged (a resent iPhone capture is still a duplicate).
- [ ] Group expiry as one (FR-I-05); the group's source text dropped once every piece is decided.

### 6a.4 Agent input and the policy · 4 h
- [ ] Pieces outside the agent's scope: flagged, never auto-applied, left out of Apply all ([access policy §5.3](../domain/access-policy.md#53-scope-check-for-the-proposed-memory)).
- [ ] Direct writes: save, then split. Raise the original's sensitivity at once when extraction finds it higher. At Everything except conflicts, pieces within the agent's write scope replace the original (create-only, counted toward its write rate limit); otherwise a Split this memory suggestion.
- [ ] A correction targeting a split original is redirected to the pieces the agent can read.
- [ ] Updates and retractions from agent input are always suggestions; caller metadata never sent.
- [ ] Policy tests: no out-of-scope piece saved for an agent; no linking to unreadable memories for auto-applied pieces; split never lowers sensitivity; the MCP result unchanged (`tools.json` goldens).

### 6a.5 Auto-apply for new memories · 3 h
- [ ] The levels of [§5.7](../domain/memory-processing.md#57-auto-apply-for-new-memories): trust (changes to existing memories only from typed or dictated text), agents by their own access, chosen engine only, the policy-engine check that no agent gains access, each change in one transaction with its undo entry.
- [ ] A level is offered only for engines that reached 95% on Spike E's two fixture sets pooled: none for Duplicates only, GPT-6-Luna exactly at the line for Everything except conflicts. Ship review-first; `confidence` gates nothing, the gate is atomic plus the support check.
- [ ] Decide the atomicity rule for compound claims (a rule with its exception, a fact with its fallback) before freezing the extraction prompt: Spike E's second author counted them as one claim, and every model split them.

### 6a.6 Inbox and Settings · 4 h
- [ ] Group card, row badges, Apply all, Keep as one (only while nothing is decided), the "Split into N?" offer, Split this memory, the flagged rows, the engine line.
- [ ] Applied automatically list with Undo (and "undo this and N later changes").
- [ ] Settings ▸ AI Models ▸ New memories: the split switch, the disclosure line; import preview with the request estimate, today's remaining cap, and Import without splitting.
- [ ] New UI words (split, pieces, Applied automatically, Outside <agent>'s scope; and 6b's Tidy up) added to [Words in the app](../product/06-glossary.md) first; string catalog, UI snapshots (light and dark), accessibility labels.

### 6a.7 Tests and docs · 3 h
- [ ] Spike E's fixtures as FunesCore tests against a recorded or fake provider: claim recall, no invented claims, links, injection attempts.
- [ ] Concurrency: a split arriving while the card is edited, applied on the iPhone, or in a Save panel.
- [ ] When the code lands: PRIVACY.md (what goes to a provider now), README, docs, CHANGELOG.

## Exit criteria
- A ChatGPT-style dump from an agent becomes a group of single-claim pieces, with duplicates and updates of existing memories recognised.
- With splitting off or no model, behaviour is v0.2's.
- No auto-applied change from untrusted text, and no agent gains access, in the policy and fixture tests.
- The author uses it daily for a week with a cloud model.
