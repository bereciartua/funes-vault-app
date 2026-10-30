# UX: Funes Vault for Mac

Funes is a menu bar app (`LSUIElement`) with one main window and floating panels. The structure deliberately mirrors EK Bridge so both apps feel like siblings: a menu bar first, a setup checklist, the main window's sections, panels at the top right, and Activity.

## Surfaces at a glance

```
Menu bar icon ─┬─ Panel ────────────── (v0.7) Waiting for you · Agents and Remote Access switches · remember or search · last 24 hours · Inbox · Open · Settings
               ├─ Right-click menu ─── Open Funes Vault · Settings… · Check for Updates… · Quit
               ├─ Capture box ───────── (⌥⌘M) quick capture
               └─ Panels (top right) ── <agent> wants N memories · Save this memory? · <agent> wants to read <category> · <app> wants to connect
Main window ───┬─ Home         (v0.4: compose, the vault's pulse and shape; where the window opens)
               ├─ Vault        (memories: list + detail)
               ├─ Inbox        (suggestions to review)
               ├─ Agents       (connections: access, connect, cloud, activity)
               ├─ Remote Access (cloud agents through your tunnel; experimental, off by default)
               ├─ Activity     (log)
               └─ Settings…    (a separate window, v0.8: about you · general · notifications · capture & shortcuts · AI: features, models & accounts, privacy & limits · agent server · iPhone · data & backups · advanced)
```

## Menu bar
*From v0.7 the icon opens a panel ([ADR-0029](../architecture/decisions/0029-menu-bar-panel.md), [Phase 10](../plans/phase-10-menu-bar-panel.md)). Before v0.7 it opened a menu: Review …'s Request, the status line, Remember…, Inbox, Pending requests ▸, Remote Access and Turn Off Remote Access, Pause Funes Vault ▸, Open Funes Vault, Check for Updates…, Settings… and Quit.*

**Icon states:**

