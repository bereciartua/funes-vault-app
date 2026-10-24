# Phase 6b: Daily tidy-up

**Goal:** once a day (or on demand), compare changed memories with related ones and propose, or with the user's permission apply, updates, merges, splits and archives, and ask about conflicts ([ADR-0021](../architecture/decisions/0021-daily-tidy-up.md), FR-AI-03, FR-AI-14).

**Duration:** 3–4 weekends. **Depends on:** Phase 6a (the finder, the extractor for splits, group cards, auto-apply plumbing). Specs: [memory processing §9](../domain/memory-processing.md#9-daily-tidy-up), [UX: Mac](../product/04-ux-mac.md#inbox), [storage §5](../architecture/storage.md#5-maintenance-jobs).

## Tasks
### 6b.1 Scheduling and runs · 3 h
- [x] Daily at the user's time via `NSBackgroundActivityScheduler`, a catch-up run at launch or wake after a missed one, **Tidy up now**; off by default.
- [x] `tidy_up_run` records; at most 40 clusters per run, newest changes first, `partial` with roll-over; a 20 s timeout per call; stops at the daily cap and resumes the next day.
- [x] First-run estimate in Settings.

### 6b.2 Candidates and clusters · 3 h
- [x] Changed memories by watermark; neighbours by the shared finder (up to 8); clusters of at most 6, with shared memories read-only after the first cluster.
- [x] Code-only actions: exact duplicates, expiry.
- [x] Eligibility: no pending tidy-up suggestion, not in a pending Share panel, within the cloud limit for a cloud provider; ineligible and neighbourless memories marked inspected.
- [x] Non-atomic memories routed to 6a's extractor as `split` proposals.

### 6b.3 The model call and validation · 4 h
- [x] The request and schema of [§9.3](../domain/memory-processing.md#93-the-model-call), through `ModelRouter` with typed items.
- [x] Validation of [§9.4](../domain/memory-processing.md#94-validation-code): ids, one action per memory, full text only, the access-safe rules (sensitivity floor, merges only with the same sensitivity and categories, updates keep categories), secret scan, version pinning (Spike E: `confidence` is recorded, not used as a threshold).

### 6b.4 Applying and auto-apply · 4 h
- [x] Suggestions with `suggestion_target` rows; the watermark set to the result's version in the same transaction as an applied change.
- [x] Auto-apply per level, never on the strength of untrusted text (except archiving the untrusted copy of an exact duplicate), chosen engine only, the policy-engine access check, conflicts always to the user; undo entries.
- [x] Dismissals keyed on ids plus a content hash; "Both are true" remembered.

### 6b.5 Inbox, notifications, Settings · 4 h
- [x] Tidy-up section: update, merge, split, archive and conflict cards; header with the last run and Tidy up now.
- [x] Applied automatically rows for tidy-up changes; undo of merges and splits restores the originals.
- [x] The notification after a run (no memory text); Settings ▸ AI Models ▸ Daily tidy-up.
- [ ] String catalog and accessibility labels done; the UI-review build has an `inbox-tidy-up` scene, but its snapshots weren't captured (window capture was refused in the implementing session): run `sh scripts/ui_snapshots.sh`.

### 6b.6 Tests and docs · 3 h
- [x] Spike E's tidy-up fixtures as tests: no action for complementary facts, `conflict` never archived, merges that lose a constraint refused, mixed-sensitivity and mixed-category merges refused, injection in an agent-written memory never auto-applied.
- [x] Loops: a second run after applying finds nothing new; dismissals aren't re-asked; partial runs resume.
- [x] When the code lands: PRIVACY.md, README, docs, CHANGELOG.

## Exit criteria
- On the author's vault, a week of daily runs with a cloud model: proposals reviewed, no oscillation, no access widened.
- Auto-apply levels enabled only where the fixtures reach the target precision (Spike E, both fixture sets pooled: Duplicates only with GPT-5.6-Terra, Claude Haiku 5.5 or Opus 5.5; Everything except conflicts with Haiku or Opus; otherwise updates, merges and splits stay in the Inbox). An update and an archive with that update's target as survivor are applied together or not at all.
