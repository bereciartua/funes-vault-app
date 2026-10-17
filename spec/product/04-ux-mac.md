# UX: Funes Vault for Mac

Funes is a menu bar app (`LSUIElement`) with one main window and floating panels. The structure deliberately mirrors EK Bridge so both apps feel like siblings: a menu bar first, a setup checklist, the main window's sections, panels at the top right, and Activity.

## Surfaces at a glance

```
Menu bar icon ─┬─ Menu ─────────────── Remember… · Inbox (3) · Pending requests · Pause Funes Vault · Open Funes Vault · Updates · Quit
               ├─ Capture box ───────── (⌥⌘M) quick capture
               └─ Panels (top right) ── Share with <agent>? · Save this memory? · <agent> wants more access
Main window ───┬─ Vault        (memories: list + detail)
               ├─ Inbox        (suggestions to review)
               ├─ Agents       (connections: access, connect, activity)
               ├─ Activity     (log)
               ├─ iPhone       (v0.2: pairing, devices, reachability)
               └─ Settings     (general, capture, MCP, data, updates, advanced)
```

## Menu bar

**Icon states:**

| State | Look | Meaning |
|---|---|---|
| Normal | outline "f." glyph | on, nothing waiting |
| Needs you | filled glyph with an accent dot | a panel is open, or requests or suggestions are waiting |
| Paused | glyph with a slash | Funes or the MCP server is paused |
| Off | dimmed glyph | MCP server off (before setup) |

**Menu:**
```
Funes Vault is on · 3 agents
──────────────────────
Remember…                         ⌥⌘M
Inbox                               3
Pending requests                    1   ▸  Claude Code · 2 min left
──────────────────────
Pause Funes Vault                            ▸  For 1 Hour · Until Tomorrow · Until I Resume
Open Funes Vault                          ⌘O
──────────────────────
Check for Updates…
Quit Funes Vault                          ⌘Q
```
- The first line opens the main window on the Agents section.
- A pending request item opens its panel again.

## Capture box
- **Window:** a small borderless window centred near the top of the screen, like Spotlight. It has:
  - a multi-line text field with the placeholder "What should Funes remember?";
  - a footer with "⏎ Save · ⇧⏎ New line · Esc Cancel".
- **On save:**
  - The box closes and a brief HUD says "Saved to Inbox".
  - Classification runs in the background and fills in the proposed fields.
- **If the secret scanner matches:** the box stays open with an inline error ("This looks like an API key. Funes never stores secrets.") and nothing is saved.

## Main window

A sidebar plus a content area, with a minimum size of 860×560.

### Setup checklist (until complete)
A card at the top of the Vault:
1. **Seed your vault**: "Answer a few questions or import from ChatGPT or Claude." [Start]
2. **Review your Inbox**: "Apply what's right." [Open Inbox]
3. **Add an agent**: tiles for detected agents. [Add]
4. **Connect it**: [Add to Claude Code…] / [Show setup]. The step completes when the first request arrives ("Claude Code connected 10:42").

### Vault
- **Toolbar:**
  - search field (⌘F);
  - filter pop-ups (Category, Kind, Sensitivity, Status, Source);
  - sort;
  - **+ New Memory** (⌘N).
- **List row:**
  - title;
  - one-line body preview;
  - category chips;
  - a sensitivity badge, colored by level, with text;
  - kind icon;
  - "expires in 3 days" or "Expired" when relevant;
  - updated time.
- **Detail** (right pane or sheet):
  - **Fields:** title, body (plain text, up to 10,000 characters, with a counter), kind, categories (token field), sensitivity (segmented control with a one-line explanation), expiry (date picker, with "never").
  - **Shared with:** "Shared 4 times · last with Claude Code yesterday", with a link to filtered Activity.
  - **Provenance timeline:** created, edited, archived, shared, suggested by. Rows hold labels only.
  - **Actions:** Archive / Restore, Delete, "Still true" (confirm).
- **Empty state:** "Your vault is empty. Answer a few questions to get started, or press ⌥⌘M anytime to remember something."

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
- **Sections:** From agents · Captures · Imports · (later) Cleanup suggestions.
- **Item card:**
  - source line ("Suggested by Claude Code · 10:31", "Captured on iPhone · yesterday", "Imported from ChatGPT");
  - proposed title and body, editable inline;
  - proposed kind, categories and sensitivity;
  - evidence, if the agent provided it, shown as quoted data;
  - a duplicate hint, when it applies;
  - the engine that proposed the fields ("Proposed on this Mac", "Proposed by Claude via Anthropic", "Kept on this Mac: looked sensitive").
- **Actions:** Apply (⌘⏎), Reject (⌫), Later. Multi-select gives "Apply 12" and "Reject 12".
- **Correction suggestions:** when a suggestion references an existing memory, the card shows a diff (old → new) with **Replace** and **Keep both**.