| State | Look | Meaning |
|---|---|---|
| Normal | outline eye (the app icon's almond and iris) | on, nothing waiting |
| Needs you | filled eye with an accent dot | a panel is open, or requests or suggestions are waiting |
| Paused | eye with a slash | all agents are paused |
| Can't connect | eye with a small warning badge | the agent server failed (a port in use, or it stopped) |
| Off | dimmed eye | the agent server is off (before setup, or turned off in Settings) |
| Remote Access on | any of the above, plus a small globe | the Remote Access listener is on |

The tooltip says the same in words ("Agents paused until 14:00", "Inbox: 3", "Waiting for you: 2"), and so does VoiceOver's label.

**Clicks:**
- **A click** opens the panel. Another click on the icon closes it, and so do Esc (see [Keys](#keys-in-the-panel)), a click outside, switching to another app (⌘⇥ included), and switching Spaces.
- **A right click** or Control-click shows a short native menu: **Open Funes Vault** ⌘O, **Settings…** ⌘,, **Check for Updates…** (only in a copy that can update itself) and **Quit Funes Vault** ⌘Q.

### The panel
```
┌────────────────────────────────────────────────┐
│ Claude Code wants 4 memories          [Review] │  Waiting for you
│ 0:41 to answer · ⌃⌥⌘R                          │  (only while something waits)
│ Codex wants 2 memories                [Review] │
│ Still answerable · 12 min left                 │
│ ┌ (👥)           (on) ┐ ┌ (🌐)           (on) ┐ │
│ │ Agents              │ │ Remote Access       │ │  the switches
│ │ On · 4 agents       │ │ On · 2 cloud agents │ │
│ └─────────────────────┘ └─────────────────────┘ │
│ ┌────────────────────────────────────────────┐ │
│ │ Remember something, or search…         🎙  │ │  the field
│ └────────────────────────────────────────────┘ │
│   ⏎ Remember · ⌘⏎ Search · goes to your Inbox  │
│ Last 24 hours     13 in · 27 shared · 1 refused │
│  ▂ ▅ ▁     ▁ ▃ ▇ ▂                    ▁   ▂ ▁ ▂ │  in
│ ─────────────────────────────────────────────── │
│  ▃ ▅ ▂   ▂ ▆ ▃ ▂                    ▂ ▅ ▆ ▃ ▅ │  shared
│                                       •        │  refused
│  12:00    18:00     00:00     06:00       now  │
│ ────────────────────────────────────────────── │
│ [Inbox 3] [Open Funes Vault]          [⚙] [⋯] │  footer
└────────────────────────────────────────────────┘
```
- **Look:** 350 pt wide, a rounded borderless panel under the icon, with the menu bar's material. It follows Settings ▸ General ▸ Appearance (FR-G-06).
- **Height:** fits what it shows, and never exceeds the screen's visible area. The cards, the switches and the footer keep their size. The field grows to 4 lines, then scrolls inside itself. The area under it (the chart, or the results and the answer) takes what's left and scrolls. Checked with the most it can hold (3 cards and the overflow line, a 4-line field, an answer with 3 claims, 5 results) at 350 pt, on macOS 15 and 26.
- **Freshness:** read when the panel opens. While it's open, the countdowns tick each second; the counts follow vault, queue and Remote Access changes; and the chart moves on at each hour, after the Mac wakes and when the time zone changes.
- **Not activating:** the panel takes key focus for its own controls without bringing Funes's windows forward or deactivating the frontmost app.
- **Closing** keeps only a draft ([The field](#the-field)): results, an answer and anything in progress are cleared, and the panel opens again on the chart.

### Waiting for you
- **One card per item the user must answer,** each request once, matched by its request id. The order:
  1. the approval panel's items, in its order ([Panels](#panels)): items on a clock first, soonest first, then a Save;
  2. a cloud sign-in, while one waits (one at a time, as [its panel](#app-wants-to-connect-cloud-sign-in) says);
  3. Pending requests that can still be shared and aren't already one of the cards above, soonest expiry first.
  A request that's approved and waiting for its agent has no card: there's nothing to do. It stays on the agent's page and in Activity.
- **A card's text:** the item's panel title ("Claude Code wants 4 memories", "Cursor wants to read Project context", "claude.ai wants to connect", "Codex wants to save a memory"). Under it, its time:
  - a live panel: "0:41 to answer";
  - a sign-in: "Until 10:52";
  - a Pending request: "Still answerable · 12 min left";
  - a Save: nothing.
- **The Review Request shortcut** shows on the card it would review: the approval panel's current item, else the soonest Pending request. Review Request and that card always do the same thing.
- **At most 3 cards.** Beyond 3, a line says how many more wait ("2 more waiting"). The approval panel's own chips show its other items once one is reviewed. While some of the rest are Pending requests, the line has **Show All Pending Requests**, which opens Activity with them at the top.
- **The first card is drawn in the accent color.** The others are plain.
- **Review** is the card's only button. It closes the panel, then:
  - **a live approval-panel item:** that item is selected in the approval panel, which comes forward and becomes key, as Review Request does. Its content is already current, and its arming delay restarts whenever its content changes.
  - **a Pending request:** reopened as [Share](#agent-wants-n-memories-share) describes, refreshed and armed again if anything changed. Its 15 minutes don't restart.
  - **a sign-in:** its panel comes forward. It has no Return key; the codes must be compared.
  Each panel keeps its own keys and arming, so the key press that chose Review can't also answer the panel it opens.
- **The panel never shares, denies, saves a suggestion, connects an app or allows access.**
- **Arrivals never move keyboard focus.** A new card appears in place, and VoiceOver announces it ("Cursor wants to read Project context"), but focus stays where it was. A card whose item is answered elsewhere (in its panel, or on the iPhone) or expires goes away.
- **VoiceOver:** each card reads as one element ("Claude Code wants 4 memories, 41 seconds to answer"), followed by its Review button.

### The switches
Two tiles side by side. Each has an icon, a name, a status line and a switch or a button. The tile itself is also a button: it opens its section, Agents or Remote Access.

**Agents**

| State | Tile | Switch or button |
|---|---|---|
| On | "On · 4 agents" ("1 agent") | switch on |
| No agents yet | "No agents yet" | **Add Agent…** (opens Add Agent) |
| Paused | orange; "Paused until 14:00", "Paused until tomorrow at 09:00", "Paused until you resume" | switch off |
| Starting | "Starting…" with a small spinner | switch disabled |
| Can't connect | warning tint; "Port 47625 is in use", "The agent server stopped" | **Fix…** (Settings ▸ Agent Server) |
| Off in Settings | "Off · agents can't connect" | **Turn On…** (Settings ▸ Agent Server) |

- The states are checked in this order: off in Settings, can't connect, starting, paused, no agents yet, on.
- **Fix…** and **Turn On…** open Settings ▸ Agent Server (destination `agent-server`), which holds the switch and the port.
- **Turning the switch off** opens a small menu from it: **For 1 Hour**, **Until Tomorrow**, **Until I Resume**. Choosing one pauses all agents (FR-A-11); Esc or a click elsewhere closes the menu and leaves them on. **Turning it on** resumes at once.
- **While paused,** a line sits under the tiles: "Agents' requests are refused. Capture and the Inbox keep working.", with **Resume**.
- "4 agents" counts the agents set up and not removed, as the old status line did. It says nothing about which are connected now, paused on their own, or expired; the Agents section says that.
- **The paired iPhone isn't an agent.** Pausing all agents doesn't touch it, and neither does Remote Access.

**Remote Access**

| State | Tile | Switch or button |
|---|---|---|
| Not set up | "Not set up" | **Set Up…** (the Remote Access section) |
| Off | "Off" | switch off |
| On | "On · 2 cloud agents" (the agents with cloud access); "On · told it's paused" while agents are paused | switch on |
| On, turning off later | "On · until 18:00" (its automatic turn-off) | switch on |
| Tunnel down | warning tint; "On · tunnel down" | switch on |
| Not listening | warning tint; "On · not listening" (the agent server is off or failed, or the listener failed) | switch on, and **Fix…** on the status line |

- **"Not set up"** follows the Remote Access section's own rule for showing its introduction. Once set up, the tile has a switch.
- The states are checked in this order: not set up, off, not listening, tunnel down, then on, with "until" or "told it's paused" added.
- **While Remote Access is on, the switch is always there,** whatever else is wrong, so it can always be turned off.
- **Turning it on asks first,** with the Remote Access section's own question (FR-AI-04). Cancelling leaves it off.
- **Turning it off acts at once,** with no question: the public address stops answering (FR-AI-04). It's the quick way to close it: pausing refuses requests but leaves the address up.
- **When it turns off by itself** at its set time, the tile updates at once.
- **VoiceOver:** each tile reads its name and status, then its switch or button ("Agents, on, 4 agents, switch", "Remote Access: Not set up. Set Up…").

### The field
- **Placeholder** "Remember something, or search…", with the mic as in the capture box (macOS 26 and later). It has the panel's initial focus. It grows to 4 lines; ⇧⏎ is a new line.
- **Hint** under it: "⏎ Remember · ⌘⏎ Search · goes to your Inbox", with the capture box's Cloud chip when a cloud model proposes the fields.
- **⏎ Remember** saves a capture as the [capture box](#capture-box) does: the same secret scanner and errors, classification and Activity.
  - **The panel stays open.** The field clears, and the hint says "Saving…" until the capture is stored, then "Saved to Inbox" for 2 s.
  - **If the scanner matches,** the error shows under the field, the text stays, and nothing is saved.
  - **If storing fails:** the error shows under the field. The text comes back only if the field is still empty. Otherwise the line says "Your last note wasn't saved" with **Restore**, which swaps it in and keeps what was typed since as the next draft.
- **⌘⏎ Search** runs the Vault's search (Active scope, no filters) and shows the results in place of the chart:
  - up to 5 rows, each with the title, the first category and the sensitivity badge; no body text;
  - **Show All 23 in Vault** under them, which opens the Vault searching for the text;
  - "Nothing matches." with no results.
- **Search answers,** only while Settings ▸ AI ▸ Features ▸ Search answers is on, work as in the [Vault](#vault):
  - the **✦ Ask Funes** row above the results;
  - **⌘⏎** again to ask, or automatically when the setting says so;
  - the reading card with **Cancel**;
  - the answer card: up to 3 claims with numbered chips, a one-line quote each, the engine badge, the footer, and every message and failure of §10.5.
  - **A claim's number** opens that memory in the Vault with the quoted sentence highlighted, as the Vault's numbers do, and closes the panel. The answer reads the same 10 results as the Vault's (5 for Apple on-device), so a cited memory may not be one of the 5 rows shown.
  - **Logging:** Activity records it as `search_answered`, actor the user, as in the Vault.
- **Editing the text** after a search clears the results and the answer, cancels a call in progress and an automatic answer's wait, and the chart comes back. ⌘⏎ searches again.
- **Dictation stops** when the capture is saved, on ⌘⏎, on Esc and when the panel closes. Words that arrive after it stopped are dropped.
- **A draft** left in the field when the panel closes is still there when it opens again, until it's saved or cleared, or Funes quits. It's kept in memory only. Results and answers aren't drafts: closing clears them and cancels their calls, and a late response is dropped. Reopening shows the chart under the draft, and ⌘⏎ searches again.
- **Retrieved vault content** (titles, quotes, answers) appears only after the user searches. The draft is the user's own typing, not vault content.

### Keys in the panel
| Focus | ⏎ | ⌘⏎ | ↑ ↓ | Esc |
|---|---|---|---|---|
| Field, no results | Remember | Search | — | clears the text; with no text, closes the panel |
| Field, results showing | opens the selected result in the Vault | asks (with Search answers on) | move the selection | back to the chart (the text stays) |
| A result row | opens it in the Vault | — | move the selection | back to the field |
| The chart | opens Activity for the focused hour | — | — | back to the field |
| The pause menu, or ⋯'s menu | chooses the item | — | move | closes that menu only |
| Anything else | activates it | — | — | closes the panel |

- **While results show, ⏎ opens a result and never saves the text.** To remember the text instead, Esc back to the chart, then ⏎.
- **Tab** goes top to bottom: each card's Review; the Agents tile, then its switch or button; the same for Remote Access; the field; the results or the chart; the footer's buttons. Shift-Tab goes back.
- **In the chart,** ← → move between hours. VoiceOver offers **Show Problems** as an action on an hour with a refused dot.
- **⌘O, ⌘, and ⌘Q** work while the panel is key.
- **Global shortcuts stay:** Review Request (⌃⌥⌘R, changeable in Settings ▸ Capture & Shortcuts) works from any app, panel open or not, and so does the capture box (⌥⌘M).
- **Announcement:** opening the panel announces "Funes Vault" and what waits ("2 requests waiting for you").

### Last 24 hours
- **Header:** "Last 24 hours", then the counts on the right: "13 in · 27 shared · 1 refused". Parts with nothing to say drop out; with nothing at all, "Quiet: nothing in or out".
- **Chart:** 24 hourly bars, the current hour last ("now"). **In** sits above the line: new memories (one color, not stacked). **Shared** sits below it: memories delivered to agents. **Refused:** a dot under the hour. Each half has its own scale, as in Home's pulse. The x axis says "12:00 · 18:00 · 00:00 · 06:00 · now", following the clock.
- **Hover** an hour: "09:00–10:00 · 1 in (iPhone) · 4 shared (Claude Code 3, Codex 1) · 1 refused" (in by source, shared by agent), on one line under the chart that stays when nothing is marked, so hovering never changes the panel's height; a long one is shortened in the middle, and VoiceOver reads it whole. An hour that happens twice when clocks go back carries its zone ("01:00–02:00 EST").
- **Click** an hour (or ⏎ on it) to open Activity filtered to that hour ("Showing 09:00–10:00 only · Show Everything"). A refused dot (or **Show Problems**) opens Activity ▸ Problems for that hour. Either closes the panel.
- **Data:** counts only, from `VaultStore.recentPulse` (FR-H-07). Never text or titles.
- **Empty:** "Your pulse starts with your first memories" in a new vault.
- **Accessibility:** a chart descriptor (VoiceOver's audio graph). It reads "Last 24 hours: 13 memories in, 27 shared, 1 request refused", and each hour reads its breakdown. Reduce Motion turns off the bars' drawing in, and Increase Contrast uses the strongest colors for the bars. Color is never the only cue: the hover text and VoiceOver say it in words.
- **Hidden** while search results or an answer show.

### Footer
- **Inbox**, with the count of waiting suggestions as a badge, opens the Inbox.
- **Open Funes Vault** opens the main window on Home.
- **⚙** opens Settings.
- **⋯** opens a small menu: **Check for Updates…** (only in a copy that can update itself) and **Quit Funes Vault**.

## Capture box
- **Window:** a small borderless window centred near the top of the screen, like Spotlight. It has:
  - a multi-line text field with the placeholder "What should Funes remember?", and from v0.4 a mic that dictates into it (SpeechAnalyzer, as in Home's composer; macOS 26 and later, and on macOS 15 there's no mic, while the system's own dictation still works in the field);
  - a footer with "⏎ Save · ⇧⏎ New line · Esc Cancel" and where the text goes: "Goes to your Inbox", or, while a cloud model proposes the fields, "Goes to your Inbox · fields suggested by Anthropic" with a **Cloud** chip (principle 7).
- **On save:**
  - The box closes and a brief HUD says "Saved to Inbox".
  - Classification runs in the background and fills in the proposed fields.
- **If the secret scanner matches:** the box stays open with an inline error ("This looks like an API key. Funes never stores secrets.") and nothing is saved.

## Main window

A sidebar plus a content area, with a minimum size of 860×560. Every section fits at that size, with the sidebar at any width it allows (180–260): nothing runs off the right edge. The UI-review build shows each section at the minimum size, shrunk from the default as a user would (`*-min` snapshots).

Warnings are an orange icon with primary text, never orange text, which is under 3:1 on white. Text on a colored badge is primary; the color is in the fill. Text aims for 4.5:1 or better, and Increase Contrast strengthens fills, borders and the warning orange.

### Sidebar
Modelled on EK Bridge's sidebar, top to bottom:

```
Home                  ⌘1   (v0.4)
Vault                 ⌘2
Inbox             3   ⌘3
Activity              ⌘4
AGENTS             +
  Claude Code     1   ● 2 min. ago
  Cursor              ● Paused
  claude.ai           ● Cloud · No requests yet
──────────────────────
Remote Access    On   ⌘6
Settings…             ⌘,
● Agents paused until 14:00  [Resume]
```

- **Home, Vault, Inbox, Activity** at the top. Inbox's badge counts the suggestions waiting. (Before v0.4 there's no Home, and the shortcuts start at Vault ⌘1.)
- **Agents:** a section listing each agent (⌘5 shows the last one shown, or the first). Each row shows the agent's icon, name, a colored dot and a short status: "2 min. ago", "No requests yet", "Paused", "Access expired", with "Cloud · " in front for a cloud agent. Its badge counts that agent's pending requests. The header's **+** opens Add Agent; with no agents the section shows **Add Agent…** instead. A row's context menu has Pause or Resume and Show Activity. Removing an agent shows the first one left.
- **Remote Access** and **Settings…** stay pinned at the bottom; agents scroll under them, which get a bar background once the list is long. Settings… opens the Settings window, as ⌘, does. It is a button, not a page.
- **The status line** shows under them only while something's off: agents paused (with **Resume**), the agent server turned off, or the server stopped ("Port 47627 is in use by another app"). While agents can connect there is none; the menu bar icon says so.
- **VoiceOver:** the Agents header is a heading and its + reads "Add Agent…". An agent reads as one element with its full status and waiting requests ("Claude Code, Connected · 2 min. ago, 1 request waiting"). Remote Access reads "Remote Access, On", and the status line reads as one element.
- There's no separate Overview page: from v0.4, Home holds the overview, and Activity the detail.

### Home
*v0.4, [Phase 7](../plans/phase-7-home.md) task 7.3; the counts come from `VaultOverview` ([ADR-0025](../architecture/decisions/0025-vault-overview-and-iphone-cache.md)).* The main window opens on it, and so does **Open Funes Vault**. A place to add a memory right there, then the vault's pulse: what came in, what went out to your agents, and its shape. No memory text or titles anywhere on it.

```
         Good afternoon, Martin.
         What should Funes remember?
  ┌───────────────────────────────────────────────────────┐
  │ Tell me something, or search what I know…             │
  │                                        (🎙) [Remember] │
  └───────────────────────────────────────────────────────┘
      ⏎ Remember · ⌘⏎ Search vault · Goes to your Inbox
  ┌ This week: 9 saved, 23 shared with 3 agents, 2 refused ┐
  │                            [7 days|30 days|12 weeks|12 months]
  │ IN   ▂ ▅ ▁   ▃ ▇ ▂ ▁ ▄   ▂ ▆ ▃       ▁ ▅ ▂ ▃ ▇          │
  │ ──────────────────────────────────────────────────     │
  │ OUT  ▆ ▃ █   ▂ ▅ ▇ ▃ ▂   ▄ █ ▅ ▂     ▃ ▆ ▂ █ ▄          │
  │        •          •                  •   refused       │
  └────────────────────────────────────────────────────────┘
  ┌Memories ┐ ┌Sensitivity┐ ┌Rhythm   ┐ ┌Who reads      ┐
  │64  ╱‾‾‾ │ │Vault ▇▇▇▇ │ │12 weeks │ │Claude Code 41 │
  │+9 week  │ │Shared ▇▇▇ │ │Most Sun │ │Cursor 12      │
  └─────────┘ └───────────┘ └─────────┘ └───────────────┘
      3 waiting in Inbox · Last tidy-up today 03:04
```

- **Greeting:** "Good morning / afternoon / evening, <name>." with the name Funes calls you from **About You** (the preferred name, else the given name; v0.5, [ADR-0026](../architecture/decisions/0026-about-you-profile.md)), then "What should Funes remember?". With no name set it's "Good afternoon." alone: the macOS account's name is only a suggestion in About You, never used by itself, since it's often a username ("mib"). Before v0.5 it was the first word of the account's full name.
- **Composer:** focused when Home appears, so ⌘1 then typing is a capture.
  - **⏎ Remember** saves it as a capture, exactly as the capture box does (the same view, words, HUD and secret-scanner error). **⇧⏎** is a new line. **⌘⏎ Search vault** opens the Vault searching for the text.
  - **Mic:** dictates into the field with SpeechAnalyzer, after what's already there; the text stays editable, and ⏎ stops it and saves. Asks for microphone and speech recognition access the first time; if either is refused, the field's error says where to allow it. macOS 26 and later: on macOS 15 there's no mic (the system's own dictation still works in the field).
  - Footer: "⏎ Remember · ⌘⏎ Search vault · Goes to your Inbox", with the capture box's Cloud chip when a cloud model proposes the fields.
- **Pulse card:**
  - **The sentence first,** numbers over adjectives: "This week: 9 saved, 23 shared with 3 agents, 2 refused." Parts with nothing to say drop out ("This week: 9 saved.").
  - **In** (above the line): new memories per day, stacked by source: You (Mac), iPhone, Agents, Imports, Tidy-up. **Out** (below): memories shared per day, stacked by agent (the top four, then Other). **Refused:** a red dot under the day, sized by count.
  - **Range:** 7 days · **30 days** (default) · 12 weeks · 12 months, remembered; the longer ranges group by week and month.
  - **Hover** a day: "Tue 21 Oct · 4 in (2 iPhone, 2 Agents) · 11 shared (Claude Code 8, Cursor 3) · 1 refused" (in counts by source; the overview doesn't say which agent's suggestions they were). **Click** opens Activity filtered to that day ("Showing Tue 21 Oct only · Show everything"), or that week or month in the longer ranges; a refused dot opens Activity ▸ Problems for that day.
  - **Each half has its own scale,** so a quiet side isn't flattened by a busy one: the line is always in the middle, the busiest In day reaches the top and the busiest Out day the bottom (a little above it when there are refused dots, which sit beneath). Since a bar of 3 can then stand as tall as one of 22, the y axis labels each half with its own peak, the tallest In and the deepest Out ("3 in", "13 out"), each with a faint gridline. A half with nothing in the range stays empty, with no label. The x axis shows about five dates, the newest under today. The hover text and VoiceOver give the real counts.
  - Counts memories shared: a request that shares 3 counts 3.
- **Cards** (each opens its place):

  | Card | Shows | Opens |
  |---|---|---|
  | **Memories** | Total (counted up); the vault's growth over 12 weeks as a line; "+9 this week" | Vault, newest first |
  | **Sensitivity** | Two bars: the vault's mix, and what was shared in the range (7 days shows the last 30), with "Shared: 78% Low" over "Vault: 48% Low" | Vault, filtered to the level the caption names first |
  | **Rhythm** | A 12-week grid of days (like GitHub's); "Most on Sundays" over "3-week streak" (a weekday only when one leads, a streak from 2 weeks) | Activity, Suggestions (what came in) |
  | **Who reads your vault** | The top three agents by memories shared in the range, with the count | Each row: the agent's Activity tab (a removed agent: Activity narrowed to it) |

- **Status line:** "3 waiting in Inbox · Last tidy-up today 03:04", each part a link to the Inbox (the tidy-up's suggestions are there), each hidden when there's nothing to say.
- **Empty states:** a new vault ("Your pulse starts with your first memories"; the cards say "Too few memories for a rhythm yet", under 5 new memories in 12 weeks); no agents ("No agent has read your vault yet. **Add Agent…**" in place of Out and Who reads); nothing this week ("Nothing new this week"). With agents but nothing shared in the range, Who reads says "Nothing shared in the last 30 days".
- **Refreshes** when Home appears and whenever the vault changes while it shows; the read runs off the main thread.
- **Size:** fits without scrolling at the default window size; at the minimum (860×560) the page scrolls and the four cards wrap to two rows. The composer isn't sticky.
- **Accessibility:** the pulse chart has a chart descriptor (VoiceOver's audio graph) and reads as "Last 30 days: 41 memories in, 96 shared, 3 requests refused"; each day reads its breakdown. Reduce Motion turns off the count-up and the chart's drawing in. Colors are never the only cue: the legend names every series, and the hover text says it in words.

### Setup checklist (until dismissed)
A card at the top of Home, above the greeting (before v0.4, at the top of the Vault), connecting first:
1. **Connect an agent**: "Found on this Mac: Claude Code, Cursor". [Add…]
2. **Approve its first request**: [Add to Claude Code…] / [Show Setup]. "Ask it something. Funes shows you exactly what it would share." The step completes when the first request arrives ("Claude Code connected 10:42").
3. **Seed your vault**: "Answer a few questions or import from ChatGPT or Claude." [Start]. From v0.5 the questions open on **About you** ([Settings ▸ About You](#settings)): "First, what should Funes call you?", with given name, family name and "Call me" prefilled from the macOS account's name when it looks like a person's name (two or more words, or capitalized), and empty otherwise; **Continue** saves it, **Skip** leaves the profile as it is. Pronouns, languages and the rest stay in Settings, so seeding stays short.
4. **Review your Inbox**: "Apply what's right." [Open Inbox]
- Home's composer has the initial keyboard focus, and the first unfinished step's button is the checklist's default focus; Hide never is. Hide leaves "Setup checklist hidden. Settings ▸ Advanced brings it back. [Undo]" for 10 seconds.

### Vault
- **Toolbar:**
  - search field (⌘F);
  - filter pop-ups (Category, Kind, Sensitivity, Status, Source);
  - sort (its "Sort by" label drops when the window is too narrow for it);
  - **+ New Memory** (⌘N).
- **List row:**
  - title;
  - one-line body preview; while searching (v0.6), the passage that matches the search, with the search's words highlighted (FR-V-17, [memory processing §10.2](../domain/memory-processing.md#102-snippets));
  - category chips;
  - a sensitivity badge, colored by level in its fill, with the level's name in primary text;
  - kind icon;
  - "expires in 3 days" or "Expired" when relevant;
  - updated time.
- **Detail** (right pane or sheet):
  - **Fields:** title, body (plain text, up to 10,000 characters, with a counter), kind, categories (token field), sensitivity (segmented control with a one-line explanation), expiry (date picker, with "never").
  - **Shared with:** "Shared 4 times · last with Claude Code yesterday", with a link to filtered Activity.
  - **Provenance timeline:** created, edited, archived, shared, suggested by. Rows hold labels only. **Show All in Activity** opens the memory's Activity. A change's row has a disclosure (v0.5) with what it did, before and after, as in Activity's detail pane: an automatic change's from its undo entry, any other's from the memory's earlier versions (FR-V-16). The disclosure has **Show in Activity**, which selects its Activity row (also in every row's context menu). A merge's or split's row links to the other memory. While a memory has earlier versions, the header offers **Forget Earlier Versions…**, which asks first ("Forget this memory's earlier versions?").
  - **Actions:** Archive / Restore, Delete, "Still true" (confirm), and for an active memory **Tidy Up** (also in the list's context menu), which checks it now with the tidy-up model ("Tidying Up…") and shows what it found on a line under the actions, with **Show in Inbox** when it left a suggestion ([memory processing §9.7](../domain/memory-processing.md#97-tidy-up-on-one-memory)). Off, with a tooltip, until a tidy-up model is chosen. In Recently Deleted: Restore and **Delete Now…**, which asks first ("Delete this memory now?"), from the detail, the list's context menu and the bulk bar alike.
- **Search answers** (v0.6, FR-AI-17, [ADR-0028](../architecture/decisions/0028-search-answers.md)), only while Settings ▸ AI ▸ Features ▸ Search answers is on:
  - **Ask row:** the list's first row, "✦ Ask Funes" with ⌘⏎, when the search isn't empty, the scope is Active and there are results. **⌘⏎** in the search field does the same. Not shown in Archived or Recently Deleted.
  - **Reading:** the row becomes a card, "Reading 10 results…" with a shimmer and **Cancel**. The results below stay as they are and can be used meanwhile.
  - **Answer card:** "✦ Answer" with the engine's locality badge ("Claude · Cloud", "On this Mac"); up to 3 claims, the first in bold, each with numbered chips and its quote under it in a quote style (one line, the whole quote in a tooltip); a footer, "Read 10 of 30 results · 6 s", plus "1 memory above Internal wasn't read" or "1 claim left out: it didn't quote a memory" when they apply; **Copy** (the claims' text) and **Clear**. The cited rows carry the same numbered chips.
  - **A number** selects that memory; the detail shows the quoted sentence (found with `QuoteLocator`) highlighted in its context in a "Quoted in the answer" box above the text, until the selection changes or the text is edited (the text field itself can't highlight a range). Nothing is selected automatically, and rows never move.
  - **No answer and failures:** "No answer in the 10 results read."; "Your search looks like it contains a secret, so it wasn't sent."; "Today's 300 cloud requests are used up. Search still works; answers are back tomorrow."; "Took too long."; the provider's state ("Claude Code isn't signed in on your Mac."). **Try Again** where it can help.
  - **Automatically** (Answer set to Automatically for questions or for every search, [memory processing §10.6](../domain/memory-processing.md#106-limits-and-automatic-answers)): the Ask row turns into the reading card on its own once the results have shown unchanged for 0.6 s (a question) or 1 s (any search), once for each search; ⌘⏎ still asks about any other search.
  - **Changing the search,** the scope or a filter clears the card (and cancels a call in progress). Home's composer keeps ⌘⏎ for Search vault; the Vault it opens shows the Ask row.
- **Empty state:** "Your vault is empty. Answer a few questions to get started, or press ⌥⌘M anytime to remember something."
- **First run** (no memories yet, nothing filtered): a welcome instead of the toolbar, list and detail: "Your memory, shared only as you allow", three lines on the promise (the vault stays on this Mac; each agent gets only the access you give it and you see the exact text first; Activity records every request, without the text), [Answer a Few Questions…] [New Memory…] "or press ⌥⌘M in any app".

**Sensitivity explanations (UI copy):**

| Level | One-liner |
|---|---|
| Public | Fine for anyone to know. |
| Low | Everyday preferences. Fine for most of your agents. |
| Internal | Work or project context. Share with agents you use for that work. |
| Sensitive | Personal: health, money, family. Share rarely, and always ask. |
| Restricted | Very personal. Only for agents you fully trust, and always ask. |
| Secret | Never shared with agents unless you raise an agent's ceiling to Secret. |

### Inbox
- **Sections:** From agents · Captures · Imports · Your answers (seed questions) · Tidy-up (v0.3) · Applied automatically (v0.3). Expired suggestions (FR-I-05) sit at the end with Restore.
- **Item card:**
  - source line ("Suggested by Claude Code · 10:31", "Captured on iPhone · yesterday", "Imported from ChatGPT");
  - proposed title and body, editable inline;
  - proposed kind, categories and sensitivity;
  - evidence, if the agent provided it, shown as quoted data;
  - a duplicate hint, when it applies;
  - the engine that proposed the fields ("Proposed on this Mac", "Proposed by Claude via Anthropic", "Kept on this Mac: looked sensitive").
- **Apply stores exactly what the card shows.** A card the user hasn't edited follows background classification; an edited one keeps the user's values.
- **Actions:** Apply (⌘⏎), Reject (⌫ when no field is being edited, ⌘⌫ anytime), Later. Click a card to make it the one the keys act on. Multi-select gives "Apply 12" and "Reject 12", with per-item results ("12 applied, 1 blocked by the secret scanner").
- **Correction suggestions:** when a suggestion references an existing memory, the card shows a diff (old → new) with **Replace** and **Keep both**. Only `update` suggestions offer that choice; every other action applies as itself (v0.3, FR-I-02). If the memory changed since the suggestion was made, the card says "Changed since this was suggested" and shows the current text.

**From v0.3** (Phase 6, [memory processing §5](../domain/memory-processing.md#5-new-memories-split-classify-link) and [§9](../domain/memory-processing.md#9-daily-tidy-up)):
- **Group card** for a split input: the source line ("From ChatGPT · 12 pieces"), the original text (collapsible), then one row per piece with its own Apply / Reject / edit, and a badge: New · Updates *<memory>* · Already saved · Removes *<memory>* · Outside <agent>'s scope. **Apply all** applies each row with its own action and skips flagged rows; **Keep as one** (restores the original) shows only while no piece is decided. Engine line: "Split by Claude via Anthropic", "Split on this Mac", "Kept on this Mac: looked sensitive".
- **Processing… card:** a new input whose split hasn't finished shows its original text, read-only, and why it waits: "Splitting with Claude…", "2 ahead of it", "Next in line", "Waiting: today's model limit reached", "Waiting to try again". It can't be applied or edited ("It can be saved once it's split."); bulk Apply skips it ("1 still processing"). **Reject** works and cancels the split. When the split is done, the card is replaced by the result: a group card, an update or Already saved card, or the same card when nothing changed. With splitting off, cards appear ready at once.
- **Couldn't split:** a split that failed (the provider, a timeout, an unusable answer, a blocked CLI run) says why ("The model took too long.") and offers **Try Again** (prominent) and **Keep as One** (review it as it is, as one memory), with Reject. Bulk Apply leaves it for the user.
- **Split this memory:** for an agent's directly saved memory, the memory and its proposed pieces.
- **Tidy-up section:** update (diff, Replace / Keep) · merge (sources, and the proposed memory, editable) · split (the group card) · archive ("Keeps *<survivor>*") · conflict (both memories and the question: **Keep A**, **Keep B**, **Both are true**, **Edit…**). Header: "Last tidy-up: today 03:04 · 37 memories checked · 4 suggestions" and **Tidy up now**; after a run that stopped early, "· 2 left: the model took too long to answer" and **Try Again**, with **Daily Tidy-up…** when the model's setup failed, or the account's name ("Claude…") when its sign-in or key did, opening that page in Settings ([memory processing §9.6](../domain/memory-processing.md#96-limits)).
- **Applied automatically:** one row per automatic change (what changed, when, the engine), with **Undo** for 30 days, and a disclosure with its before and after (v0.5); after later changes, "Undo this and N later changes", listing them.
- **Notification** after a tidy-up with results: "Funes applied 3 changes and has 2 for you to review." No memory text.

### Agents
- **Layout:** the sidebar lists the agents (see Sidebar); the page shows the selected one.
- **Header:** its icon (detected type), name (with a pencil to rename), status ("Connected · 2 min ago", "Waiting for first request", "Paused", "Access expired"), kind, and access summary ("Reads Low and below in 3 categories · asks first · knows your name"; with more profile fields, "· knows your name and 2 more"), with Pause or Resume and Remove….
- **Pending requests** from this agent sit under the header while any wait ("Claude Code · 3 memories · 13 min left", the task's first line while this session holds it, [Review…], Details); the agent's badge in the sidebar counts them. Activity shows every agent's, at the top.
- **Add Agent:** two tabs, **On This Mac** (agents found on this Mac first, "Show All 11 Agents") and **Cloud · Experimental** (Remote Access's state first, with Set Up Remote Access… while it's off). Names wrap instead of truncating, and the sheet scrolls rather than outgrow the screen. For an agent with one-click setup the button is **Add and Connect…**: the agent is added and its Connect tab shows the change to its settings at once; after Add, it suggests a first question to ask the agent. New agents start with Deny for the never-share categories.
- **Agent detail tabs:**
  - **Access:**
    - **Operations:** Read, Suggest and Write toggles, with plain explanations.
    - **Maximum sensitivity:** a slider from Public to Secret.
    - **Categories:** a table with one row per category and an Allow / — / Deny control. Shows "Empty allow list means all categories".
    - **Ask before sharing:** on by default. Turning it off shows a warning.
    - **Ask before saving:** shown only with Write.
    - **Access expires:** never, or a date.
    - **Let it ask for more access:** on or off.
    - **About you** (v0.5, [ADR-0026](../architecture/decisions/0026-about-you-profile.md)): a checkbox per profile field, each showing its current value dimmed ("Name · Martin Bereciartua", "Pronouns · he/him", "Location · not set"): Name (on for a new agent), Pronouns, Languages, Location, Time zone, Occupation. Caption: "Sent with every answer to <agent>'s requests, without asking. Edit them in Settings ▸ About You." A field that isn't set can still be ticked; it goes once it has a value. Disabled without Read ("Needs Read"). Saved with the rest of the tab, so it bumps the agent's revision like any access change.
    - If the agent changes elsewhere while the tab is open (Always Allow from a panel), an untouched editor shows the new access; an edited one says so and must be reviewed again before saving, so it can't undo the other change.
  - **Connect:**
    - one-click buttons (a changed file is backed up first; when the agent's own command replaces an existing entry, its settings file is backed up, removal must succeed, and a failed add puts the backup back);
    - snippets;
    - the launcher path;
    - Copy key (with a warning);
    - Rotate key.
  - **Cloud** (shown while Remote Access is on, or while the agent has cloud access):
    - **Allow cloud access:** off by default. The caption says where shared text goes ("Text you share with a cloud agent goes to its vendor's servers. Use one agent per cloud app, with only the access it needs."), then sums up what the agent can do from the internet ("Cloud agents can use this from the internet: reads Low and below, asks first"). Its access is the same as on this Mac; nothing here changes it.
    - **Agent:** a picker of cloud agents, marked Token or OAuth, with the MCP URL, the setup to copy and its steps (EK Bridge's cloud setups, in Funes's words). The steps point to this section's own buttons ("click Connect a Cloud App… below"), not to the screen the user is already on. A long agent name truncates in the picker rather than widening the section.
    - **Connected:** cloud apps signed in with OAuth, with when they connected and were last used, and **Revoke**.
    - **Connect a Cloud App…** opens pairing for this agent for 10 minutes. **Copy Remote Token…** (asks first; clears the clipboard after 90 s) and **Reset Remote Token…**.
    - Turning cloud access off asks first when the agent has a remote token or connected apps: they stop working at once.
  - **Activity:** this agent's log.
- **Header:** icon, name (Rename), status and the agent's kind ("claude.ai · Claude Desktop · mobile"), which goes under the status and wraps when the column is narrow. **Header actions:** Pause / Resume, Remove…, which move to a line of their own when they don't fit beside the name.
- **Add Agent**'s cloud tab has tiles (claude.ai, ChatGPT, Gemini Enterprise, the Anthropic and OpenAI APIs, Claude Code on the web, Cursor, Copilot, Devin). A tile creates an agent with cloud access on and the chosen starting access, then opens pairing or the token setup. With Remote Access off, it offers to set it up first.

### Remote Access (experimental)
Adapted from EK Bridge's Remote Access page. Cloud agents can't reach `127.0.0.1`, so a tunnel the user runs forwards them to a second port on this Mac.
- **Before setup:** what it does, that it's off by default, and what it means: "While Remote Access is on, cloud agents reach Funes Vault through a public address. What you share with them goes to their servers." [Set Up Remote Access…]
- **Guided setup**, four steps:
  1. **Choose a tunnel:** Tailscale Funnel (recommended: TLS ends on this Mac), Cloudflare Tunnel, ngrok, Cloudflare quick tunnel (testing only), other.
  2. **Start it:** **Turn On Remote Access** (asks first), then the tunnel's command to copy into Terminal. Funes never runs a tunnel. It checks every 3 s whether the tunnel runs and forwards to 47627, and moves on by itself.
  3. **Paste its address:** the public `https://` address, filled in when step 2 found it.
  4. **Test:** one request through the tunnel to Funes's own health URL: **Reachable**, or **Not reachable** with the reason.
- **Once set up:** the switch at the top, then rows for **Status** (Test), **Tunnel** (Running · forwards to 47627, Not running with its command, Wrong port, Not public; **Switch Tunnel…**), **Address** (Edit…), **MCP URL** (copy, Reset Path…), **Port** (47627), **Turn off automatically** (Never, 1 hour, 8 hours, 1 day) and **Keep this Mac awake while on power**. Below them, the agents with cloud access, each linking to its Cloud section.
- The sidebar row shows an **On** pill, or ⚠ **Down** while the tunnel in use isn't running.

### Activity
- **Columns:** time, agent or device, event, detail, result.
- **Example rows:**
  - "Shared 3 memories" · Approved by you
  - "Refused" · Category not allowed
  - "Suggested *Prefers Vitest*" · Waiting in Inbox. The title is looked up live; if the memory was deleted, the row shows "(deleted memory)".
- **Filters:** All, Shared, Suggestions, Problems, Remote Access; Agent ▾; Device ▾; Today / 7 days / 30 days / All.
- Rows from cloud agents carry a cloud icon and "via Remote Access". The detail pane shows the tunnel and forwarded address for the last 50 remote requests, kept in memory only.
- **Detail pane:**
  - the request id;
  - the task, for requests whose Share panel this session showed (the vault stores only a hash, so otherwise, and after relaunch, it shows "Task text not stored");
  - withheld counts by reason;
  - the profile fields that went ("Also sent: name, pronouns"; v0.5), names only;
  - fix links ("Allow Project Context for Cursor…");
  - what a change did (v0.5): for an automatic change and its undo, each memory it touched with a **New**, **Changed**, **Archived**, **Restored**, **Removed** or **Kept** (a duplicate's survivor) badge and a link to it, the old text struck through above the new, and kind, categories, sensitivity and expiry as "Low → Internal"; for a tidy-up run, its changes, each in a disclosure, and **Review Suggestions in the Inbox**; for an edit, an Inbox apply, an archive or a restore, its before and after from the memory's earlier versions, or "Changed: text, title" when none is kept. Automatic changes come from the undo log, so for 30 days; earlier versions for 90.
  - **×** at the top right closes the pane (clears the selection).
  - The pane is as tall as its content, up to 45% of the list, then scrolls.

### iPhone (v0.2)
*Built in task 5.2; in Release builds from v0.2 (task 5.9).*
- **Off state:** an **Allow iPhone access** switch, off by default, with "A paired iPhone can capture, search, edit and review the Inbox while it can reach this Mac. What it sends is end-to-end encrypted, and your vault stays on this Mac." While on, the listener's status ("Listening on port 47626", or the port in use).
- **Reachability:**
  - **Same Wi-Fi:** default; works at home.
  - **Tailscale:** shows "Tailscale detected · 100.x.y.z", or a link to set it up.
  - **Public tunnel:** advanced: the tunnel's public host, the URL to forward to `http://127.0.0.1:47626` (`https://<host>/r/<secret>`) and **Reset Path**. (EK Bridge's tunnel checklist later.)
- **Pair iPhone…** shows a sheet with:
  - the QR code;
  - a 5-minute countdown;
  - instructions: "On your iPhone, open Funes Vault, tap Pair with Mac and scan this code."
  - then "“Sam's iPhone” wants to pair", with the model, **Deny** and **Allow** (the second factor), and "Paired with “Sam's iPhone”."
- **Devices:** name, model, paired date, last seen, connection used, and **Remove…** (it revokes the device). At most five.

### Settings
*From v0.8 ([ADR-0030](../architecture/decisions/0030-settings-window.md), [Phase 11](../plans/phase-11-settings.md)). Until then Settings is a toolbar of nine tabs: About You, General, Capture, AI Models, MCP, iPhone, Data, Updates and Advanced, with the same controls ([Phase 11's control map](../plans/phase-11-settings.md#control-map) says where each goes).*

#### Window
```
┌──────────────────────────┬───────────────────────────────────────────────┐
│ ● ● ●                    │ ‹ Features   Daily tidy-up                    │  ← toolbar: back (on a page) and title
│ (MB) Martin Bereciartua  │                                               │
│      About You           │   grouped Form, as today                      │
│ ─────────────────────    │                                               │
│ ⚙ General                │                                               │
│ 🔔 Notifications          │                                               │
│ ✎ Capture & Shortcuts    │                                               │
│ AI                       │                                               │
│ ✦ Features               │                                               │
│ 🔑 Models & Accounts      │                                               │
│ 🛡 Privacy & Limits       │                                               │
│ CONNECTIONS              │                                               │
│ ⏚ Agent Server           │                                               │
│ ▯ iPhone                 │                                               │
│ VAULT                    │                                               │
│ ⛁ Data & Backups         │                                               │
│ ☰ Advanced               │                                               │
└──────────────────────────┴───────────────────────────────────────────────┘
```
- **Sidebar:** fixed width (210 pt), not collapsible (no sidebar toggle), no search field. It's a plain `List` beside the pane, since `NavigationSplitView`'s sidebar could still be dragged and collapsed ([Phase 11.0](../plans/phase-11-settings.md), [ADR-0030 §1](../architecture/decisions/0030-settings-window.md)). Each pane has a colored rounded-square icon (SF Symbols, as today's tab symbols). Group headers are plain labels (AI, Connections, Vault), not disclosure groups.
- **Profile row:** the initials of Call me or the given and family name (a person symbol while empty), the full name, and "About You" under it. While the profile is empty it reads "About You" alone.
- **Size:** 820×600 by default, at least 760×520; the frame is remembered (not in a development vault, as today).
- **Opening:** ⌘, the menu bar's Settings… and the main window's Settings… open the last pane shown, General the first time. A deep link opens its destination (below).
- **Pages:** a row with a chevron opens a page inside the pane. The toolbar shows "‹ <pane>" and the page's title; ⌘[ goes back. Back never leaves the pane. Choosing a pane in the sidebar, or reopening the window, shows that pane's top level.
- **Keyboard:** ↑↓ move in the sidebar when it has focus; Tab moves between the sidebar and the pane; Esc doesn't close the window (as today).
- **VoiceOver:** the sidebar is a list with the group names as headings; the profile row reads "About You, Martin Bereciartua". The back button reads "Back to Features".

#### Destinations
| Destination | Opens | Used by |
|---|---|---|
| `about-you` | About You | Agents ▸ Access ▸ About You…, the seed sheet |
| `general` | General | |
| `notifications` | Notifications | |
| `capture` | Capture & Shortcuts | |
| `ai.features` | AI ▸ Features | |
| `ai.features/new-memories` | its page | Capture's "New memories…" link, Inbox processing card |
| `ai.features/tidy-up` | its page | the tidy-up's errors (Inbox header, memory detail) |
| `ai.features/search-answers` | its page | search answers' errors in the Vault, the iPhone's hint |
| `ai.features/search-index` | its page | |
| `ai.accounts` | AI ▸ Models & Accounts | Add a Model… in any job picker |
| `ai.accounts/<account id>` | an account's page | "check the API key" / "not signed in" errors |
| `ai.privacy` | AI ▸ Privacy & Limits | the cap's HUD |
| `agent-server` | Agent Server | the launcher's "port in use" message names it |
| `iphone` | iPhone | |
| `data` | Data & Backups | the integrity-check notification |
| `advanced` | Advanced | the setup checklist's "brings it back" |

**Which link an error uses:** when a job fails because of its account (no key, not signed in, Codex not allowed, a CLI paused after a tool event), the account's page; otherwise the job's page. An account destination that no longer exists opens Models & Accounts.

The written path in strings is "Settings ▸ AI ▸ Features ▸ Daily tidy-up", "Settings ▸ AI ▸ Models & Accounts", "Settings ▸ Agent Server", and so on.

#### About You
What Funes and your agents call you (v0.5; [ADR-0026](../architecture/decisions/0026-about-you-profile.md)). Every field is optional. Opened from the profile row.
```
Name            [Martin      ] [Bereciartua   ]     (given · family, in the locale's order)
Call me         [Martin      ]  (placeholder: the given name)
Pronouns        [he/him      ]
Languages       English · Spanish        [+] [−]   (drag to reorder; the first is the one you write in most)
Location        [Lisbon, Portugal                ]
Time zone       Automatic (Europe/Lisbon) ▾
Occupation      [                                ]

Shared with agents
Name            Claude Code, Cursor and 2 more ⌄
Pronouns        Claude Code ⌄
Languages       Not shared
…               (one row per field)
Agents get only the fields you tick in each one's Access tab. New agents get your name.
```
- **Saves** when a field loses focus or Return is pressed, like the other panes. The secret scanner checks each field; a match keeps the old value, with the scanner's usual message under the field.
- **Prefill:** an empty profile shows the macOS account's name as the fields' placeholders, never as their values, so nothing is saved until the user types or clicks **Use "Martin Bereciartua"** (shown only when the account's name looks like a person's).
- **Shared with agents** has a row for every field: the agents that get it, by name (two, then "and N more"; all of them on hover), as a menu whose items open each agent's Access tab, or "Not shared". A removed agent isn't listed.
- **Languages:** a picker of the system's languages; **Time zone:** Automatic (following the Mac, shown in parentheses) or a searchable list of time zones.
- Logged in Activity as "Edited About you · Pronouns" (field names, no values).

#### General
```
Appearance                    [Automatic ▾]
  Automatic follows macOS.
Open Funes Vault at login     [●]
Show in Dock                  [ ]
  Funes Vault always stays in the menu bar. …

UPDATES
Check for updates every day   [●]
Last checked                  Today 09:12
                              [Check Now]
  Updates come from GitHub, signed for Funes Vault. …
Version                       0.7.0 (21)
```
- **Appearance:** Automatic, Light or Dark (FR-G-06). Automatic is the default. The choice applies at once to every window, panel, sheet and alert, and to the menu bar menu, and is kept across relaunches. The app menus (File, Edit…) follow the menu bar, as in every app. EK Bridge has the same setting with the same words.
- The login-approval line and errors as today. A copy that doesn't update shows today's "This copy of Funes Vault doesn't check for updates…" instead of the three update rows; Version stays.

#### Notifications
Today's four switches and "Notifications never include memory text.", moved from General unchanged.

#### Capture & Shortcuts
```
SHORTCUTS
Quick capture       [⌥⌘M]  [Turn Off]           [Try It]
  Opens the capture box from any app. …
Review Request      [⌃⌥⌘R] [Turn Off]
  Brings a waiting approval panel forward from any app, …

NEW CAPTURES
Sensitivity         [Let Funes propose it ▾]
  Funes proposes a title, kind and categories with the New memories model; you review every proposal in the Inbox.
  ↗ New captures are sent to Claude to suggest their fields, within the cloud limit.     (only with a cloud model)
  New memories…     (link to AI ▸ Features ▸ New memories)

FROM OTHER APPS
  Select text in any app, then choose Services ▸ Remember in Funes. It goes to your Inbox.
```
- **Sensitivity** is a minimum: "At least <level>" means no proposal, from rules or a model, goes below it.
- Both shortcut recorders as today ("Use ⌥⌘M" to restore, conflicts reported). The Review Request shortcut moves here from General.

#### AI ▸ Features
```
┌ New memories                     Claude · haiku  [Cloud]   › ┐
│   Proposes a title, kind and categories · Splits notes       │
├ Daily tidy-up                    Same model      [Cloud]   › ┤
│   Daily at 03:00 · Last run today, 4 suggestions             │
├ Search answers                   Apple on-device [On this Mac] › ┤
│   Only when you ask (⌘⏎)                                     │
├ Search index                                    [On this Mac] › ┤
│   Built in (bge-small) · Ready                               │
└──────────────────────────────────────────────────────────────┘
  Each feature uses a model from Models & Accounts.

REVIEW
Apply changes automatically       [Off ▾]
  (today's caption: what each level does, "Agents always follow their own access.", Undo for 30 days)

What leaves this Mac ›            (opens Privacy & Limits)
```
- **Row summaries** (second line):
  - New memories: "Proposes a title, kind and categories", then "· Splits notes" when split is on; with proposals off, "Splits notes" when split is on, or "Simple rules on this Mac".
  - Daily tidy-up: "Off", or "Daily at 03:00", then "· Last run today, 4 suggestions" or "· Not run yet".
  - Search answers: "Off", "Only when you ask (⌘⏎)", "Automatically for questions", "Automatically for every search".
  - Search index: "Built in (bge-small) · Ready", plus " · qwen3-embedding:0.6b (Ollama): Embedding 1,240 of 3,000" or "…: Ready".
- **Row trailing:** the effective model ("Claude · haiku", "Same model" when it follows New memories, "Apple on-device", "Rules only" for a tidy-up with no model) and its locality badge. When the job can't run as chosen, an orange label replaces both, from configuration only ([ADR-0030 §6](../architecture/decisions/0030-settings-window.md)): "Choose a model" (unresolved), "Needs a key", "Not signed in", "Needs your OK" (Codex), "Paused after a tool use", "Not available on this Mac" (Apple Intelligence).
- Search answers' row shows no model while Answer is Off.
- **Apply changes automatically:** Off (recommended) · Duplicates only · Everything except conflicts. A level whose engine hasn't reached its target precision is disabled (none has for New memories; the tidy-up's level follows its chosen model).

##### Page: New memories
```
Model             [Claude · haiku ▾] [Cloud]
  Ready. If it fails, Funes uses the on-device model, then rules.
  ↗ New memories sends new captures (up to Internal) and your category names and descriptions to Claude through your Claude Code sign-in. …
Propose a title, kind and categories   [●]
Split into separate memories           [●]
  (today's split caption)
```
- **Model** pop-up: Apple on-device; then, per configured account, a section with its name and its models ("haiku", "opus"), with why it can't run now after the name ("No key", "Not signed in"); then **Add a Model…**. A plan shows when its CLI is found or it's the current choice (today's rule). An account with no models shows "No models" (disabled). An unresolved choice shows "<account> · Choose a model".
- Status, disclosure, the split switch's availability and captions: today's text and rules, with the account and model the choice names.

##### Page: Daily tidy-up
```
Schedule          [Daily ▾] [03:00]        [Tidy Up Now]
Model             [Same as New memories ▾]
  (today's caption, with the last run or the estimate)
  ↗ The daily tidy-up sends related memories (up to Internal), with their dates and sources, to Claude.
```
- **Model** pop-up: Same as New memories; then the accounts' models; no Apple on-device (as today); Add a Model….
- Turning Daily on asks for notification permission, as today.

##### Page: Search answers
```
Answer            [Only when I ask ▾]
Model             [Same as New memories ▾] [Cloud]        (hidden while Off)
  Ready. Press ⌘⏎ in a search, or tap Ask on your iPhone. Each claim quotes the memory it came from, …
  ↗ Search answers send your search and its top results (up to Internal) to Claude …
```
- **Answer:** Off, the default · Only when I ask · Automatically for questions · Automatically for every search. **Model:** Same as New memories, Apple on-device, or an account's model, with the locality badge.
- **Status:** "Ready. Press ⌘⏎ in a search, or tap Ask on your iPhone."; with an automatic choice, "Ready. A search that's a question is answered after a short pause, on this Mac and your iPhone; press ⌘⏎ to ask about any other." or "Ready. Every search is answered after a short pause, on this Mac and your iPhone."; for Apple on-device "Apple's on-device model is slow on this Mac: answers may take 30 s or more." (or, with an automatic choice, "…too slow to answer on its own: it answers only when you ask…"); "Choose a model to answer searches."
- **Disclosure:** "Search answers send your search and its top results (up to Internal) to Claude through your Claude Code sign-in, when you ask. It counts toward your plan's limits."; with an automatic choice, "…when you ask or pause on a question." or "…each time you pause on a search.", and "Each answer counts toward your plan's limits and today's 300 cloud requests."

##### Page: Search index
Today's Embeddings rows (FR-AI-09, FR-AI-11): the built-in bge-small and its status; **Second index**: account (OpenAI-compatible accounts only) and model, Load Models, Use… with its confirmation; once chosen, its status, Cancel or Retry, Calibrate…, "Embed agent requests with the cloud model" and the disclosure line for a cloud model, and Stop Using…. "Provider model" is renamed **Second index**. **Use…** checks the model and asks to confirm with the memory and token counts; the status reads "Embedding 1,240 of 3,000. Search uses bge-small until it's done.", "Ready: …" or an error with **Retry**. A memory above the cloud limit says "Searched on this Mac only (above cloud limit)." on its page.

#### AI ▸ Models & Accounts
```
                                                  [Add Account ▾]
BUILT IN
Apple on-device    Used by: Search answers         Ready        [On this Mac]
bge-small          Used by: Search index           Ready        [On this Mac]  ›

YOUR PLANS
Claude (Claude Code)  Used by: New memories, Daily tidy-up   Signed in   [Cloud]  ›
ChatGPT (Codex)       Install Codex and sign in to use your ChatGPT plan.  Not installed  ›

API KEYS
Anthropic          Used by: none                   Key in Keychain  [Cloud]   ›

LOCAL SERVERS
Ollama             Used by: Search index           1 model      [Local server] ›

  Keys stay in this Mac's Keychain, never in the vault, exports or Activity.
```
- **Groups:** Built in, Your plans, API keys, Local servers. An OpenAI-compatible account goes under Local servers when its endpoint resolves local and isn't marked cloud, under API keys otherwise (cloud until resolved). Empty groups show one line: "None. Add one with Add Account…" (API keys, Local servers).
- **Row:** name; "Used by: …" (the jobs whose effective choice is this account, or "none"); the state ("Ready", "Key in Keychain", "No key", "Signed in", "Not signed in", "Not installed", "Update Codex to use it", "Off: needs your OK to read files" for Codex; for a local server, its number of models, or "No models"); the locality badge. Funes doesn't probe servers to fill this in: Test Connection is still the check.
- **Apple on-device** has no page; its state is "Ready" or "Not available on this Mac". **bge-small** opens Features ▸ Search index.
- **Add Account…** menu: Anthropic, OpenAI, Ollama, LM Studio (a preset already added is disabled, as today), then Other OpenAI-Compatible Server…. It opens today's add sheet (Name, Base URL, API key, It's a cloud service, a first **Model** with Load Models, Test Connection); **Add** saves and opens the new account's page. Plans aren't added: they're found on the Mac.

##### Account page: an API key or a local server
```
Anthropic                                         [Cloud]
  Key in Keychain · Ready

CONNECTION
Name          [Anthropic                 ]
Base URL      [https://api.anthropic.com ]
API key       [Saved; type to replace    ]
It's a cloud service  [ ]          (OpenAI-compatible only, with today's caption)

MODELS
claude-haiku-5-5                              [Remove]
claude-opus-5-5                               [Remove]
[Model name             ] [Load Models ▾] [Add]
  Chat models, for New memories, the tidy-up and search answers. Embedding models are chosen in Features ▸ Search index.

USED BY
New memories · claude-haiku-5-5    ›
Daily tidy-up · claude-opus-5-5    ›

TEST
[claude-haiku-5-5 ▾]  [Test Connection]
  Works: it proposed “Dentist on Tuesday” in 1.8 s.
  Test Connection classifies one made-up note …; none of your memories or category names are sent.

USAGE
412 requests · 1,203,550 tokens in · 80,112 out     [Reset Usage]

                                         [Remove Account…]
```
- **Connection fields save** when they lose focus or on Return, like About You; a base URL that isn't a URL keeps the saved one with a red line under it.
- **API key:** saves on Return or **Save Key**, never by leaving the field; leaving the page discards a key that wasn't saved. An empty field does nothing; **Remove Key** (shown while a key is saved) deletes it. If the Keychain refuses, "The key couldn't be saved in the Keychain." under the field, and the typed key stays until the page closes. The key is never shown.
- **Re-embedding:** among account edits, only a change to the address, key or cloud flag of the account the second index uses re-embeds. The name and the models don't. (The cloud limit, the embedding choice and Calibrate still re-embed, as today.)
- **Models:** an ordered list, no duplicates, each trimmed. **Add** takes the typed name; **Load Models** lists the server's models to add (`/v1/models`, or Anthropic's list). An embedding model typed here gets today's warning ("…is an embedding model: …choose it in Features ▸ Search index"). **Remove** on a model a job uses asks first: "Daily tidy-up uses claude-opus-5-5. Remove it? The tidy-up will use the same model as New memories."
- **Used by** rows open the job's page. With none: "No feature uses this account."
- **Test** uses the chosen model, as today's test.
- **Usage** counts this account only; Reset Usage resets this account.
- **Remove Account…** asks first, naming every job that uses it, directly or by following New memories, and the second index ("Its vectors are deleted and search uses bge-small alone."). It deletes the key and the usage, resets the jobs, and stops the second index if it's this account's.
- **Remove** on a model New memories uses also names the jobs that follow it: "Search answers follows New memories and will use Apple on-device."

##### Account page: a plan
```
Claude (Claude Code)                              [Cloud]
  Signed in to Claude Code 2.1.310

MODELS
haiku                                          [Remove]
opus                                           [Remove]
[Model name             ] [Add]
  Your plan decides which models you can use.

USED BY
New memories · haiku   ›

TEST
[haiku ▾]  [Test Connection]

USAGE
9 requests · 31,400 tokens in · 2,050 out          [Reset Usage]

  Uses your plan's limits, through the Claude Code you installed and signed in to. Funes never sees your sign-in. Your account's training setting applies.
  Claude Privacy Settings ↗
```
- The state line is today's (`SubscriptionRow.text`): "Not signed in: run `claude` in Terminal and sign in with Claude", "Claude Code isn't installed on this Mac", "Update Claude Code to use it", and so on. While not installed, the page shows the state, how to install, Usage with Reset Usage (counted before, kept), and the privacy link; Models, Used by and Test need the CLI and are hidden.
- **ChatGPT (Codex)** adds, above Models, today's switch "Use Codex even though it can read files on this Mac" and its warning. Off, its jobs can't use it and its row says so.
- A new plan's Models start with its suggestions; a plan can't have an empty list (its last model's Remove is disabled).

#### AI ▸ Privacy & Limits
```
Send memories to cloud models up to   [Internal (recommended) ▾]
  Applies to every cloud provider and every task. Text is checked on this Mac first, and anything that looks like a secret is never sent, whatever the limit.

Cloud requests per day                [300 ⌃⌄]
  Today: 12 of 300, agents 3 of 120. Shared by every task that uses a cloud model; …

WHAT AI FEATURES SEND
↗ New memories: new captures (up to Internal) and your category names and descriptions, to Claude through your Claude Code sign-in.
↗ Daily tidy-up: related memories (up to Internal), with their dates and sources, to Claude through your Claude Code sign-in.
⌂ Search answers: nothing; Apple on-device answers on this Mac.
⌂ Search index: memory text and your searches to Ollama, on your local network.
  Agents, Remote Access and your iPhone are in their own panes.
```
- **Cloud limit:** Public · Low · Internal (recommended) · Sensitive · Restricted · Everything, including Secret · Nothing; one limit for every task (ADR-0022); moving above Internal asks to confirm, naming the provider.
- **Cloud requests per day:** 300 by default; at the limit a HUD says so once a day.
- **What AI features send:** one line per job that can send anything, from the same facts as the job page's disclosure, prefixed with the job's name. A local account's line says where it runs ("on this Mac", "on your local network").
  - New memories: listed while proposals or splitting is on; with splitting, the split payload (captures, your answers, agents' suggestions and imports, each with up to 5 related memories).
  - Daily tidy-up: listed whenever it has a model, scheduled or not, ending "every day at 03:00" or "when you tidy up".
  - Search answers: listed while Answer isn't Off, with the effective trigger (Apple on-device answers only when asked).
  - Search index: the built-in index sends nothing; a second index's line follows the agent-request switch and the cloud limit, including Nothing ("your searches and agents' task descriptions, but no memory text").
  - With nothing listed: "AI features send nothing off this Mac."

#### Agent Server
Today's MCP tab, renamed, under the caption "The MCP server that agents on this Mac connect to.": Let agents connect, Status, **Port** (47625 by default; changing it says which agents need their setup again; Funes never moves on its own), Address, the port-in-use warning; Launcher (path, Link or Remove Link); Traffic since launch (counts only, never bodies).

#### iPhone
Unchanged from today (FR-P-01):
- **Allow iPhone access**, its caption and status line (listening, starting, the Keychain and port warnings).
- **Reach this Mac over:** Same Wi-Fi, Tailscale (with "Tailscale detected · <address>" or how to set it up) and Public tunnel, each a switch. With Public tunnel: **Public host** (saved on Return), the URL to forward to `http://127.0.0.1:<port>`, **Reset Path** and its caption ("A new path stops the old URL. Paired iPhones learn the new one when they pair again.").
- **Paired iPhones:** each with its detail line, **Remove…** (with its confirmation) and **Approve requests on this iPhone**; the notification note; **Pair iPhone…** (the QR sheet, Allow or Deny); the five-iPhones limit line.

#### Data & Backups
Today's Data tab, renamed: Backups (daily, keep 7, Back Up Now, Restore from Backup…), **Keep earlier versions for 90 days** (v0.5, on by default; turning it off asks first, "Stop keeping earlier versions?", and deletes them), Export and import, Data folder (Show in Finder), Erase All Data…. Restore from Backup relaunches; before the chosen backup replaces the vault, the current vault is saved as a self-contained `pre-restore-…` backup (an SQLite online backup, so nothing still in the WAL is lost).

#### Advanced
Unchanged: Activity retention (two steppers, Restore Defaults) and Show the Setup Checklist Again.

## Panels

All panels are non-activating floating `NSPanel`s at the top right. When several wait, one panel shows them one at a time, with a chip for each at the top ("Cursor · access · 0:13"), at most 3; later ones wait unseen ("+2 more").
- **Order:** items on a clock come first, soonest first; a Save panel, which waits for nothing, comes last. Once the user picks a chip or acts on an item, a more urgent arrival doesn't replace it under the cursor.
- **Arming:** buttons are disabled for 0.6 s after the content appears or changes.
- **Default button:** drawn prominent, and never a choice with lasting effect: Share N, Save, or Allow Once. Return and Esc work once the panel is key: after a click, or after **Review Request** (⌃⌥⌘R, or the menu's first item).
- **Countdown:** visible, and read as "41 seconds left" by VoiceOver.
- **Announcements:** one VoiceOver announcement for everything that arrived together, with the time to answer and the shortcut ("Cursor wants to read Project context. 38 seconds to answer. Control-Option-Command-R to review.").
- Panels never take keyboard focus from the frontmost app by themselves.

### <agent> wants N memories (Share)
```
┌─────────────────────────────────────────────────────┐
│ ⟡ Claude Code wants 4 memories                      │
│ ┌ Goes to ────────────────────────────────────────┐ │
│ │ Claude Code on this Mac. It may send what it    │ │
│ │ reads to its AI service.                        │ │
│ └─────────────────────────────────────────────────┘ │
│ ▍The agent says · not checked by Funes              │
│ ▍Task          "Set up a new TypeScript repo…"      │
│ ▍Looking for   package manager, test framework, …   │
│ ▍Purpose       "scaffold project"                   │
│ ▍Keeps what it gets   For the session               │
│ Your note      Keeps what it gets: Not at all       │
│ ☑ Prefers pnpm and Vitest                    LOW    │
│   Use pnpm for packages and Vitest for tests…       │
│ ☑ Repo conventions                           LOW    │
│ ☑ Current project: Funes                  INTERNAL  │
│ Also matched, less closely                          │
│ ☐ Writes Swift 6                             LOW    │
├─────────────────────────────────────────────────────┤
│ 2 more matched but can't go to this agent (…).      │
│ 0:41  More Time               [ Deny ]  [ Share 3 ] │
└─────────────────────────────────────────────────────┘
```
- **Goes to** is built only from what Funes knows. Local agent: "<agent> on this Mac. It may send what it reads to its AI service." Cloud agent: "claude.ai, through your Tailscale Funnel, to Anthropic's servers", with a **Cloud** chip; the vendor comes from a fixed table of cloud agents, the tunnel from Remote Access ("a cloud agent, through Remote Access" when either is unknown).
- **The agent says** holds everything the agent supplied: the task, its `keywords` ("Looking for"), purpose, how long it says it keeps what it gets, and who it says it shares with (`processors`). Long values are cut to about two lines with "Show all". None of it decides anything.
- **Your note** is the user's own "Keeps what it gets" from the agent's Access tab, when set.
- **About you** (v0.5): a line above the buttons when the agent's answer carries profile fields: "Claude Code also has your name and pronouns, as set in its Access." It isn't tickable, and **Deny** doesn't take it back: the answer that started the request already carried it ([access policy §3.10](../domain/access-policy.md#310-the-profile)). "its Access" is a link to the agent's Access tab.
- **Strong matches are ticked; weaker ones are offered unticked** under "Also matched, less closely" (access policy §3.2).
- The body text is clipped to 3 lines (at most 160 characters), with "Show all" to expand. The text is the exact text that will be sent, and every row whose text is cut offers "Show all", so everything Share would release can be read first.
- The panel is never taller than the screen's visible area: the title and the buttons stay in place and the rows between them scroll.
- Opening a pending request again (from the menu bar panel's Review, Pending requests or an agent's `open_in_funes`) refreshes the same panel. Rows whose memory is unchanged keep the user's ticks. If anything that would be shared changed, the buttons arm again. It counts down to the end of its 15 minutes ("9:05").
- **More Time** moves the request to Pending requests at once (a HUD says until when). On timeout the HUD says "No answer: Claude Code was told to wait. It's in Pending requests."

### Save this memory?
- Shows: from <agent>; the memory (title and body) first; then kind, category and sensitivity; then the agent's "Why" in the agent-says block.
- Buttons: Edit… (a link) · Discard · Later · **Save**. No countdown: it's in the Inbox either way.
- **Later for all N suggestions** (a link on its own line) when more than one Save panel waits, shown or behind "+N more": answers each Later, so all of them stay in the Inbox. Share and access panels stay, since an agent waits on them.
- **Answered elsewhere, gone here** (FR-S-02): a panel whose suggestion was saved, rejected or split in an Inbox (the iPhone's or the Mac's), expired or deleted is withdrawn at the next vault change, quietly (no HUD), and its iPhone doorbell is taken back.
- **Waits for New memories processing** (v0.3, memory processing §5.6): with splitting on, no panel shows while the suggestion is processing. When it's done, one panel per resulting piece, queued with the chips ("+4 more"), or one for the suggestion when nothing changed or the split failed. The arrival notification comes once. Opening a processing suggestion (`open_in_funes`) shows its Processing… card in the Inbox. With splitting off, the panel shows at once.

### <app> wants to connect (cloud sign-in)
- Shown only while pairing is open for one agent. Example: "**Claude** wants to connect as **claude.ai**", with the app's metadata URL, "Returns to claude.ai", and the six-digit code the browser shows ("482 913", read digit by digit by VoiceOver).
- Text: "Allow only if this code matches the one in your browser. It will use claude.ai's access." Shows when pairing ends ("Until 10:52").
- Buttons: Deny (Esc) · Allow (armed after 1 s, no Return key: the codes must be compared). A second sign-in waits until this one is answered.

### <agent> wants to read <category>
- Example: "**Cursor wants to read Project context**", with the task in the agent-says block, and: "Allow Once is for this request only. Next, you'll see exactly what would be shared." (for an agent that shares without asking: "…so the matching memories go to it at once").
- Buttons: Not Now (Esc) · **Allow Once** (the default). **Always Allow Cursor to Read Project context** is a link on its own line, never the default.
- When the agent already got an answer (shared without asking): Not Now and the Always Allow link only, with no default (access policy §7).
- A panel that runs out or is withdrawn counts as unanswered: Funes may ask again on the next request, while Not Now waits an hour.

## Content style (applies to both apps)
Use the words in the [glossary](06-glossary.md): one word for each thing, with the words it replaces.
- **Plain words:** "Share", "Save", "Agent", "Memory", "Inbox", "Paused", not "disclosure", "policy" or "client" in the UI. Those terms appear only in docs and in the API.
- **Name the agent and the exact action:** "Claude Code can't add to Health", not "Permission denied".
- **Numbers over adjectives:** "2 more matched but aren't allowed", "3 captures waiting".
- **Never claim more security than there is:** "Encrypted between your iPhone and your Mac", not "military-grade".
- **Agent-provided text is always labelled:** "(as reported)", "Purpose given by the agent".
