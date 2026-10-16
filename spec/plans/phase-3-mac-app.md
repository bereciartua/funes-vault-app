# Phase 3: The Mac app

**Goal:** a daily-usable Funes Vault for Mac: the vault, Inbox, agents, Activity, capture, onboarding and one-click setup.

**Duration:** 3 weekends. **Depends on:** Phase 2. UX reference: [UX: Mac](../product/04-ux-mac.md).

## Tasks
### 3.1 App shell · 2 h
- [ ] Menu bar controller (icon states, menu), main window with sidebar sections, Settings window.
- [ ] Launch at login (`SMAppService`), `AppMover`, Dock visibility preference.
- [ ] "Pause Funes Vault" (1 hour, until tomorrow, until resumed).

### 3.2 Vault UI · 5 h
- [ ] List with search (debounced, 150 ms), filters, sort and empty states.
- [ ] Detail and editor: fields, sensitivity explanations, category token field, expiry picker, provenance timeline, "Shared N times" link, Archive, Delete, Still true.
- [ ] Recently Deleted view with restore and Delete Now.
- [ ] Custom categories management (S).
- [ ] Bulk actions (S).

### 3.3 Inbox UI · 3 h
- [ ] Cards by source, inline editing, Apply, Reject and Later, a duplicate hint, a correction diff with Replace or Keep both.
- [ ] Multi-select bulk review with per-item results. Badge counts.

### 3.4 Agents UI · 4 h
- [ ] Add-agent sheet with detected tiles (BridgeUI `AgentDetection`) and starting-access presets.
- [ ] Access editor: operations, ceiling slider, category allow/deny table, ask-before switches, expiry, "let it ask for more access".
- [ ] Connect tab: one-click setup buttons (Claude Desktop, Claude Code, Cursor, Codex) with preview and backup; snippets for the rest; copy and rotate key.
- [ ] Status: waiting for first request, connected, paused, expired. Pause and Remove.

### 3.5 Activity UI · 2 h
- [ ] Adapt `ActivityView`: filters, live title lookup, detail pane, fix deep links.

### 3.6 Panels, final · 2 h
- [ ] Pending requests (from the menu bar and Activity), approvable within 15 minutes.
- [ ] Access-request panel (Not Now, Allow Once, Always Allow) with an hourly throttle.
- [ ] Optional notifications (FR-L-04).

### 3.7 Capture · 2 h
- [ ] Global hotkey (Carbon) with a configurable shortcut. Capture box with secret-scanner feedback.
- [ ] "Remember…" menu item. Services provider ("Remember in Funes").
- [ ] Classification through `ModelRouter` (default Foundation Models, with rules as a fallback; or the user's chosen provider), run asynchronously, with the engine shown on Inbox cards.

### 3.8 Onboarding · 2 h
- [ ] Setup checklist card.
- [ ] Seed-questions sheet (7 prompts) that creates suggestions.
- [ ] Import entry points: ChatGPT file, Claude paste, Markdown (if 1.10 is done).
- [ ] The checklist completes on the first agent request.

### 3.8b AI Models settings · 3 h
- [ ] A per-task provider and model picker with locality badges; a providers list (add or edit, base URL, Keychain-stored key, **Test connection**).
- [ ] Cloud sensitivity limit; the "embed agent requests" switch; disclosure sentences; usage counters.
- [ ] Re-embedding progress and cancel; **Calibrate…** for unknown embedding models.

### 3.9 Settings and data · 1 h
- [ ] General, Capture, MCP (port, launcher symlink), Data (backups, export, import, Show in Finder, Erase), Updates (Sparkle), Advanced.

### 3.10 Accessibility and polish · 2 h
- [ ] Keyboard navigation everywhere, VoiceOver labels, Increase Contrast, Reduce Motion.
- [ ] UI snapshot build (`FUNES_UI_REVIEW` with fake data) in light and dark.

## Exit criteria
- You (the author) use Funes daily for a week with at least 2 agents, with no blocking bugs.
- A fresh macOS user account goes from install to first approved request in under 5 minutes.
- The UI snapshot set is reviewed in light and dark.
