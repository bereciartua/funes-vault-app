# Words in the app

One word for each thing the user sees, in both apps. The copy pass over `Apps/FunesMac/Localizable.xcstrings` applies this page, and new strings follow it. It comes from the UX review's findings F17, F23 and F24 (work package WP4). The [domain glossary](../domain/glossary.md) defines the model behind these words. This page decides what the UI calls them.

**How to read the tables:**
- **Use:** the one word to use.
- **Stop using:** the words it replaces in the UI.
- **Where:** the screens it appears on, with the number of catalog strings found by a case-insensitive grep of the 1,331 strings on `main` at 6f7d11a.

The [content style](04-ux-mac.md#content-style-applies-to-both-apps) still applies: plain words, name the agent and the exact action, numbers over adjectives, never claim more security than there is, and always label agent-provided text.

**Pending decisions.** Three entries use a recommended choice that the owner hasn't confirmed yet, marked **D1–D3**. If a decision goes the other way, change the entry before the copy pass.
- **D1:** keep the level name *Secret*, and describe what the scanner catches instead ("passwords and keys").
- **D2:** *agent server* is the one name for the server.
- **D3:** *Save* / *Reject* answer a suggestion everywhere.

## Kept as they are (API, docs and other apps)
- **The API and agent-facing text keep their words:**
  - reason codes (`above_sensitivity_ceiling`, `denied_category`, `funes_paused`, `secret_like_content`…);
  - tool names (`suggest_memory`…);
  - sensitivity values (`secret`…);
  - key prefixes (`fns_mcp_v1_`, `fns_mcpr_v1_`, `fns_oat_v1_`, `fns_ort_v1_`, `fns_ocs_v1_`);
  - the messages agents receive (`FunesMCP/Messages.swift`, e.g. "Funes Vault is paused.").
  The UI translates them; it never shows them raw.
- **Other apps' labels are quoted exactly** when a step says where to click: "MCP server" (9 strings), "Add custom connector", "Client secret", "Header key", "Agents secret", "API credential". Introduce them as the other app's words: "In ChatGPT, … Create custom MCP server".
- **The spec, ADRs and plans** may keep their technical terms ("secret path", "maximum sensitivity", "MCP server"). They should use this page's word when they quote UI text.

## Sensitivity
| Use | Stop using | Means | Where |
|---|---|---|---|
| **Secret** (the level) **D1** | n/a | The top sensitivity level. Never shared unless you raise an agent's sensitivity limit to Secret. | Sensitivity picker, badges, the level's explanation (2) |
| **looks like a password or key** **D1** | "secret", "secrets", "secret scanner", "Funes never stores secrets" | Text matching the scanner's patterns: passwords, API and agent keys, private keys, sign-in tokens, card numbers. It's never saved and never sent to a cloud model. Say what matched, not "never": the scanner works on patterns. Example: "This looks like an API key. Funes doesn't save text that looks like a password, key or card number." | Capture box, Inbox results, Import, Privacy & Limits, Activity (8) |
| **sensitivity limit** | "Maximum sensitivity", "ceiling", "limit" alone | The highest level one agent can read. Set per agent, in Access. Buttons name it in full: "Raise Cursor's Sensitivity Limit…". | Access editor (2), Secret's explanation (1), Activity (3) |
| **cloud limit** | "Never send memories above" | The highest level Funes sends to a cloud AI model. One for all providers, in Privacy & Limits. It filters captures too, so the row reads "Never send captures above" (F6). | Privacy & Limits, Capture & Shortcuts (4) |

## Keys and sign-ins
| Use | Stop using | Means | Where |
|---|---|---|---|
| **agent key** | "key" alone, "Refused keys" | The `fns_mcp_v1_…` key one agent on this Mac uses, kept in its key file. The traffic count becomes "Requests with a wrong key". | Connect tab, Settings ▸ Agent Server, Remove and Erase (41 strings say "key") |
| **remote token** | "Token" (the Cloud tab's pill), "credentials" | The `fns_mcpr_v1_…` token a cloud agent sends in its Authorization header. One per agent. | Cloud tab, Remote Access, setup steps (21) |
| **API key** | "key" alone | The key you give Funes for a cloud AI model provider. Stored in the Keychain on this Mac. | Models & Accounts (6) |
| **Client ID**, **Client secret** | "Copy Secret", "the secret" | OAuth values for a cloud app that asks you to type them in. The cloud app's own fields use these words, so they stay. The button becomes "Copy Client Secret". | Cloud tab ▸ Set Up OAuth Client… (4) |
| **random path** | "secret path" | The random part of the Remote Access URL. It makes the URL hard to guess, but it isn't a password: the tunnel provider can see it. "Reset Path…" stays. | Remote Access (6) |
| *(none)* | "credentials", "No credentials yet" | Name what the agent has: "No remote token or cloud app yet". | Remote Access list (1) |

## Agents and the cloud
| Use | Stop using | Means | Where |
|---|---|---|---|
| **agent** | "client", "connection" | An app you added that asks Funes for memories, on this Mac or in the cloud. | Everywhere |
| **cloud agent** | n/a | An agent that reaches Funes from the internet through Remote Access, with a remote token or a connected cloud app. | Remote Access, Cloud tab, Add Agent (34) |
| **cloud app** | "signed-in app", "connector" (in Funes's own words), "app" alone | A vendor's product that connects to a cloud agent by signing in (claude.ai, ChatGPT). Once signed in, it's a **connected cloud app**. "Connector" only appears when quoting Claude's UI. | Cloud tab, Remote Access, sign-in panel (14; "signed-in app" 1, "connector" 5) |
| **connect** (a cloud app) | "Cloud sign-in" (the panel's title) | The sign-in where you check the code and allow the app on this Mac. The panel's title is "<app> wants to connect", as [04](04-ux-mac.md#app-wants-to-connect-cloud-sign-in) says. The button is "Connect a Cloud App…". | Sign-in panel (1), Cloud tab |
| **cloud access** | n/a | One agent's switch, "Allow cloud access". It never changes what the agent can read. | Cloud tab, Remote Access (8) |
| **Remote Access** | n/a | The feature: a second port that a tunnel you run makes reachable. Always capitalised. | Sidebar, Settings |
| **About You** (v0.5) | "profile", "user info", "personal details", "identity" | What you tell Funes about yourself: your name, what to call you, pronouns, languages, location, time zone and occupation. Not a memory. The Settings pane and each agent's Access section use this name; agents see the fields you tick. "Profile" is kept for the API's `profile` key. | Settings, Access tab, Share panel, Activity |
| **call you** (v0.5) | "nickname", "display name", "preferred name" | The name Funes greets you with and agents use: "Call me" in About You, "What should Funes call you?" in the setup questions. | About You, setup questions |

## The app, its server and Pause
| Use | Stop using | Means | Where |
|---|---|---|---|
| **Funes Vault** | n/a | The product's name, used in menu items (About, Quit), window titles, the status line, and any text another app shows. | 41 strings |
| **Funes** | n/a | Short form, only as the actor in running text: "Funes shows you the exact text". Don't mix both names in one sentence. | 42 strings |
| **agent server** **D2** | "MCP server" (in Funes's own words), "server" alone, "Funes Vault is off" | The part of Funes Vault that agents connect to: the local port, plus Remote Access's port when it's on. When it's off, no agent can connect, but the vault, capture and Inbox still work. Status lines say what that means: "Agents can't connect: the agent server is off". The menu bar panel's Agents tile says the same ("Off · agents can't connect"); it never says "Funes Vault is off". Its Settings pane is "Agent Server", under Connections (v0.8), with "Let agents connect" as its first row. | Sidebar status (2), the menu bar panel's Agents tile, Settings ▸ Agent Server |
| **Pause All Agents** | "Pause Funes Vault", "Funes was paused", "Funes Vault paused" | Refuses every agent request, local and cloud, until the time you chose; agents are told Funes Vault is paused. The agent server and Remote Access stay up, so cloud agents get the same answer instead of a connection error. Capture, the Inbox and the vault keep working. The menu bar panel says so under its switches while paused: "Agents' requests are refused. Capture and the Inbox keep working." Status: "Agents paused until 14:00"; the Agents tile says "Paused until 14:00". It doesn't touch the paired iPhone, which isn't an agent. | Menu bar panel (the Agents switch), sidebar status, Activity (12 "pause" strings) |
| **Pause**, **Resume** (one agent) | n/a | Refuse one agent's requests until you resume it. | Agents (2) |
| **menu bar panel** (v0.7) | "menu bar menu" for the panel, "dropdown", "popover" | What a click on the menu bar icon opens: Waiting for you, the Agents and Remote Access switches, the field, Last 24 hours ([ADR-0029](../architecture/decisions/0029-menu-bar-panel.md)). The short menu a right click shows is the **menu bar menu**. | UX, docs |
| **Waiting for you** (v0.7) | "Pending" as a heading | The panel's cards for what the user must answer, each with **Review**. "Pending requests" stays the name of the requests that outlived their 45 s and can still be shared. | Menu bar panel |

## Memories and suggestions
| Use | Stop using | Means | Where |
|---|---|---|---|
| **suggestion**, **suggest** | "propose" for memories | A new memory, or a change to one, that waits in the Inbox. It can come from an agent, a capture, an import or a seed question. Fix the Suggest operation's caption: "Suggest new memories or corrections. They wait in your Inbox." | Inbox, panels, Access, notifications (37) |
| **propose** | n/a | Filling in a capture's fields (title, kind, categories, sensitivity), whether by an AI model or by the agent. "Proposed by Claude via Anthropic". | Inbox cards, Capture & Shortcuts and Features settings (10) |
| **Save** **D3** | "Apply", "Applied" | Accept a suggestion: it becomes a memory, or changes one. Inbox buttons: Save · Reject · Later, with "Save 12" for a selection. Save panel: Save · Later · Reject. Activity: "Saved from the Inbox". | Inbox (11 "apply" strings), Save panel |
| **Reject** | "Discard" | Turn a suggestion down. It leaves the Inbox, and Activity records it. | Inbox (7), Save panel (1) |
| **Share**, **Deny** | "Approve" as a button | Answering a Share panel. "Approved" is kept only in Activity, for a share that was approved and is waiting for the agent to pick it up. | Share panel, Activity (13 "approve" strings) |

## Splitting and the tidy-up (v0.3)
New words for [memory processing §5 and §9](../domain/memory-processing.md#5-new-memories-split-classify-link), added before the Phase 6a UI.

| Use | Stop using | Means | Where |
|---|---|---|---|
| **split**, **pieces** | "chunks", "atoms", "fragments", "extracted" | What Funes does with a new input when a local server or cloud model is chosen: one suggestion per claim. The card's source line: "From ChatGPT · 12 pieces". The switch: "Split into separate memories". | Inbox group card, Features ▸ New memories |
| **Split by \<model> via \<provider>** | "Extracted by" | The group card's engine line; "Kept on this Mac: looked sensitive" when the cloud limit kept it here. | Inbox |
| **Processing…** | "Pending", "Working" | A new input whose split hasn't finished: its card can only be rejected. The line under it says why it waits ("Splitting with Claude…", "2 ahead of it"). | Inbox (Mac and iPhone) |
| **Couldn't split** | "Split failed", "Error" | A split that failed; its buttons are **Try Again** and **Keep as One**. | Inbox (Mac and iPhone) |
| **Keep as One** | "Undo split", "Merge back" | Throws the pieces away and keeps the input as one suggestion. Only while no piece is decided. | Inbox group card |
| **Apply All** | "Accept all" | Applies each undecided piece with its own action, skipping the ones outside the agent's scope. Follows **D3** if it goes to Save ("Save All"). | Inbox group card |
| **New**, **Updates \<memory>**, **Already saved**, **Removes \<memory>** | "create", "update", "duplicate", "retract" | A piece's badge: what applying it does. "Already saved" defaults to Reject. | Inbox group card |
| **Outside \<agent>'s scope** | "out of scope", "not allowed", "flagged" | A piece of an agent's input in a category or above a level that agent can't save to. Only you can apply it. | Inbox group card |
| **may contain more than one thing** | "not atomic" | A piece the model couldn't make a single claim. | Inbox group card |
| **has words that aren't in the original** | "unsupported", "failed the support check" | A piece whose text adds words the input didn't have (usually a paraphrase). Never applied automatically. | Inbox group card |
| **Split This Memory** | "Split suggestion" | An agent's directly saved memory and the pieces Funes proposes for it. | Inbox |
| **Applied automatically** | "auto-applied", "auto-apply", "Applied by Funes" | The Inbox list of changes Funes made without asking, each with **Undo** for 30 days ("Undo This and 2 Later Changes"). The setting is "Apply changes automatically". | Inbox, Features, Activity |
| **Tidy up**, **daily tidy-up** (6b) | "consolidation", "cleanup", "reconcile" | The daily pass that proposes updates, merges, splits and archives. "Tidy Up Now". | Inbox, Features ▸ Daily tidy-up |

## Activity (F23)
Activity explains what happened in the user's words, and never leads with internals.

| Reason code | Today | Use |
|---|---|---|
| `denied_category` | Category denied | Never allowed for this agent |
| `category_not_allowed` | Category not allowed | Not in its allowed categories |
| `above_sensitivity_ceiling` | Above its sensitivity limit | (keep) |
| `invalid_input` | Invalid input | The request couldn't be read |
| `secret_like_content` | Looked like a secret | Looked like a password or key |
| `funes_paused` | Funes was paused | All agents were paused |
| *(any unlisted outcome)* | the raw outcome, capitalised | a written label for every outcome; no raw fallback |

- **Request ids:** the detail pane leads with the request's UUID today. Move it to a "Copy Request ID" item in the row's context menu.

## Buttons and labels (F24)
- **Title Case** for buttons, menu items, window titles and tab names (HIG): every word capitalised except articles, coordinating conjunctions and short prepositions. Everything else, including toggles, section headings and captions, uses sentence case. Fix these:
  - "Show all" → "Show All";
  - "Paste and test" → "Paste and Test";
  - "Show everything" → "Show Everything";
  - "Change \<agent>'s categories…" → "Change \<agent>'s Categories…";
  - "Edit \<agent>'s access…" → "Edit \<agent>'s Access…";
  - "Raise \<agent>'s limit…" → "Raise \<agent>'s Sensitivity Limit…".
- **One verb per action:** "Change tunnel" and "Switch Tunnel…" become "Switch Tunnel…".
- **Ellipsis only when more input follows** (HIG): a sheet, a dialog with choices, or a confirmation before something hard to undo ("Remove…", "Rotate Key…", "Delete Now…").
  - Add it to "Answer a Few Questions…".
  - "Still True…" only asks the question its label already answers: drop the dialog and the ellipsis.
  - The button inside a confirmation has no ellipsis ("Rotate Key").
- **Typo:** "Add Agent…." (an ellipsis plus a period) on the Remote Access page.
- **One clipboard timeout:** an agent key clears after 60 s today, while tokens and secrets clear after 90 s. Use 90 s for everything copied, worded "The clipboard is cleared in 90 seconds."
