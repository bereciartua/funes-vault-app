# Phase 12: Every Inbox card on the iPhone

**Goal:** the iPhone answers every card the Mac's Inbox does, the overnight tidy-up's included, after showing what each one changes.

**Duration:** about 1 weekend. **Depends on:** nothing unfinished. **Decision:** [ADR-0031](../architecture/decisions/0031-iphone-answers-every-inbox-card.md). **Specs:** [companion protocol §4.2](../architecture/companion-protocol.md#42-every-inbox-card-on-the-iphone-v09), [UX: iPhone ▸ Inbox tab](../product/05-ux-iphone.md#inbox-tab), FR-iOS-09.

**Order:** 12.1 → 12.2 → 12.3 → 12.4 → 12.5, in one PR (`feat/iphone-inbox-parity`), the spec first.

## 12.1 Spec · ⅛ weekend
- [x] ADR-0031, companion protocol §4.2, the iPhone UX's Inbox tab, FR-iOS-09, the notes in ADR-0020 and ADR-0021. Reviewed by GPT-6-Astra.
  - *Turned out:* the review moved swipe-to-apply to new memories and duplicates only, bound the card's apply to a `revision` (`request_changed`), had `conflict` re-read the Inbox and a split refresh it, logged Review Again, added the outside-scope badge, left a split input's group actions on the Mac, and found the purged-target staleness bug (12.2).

## 12.2 Protocol and the Mac · ¼ weekend
- [x] **FunesCore:** a suggestion with a stored target version but no target (purged) is stale, and Review Again refuses it with `targetChanged`; tests.
- [x] **FunesProtocol:** `inbox.get` (`InboxGet`, `InboxDetail` with `revision`, `InboxMemory` with `InboxMemoryRole`, `InboxTidyUp` with `InboxArchiveReason`, `InboxSimilar`), `inbox.reviewAgain` (`InboxReviewAgain`), and `InboxApplyParams.mode` (`InboxApplyMode`) with `keepMemoryId` and `revision`. `SuggestionAction.appliesOnPhone` is every action but `unknown`; `needsAnswer` is a conflict.
- [x] **FunesCompanion:** `inbox.list` sends the tidy-up's real actions. `inbox.get` builds the detail from `SuggestionService` (`targets`, `pieces`, `isStale`), the store and `TidyUpRecord`, and the similar memories as the Mac's card finds them (exact copies, then `nearDuplicates`, without the target, at most 2); logs `inbox_viewed`. `inbox.apply` checks the revision (`request_changed`) and maps the mode to `ApplyMode`, refusing `keep_both` on a tidy-up proposal and a conflict without a mode. `inbox.reviewAgain` calls `reviewAgain` and logs `suggestion_reviewed_again`.
- [x] **Tests** (`CompanionServerTests`): the tidy-up's archive, update with a copy, merge, split and conflict listed with their actions and applied from the phone; `inbox.get`'s memories and roles, pieces, reason, kept text, staleness and similar; Keep Both refused for a tidy-up update; a conflict's Keep This with edits and Both Are True; Review Again, then apply; a revision from before a Mac edit and Review Again refused; `inbox_viewed` and `suggestion_reviewed_again` without text.

## 12.3 FunesPhone · ¼ weekend
- [x] **`InboxModel`:** `detail(_:)` (`inbox.get`), `save(_:mode:keep:edits:revision:)`, `reviewAgain(_:)`; `target_changed` and `request_changed` leave the row in place and the screen reloads the card; `conflict` reads the list again instead of counting it answered elsewhere; a split reads the list again. Swiping saves only a create or a duplicate.
- [x] **Demo vault:** tidy-up cards, an archive of a copy (with the memory it keeps), a merge, a conflict and a split, on the demo's memories, answered as a Mac would.
- [x] **Tests** (`VaultModelTests` against `FakeVault`): the detail, each mode and the revision sent, Review Again, a stale apply, `conflict` re-reading the list, a split refreshing it, swipes only on creates and duplicates; the demo answering each card.

## 12.4 The iPhone's screens · ⅓ weekend
- [x] **`InboxView`:** the row's action line and outside-scope badge; Save and Already Saved swipes only.
- [x] **The card's screen** per action, as the UX says: memories quoted with their roles, old → new for an update, the pieces of a split, the sources of a merge with what each keeps, the conflict's Keep This and Both Are True, Edit & Replace / Edit & Merge / Edit… through `MemoryEditSheet`, the stale banner and Review Again, the tidy-up's reason, similar memories, a memory's title opening it.
- [x] Strings in the app's catalog.

## 12.5 Ship · ⅛ weekend
- [x] `sh scripts/test.sh` green; the iPhone app builds; each card checked in the demo on a simulator.
  - *Turned out:* checked in dark mode only (iPhone 18 Pro, iOS 27): the archive (applied), merge, conflict (with its Edit… sheet), split and an agent's correction. A GPT-6-Astra review of the diff had every screen apply wait for `inbox.get`, `conflict` ask `inbox.get` rather than re-read the first page, Review Again keep its row through a refresh, and the demo's cards go stale like the Mac's. Not done: checking the revision inside FunesCore's apply transaction (the check runs just before it; same-user race, and FunesCore's version checks still apply).
- [x] CHANGELOG. The App Store review notes still hold: swiping saves a new suggestion, and tapping one opens it.
