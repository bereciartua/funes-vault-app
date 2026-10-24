# Phase 6.1: Foundations for memory processing

**Goal:** build what New memories (6a) and the daily tidy-up (6b) assume already exists. A review of the plan (2026-10-23) found that it doesn't: today only `update` + Replace applies as itself, model work is a fire-and-forget task, and the cloud guard checks one sensitivity per request. Several items fix real bugs and ship on their own.

**Duration:** 2–3 weekends. **Depends on:** Phase 5. Can run in parallel with Spike E. Specs: [ADR-0020](../architecture/decisions/0020-atomic-extraction-for-every-source.md), [ADR-0021](../architecture/decisions/0021-daily-tidy-up.md), [ADR-0022](../architecture/decisions/0022-cloud-limit-and-daily-cap.md), [domain model](../domain/domain-model.md), [storage §3](../architecture/storage.md#3-migrations).

**There are no external users yet:** settings, schema and the companion protocol change without compatibility shims. The author's vault is still migrated with a backup first.

## Tasks
### 6.1.1 Per-action apply · 4 h
*Today `SuggestionService.apply` only treats `update` + Replace as itself; every other action inserts a new memory, so an `archive` suggestion creates a memory instead of archiving one. The Mac shows Replace / Keep both for any targeted suggestion; the iPhone and bulk apply always use Keep both.*
- [x] FunesCore: apply per action: `create`, `update` (Replace or Keep both), `archive`, and the new `duplicate` (no-op), `split`, `merge`, `conflict` (answer: keep A, keep B, both true, edit). One transaction each, with provenance.
- [x] The Mac's card offers Replace / Keep both for `update` only; bulk apply uses each row's own action; clients refuse actions they don't support.
- [x] Tests for every action, from the Mac, bulk and the companion handler.

### 6.1.2 Version-checked targets · 2 h
- [x] `suggestion.target_memory_version`, set whenever a suggestion targets a memory (agent corrections included); apply checks it in the transaction and refuses a stale or archived target (the card says "Changed since this was suggested").
- [x] The Mac's memory editor passes an expected version, like the phone, so it can't silently overwrite a change made meanwhile.

### 6.1.3 Schema `v4_memory_processing` · 3 h
- [x] The migration of [storage §3](../architecture/storage.md#3-migrations): `memory.trust` (`agent_write` memories start `untrusted`), `memory.reconciled_version`, the suggestion fields and `split` status, `suggestion_target`, `suggestion_group`, `processing_job`, `undo_entry`, `tidy_up_run`, `tidy_up_dismissal`, provenance `related_memory_id` and `engine`. Migration test from a v0.2 fixture. *(Landed with 6.1.1–6.1.2, which need its columns.)*
- [x] `MemorySource.tidy_up`; `originActor` stops mapping `.consolidation` to seed question.
- [x] Trust rules in `MemoryStore`: user create, edit or apply → trusted; agent direct write → untrusted.

### 6.1.4 Durable processing queue · 4 h
- [x] `ProcessingQueue` in FunesCore over `processing_job`: enqueue in the same transaction as the input, one job at a time, resumed at launch, idempotent per subject, retries with backoff, Activity rows without text.
- [x] Every ingest path enqueues: the Mac capture box (replacing today's fire-and-forget `Task` in `CaptureController`), Services, iPhone captures (which get no model processing today), MCP suggestions and writes, imports. *(Also seed answers. Not corrections, tidy-up proposals, split pieces or a Funes export restore, which §5.2 doesn't split.)*
- [x] In this step the job only runs today's classification, so behaviour is unchanged; 6a adds splitting. *(`NewMemoryProcessor`: captures only; the Mac's `ProcessingRunner` drives it.)*

### 6.1.5 Multi-item cloud guard, pre-screen and daily cap · 4 h
- [ ] `ModelRouter.send` takes typed items (text plus sensitivity or unknown) and guards on the highest; the secret scanner covers every item.
- [ ] On-device pre-screen for agent and import text; the guard uses the higher of the pre-screen and the declared level.
- [ ] The cloud limit's new levels (Restricted, Everything) with a one-time confirmation above Internal ([ADR-0022](../architecture/decisions/0022-cloud-limit-and-daily-cap.md)).
- [ ] The daily cap: a per-local-day counter kept across restarts, the agents' 40% share, `ProviderError.capReached`, a once-a-day notice. Embeddings excluded.
- [ ] Guardrail tests ([model providers §9](../architecture/model-providers.md#9-testing)).

### 6.1.6 Undo log · 3 h
- [ ] `UndoLog` over `undo_entry`: record the before-state of an automatic change in its transaction; undo one change, or a change and the later ones that depend on it; refuse with an explanation otherwise.
- [ ] Purge with the memory (daily purge, Delete Now, Erase All Data); daily cleanup after 30 days; never exported.

### 6.1.7 iPhone and companion · 2 h
- [x] FunesProtocol: `SuggestionAction` gains the new cases and an `unknown` fallback when decoding; `InboxItem` gains `groupId`, `groupLabel`, `outsideScope`, `targetMemoryVersion`.
- [x] The phone shows unknown actions, and merge, split and conflict, as "Review on your Mac"; `inbox.apply` refuses them with `unsupported_action` and applies the rest per action (6.1.1). A stale target is `target_changed`.
- [x] Shipped together with the Mac change.

### 6.1.8 Export, restore, Activity, settings · 3 h
- [ ] Export and restore keep a memory's status (archived stays archived) and its split and merge links; restore sets `reconciled_version` so the tidy-up doesn't re-split restored memories.
- [ ] Activity events with `actor = system`: `auto_applied`, `undone`, `split`, `tidy_up_run`, `cap_reached` (ids and counts only).
- [ ] Settings ▸ AI Models: rename Classification to New memories (split switch disabled until 6a), the cloud limit's new wording, the daily cap row, Apply changes automatically (levels disabled until 6a/6b reach their precision). The Settings ▸ Capture classification switch moves here.

## Exit criteria
- Every suggestion action applies as itself on the Mac, in bulk and from the iPhone; stale targets are refused.
- Quitting during processing loses nothing; iPhone captures are classified like Mac captures.
- Guardrail tests show multi-item calls and pre-screened agent text guarded, and the cap holding across a restart.
- The author's vault migrated with its backup; `sh scripts/test.sh` green.
