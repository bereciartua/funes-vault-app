# Phase 10: Menu bar panel

**Goal:** a click on the menu bar icon answers three questions at a glance: what waits for me, can agents reach my vault, and what happened lately. It also lets you remember or search without opening the window. Every control says what it does.

**Duration:** about 2 weekends. **Depends on:** nothing unfinished (Phase 9's search answers are in). **Decision:** [ADR-0029](../architecture/decisions/0029-menu-bar-panel.md). **Specs:** [UX: Mac ▸ Menu bar](../product/04-ux-mac.md#menu-bar), requirements FR-G-01, FR-A-11, FR-D-05, FR-H-07, [glossary](../product/06-glossary.md#the-app-its-server-and-pause).

**Order:** 10.0 → 10.1 → 10.2 → 10.3, 10.4 and 10.5 (any order) → 10.6. Everything lands in one PR with the spec, as `feature/menu-bar-panel`.

## 10.0 Spike: closing a non-activating panel · ¼ weekend
Throwaway code (a scratch target or a branch of the app that isn't merged) that proves the panel's mechanics before anything else is built. Record what works in this plan.
- [ ] A borderless non-activating `NSPanel` that becomes key for a text field, under the status item, while another app stays active (check with TextEdit frontmost).
- [ ] **It closes on:** a click outside (another app, the desktop, the menu bar); a second click on the status item (no reopen from the same click); Esc; ⌘⇥ to another app; a Space or full-screen change; the screen locking.
- [ ] **It doesn't close** while its own pause menu, ⋯ menu or the Remote Access confirmation is up, or while the dictation permission prompt shows.
- [ ] **The field:** typing, IME input (Japanese, accents) and the system's dictation work; Return reaches the field; VoiceOver lands in it.
- [ ] Note which signals were needed (workspace activation notifications, key-window changes, event monitors) and update the UX spec if a closing rule can't be met.

## 10.1 Last 24 hours read · ¼ weekend
- [ ] **`VaultStore.recentPulse(now:calendar:)`** in FunesCore (`Store/OverviewStore.swift`, beside `overview`): 24 hourly buckets ending with the current hour. Each bucket holds new memories by source (`memory.created_at`, `memory.source`, the iPhone rule of ADR-0025), memories delivered by agent (`disclosure.delivered_at` joined to `disclosure_item`) and requests refused (`disclosure` with status `denied`). Plus the totals and the agents' display names. It reuses `VaultOverview.Bucket` (its `date` is the hour's start) and adds no table. Hours follow the calendar's time zone.
- [ ] **Tests:** buckets and totals on a fixture; an empty vault; a memory at 09:59:59 and one at 10:00:00; a daylight-saving change (23 or 25 clock hours still make 24 buckets of an hour each); no text or title anywhere in the result (encode it and search for the fixture's sentinel strings).
- [ ] **Budget:** under 20 ms on the 10,000-memory benchmark vault, in the existing `FUNES_OVERVIEW_BENCHMARK=1` check. If it misses, say so here before adding an index.
- [ ] **A repeated hour** when clocks go back is two buckets; each bucket carries its start as an instant, so the UI can label it with its zone.

## 10.2 The panel shell · ½ weekend
- [ ] **`MenuBarPanel`** (`Apps/FunesMac/MenuBar/`): a borderless, non-activating `NSPanel` that can become key, hosting SwiftUI, 350 pt wide, positioned under the status item's button (and kept on the screen that has it). It closes on what 10.0 proved: Esc, a click outside, another click on the icon, another app activating, a Space change and the screen locking. Closing clears results and answers, cancels their calls and dictation, and keeps only the draft.
- [ ] **`StatusMenuController`:** a left click toggles the panel; a right click or Control-click pops up the short menu (Open Funes Vault ⌘O, Settings… ⌘,, Check for Updates… while `updater.isAvailable()`, Quit Funes Vault ⌘Q). The old menu's items and `menuNeedsUpdate` go away. The icon's tooltip and accessibility label stay, with the new wording of [UX: Menu bar](../product/04-ux-mac.md#menu-bar).
- [ ] **The icon's "can't connect" state** in `MenuBarIcon` and `AppModel.iconState`: `mcpStatus == .failed` draws the warning badge instead of the slash.
- [ ] **Appearance** follows `NSApp.appearance` (FR-G-06); the material is the menu bar's (`NSVisualEffectView` `.menu` or `.popover`, whichever matches macOS 26's extras best, checked on screen).
- [ ] **Focus and keys:** the frontmost app stays active while the panel is key (a manual check, from 10.0); the field has the initial focus; Tab order and the key table of [UX: Keys in the panel](../product/04-ux-mac.md#keys-in-the-panel); ⌘O, ⌘, and ⌘Q work while it's key. Arrivals never move focus.
- [ ] **Height:** sections keep their size and the area under the field scrolls, as the UX spec says. A UI-review snapshot with the most the panel can hold, at 350 pt, on macOS 15 and 26.
- [ ] **VoiceOver:** the panel announces "Funes Vault" and what waits when it opens.

## 10.3 Waiting for you and the switches · ½ weekend
- [ ] **`WaitingItems`**, a small model (with tests) that merges three sources into cards: `services.approvals.queue.items` in the queue's order; `model.signIns` (one at a time); and `model.pending` with status `needsApproval`, soonest expiry first, leaving out any request already in the queue (matched by request id: `DisclosureService.pendingRequests` also returns the one on screen). At most 3 cards, then "2 more waiting" with **Show All Pending Requests** while some of the rest are Pending requests. It also names the card the Review Request shortcut would review, and Review Request uses the same answer, so the label and the shortcut never disagree. Tests: a live request timing out into Pending (one card throughout), one answered on the iPhone (its card goes), sign-in plus queue ordering, more than 3.
- [ ] **Review routes:**
  - a live queue item: `approvals.queue.select(id)`, then the approvals' review (bring forward, key);
  - a Pending request: `model.openPendingRequest(id)`, which refreshes it;
  - a sign-in: a new route that brings `SignInPanelController`'s panel forward, key.
  A test that the key press choosing Review doesn't answer the panel it opens (each panel's arming delay, and the sign-in's missing Return key). A test that the card view can't reach `answer`, `withdraw` or any sign-in decision.
- [ ] **Agents tile:** every state in the UX table, in its order, from `preferences.mcpEnabled`, `mcpStatus`, `pausedUntil` and `agents.count` ("No agents yet" with **Add Agent…** opening `wantsAddAgent`). Turning it off shows the three lengths (`FunesPause.Duration`) and calls `model.pause(_:)`; turning it on calls `model.resume()`. The paused line with **Resume**. **Fix…** and **Turn On…** open Settings ▸ Connections. A tap on the tile opens Agents.
- [ ] **Remote Access tile:** every state in the UX table, in its order, from `remoteAccess`: "not set up" by the same rule as `RemoteAccessPage.mode`'s introduction (move that rule into the controller so both use it); `enabled`; the listener's real status (not listening while the agent server is off or failed); `tunnelDown`; `offAt` ("On · until 18:00"); `cloudAgents`. The switch shows whenever it's enabled. Turning it on goes through `RemoteAccessController`'s existing confirmation; turning it off calls `remoteAccess.apply(false)` at once; the automatic turn-off updates the tile at once. **Set Up…** and a tap on the tile open Remote Access.
- [ ] **Countdowns** tick each second while the panel is open (a timer only while it shows), with VoiceOver's "41 seconds left" wording as the panels use.

## 10.4 The field · ½ weekend
- [ ] **Remember:** the field shares the capture box's save path (`CaptureSaver` in `CaptureController.swift`), so the scanner, classification, the Cloud chip and Activity aren't copied. Today it clears the box at once and puts the text back on failure, which in a panel that stays open would overwrite the next draft: give it a result the caller handles, so the panel shows "Saving…", then "Saved to Inbox" (2 s), and on failure puts the text back only into an empty field, else "Your last note wasn't saved" with **Restore**. The capture box keeps its behavior. ⏎ saves, ⇧⏎ is a new line, and the field grows to 4 lines, then scrolls.
- [ ] **Dictation** on macOS 26 and later with `Dictation.swift`, stopped (as `stopDictation` does for the box) on save, ⌘⏎, Esc and closing, with late words dropped. Tests or a manual check for the permission prompt, Esc during dictation, and reopening.
- [ ] **Search:** ⌘⏎ runs the Vault's search (Active scope, no filters, `VaultModel`'s search call or what it calls) and shows up to 5 results: title, first category, sensitivity badge, no body. **Show All N in Vault** calls `model.showVault(query:)`, and ⏎ on a row calls `model.showMemory(_:)`; both close the panel. ↑ ↓ move the selection. "Nothing matches." when empty. While results show, ⏎ never saves (a test).
- [ ] **Search answers:** reuse `AnswerCard` from the Vault (`Apps/FunesMac/Vault/AnswerCard.swift`), compact if it needs a width parameter. The Ask row, ⌘⏎ to ask, the automatic triggers (§10.6's pauses), Cancel, Clear, every message of §10.5. A claim's number opens that memory in the Vault with the quote highlighted (the Vault's own path), since the answer reads 10 results and the panel shows 5. Editing the text, Esc back to the chart, and closing all cancel a call and an automatic answer's wait; a late response is dropped (a test, since `VaultModel`'s task outlives its view today). Activity logs `search_answered` as for the Vault (a test).
- [ ] **Esc** steps back: results → chart, then the text is cleared, then the panel closes. **A draft** stays in memory while the app runs (never on disk; a test that the field's text isn't written to user defaults).
- [ ] A test that the panel's view model holds no memory text or title before a search: build it with a fixture vault and inspect its published values.

## 10.5 The chart · ¼–½ weekend
- [ ] **`RecentPulseChart`** with Swift Charts, sharing what it can with Home's `PulseCard` (colors, the two-scale layout, the refused dot): 24 bars, In above the line and Shared below it, the x labels every 6 hours plus "now", and the header's counts with empty parts dropped. "Quiet: nothing in or out", and the new-vault empty state.
- [ ] **Hover** text as in the UX spec, with the zone on a repeated hour. **Click** or ⏎ on a focused hour opens Activity with `ActivityFocus.period(DateInterval)` for that hour (Activity's banner then reads "Showing 09:00–10:00 only"); a refused dot (or VoiceOver's **Show Problems** action) opens Activity ▸ Problems for that hour. Both close the panel. Check that Activity's banner formats an hour, not only a day, week or month.
- [ ] **Accessibility:** a chart descriptor; the summary label; each hour's breakdown; ← → between hours; Reduce Motion; Increase Contrast.
- [ ] Refreshes on open, on vault changes while open, at each hour boundary, after wake (`NSWorkspace.didWakeNotification`) and on time-zone changes (`NSSystemTimeZoneDidChange`), off the main thread.

## 10.6 Ship · ¼ weekend
- [ ] **Strings:** `sh scripts/sync_strings.sh`; remove the old menu's strings that nothing uses now.
- [ ] **UI snapshots** (light and dark) in the UI-review build: `menubar-panel`, `menubar-panel-waiting` (2 cards, one live), `menubar-panel-paused`, `menubar-panel-search` (results and an answer), `menubar-panel-cant-connect` (port in use), `menubar-panel-remote-down`, `menubar-panel-remote-until` (automatic turn-off), `menubar-panel-empty` (new vault, no agents), `menubar-panel-full` (3 cards, overflow, a 4-line field, an answer).
- [ ] **Docs:** README ("Pending requests in the menu bar menu", "Pause Funes Vault"), `docs/MCP.md` (§ pause, pending requests, troubleshooting), `docs/ARCHITECTURE.md`, and `docs/TESTING.md`'s manual checklist (the panel's states, Review from a card, Remote Access off at once, Esc's steps, VoiceOver). Check `site/` for menu wording (no iPhone content there yet).
- [ ] **CHANGELOG** entry.
- [ ] Tick FR-G-01's acceptance, then a few days of the author's use before the release.