### Agents
- **List:** each agent shows its icon (detected type), name, status ("Connected · 2 min ago", "Waiting for first request", "Paused", "Access expired") and access summary ("Reads Low and below in 3 categories · asks first").
- **Agent detail tabs:**
  - **Access:**
    - **Operations:** Read, Suggest and Write toggles, with plain explanations.
    - **Maximum sensitivity:** a slider from Public to Secret.
    - **Categories:** a table with one row per category and an Allow / — / Deny control. Shows "Empty allow list means all categories".
    - **Ask before sharing:** on by default. Turning it off shows a warning.
    - **Ask before saving:** shown only with Write.
    - **Access expires:** never, or a date.
    - **Let it ask for more access:** on or off.
  - **Connect:**
    - one-click buttons;
    - snippets;
    - the launcher path;
    - Copy key (with a warning);
    - Rotate key.
  - **Activity:** this agent's log.
- **Header actions:** Pause / Resume, Remove…

### Activity
- **Columns:** time, agent or device, event, detail, result.
- **Example rows:**
  - "Shared 3 memories" · Approved by you
  - "Refused" · Category not allowed
  - "Suggested *Prefers Vitest*" · Waiting in Inbox. The title is looked up live; if the memory was deleted, the row shows "(deleted memory)".
- **Filters:** All, Shared, Suggestions, Problems; Agent ▾; Device ▾; Today / 7 days / 30 days / All.
- **Detail pane:**
  - the request id;
  - the task, shown during the session only (stored as a hash, so after relaunch it shows "Task text not stored");
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
- **General:** launch at login, show in Dock, notifications.
- **Capture:** hotkey, default sensitivity for captures, classification on/off.
- **AI Models:**
  - **Tasks:** Embeddings (v0.1: "Built in (bge-small, on this Mac)", no choice; other models later), Classification (later Consolidation). Each has a provider pop-up with a locality badge (On this Mac · Local server · Apple cloud · Cloud), a model pop-up, and a status ("Ready", "Re-embedding 1,240 / 3,000", "Unavailable: using on-device").
  - **Providers:** add or edit (base URL, API key stored in the Keychain, local or cloud), **Test connection**, usage counters.
  - **Cloud limit:** "Never send memories above **Internal** to cloud models".
  - **Embedding options** (later): "Embed agent requests with the cloud model", shown when the embedding model is in the cloud.
  - **Disclosure:** a sentence under every non-local choice saying exactly what is sent where.
  - **Calibrate…** (later) for embedding models Funes doesn't know.
- **MCP:** server on/off, port (47625), launcher location, protocol log counts (no bodies).
- **Data:** backups, export, import, Show in Finder, Erase All Data.
- **Updates:** automatic checks, Check Now.
- **Advanced:** activity retention, reset the setup checklist.

## Panels

All panels are non-activating floating `NSPanel`s at the top right, stacked if more than one, with a maximum of 3 visible. Their buttons are disabled for about 0.5 s after appearing ("arming"). They show a visible countdown, are announced by VoiceOver, and never take keyboard focus from the frontmost app unless clicked.

### Share with <agent>?
```
┌─────────────────────────────────────────────────────┐
│ ⟡ Share with Claude Code?                     0:41 │
│ Task: "Set up a new TypeScript repo following the   │
│ user's preferences"                                 │
│ Looking for: package manager, test framework, …     │
│ Purpose (as reported): "scaffold project"           │
│ Keeps it: for this session                          │
├─────────────────────────────────────────────────────┤
│ ☑ Prefers pnpm and Vitest                    LOW    │
│   Use pnpm for packages and Vitest for tests…       │
│ ☑ Repo conventions                           LOW    │
│   Conventional commits, MIT license, …              │
│ ☑ Current project: Funes                  INTERNAL  │
│   Rewriting Funes as a native menu bar app…         │
│ ☐ Work hours                              INTERNAL  │
│   Focus time 9–12, no meetings…                     │
├─────────────────────────────────────────────────────┤
│ 2 more matched but aren't allowed for Claude Code.  │
│                         [ Deny ]   [ Share 3 ]      │
└─────────────────────────────────────────────────────┘
```
- The body text is clipped to 3 lines, with "Show all" to expand. The text is the exact text that will be sent.
- On timeout the panel says "No answer: Claude Code was told to wait" and moves to Pending requests.

### Save this memory?
- Shows: from <agent>, title, body, kind, categories, sensitivity, evidence (as quoted data).
- Buttons: Discard · Later · Edit… · Save.
- On timeout: "Saved to Inbox for later".

### <agent> wants more access
- Example: "Cursor can't read **Project Context**. It asked for context for: <task>."
- Buttons: Not Now · Allow Once · Always Allow.

## Content style (applies to both apps)
- **Plain words:** "Share", "Save", "Agent", "Memory", "Inbox", "Paused", not "disclosure", "policy" or "client" in the UI. Those terms appear only in docs and in the API.
- **Name the agent and the exact action:** "Claude Code can't add to Health", not "Permission denied".
- **Numbers over adjectives:** "2 more matched but aren't allowed", "3 captures waiting".
- **Never claim more security than there is:** "Encrypted between your iPhone and your Mac", not "military-grade".
- **Agent-provided text is always labelled:** "(as reported)", "Purpose given by the agent".
