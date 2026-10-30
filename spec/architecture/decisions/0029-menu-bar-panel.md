# ADR-0029: The menu bar icon opens a panel: Review cards, two switches, a field and the last 24 hours

**Status:** Accepted · 2026-10-30 · **Amends** [ADR-0001](0001-native-menu-bar-app.md) (the menu bar menu becomes a panel), [ADR-0025](0025-vault-overview-and-iphone-cache.md) (an hourly read beside the overview, Mac only), [FR-G-01](../../product/03-requirements.md), [FR-A-11](../../product/03-requirements.md), [FR-D-05](../../product/03-requirements.md), [UX: Mac ▸ Menu bar](../../product/04-ux-mac.md#menu-bar); adds FR-H-07

**Context.**
- **The menu grew one item at a time.** It now mixes status, actions, navigation and app items at the same weight, and most rows don't say what a click does ([the menu before this ADR](../../product/04-ux-mac.md#menu-bar), `StatusMenuController`):
  - **Hidden buttons.** "Funes Vault is on · 4 agents" and "Remote Access on · 2 cloud agents" look like status lines, but they open Agents and Remote Access.
  - **A stray click acts at once.** "Turn Off Remote Access" sits among those status lines and runs without asking.
  - **Labels that don't explain.** "Remember…" doesn't say it goes to the Inbox, and "Inbox" has no hint when it's empty. "Pending requests" is greyed out most of the time and repeats the "Review …'s Request" row above it.
  - **"Pause Funes Vault"** sounds like it stops everything, but it only refuses agents. The [glossary](../../product/06-glossary.md#the-app-its-server-and-pause) already renamed it "Pause All Agents", and the code never followed.
- **The author compared five directions** in mockups (the canvas "Funes Menu Bar Options"), and asked GPT-6-Astra to review them against this repository:
  - **A**, a tidy native menu with subtitles;
  - **B**, a Control Center-style panel with switches and a live agent list;
  - **C**, a panel led by a 24-hour chart and an activity feed;
  - **D**, a Spotlight-style field to remember or search;
  - **E**, a four-item menu.
- **The author chose a combination:**
  - B's switches, and its Review cards for whatever waits;
  - D's field, which remembers or searches;
  - C's chart.
  The agent list, the feed and the status chips were left out.

**Decision.**
1. **A left click on the icon opens a panel, not an `NSMenu`.** It's a borderless `NSPanel` (non-activating, able to become key) hosting SwiftUI and anchored under the status item. The panel is 350 pt wide, and closes on Esc, a click outside, another click on the icon or a switch to another app. A **right click** (or Control-click) shows a short native menu: Open Funes Vault, Settings…, Check for Updates… and Quit Funes Vault. So Quit, the window and Settings are always one native menu away.
2. **The panel's sections, top to bottom** ([UX: Mac ▸ Menu bar](../../product/04-ux-mac.md#menu-bar)):
   - **Waiting for you:** cards, only while something waits;
   - **two switches:** Agents and Remote Access;
   - **a field** that remembers (⏎) or searches (⌘⏎);
   - **Last 24 hours:** a chart;
   - **a footer:** Inbox, Open Funes Vault, Settings, and ⋯ for updates and Quit.
3. **Nothing is answered in the panel.** A card's only button is **Review**. It closes the panel and brings that item's own panel forward, key:
   - **a live item** of the approval panel (Share, access request, Save) is selected there, as **Review Request** (⌃⌥⌘R) does;
   - **a Pending request** is reopened and refreshed, as reopening one does today;
   - **a cloud sign-in**, which lives outside the approval panel, comes forward on its own.
   Each panel keeps its arming delay, exact text and keys ([UX: Panels](../../product/04-ux-mac.md#panels)): the sign-in has no Return key. Every waiting request gets one card, matched by request id. Only items the user must answer get a card: a request that's approved and waiting for its agent isn't one.
4. **Each switch shows its state and changes it:**
   - **Agents:** turning it off asks how long (FR-A-11's three lengths), and turning it on resumes.
   - **Remote Access:** turning it on asks first (FR-AI-04), and turning it off acts at once. It's the quick way to close the public address, which Pause doesn't do: Pause refuses requests but leaves both listeners up.
   - **A state with no switch:** the tile shows it and a button for it. For Agents, those states are the agent server off, starting or failed, and no agents yet. For Remote Access, it's only "not set up": **while Remote Access is on, its switch is always there**, whatever else is wrong (tunnel down, not listening), so it can always be turned off.
5. **The field remembers or searches.**
   - **⏎** saves a capture exactly as the capture box does: the same scanner, Cloud chip and Inbox.
   - **⌘⏎** searches the vault as the Vault does, and shows up to 5 results in place of the chart.
   - **Search answers** follow the user's setting and [ADR-0028](0028-search-answers.md)'s rules. The Ask row, the automatic choices, the card and every message match the Vault's.
   - **No retrieved vault content** (titles, quotes, answers) appears in the panel until the user searches.
6. **The chart comes from a new read, `VaultStore.recentPulse(now:calendar:)`.** It returns the last 24 hours, hour by hour: new memories by source, memories delivered by agent, and refused requests. These are the same aggregates as `VaultOverview`'s days, from the same tables, with no new table and no text. It's Mac only: the companion protocol and `OverviewRange` don't change, and neither does the iPhone.
7. **The capture box (⌥⌘M) and Review Request (⌃⌥⌘R) stay** as global shortcuts that work without the panel.

**Consequences.**
- **What `NSMenu` gave for free has to be built:**
  - the initial focus (the field);
  - Tab order, top to bottom;
  - Esc's three steps;
  - arrow keys in the results and the chart;
  - VoiceOver labels and the panel's announcement;
  - Reduce Motion and Increase Contrast.
  [NFR-A11Y-01](../../product/03-requirements.md) applies to the panel as to any window.
- **The panel must not steal the frontmost app.** It's non-activating and becomes key only for its own field and controls. Review hands focus to the approval panel, as ⌃⌥⌘R does today.
- **A draft survives the panel closing.** Text left in the field is kept in memory until it's saved, cleared or Funes quits, so a stray click outside doesn't lose it. It's never written to disk. Results, answers and calls in progress don't survive: closing clears and cancels them, and reopening shows the chart.
- **Closing a non-activating panel reliably needs care.** Mouse monitors miss ⌘⇥ and Space changes, and Funes never becomes the active app. Phase 10 starts with a short spike that proves the closing rules before the rest is built.
- **The menu bar shows memory text only after a search.** That's the same exposure as the Vault's search, and screen sharing shows it too. Nothing appears unasked.
- **The icon gains a "can't connect" state** (a warning badge), so a failed agent server no longer looks like a pause.
- **`StatusMenuController` becomes the right-click menu and the panel's anchor.** The old menu's items go away.
- **The docs change with it:** README, `docs/MCP.md` and `docs/ARCHITECTURE.md` describe "Pending requests in the menu bar menu" and "Pause Funes Vault" today.

**Alternatives considered.**
- **A, a tidy native menu:** the cheapest, and it keeps NSMenu's keyboard and VoiceOver for free. But it can't hold a field, switches or a chart. GPT-6-Astra preferred it, for those reasons. The author chose the richer panel, keeping A's wording (what each control does), its "Waiting for you" grouping and its fast Remote Access off.
- **B's live agent list:** useful, but the Agents section and Home's "Who reads" card already show it, and it made the panel tall.
- **C's feed and "who's reading" avatars:** they repeat Activity, and their glow can't be read without a text equivalent.
- **D's status chips:** the switches say more in the same space.
- **E, a four-item menu:** nothing to misread, but nothing to learn from either. It would also have made a click on the icon do different things depending on the state.
- **A transient `NSPopover`:** it has the arrow and closes for free, but it fights a field that must survive a stray click, and its arrow doesn't match macOS 26's menu bar extras. A borderless panel with the same closing rules is simpler to control.
