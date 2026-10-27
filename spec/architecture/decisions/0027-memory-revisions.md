# ADR-0027: Keep each memory's earlier versions for 90 days, so every change can show what it replaced

**Status:** Proposed · 2026-10-27 · **Would amend** [FR-V-12](../../product/03-requirements.md) (provenance), [FR-L-02](../../product/03-requirements.md) (Activity's detail pane), [security and privacy §1 and T14](../security-and-privacy.md), [storage](../storage.md) (`v7_memory_revisions`, §5's jobs, purging), the [domain model](../../domain/domain-model.md) (MemoryRevision), [UX: Mac ▸ Vault](../../product/04-ux-mac.md#vault)

**Context.**
- **Most changes can't say what they replaced.** In v0.5, Activity's detail pane and a memory's History show before → after only for automatic changes (auto-apply, the tidy-up's merges, updates, splits and archives, and their undos). That comes from the undo log, which keeps each memory's state before and after for 30 days ([domain model: UndoEntry](../../domain/domain-model.md)). Everything else records only which fields changed ([provenance](../../domain/domain-model.md#provenance-entry): `fields_changed`, names only):
  - your edits in the Mac's editor;
  - edits from the iPhone (`memory.update`);
  - corrections, merges and archives you apply from the Inbox (the card compares against the memory as it is then, and nothing keeps the old text after Apply);
  - an agent's direct write when Funes splits it and archives the original (kept by the undo log only when auto-apply did it).
- **This is deliberate today.** FR-V-12's acceptance reads "Old body text is never stored in provenance", and T14 keeps Activity and provenance to ids and labels. Provenance is the audit trail, and the audit trail must not be another copy of the text.
- **But day-to-day use needs it.** The author's feedback after daily use: History lists that a memory was "Edited text by Claude Code" or "Applied from the Inbox", and there is no way to see what the text said before. The Inbox showed the diff at the moment of deciding; afterwards it's gone. The question "what did this change do to my memory?" is a trust question. Funes answers it for its own automatic changes, but not for agents' writes, the iPhone or the user's own past self.
- **The text already lives in `vault.sqlite`.** Memories, pending suggestions (with proposed text), suggestion groups (source text until decided) and undo entries (old text, 30 days) are all there. They're protected by FileVault ([Q7](../../plans/open-questions.md)) and copied by the daily backup (the last 7 days). A copy of earlier versions in the same file adds no new place the text lives, only more of it, for longer.

**Decision (proposed).**
1. **A `memory_revision` table in `vault.sqlite`**: one row per state a change replaced. Columns: `memory_id` (references `memory`, `ON DELETE CASCADE`), `version` (the version this state was), `title`, `body`, `kind`, `category_keys` (JSON), `sensitivity`, `status`, `expires_at`, `replaced_at`, `replaced_by` (the actor of the change: `user`, `agent:<id>`, `device:<id>`, `import:<id>`, `system`). Primary key `(memory_id, version)`.
2. **Written at the one place versions change.** `MemoryStore.update` and `MemoryStore.setStatus` already bump `memory.version` whenever the title, body, kind, categories, sensitivity, status or expiry changes. In the same transaction, before the bump, they insert the old state. So every path is covered (the Mac editor, the iPhone, the Inbox, agents, imports, auto-apply, undo, restore) and no caller can forget. A change that doesn't bump the version (Still true, sharing) writes none.
3. **Kept 90 days, and at most 50 per memory.** The daily job that cleans the undo log also deletes revisions older than 90 days, and the oldest beyond 50 for any memory. A memory's revisions go when it's purged (cascade), with **Delete Now**, and with Erase All Data.
4. **Never leaves the Mac's vault.** Not in Activity, provenance or logs. Not in exports, not sent to the iPhone (until a later decision), never read by the policy engine, retrieval, embeddings or memory processing. No MCP tool or companion method returns it. Agents see only the current memory, as today.
5. **You can make Funes forget.** A memory's History gets **Forget Earlier Versions…** ("The earlier text of this memory will be deleted. Its history keeps the labels."). Settings ▸ Advanced gets **Keep earlier versions for 90 days** (on by default). Turning it off deletes every revision after a confirmation, and nothing more is kept.
6. **What it shows.** Each History row for a change opens to before → after: the old text struck through above the new, and the other fields as "Low → Internal". Activity's detail pane does the same for `memory_edited`, `suggestion_applied`, `memory_archived` and `memory_restored`. The row is matched by memory and time, like Phase 1's automatic changes. Rows older than the revisions say "Earlier text is kept for 90 days." Restoring an earlier version is a separate, later decision.
7. **The undo log stays as it is.** Undo needs its own snapshot (trust, and the exact version each memory must still be at). Revisions don't replace it, and it keeps its 30 days.

