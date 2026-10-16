# Phase 1: FunesCore

**Goal:** the complete vault logic as a UI-free Swift package, proven by tests. Nothing here depends on AppKit, MCP or networking.

**Duration:** 2 weekends (about 16–20 h). **Depends on:** Phase 0 spike 2 (search choices) and [project setup](project-setup.md).

## Deliverables
- `Packages/FunesCore` and `Packages/FunesProtocol` (shared types plus `SecretScanner`).
- Swift Testing suites covering every [access policy test vector](../domain/access-policy.md#9-test-vectors).

## Tasks
### 1.1 Models and enums (FunesProtocol + FunesCore) · 2 h
- [ ] Enums: `MemoryKind`, `Sensitivity` (ordered, `Comparable`), `Operation`, `Retention`, `DisclosureStatus`, `SuggestionStatus`, `ReasonCode`, `MemorySource`, `SuggestionOrigin`.
- [ ] Value types: `Memory`, `Category`, `Suggestion`, `Agent`, `Access`, `Disclosure`, `DisclosureItem`, `Device`, `ProvenanceEntry`.
- [ ] `InputLimits` constants (title 180, body 10,000, task 1,000, purpose 160, evidence 2,000, categories 12/24, processors 12×120, tokens 100–8,000, default 1,200).

### 1.2 Store (GRDB) · 4 h
- [ ] `VaultStore` with a `DatabasePool`, the migrator and `v1_initial` (the [schema](../architecture/storage.md#2-schema-v1)).
- [ ] FTS5 external-content table and triggers. Seed the built-in categories.
- [ ] CRUD APIs that enforce invariants: at least one category, version bump, provenance append.
- [ ] Soft delete, restore and purge. Online backup.
- [ ] Tests: migration from empty; invariants; FTS stays in sync on insert, update and delete.

### 1.3 SecretScanner (FunesProtocol) · 1 h
- [ ] The [patterns](../domain/memory-processing.md#1-secret-scanner), including the Luhn check.
- [ ] Tests: positive and negative samples per pattern, plus 20 realistic non-secret memories that must pass.

### 1.4 Search and embeddings · 3 h
- [ ] `Embedder` protocol. `NLEmbedder` implementation (the Spike 2 winner) and a deterministic `FakeEmbedder` for tests.
- [ ] `EmbeddingIndex`: load vectors, brute-force dot product (Accelerate), update on change.
- [ ] `SearchService.vaultSearch(query, filters)` and `retrieve(task, categories)` using the weights and thresholds from Spike 2.
- [ ] Tests: the memories-200 and queries-30 benchmark as a regression (recall@5 must stay ≥ the baseline).

### 1.5 PolicyEngine · 3 h
- [ ] Pure functions:
  - `gate(agent, access, globalPaused, now) -> ReasonCode?`;
  - `eligibility(memory, access, now) -> ReasonCode?`;
  - `decide(eligible, access, window) -> Decision`;
  - `scopeCheck(proposed, access)` for suggestions.
- [ ] Tests: T1–T12 and T27–T33 as parameterized tests.

### 1.6 BundleCompiler · 1 h
- [ ] `title: body`, `ceil(chars/4)`, skip-overflow, clip the first item, instructions v1.
- [ ] Tests: T21 plus edge cases (budget exactly met; an empty body is impossible; Unicode character counting).

### 1.7 DisclosureService · 3 h
- [ ] `request(agentId, input) -> RequestOutcome` (persists the snapshot; keeps task text in an in-memory cache with a 15-minute TTL).
- [ ] `approve(requestId, revision, ids)`, `deny(requestId)`, `deliver(requestId, agentId) -> Bundle | Status`, `expirePending(now)`.
- [ ] One write transaction per approve and per deliver.
- [ ] Tests: T13–T20 and T22, plus concurrency (two deliveries racing: exactly one wins; approve racing deliver).

### 1.8 SuggestionService and CaptureService · 2 h
- [ ] `suggest(agentId, input) -> SuggestOutcome` (validation, scan, gate, scope, write or suggest).
- [ ] `apply(suggestionId, edits)`, `reject`, `expire`.
- [ ] `capture(text, origin, captureId?, deviceId?)` with idempotency via `capture_receipt`.
- [ ] Tests: T23–T29, T34 and T35 (the service level of device handling), plus duplicate `captureId`.

### 1.9 Agents and access · 1 h
- [ ] `AgentService`:
  - create (key generation via BridgeKitCore, digest stored; BridgeKitCore only exists from Phase 2, so until then generate keys behind a small `AgentKeyIssuer` protocol in FunesCore and swap in BridgeKitCore's implementation when it lands);
  - update access (revision +1);
  - pause, resume, remove, rotate key;
  - `authenticate(keyDigest)`.
- [ ] Tests: the revision bumps on every change; a removed agent can't authenticate.

### 1.9b Model providers · 4 h
- [ ] `EmbeddingProvider` and `GenerationProvider` protocols, plus `ModelRouter` (task → provider, timeouts, fallbacks, usage counters) ([model providers](../architecture/model-providers.md)).
- [ ] `AppleNLEmbedder` and `AppleFoundationGenerator` (default), and `RulesClassifier`.
- [ ] `OpenAICompatibleClient` (embeddings; chat with JSON-schema output; model list) and `AnthropicClient` (Messages API; structured output).
- [ ] Guardrails: the secret scanner on outgoing text; the cloud sensitivity limit; the capture pre-screen; locality detection (loopback or private address = local).
- [ ] `ProviderKeyStore` (Keychain, this device only).
- [ ] Re-embedding job (new `model_id`, batches, resume, atomic switch), and per-model thresholds with top-K for unknown models.
- [ ] Tests: `URLProtocol` contract fixtures per adapter; guardrail tests capturing outgoing bodies; fallbacks (timeout, 401, 429, 500, bad JSON); a re-embedding switch and cancel.

### 1.10 Import and export · 2 h (S priority; can slip to Phase 3)
- [ ] Parsers: ChatGPT JSON (tolerant), Claude paste, Markdown, `funesvault.export.v1`.
- [ ] Preview model (counts, duplicates, blocked items) and commit as suggestions.
- [ ] Export, writing `funesvault.export.v1`.
- [ ] Tests: fixtures for each parser; export → import round trip; no keys in the export.

## Exit criteria
- `swift test` passes on both packages; every policy test vector is implemented and green.
- Spike 2 benchmark recall@5 is at or above the recorded baseline.
- No `import AppKit` or `import SwiftUI` in FunesCore or FunesProtocol.
