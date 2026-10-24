# Phase 6a: New memories (split, classify, link)

**Goal:** every new input (captures, seed answers, agent suggestions and direct writes, ChatGPT, Claude and Markdown imports) is split into atomic pieces, each classified and linked to related memories, with optional auto-apply ([ADR-0020](../architecture/decisions/0020-atomic-extraction-for-every-source.md), FR-AI-13, FR-AI-14).

**Duration:** 4–5 weekends (one more for 6a.0). **Depends on:** Spike E (prompt shape, thresholds, Apple on-device's role) and Phase 6.1. Specs: [memory processing §5](../domain/memory-processing.md#5-new-memories-split-classify-link), [access policy §5.3](../domain/access-policy.md#53-scope-check-for-the-proposed-memory), [UX: Mac](../product/04-ux-mac.md#inbox), [model providers](../architecture/model-providers.md).

## Tasks
### 6a.0 Subscription providers · 6 h
*[ADR-0024](../architecture/decisions/0024-subscription-providers.md), FR-AI-16, [model providers §5.8](../architecture/model-providers.md#5-guardrails-all-non-local-providers). First, so 6a's week of daily use can run on the author's Claude or ChatGPT plan. Spike E's harness (`spikes/memory-processing/`) already calls both CLIs and is the reference.*
- [x] `CLIRunner` in FunesCore: find the executable (`ExecutableLocator`), read its version, check sign-in, and run a call as a child process in a new empty temporary directory, with API keys removed from the environment, the prompt on stdin, a 90 s timeout and a kill on cancel. No credentials read or stored.
- [x] `ClaudeCodeClient`: the isolation flags of §5.8 (`--safe-mode --tools "" --disallowedTools "mcp__*" --strict-mcp-config`, hooks off, `--no-session-persistence`, never `--bare`), `--json-schema`, `stream-json` parsing; refuse a run whose `system/init` lists MCP servers, plugins, hooks or tools other than the structured-output one; read `structured_output`; map signed out, plan limit and schema failure to `ProviderError`s.
- [x] `CodexClient`: `--ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check --sandbox read-only -C <dir> --output-schema --json`, `--disable` for every tool feature; the known-safe feature list checked against `codex features list` (unknown enabled feature → unavailable); strip `minItems`/`maxItems`.
- [x] Both: any tool or command event stops the run, discards the output, logs `provider_tool_blocked`, marks the provider unavailable; usage and the daily cap counted; minimum-version check.
- [x] After the first live run (2026-10-24, the author's decision): Claude Code's known built-in plugins and agent types accepted; Codex an opt-in, off by default, with the warning that it can read files, accepting only `unified_exec`; ADR-0024, model providers §4 and §5.8, FR-AI-16 and T34 amended.
- [x] Settings ▸ AI Models ▸ **Use your subscription**: detection, version and sign-in state, the sign-in command to run in Terminal, Test connection (a made-up note), the model field with suggestions, the subscription disclosure line.
- [x] Tests: recorded streams (success, schema failure, signed out, plan limit, an injected tool call), arguments and environment, the feature-list check; a live smoke test on the author's subscriptions that checks the start events show no tools, MCP servers, plugins or hooks. Live run 2026-10-24 (the author's approval, two calls with a made-up note): Claude Code 2.1.310 with haiku: start event with only `StructuredOutput`, no MCP servers or hooks, the two known built-in plugins, `apiKeySource` "none"; answer in `structured_output`. Codex 0.164.0 with gpt-6-luna and the opt-in on: no command events (one notice that code mode is off), answer as the agent message.

### 6a.1 Extraction · 4 h
- [x] Chunking (about 2,000 characters on paragraph or sentence boundaries, previous chunk as context), per-provider token budgets, up to 30 pieces per chunk and 40 per input. Apple on-device classifies only, no split ([Spike E](spike-results.md#spike-e-extraction-linking-and-tidy-up-quality)).
- [x] The extraction request and schema ([§5.3](../domain/memory-processing.md#53-extraction)), with the first-person and about-the-user variants, through `ModelRouter` with typed items; start from Spike E's [`prompts.py`](../../spikes/memory-processing/prompts.py).
- [x] Validation ([§5.4](../domain/memory-processing.md#54-validation-code)): evidence quotes (delimiter tags stripped, empty quotes ignored), the support check (a flag keeps the piece out of auto-apply), secret scan, the sensitivity floor (model, category default, hint, pre-screen, agent's declared level, original memory), length, categories, dedupe within the input; the original stays if everything fails.

### 6a.2 Linking · 4 h
- [x] The related-memories finder (bge-small and FTS5, related at cosine ≥ 0.70 or a keyword hit, top 5), excluding the original and sibling pieces; shared with 6b.
- [x] One decision call per input with dates; `create` / `update` / `duplicate` / `retract`; targets validated and version-pinned.
- [x] Agent input: Inbox proposals link against all memories; anything auto-applied for an agent only against memories it can read.

### 6a.3 Replacing suggestions with groups · 3 h
- [x] The job replaces a suggestion with its group in one transaction, only if it's pending, unedited and has no Save panel or iPhone approval open; otherwise it attaches a "Split into N?" offer. The original row becomes `split` and its id the group id.
- [x] Capture receipts and idempotency unchanged (a resent iPhone capture is still a duplicate).
- [x] Group expiry as one (FR-I-05); the group's source text dropped once every piece is decided.

### 6a.4 Agent input and the policy · 4 h
- [x] Pieces outside the agent's scope: flagged, never auto-applied, left out of Apply all ([access policy §5.3](../domain/access-policy.md#53-scope-check-for-the-proposed-memory)).
- [x] Direct writes: save, then split. Raise the original's sensitivity at once when extraction finds it higher. At Everything except conflicts, pieces within the agent's write scope replace the original (create-only, counted toward its write rate limit); otherwise a Split this memory suggestion.
- [x] A correction targeting a split original is redirected to the pieces the agent can read.
- [x] Updates and retractions from agent input are always suggestions; caller metadata never sent.
- [x] Policy tests: no out-of-scope piece saved for an agent; no linking to unreadable memories for auto-applied pieces; split never lowers sensitivity; the MCP result unchanged (`tools.json` goldens).

### 6a.5 Auto-apply for new memories · 3 h
- [x] The levels of [§5.7](../domain/memory-processing.md#57-auto-apply-for-new-memories): trust (changes to existing memories only from typed or dictated text), agents by their own access, chosen engine only, the policy-engine check that no agent gains access, each change in one transaction with its undo entry.
- [x] Auto-apply for new memories ships disabled: no engine reached 95% on Spike E's fixtures (both sets, the user's labels). Build the levels behind the setting so they can be enabled per engine once a re-measurement passes; `confidence` gates nothing, the gate is atomic plus the support check.
- [x] The extraction prompt uses the user's compound-claim rule (Spike E §10, `prompts.EXTRACT_RULES_V2`).

### 6a.6 Inbox and Settings · 4 h
- [x] Group card, row badges, Apply all, Keep as one (only while nothing is decided), the "Split into N?" offer, Split this memory, the flagged rows, the engine line.
- [x] Applied automatically list with Undo (and "undo this and N later changes").
- [x] Settings ▸ AI Models ▸ New memories: the split switch, the disclosure line; import preview with the request estimate, today's remaining cap, and Import without splitting.
- [x] New UI words (split, pieces, Applied automatically, Outside <agent>'s scope; and 6b's Tidy up) added to [Words in the app](../product/06-glossary.md) first; string catalog, UI snapshots (light and dark), accessibility labels.

### 6a.7 Tests and docs · 3 h
- [x] Spike E's fixtures as FunesCore tests against a recorded or fake provider: claim recall, no invented claims, links, injection attempts.
- [x] Concurrency: a split arriving while the card is edited, applied on the iPhone, or in a Save panel.
- [x] When the code lands: PRIVACY.md (what goes to a provider now), README, docs, CHANGELOG.

## Exit criteria
- A ChatGPT-style dump from an agent becomes a group of single-claim pieces, with duplicates and updates of existing memories recognised.
- With splitting off or no model, behaviour is v0.2's.
- No auto-applied change from untrusted text, and no agent gains access, in the policy and fixture tests.
- The author uses it daily for a week with a cloud model, on their subscription through 6a.0.