**Consequences.**
- **FR-V-12's acceptance is reworded, not dropped:** "Provenance rows hold ids and labels only. A memory's earlier versions are kept apart from provenance, in `memory_revision`, for 90 days." T14 gets the same split: "Activity and provenance hold ids and labels only; earlier versions of a memory live in `vault.sqlite` with the memory and go with it."
- **Text you remove lingers.** If you edit a secret out of a memory, the old text stays in `memory_revision` until it ages out, you forget it, or you delete the memory. Today it lingers only in the daily backups, for 7 days, and in an undo entry if auto-apply made the change. This is the real cost, and why point 5 exists. Raising a memory's sensitivity doesn't delete its revisions: they're never shown to agents, so their sensitivity doesn't matter for access.
- **Size is small.** Bodies are at most 10,000 characters and most are under 500. Even 20 changes a day for 90 days at 1 KB each is about 2 MB. The 50-per-memory cap bounds a memory edited in a loop.
- **A new migration, `v7_memory_revisions`.** It creates the table and nothing else: there are no earlier versions to backfill. Undo entries already holding before-states aren't copied in.
- **Tests:** a revision for every path that bumps a version and none for those that don't. Pruning by age and by count, the cascade on purge, Delete Now, Forget Earlier Versions and the setting. Plus a check that no MCP response, export, companion payload or log line contains revision text (extending T14's "no text in logs" fixtures).

**Spec changes if accepted** (not made yet; drafted here so they can be reviewed with this decision):
- **[03-requirements](../../product/03-requirements.md):**
  - **FR-V-12:** add "Each change's row opens to what it replaced (v0.6): the earlier version, for 90 days." Reword the acceptance as above.
  - **New FR-V-16 Earlier versions** · S: "A memory keeps the versions its changes replaced for 90 days (at most 50), for History and Activity. Forget Earlier Versions per memory; a setting turns it off and deletes them. Never shared, exported or sent to the iPhone."
  - **FR-L-02:** extend the v0.5 bullet so edits show before → after from earlier versions.
- **[security and privacy](../security-and-privacy.md):**
  - §1: a new asset row, "Earlier versions of memories | Old text, kept 90 days. As sensitive as memory text, and easy to forget about".
  - T14 as above.
  - A new threat: "removed text survives an edit". Mitigations: 90 days, Forget Earlier Versions, the setting, and purge with the memory.
- **[storage](../storage.md):**
  - the DDL for `memory_revision` with its index on `(memory_id, replaced_at DESC)`;
  - `v7_memory_revisions` under migrations;
  - the Undo log cleanup job in §5 becomes "Undo log and revisions cleanup": revisions past 90 days or beyond 50 per memory;
  - purging removes a memory's revisions (cascade), as for its undo entries.
- **[domain model](../../domain/domain-model.md):** a **MemoryRevision** entity next to UndoEntry: `memoryId`, `version`, the replaced state, `replacedAt`, `replacedBy`. Never exported.
- **[UX: Mac ▸ Vault](../../product/04-ux-mac.md#vault):** the History disclosure for every change, **Forget Earlier Versions…**, and the Settings switch.
- **[Import and export](../../domain/domain-model.md):** say explicitly that `funesvault.export.v1` doesn't carry revisions.

**Alternatives considered.**
- **Keep v0.5's scope (automatic changes only, 30 days):** no new copy of old text. But the changes the user is least sure about (an agent's write, an Inbox merge applied in a hurry, an edit from the iPhone) stay unexplained. This is the fallback if the cost above isn't worth it.
- **Revisions only for changes you didn't make in the Mac's editor** (agents, iPhone, Inbox, imports, Funes itself): covers the trust question with fewer copies. But "what did I change last week?" is a real question too, and the rule ("which of my edits are kept?") is harder to explain than "every change, 90 days". It's easy to narrow to this later.
- **Store diffs instead of whole states:** smaller, but the text is already small. Diffs need the next state to read and break when a revision is pruned out of the middle. Rejected.
- **Old text in provenance:** one table instead of two, but it would make the audit trail a copy of the text, which T14 exists to prevent, and provenance is kept for the memory's whole life. Rejected.
- **Keep revisions for the memory's whole life:** simplest to explain, but old text would never age out on its own. Rejected in favour of 90 days, which is three times the undo log's window and long enough to notice a change you didn't expect.
