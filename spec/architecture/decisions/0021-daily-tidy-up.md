# ADR-0021: A daily tidy-up updates, merges, splits and archives, with optional auto-apply

**Status:** Accepted · 2026-10-23 · **Supersedes** the consolidation design of FR-AI-03 and [memory processing §9](../../domain/memory-processing.md#9-daily-tidy-up) (v0.3, weekly, archive-only pairs) · **Amends** [ADR-0014](0014-user-selectable-models.md) (the Consolidation task)

**Context.**
- **Memories drift.** Duplicates arrive through paths that skip the Inbox (agents with Write, bulk-applied imports), facts change ("runs 3×/week" becomes "5×/week"), and atomic memories ([ADR-0020](0020-atomic-extraction-for-every-source.md)) make related groups common.
- **Funes Vault (web)** ran a nightly job, off by default: changed memories were paired with lexical and semantic neighbours, and a model chose which of a pair to **archive**. Archive was the only action, so it couldn't express "these three memories should be one", or "keep this memory but change the number". Its thresholds were never measured.
- **The review** (2026-10-23) found that auto-applying the tidy-up's output could let an agent-written memory archive or rewrite the user's own ("the user is no longer allergic to peanuts"), and that merging by the union of categories widens agent access, because a memory is eligible when any of its categories is allowed (access policy M5).
- **Cost:** with a cloud model, running on every change is expensive.

**Decision.**
1. **Daily, the user's choice.** Settings ▸ AI Models ▸ Daily tidy-up: Daily (at a time, default 03:00) · Off, plus **Tidy up now**. Off by default. It runs with `NSBackgroundActivityScheduler` from the daily maintenance, and after a missed run, on the next launch or wake.
2. **What it looks at:** memories whose `version` is above their `reconciled_version` watermark, each with its local neighbours (FTS5 + bge-small, always on the Mac), grouped into clusters of at most 6. Code alone handles exact duplicates and expiry. The first run on an existing vault works through it over several days.
3. **Actions:** `update` (one memory's text), `merge` (several into one new memory), `split` (a non-atomic memory into pieces, through ADR-0020's extractor), `archive` (duplicate or superseded, naming the survivor), and `conflict` (a question for the user, never resolved by the model). Complementary facts and uncertainty yield no action.
4. **Access-safe results, checked in code:**
   - a result's sensitivity is at least the highest of every memory whose text was in the call;
   - merges only between memories with the same sensitivity and the same categories; an update keeps its target's categories; split pieces never go below the original's sensitivity;
   - no change to a memory whose full text wasn't in the prompt;
   - memories in a pending Share panel are skipped.
5. **Auto-apply** is the same setting as ADR-0020's (Off · Duplicates only · Everything except conflicts), with the same rules: **never on the strength of untrusted text** (agent direct writes, auto-applied import pieces), except archiving the untrusted copy of an exact duplicate; only output from the chosen engine; never a result an agent could read when it couldn't read every source; conflicts always go to the user. Each level needs a target precision on fixtures before it can be enabled.
6. **Undo for 30 days** in the Inbox's **Applied automatically** list, including chains ("undo this and N later changes"). The undo log is purged with its memories.
7. **Suggestions are pinned to versions;** a change before review marks them stale. The tidy-up sets the watermark to its own result's version, so it doesn't re-inspect what it just did. Dismissals are keyed on memory ids and a content hash.
8. **Cost:** at most 40 clusters a run, within the shared daily cap ([ADR-0022](0022-cloud-limit-and-daily-cap.md)). At the cap the tidy-up waits for the next day; it never switches to a weaker model.

**Consequences.**
- **Moves from v0.3 to Phase 6** ([6b](../../plans/phase-6b-daily-tidy-up.md)), after the foundations and New memories.
- **New data:** `memory.reconciled_version`, `merge` and `split` suggestions referencing several memories, a tidy-up `MemorySource`, provenance links (merged from/into, split from/into), the undo log, run records and dismissals.
- **The Inbox** gets a Tidy-up section and an Applied automatically list; the iPhone shows these cards as "Review on your Mac" until it gets its own.
- **The model's role grows** from proposing fields to proposing changes. Every change is validated in code, traceable in provenance and reversible.
- **A cloud provider receives existing memories,** within the cloud limit. Memories above it are tidied only by a local provider or the code-only rules.

**Alternatives considered.**
- **Port the web job (pairs, archive only):** can't merge or update.
- **Run on every change:** expensive with cloud models, and noisy.
- **Review-only, no auto-apply:** safest, but the user wants the option; the trust and access rules make it safe enough.
- **Merge by the union of categories:** widens agent access.
