# UX: Funes Vault for Mac

Funes is a menu bar app (`LSUIElement`) with one main window and floating panels. The structure deliberately mirrors EK Bridge so both apps feel like siblings: a menu bar first, a setup checklist, the main window's sections, panels at the top right, and Activity.

## Surfaces at a glance

```
Menu bar icon ─┬─ Menu ─────────────── Remember… · Inbox (3) · Pending requests · Pause Funes Vault · Open Funes Vault · Updates · Quit
               ├─ Capture box ───────── (⌥⌘M) quick capture
               └─ Panels (top right) ── <agent> wants N memories · Save this memory? · <agent> wants to read <category> · <app> wants to connect
Main window ───┬─ Vault        (memories: list + detail)
               ├─ Inbox        (suggestions to review)
               ├─ Agents       (connections: access, connect, cloud, activity)
               ├─ Remote Access (cloud agents through your tunnel; experimental, off by default)
               ├─ Activity     (log)
               ├─ iPhone       (v0.2: pairing, devices, reachability)
               └─ Settings     (general, capture, MCP, data, updates, advanced)
```

## Menu bar

**Icon states:**

| State | Look | Meaning |
|---|---|---|
| Normal | outline eye (the app icon's almond and iris) | on, nothing waiting |
| Needs you | filled eye with an accent dot | a panel is open, or requests or suggestions are waiting |
| Paused | eye with a slash | Funes or the MCP server is paused |
| Off | dimmed eye | MCP server off (before setup) |
| Remote Access on | any of the above, plus a small globe | the Remote Access listener is on |

**Menu:**
```
Review Cursor's Request · 0:13…                ⌃⌥⌘R   (only while something waits for you)
──────────────────────
Funes Vault is on · 3 agents
──────────────────────
Remember…                         ⌥⌘M
Inbox                               3
Pending requests                    1   ▸  Claude Code · 2 min left
──────────────────────
Remote Access on · 2 cloud agents            (only while on; "· tunnel down" when the tunnel isn't running)
Turn Off Remote Access
──────────────────────
Pause Funes Vault                            ▸  For 1 Hour · Until Tomorrow · Until I Resume
Open Funes Vault                          ⌘O
──────────────────────
Check for Updates…
Quit Funes Vault                          ⌘Q
```
- While a panel or a pending request waits, the first item reviews it: it brings the panel forward and makes it key, so Return and Esc answer it. Its shortcut, **Review Request** (⌃⌥⌘R by default, changeable in Settings ▸ General), works from any app.
- The status line opens the main window on the Agents section.
- A pending request item opens its panel again.

## Capture box
- **Window:** a small borderless window centred near the top of the screen, like Spotlight. It has:
  - a multi-line text field with the placeholder "What should Funes remember?";
  - a footer with "⏎ Save · ⇧⏎ New line · Esc Cancel" and where the text goes: "Goes to your Inbox", or, while a cloud model proposes the fields, "Goes to your Inbox · fields suggested by Anthropic" with a **Cloud** chip (principle 7).
- **On save:**
  - The box closes and a brief HUD says "Saved to Inbox".
  - Classification runs in the background and fills in the proposed fields.
- **If the secret scanner matches:** the box stays open with an inline error ("This looks like an API key. Funes never stores secrets.") and nothing is saved.

## Main window

A sidebar plus a content area, with a minimum size of 860×560. Every section fits at that size, with the sidebar at any width it allows (180–260): nothing runs off the right edge. The UI-review build shows each section at the minimum size, shrunk from the default as a user would (`*-min` snapshots).

Warnings are an orange icon with primary text, never orange text, which is under 3:1 on white. Text on a colored badge is primary; the color is in the fill. Text aims for 4.5:1 or better, and Increase Contrast strengthens fills, borders and the warning orange.

### Setup checklist (until dismissed)
A card at the top of the Vault, connecting first:
1. **Connect an agent**: "Found on this Mac: Claude Code, Cursor". [Add…]
2. **Approve its first request**: [Add to Claude Code…] / [Show Setup]. "Ask it something. Funes shows you exactly what it would share." The step completes when the first request arrives ("Claude Code connected 10:42").
3. **Seed your vault**: "Answer a few questions or import from ChatGPT or Claude." [Start]
4. **Review your Inbox**: "Apply what's right." [Open Inbox]
- The first unfinished step's button has the initial keyboard focus (never Hide). Hide leaves "Setup checklist hidden. Settings ▸ Advanced brings it back. [Undo]" for 10 seconds.

### Vault
- **Toolbar:**
  - search field (⌘F);
  - filter pop-ups (Category, Kind, Sensitivity, Status, Source);
  - sort (its "Sort by" label drops when the window is too narrow for it);
  - **+ New Memory** (⌘N).
- **List row:**
  - title;
  - one-line body preview;
  - category chips;
  - a sensitivity badge, colored by level in its fill, with the level's name in primary text;
  - kind icon;
  - "expires in 3 days" or "Expired" when relevant;
  - updated time.
- **Detail** (right pane or sheet):
  - **Fields:** title, body (plain text, up to 10,000 characters, with a counter), kind, categories (token field), sensitivity (segmented control with a one-line explanation), expiry (date picker, with "never").
  - **Shared with:** "Shared 4 times · last with Claude Code yesterday", with a link to filtered Activity.
  - **Provenance timeline:** created, edited, archived, shared, suggested by. Rows hold labels only.
  - **Actions:** Archive / Restore, Delete, "Still true" (confirm). In Recently Deleted: Restore and **Delete Now…**, which asks first ("Delete this memory now?"), from the detail, the list's context menu and the bulk bar alike.
- **Empty state:** "Your vault is empty. Answer a few questions to get started, or press ⌥⌘M anytime to remember something."
- **First run** (no memories yet, nothing filtered): the checklist, then a welcome instead of the toolbar, list and detail: "Your memory, shared only as you allow", three lines on the promise (the vault stays on this Mac; each agent gets only the access you give it and you see the exact text first; Activity records every request, without the text), [Answer a Few Questions…] [New Memory…] "or press ⌥⌘M in any app".

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
- **Sections:** From agents · Captures · Imports · Your answers (seed questions) · (later) Cleanup suggestions. Expired suggestions (FR-I-05) sit at the end with Restore.
- **Item card:**
  - source line ("Suggested by Claude Code · 10:31", "Captured on iPhone · yesterday", "Imported from ChatGPT");
  - proposed title and body, editable inline;
  - proposed kind, categories and sensitivity;
  - evidence, if the agent provided it, shown as quoted data;
  - a duplicate hint, when it applies;
  - the engine that proposed the fields ("Proposed on this Mac", "Proposed by Claude via Anthropic", "Kept on this Mac: looked sensitive").
- **Apply stores exactly what the card shows.** A card the user hasn't edited follows background classification; an edited one keeps the user's values.
- **Actions:** Apply (⌘⏎), Reject (⌫ when no field is being edited, ⌘⌫ anytime), Later. Click a card to make it the one the keys act on. Multi-select gives "Apply 12" and "Reject 12", with per-item results ("12 applied, 1 blocked by the secret scanner").
- **Correction suggestions:** when a suggestion references an existing memory, the card shows a diff (old → new) with **Replace** and **Keep both**.

### Agents
- **Layout:** the list is 220 pt wide at the window's minimum width, growing to 300; the detail takes the rest. **Add Agent…** shows only its icon when the list is too narrow for its label.
- **List:** each agent shows its icon (detected type), name, status ("Connected · 2 min ago", "Waiting for first request", "Paused", "Access expired") and access summary ("Reads Low and below in 3 categories · asks first").
- **Pending requests** sit above the list while any wait ("Claude Code · 3 memories · 13 min left", the task's first line while this session holds it, [Review…]); the sidebar's Agents badge counts them. Activity shows them too, with Details.
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
- The sidebar label shows **On**, or ⚠ **Down** while the tunnel in use isn't running.

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
  - fix links ("Allow Project Context for Cursor…").

### iPhone (v0.2)
- **Off state:** "Use Funes on your iPhone to capture and search your vault." [Turn On]
- **Reachability:**
  - **Same Wi-Fi:** default; works at home.
  - **Tailscale:** shows "Tailscale detected · 100.x.y.z", or a link to set it up.
  - **Public tunnel:** advanced; reuses EK Bridge's tunnel checklist.
- **Pair iPhone…** shows a sheet with:
  - the QR code;
  - a 5-minute countdown;
  - instructions: "Open Funes Vault on your iPhone and tap Pair with Mac".
- **Devices:** name, model, paired date, last seen, connection used, and Revoke.

### Settings
- **General:** launch at login, show in Dock, the Review Request shortcut (⌃⌥⌘R), notifications.
- **Capture:** hotkey, default sensitivity for captures ("At least <level>": a minimum no proposal, rules or model, goes below), classification on/off. With a cloud classifier it says "New captures are sent to <provider> to suggest their fields, within the cloud limit in AI Models."
- **AI Models:**
  - **Tasks:** Embeddings (v0.1: "Built in (bge-small, on this Mac)", no choice; other models later), Classification (later Consolidation). Each has a provider pop-up with a locality badge (On this Mac · Local server · Apple cloud · Cloud), a model pop-up, and a status ("Ready", "Re-embedding 1,240 / 3,000", "Unavailable: using on-device").
  - **Providers:** add or edit (base URL, API key stored in the Keychain, local or cloud), **Test connection**, usage counters.
  - **Cloud limit:** "Never send captures above **Internal**" (in v0.1 only captures are classified; the limit covers anything a later version sends).
  - **Embedding options** (later): "Embed agent requests with the cloud model", shown when the embedding model is in the cloud.
  - **Disclosure:** a sentence under every non-local choice saying exactly what is sent where.
  - **Calibrate…** (later) for embedding models Funes doesn't know.
- **MCP:** server on/off, port (47625 by default; changing it says which agents need their setup again), launcher location, protocol log counts (no bodies).
- **Data:** backups, export, import, Show in Finder, Erase All Data. Restore from Backup relaunches; before the chosen backup replaces the vault, the current vault is saved as a self-contained `pre-restore-…` backup (an SQLite online backup, so nothing still in the WAL is lost).
- **Updates:** automatic checks, Check Now.
- **Advanced:** activity retention, reset the setup checklist.

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
- **Strong matches are ticked; weaker ones are offered unticked** under "Also matched, less closely" (access policy §3.2).
- The body text is clipped to 3 lines (at most 160 characters), with "Show all" to expand. The text is the exact text that will be sent, and every row whose text is cut offers "Show all", so everything Share would release can be read first.
- The panel is never taller than the screen's visible area: the title and the buttons stay in place and the rows between them scroll.
- Opening a pending request again (from the menu, Pending requests or an agent's `open_in_funes`) refreshes the same panel. Rows whose memory is unchanged keep the user's ticks. If anything that would be shared changed, the buttons arm again. It counts down to the end of its 15 minutes ("9:05").
- **More Time** moves the request to Pending requests at once (a HUD says until when). On timeout the HUD says "No answer: Claude Code was told to wait. It's in Pending requests."

### Save this memory?
- Shows: from <agent>; the memory (title and body) first; then kind, category and sensitivity; then the agent's "Why" in the agent-says block.
- Buttons: Edit… (a link) · Discard · Later · **Save**. No countdown: it's in the Inbox either way.

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
