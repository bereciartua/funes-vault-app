# Changelog

Notable changes to Funes Vault, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `MARKETING_VERSION` in the Xcode project. Release notes come from this file.

## [Unreleased]

## [0.2.0] - 2026-10-22

Funes Vault now has an iPhone app, Funes Vault for iPhone on the App Store. It pairs with this Mac to capture, search, edit, review the Inbox and approve agents' requests. Your vault stays on your Mac.

### Added

- **iPhone access on the Mac.**
  - A new Settings ▸ iPhone turns on iPhone access (off by default) and chooses how the phone reaches this Mac: Same Wi-Fi, Tailscale or a public tunnel.
  - **Pair iPhone…** shows a QR code for 5 minutes, then asks "“Sam's iPhone” wants to pair" with Allow or Deny. Paired iPhones are listed with when they were last seen, and **Remove…** cuts one off.
  - Everything the phone sends is end-to-end encrypted to this Mac. A paired iPhone acts as you, and what it does shows in Activity under its name.
  - macOS asks for Local Network access the first time iPhone access is on.
  - With Tailscale on, the iPhone reaches this Mac through Tailscale from anywhere, not only on the same Wi-Fi.
- **Funes Vault for iPhone: pairing.**
  - **Pair with Mac** scans the code from Settings ▸ iPhone ▸ Pair iPhone…, then waits while you click Allow on the Mac. Name the iPhone before scanning: iOS only tells apps "iPhone".
  - It then shows whether your Mac is reachable and how: "Connected · Wi-Fi", "Connected · Tailscale", "Connected · VPN" (your Mac's local address through a VPN such as a Tailscale subnet router), or "Mac not reachable". It also says so when Local Network access is off for Funes. It checks again whenever the app comes to the front or the network changes.
  - The iPhone's signing key is made in the Secure Enclave and never leaves it; the keys and the pairing stay on this iPhone only.
  - **Unpair This iPhone…** tells the Mac and forgets the keys.
- **Capture on the iPhone.** The app opens on Capture.
  - Type, or tap the mic to dictate (on iOS 26 and later, turned into text on the iPhone; earlier versions use the keyboard's dictation). **Remember** saves at once, even with no network, and sends it to your Mac when it's reachable.
  - Text that looks like a password, key or card number is blocked before it's saved, with the same rules as the Mac.
  - Recent captures show "Sent to Mac", "Waiting" or why your Mac didn't accept one. "Mac not reachable · 3 captures waiting" says what's still on the iPhone.
  - Captures wait on the iPhone, up to 1,000, and leave it only once your Mac has them, each exactly once. Funes sends them when the app opens or comes to the front, when the network changes, right after a capture, and in the background now and then; while your Mac is away it waits longer between tries, up to 30 minutes.
  - **Share to Funes** from any app saves the selected text or link with an optional note. **Remember in Funes** works in Shortcuts, with Siri and on the Action button. A **Capture in Funes** control for Control Center, the Lock Screen and the Action button opens Capture ready to type.
  - Settings shows how many are waiting, with **Send Now** and **Delete Queued Captures…**. Unpairing asks whether to keep or delete captures that haven't reached your Mac.
- **Search, edit and review on the iPhone.** The Search and Inbox tabs read your vault on your Mac while it's reachable.
  - **Search** asks your Mac and lists each memory's title, two lines of its text, its categories and its sensitivity. Scopes show Archived and Recently Deleted memories too.
  - A memory opens with its full text, kind, categories, sensitivity, expiry, how often it was shared and its history. **Edit**, **Archive**, **Restore** and **Delete…** save on your Mac. If the memory changed on your Mac meanwhile, the iPhone asks "Changed on your Mac, reload?" instead of overwriting it. A save that fails says why and keeps your text.
  - The **Inbox** lists the suggestions waiting on your Mac. Swipe right to save one, left to reject it, or open it to **Edit & Save**. If your Mac doesn't take the answer, the suggestion comes back with the reason; one already answered on the Mac just leaves.
  - Every tab shows how your Mac is reachable at the top: "Connected to Maya's MacBook Pro · Wi-Fi" (or Tailscale, a VPN or a tunnel), "Connecting…", or "Mac not reachable · 3 captures waiting" with **Why?**, which says what to try: the same Wi-Fi, Tailscale, waking the Mac, or Local Network access. While your Mac can't be reached, Search and the Inbox say so instead of showing old results; nothing from the vault is kept on the iPhone.
- **Approve requests on the iPhone: the Mac's side.**
  - Settings ▸ iPhone has **Approve requests on this iPhone** for each paired iPhone, on by default.
  - When a Share, Save or access request waits on your Mac, Funes rings a "doorbell" in your own iCloud for each of those iPhones. The record holds only a random tag: no memory text, titles, task or agent name, and no request id. The iPhone then gets the details straight from your Mac, end-to-end encrypted. The record is deleted once the request is answered, expires or changes. Settings ▸ iPhone says when this Mac can't notify, for example when it isn't signed in to iCloud.
  - The first answer wins, on the Mac or the iPhone. If the iPhone answers first, the Mac's panel closes and says "Answered on Sam's iPhone." Answers from the iPhone show in Activity under its name, with the same 15-minute limit and the same checks as on the Mac.
- **Approve requests on the iPhone.**
  - When an agent asks to share memories, save one or get more access, the iPhone shows a notification, also locked: "Claude Code wants 3 memories", "Cursor suggests a memory", "Codex wants to read Work". It names the agent and the count, never your memories or the task. The iPhone words it itself, after asking your Mac over the encrypted connection; if it can't reach your Mac, the notification says "Mac not reachable".
  - Tapping it opens the same panel as the Mac's: where the text goes, what the agent says (not checked by Funes), and the memories with checkboxes and sensitivity badges, weaker matches unticked under "Also matched, less closely", each with its exact text and **Show All**. **Share N** or **Deny**, **Save** or **Discard**, **Allow Once**, **Not Now** or **Always Allow…** answer it. Answering needs the iPhone unlocked.
  - The first answer counts. If your Mac answered first, the iPhone says "Answered on your Mac"; if the memories changed meanwhile, it shows the new panel to review again; after 15 minutes it says the request expired.
  - Requests still waiting are listed under **Waiting for you** at the top of Capture, for a notification you missed.
  - Settings ▸ **Approve requests on this iPhone** turns them on or off, the same switch as on the Mac. It says why notifications might not come: notifications off, the iPhone or the Mac not signed in to iCloud, or a Mac build that can't notify. The iPhone asks for notification permission once approvals are on.
- **Demo mode on the iPhone.** Try every screen without a Mac, for App Review and for a first look.
  - **Try Demo** on Capture (and in Settings, Search and the Inbox) while the iPhone isn't paired opens a sample vault built into the app: about 20 memories, three Inbox suggestions, and a Share, a Save and an access request waiting under **Waiting for you**.
  - Search, edit, archive and delete, Save and Reject in the Inbox, and answer the requests, as with a real Mac. Captures go to the demo's Inbox.
  - An orange **DEMO** banner says "Demo vault: not your data" on every tab. Nothing in the demo leaves the iPhone or touches your pairing or your real captures, and **Leave Demo** discards its changes and captures.
- **Ready for the App Store.** The iPhone app and its extensions carry Apple's privacy manifests: no tracking and no data collected. The privacy statement and funesvault.com/privacy now cover the iPhone app, including the iCloud doorbell for approvals, and funesvault.com/support has an iPhone section.

### Fixed

- **The secret scanner blocks shorter passwords**, such as "password: testqwe1234". After `password`, `api_key`, `access_token`, `auth_token` or `client_secret` and a colon or `=`, a value of 8 or more characters that mixes letters and digits now counts as a secret; before, it needed 12. "password: see 1Password" and "my password is in the vault" still save. The Mac and the iPhone share the scanner.

## [0.1.4] - 2026-10-20

### Added

- **Appearance: Automatic, Light or Dark.** In Settings ▸ General, keep Funes Vault dark while macOS is light, or the other way round. Automatic follows macOS, as before. The choice applies at once to every window and panel and to the menu bar menu, and stays after a relaunch. EK Bridge has the same setting.

### Changed

- **Each agent has its own row in the sidebar**, like EK Bridge's connections. The order is now Vault, Inbox, Activity, then the agents with a **+** to add one, then Remote Access and **Settings…** pinned at the bottom.
  - An agent's row shows a short status ("2 min. ago", "Paused") and a badge counting its requests waiting for you. Its page shows those requests under its name, with its access summary.
  - The View menu follows the new order: Activity is ⌘3, Agents ⌘4 (the last agent you looked at) and Remote Access ⌘5.
  - The status line under the sidebar shows only while something's off: agents paused (with Resume), or the agent server off or stopped.

## [0.1.3] - 2026-10-20

### Added

- **The Share panel says where the text goes.** A "Goes to" line, built only from what Funes Vault knows: "Claude Code on this Mac. It may send what it reads to its AI service.", or for a cloud agent "claude.ai, through your Tailscale Funnel, to Anthropic's servers" with a **Cloud** chip.
- **Review Request (⌃⌥⌘R), from any app.** It brings a waiting panel forward and makes it key, so Return and Esc answer it; with no panel showing, it opens the newest pending request. The menu's first item does the same while something waits. Change or turn off the shortcut in Settings ▸ General.
- **More Time** on the Share panel moves the request to Pending requests at once, where it waits up to 15 minutes.
- **Never-share categories.** "A Few Questions" ends with "Which of these should agents never see?". The categories you tick get Deny for every agent, and new agents start with it; Categories keeps the list ("New agents can't read"). It replaces the question "What should Funes be especially careful not to share casually?", whose answer was saved as a memory that agents reading Internal could get.
- **Add and Connect…** For Claude Code, Claude Desktop, Cursor and Codex, Add Agent goes straight to the change to the agent's settings, then suggests a first question to ask it.
- **The capture box says when a cloud model sees the text:** "Goes to your Inbox · fields suggested by Anthropic". Settings ▸ Capture says it too.
- **Remote Access offers to move a Tailscale Funnel setup on port 8443 or 10000 to 443.** claude.ai and ChatGPT only connect to 443. Setups from 0.1.1's drafts, or on a port picked by hand, showed as **Running**, or got start commands for the old port.
  - Once 443 can take Funes Vault's paths, the Tunnel row says so and shows the four commands that add them to 443, then the ones that turn off the old port's entry.
  - Then **Address ▸ Edit…** changes the address to the one without a port.
  - BridgeKit 0.4.1.

### Changed

- **"Wants more access" makes Allow Once the default.** The panel is now "Cursor wants to read Project context", with Not Now and **Allow Once**; Always Allow is a link that names what it adds, never the Return key, and is never cut off.
- **The Share panel keeps the agent's words apart.** Task, keywords, purpose, how long it keeps what it gets and who it shares with sit in a block marked "The agent says · not checked by Funes". Your own note on the agent shows as "Your note", as the Access tab always promised.
- **Only strong matches start ticked.** Memories that matched less closely are offered unticked under "Also matched, less closely".
- **Requests on a clock come first.** When several panels wait, chips at the top show each one with its countdown, most urgent first, so a Save panel never hides a request that is running out. VoiceOver hears one announcement with the time to answer and the shortcut.
- **An access request nobody answered doesn't block the next one for an hour.** If the panel ran out or was withdrawn, Funes Vault may ask again; Not Now still waits an hour.
- **The Save panel shows the memory first**, then its details; Edit… is a link.
- **The cloud limit says what it limits:** "Never send captures above".
- **Setup connects first.** The checklist is now Connect an agent, Approve its first request, Seed your vault, Review your Inbox. Keyboard focus starts on the first step, not Hide, and Hide offers Undo. An empty vault shows a welcome instead of an empty list and filters.
- **Add Agent has two tabs,** On This Mac (agents found on this Mac first) and Cloud · Experimental, and agent names no longer get cut off.
- **Pending requests are easier to find:** above the Agents list, counted by the sidebar's Agents badge, with how many memories each would share and its task.
- **The menu bar icon is the app's eye.**
- **The sign-in panel:** Esc denies, it shows until when pairing is open, and VoiceOver reads the code digit by digit.
- **funesvault.com has a new design**, built around the app icon's eye. The privacy statement's section on the website now describes its one script: the Homebrew copy button, and the eye on the home page that follows your pointer. It sends and stores nothing.

### Fixed

- **The setup checklist's Add… opens Add Agent** even when the Agents page wasn't showing yet.
- **The Agents page fits the window at its minimum size.** At 860×560 the agent's detail ran off the right edge, cutting off **Remove…** and the switches. The list is narrower in a small window, the header's buttons move to their own line when they don't fit, and the agent's kind wraps instead of showing "claude….". The Vault's sort menu drops its "Sort by" label when the filter row would be too wide.
- **The Cloud tab fits its column and says up front where text goes.** "Text you share with a cloud agent goes to its vendor's servers…" is now the caption under **Allow cloud access**, not a last line below the fold with its left edge cut off. A long cloud agent name in the picker no longer widens the tab past the window.
- **Cloud setup steps point to the buttons on the same tab:** "click Connect a Cloud App… below" instead of telling you to open the agent you're already looking at. The same for Copy Remote Token… and Set Up OAuth Client….
- **Delete Now… in Recently Deleted always asks first.** The list's context menu deleted for good without a question; it now asks "Delete this memory now?", like the detail and the bulk bar, and all three are labelled **Delete Now…**.
- **Warnings and sensitivity badges are easier to read.** Badges show the level's name in primary text on its color (it was colored text on a light tint, about 2:1). Warnings on the Access tab, in AI Models, Settings and the import sheet are an orange icon with primary text instead of orange text. Increase Contrast darkens the icon and strengthens the badges.
- **A copy built from source never checks for updates**, as the privacy docs promised. Only copies signed with Funes Vault's Developer ID check GitHub; builds from source, Xcode runs and Debug builds don't, and they hide **Check for Updates…**. Before, every build checked, because the feed and the update key are in the committed `Info.plist`.
- **Activity fits the window again.** Since the Remote Access filter, the filter row was wider than the page at the default window size, so the page slid under the sidebar and cut off the title, Pending requests and the table's first columns. The agent and period pickers and search now move to a second line when the row doesn't fit, and the Event and Detail columns can get narrower, down to the window's minimum width.

## [0.1.2] - 2026-10-19

The first public preview. 0.1.0 and 0.1.1 were preview builds, kept on GitHub as pre-releases: everything in them below is in 0.1.2, with this fix in place of 0.1.1's.

### Fixed

- **Remote Access shares Tailscale Funnel's port 443 with other apps on your Mac**, such as EK Bridge's Remote Access. claude.ai and ChatGPT only connect to port 443, so 0.1.1's other public ports didn't reach them.
  - The guide now shows one command per path Funes Vault answers. Each adds only that path to port 443, so other apps keep their entries, and the address has no port.
  - The command to turn Funnel off removes only those paths.
  - If 443 has another app's tailnet-only entry, which Funnel would make public, the guide uses 8443 or 10000 and says that claude.ai and ChatGPT can't reach it there.
  - New Tunnel states: **Incomplete**, with the commands for the missing paths, and **No shareable port**.
  - After **Reset Path…**, the page shows the commands that move Funnel to the new path.
  - BridgeKit 0.4.0.

## [0.1.1] - 2026-10-19

A preview build, kept as a pre-release and superseded by 0.1.2. Everything in 0.1.0 below is in it, with this fix.

### Fixed

- **Remote Access shares Tailscale Funnel with other apps on your Mac.** The guide used to offer `tailscale funnel --bg 47627`, which takes Funnel's port 443 and replaces whatever another app serves there, such as EK Bridge's Remote Access.
  - It now checks what Funnel already serves and uses the first free public port: 443, 8443 or 10000. The address ends in that port, such as `https://my-mac.tail1234.ts.net:8443`.
  - If all three are taken, it says so and offers no command.
  - Another app's Funnel entry no longer shows as **Wrong port**.
  - The command to turn Funnel off only touches Funes Vault's own port.
  - BridgeKit 0.3.0.

## [0.1.0] - 2026-10-18

The first public preview of Funes Vault for the Mac: a menu bar app that keeps your personal context in a private vault on your Mac, and shares it with AI agents only as you allow. It needs macOS 15 or later, on Apple silicon or Intel.

### Added

- **Agents connect over MCP**, on this Mac only.
  - The app serves MCP on `127.0.0.1:47625`, a port you can change in Settings ▸ MCP. Agents reach it through the `funes-mcp` launcher inside the app, or directly over HTTP.
  - Agents can list your categories, request memories for a task (with keywords for the kinds of context that would help), pick up a request you answered later, and suggest memories.
  - Each agent has its own key, kept in a private file and stored in the vault only as a hash.
  - The protocol and security core is [BridgeKit](https://github.com/bereciartua/bridgekit) 0.2.0, shared with EK Bridge. It refuses JSON-RPC ids longer than 1,024 bytes, so every response fits its 200,000-byte limit.
- **You approve the exact text.**
  - A floating Share panel shows each memory an agent may get, with a checkbox per memory, the agent's task, keywords and stated purpose, and a 45-second countdown.
  - A request left unanswered says so on screen and waits in **Pending requests** for 15 minutes, where **Review…** opens it again with the minutes it has left.
  - Quitting Funes Vault while an agent waits tells the agent at once (`funes_quit`), and the request stays in Pending requests.
  - Shares always fit in one result of at most 200,000 bytes: memories that wouldn't fit are left out, like those over the agent's token budget.
  - An approval is used once, within 15 minutes, and is cancelled if a memory or the agent's access changes. Refusals tell agents how many memories were withheld and why, never which ones.
- **Agents**: add one from tiles for the agents found on this Mac, with a starting access.
  - The access editor sets what it can do (Read, Suggest, Write), its sensitivity limit, allowed and denied categories, whether Funes asks before sharing or saving, an expiry date, and whether it may ask for more.
  - Each agent shows whether it's waiting for its first request, connected, paused or expired. **Pause** and **Remove** are in its header; **Copy Key…** and **Rotate Key…** on its Connect tab.
  - **Connect** adds Funes to Claude Desktop, Claude Code, Cursor or Codex in one click, after showing the exact change and keeping a backup, and never writes the key. Copyable setups cover VS Code (Copilot), Gemini CLI, Zed, Cline, JetBrains AI Assistant, Devin Desktop and any other MCP client.
- **Remote Access for cloud agents** (experimental, off by default): claude.ai, ChatGPT, Gemini Enterprise, the Anthropic and OpenAI APIs, Claude Managed Agents, and the Claude Code, Cursor, Copilot and Devin cloud agents can reach Funes through a tunnel you run, such as Tailscale Funnel.
  - A Remote Access page with a four-step guide (choose a tunnel, turn on and start it, paste its address, test), the tunnel's commands for port 47627, checks on this Mac of whether the tunnel runs, **Test**, **Switch Tunnel…**, **Reset Path…**, an automatic turn-off and keep-awake.
  - Each agent has **Allow cloud access**, off by default, on a new **Cloud** tab, with the cloud agent's setup, **Copy Remote Token…** and **Reset Remote Token…**, connected cloud apps with **Revoke**, and **Connect a Cloud App…**, which opens a 10-minute pairing window for that agent. Add Agent has cloud tiles.
  - claude.ai and ChatGPT sign in with OAuth: a panel on the Mac shows the same six-digit code as the browser, and **Allow** works after a second.
  - A cloud agent gets exactly the access you set for it, with the same panels, 45-second wait and 15-minute pending list as any agent. Remote calls are marked in Activity (a cloud icon, "via Remote Access", and a Remote Access filter) and have a stricter rate limit on top of the agent's own.
  - The menu bar icon shows a globe while it's on, and the menu has **Turn Off Remote Access**. An optional notification says when the tunnel stops.
  - Built on BridgeKit 0.2.0's `BridgeKitRemote`, EK Bridge's Remote Access, shared.
- **Asking for more access**: an agent you allow to ask gets a panel when a request is refused only because of a category: **Not Now**, **Allow Once** (that request only) or **Always Allow**. At most once an hour per agent and category. A refused suggestion goes to the Inbox if you allow it.
- **The Vault**: search as you type, by meaning as well as by words, with filters by category, kind, sensitivity, status and source, and three sort orders.
  - Each memory opens in an editor with a character counter, categories, a sensitivity level with what it means, an optional expiry date, how often it was shared (linking to Activity), its history, and **Archive**, **Delete** and **Still True**.
  - **Recently Deleted** keeps memories for 30 days, with **Restore** and **Delete Now**.
  - Select several memories to archive, delete, move or change their sensitivity together. Rename categories, and add or delete your own. Saving a memory says when a similar one exists.
- **The Inbox**: suggestions from agents, captures, imports and your answers, each a card you can edit before **Apply**, **Reject** or **Later**.
  - Cards say who proposed the fields, quote the agent's reasons as reported, point out similar memories, and show a correction as old → new with **Replace** or **Keep Both**.
  - Select several to apply or reject them together. Expired suggestions can be restored for 7 days.
  - The **Save this memory?** panel appears when an agent suggests something, with **Edit…** to open it in the Inbox.
- **Activity**: what each agent asked for and what happened, by day, with filters (Shared, Suggestions, Problems), agent, period and search.
  - A row's details show the memories involved by their current title, what was withheld and why, and links to fix a refusal. Pending requests sit at the top with **Review…**.
  - Activity stores ids and reason codes only, never memory text.
- **Quick capture** with ⌥⌘M (changeable in Settings ▸ Capture), **Remember…** in the menu, or **Services ▸ Remember in Funes** in any app.
  - The box says when text looks like a secret, and saves nothing then.
  - Otherwise the capture goes to the Inbox, and the chosen model (Apple's on-device model by default, with rules as a fallback) proposes a title, kind, categories and sensitivity in the background.
- **Getting started**: a checklist at the top of the Vault (seed your vault, review the Inbox, add an agent, connect it), seven optional questions whose answers go to the Inbox, and imports from a ChatGPT memories file, pasted Claude memories, a Markdown file or a Funes Vault export. Each import is previewed (duplicates, secrets, over-long items) before anything is stored.
- **The menu bar**: the icon shows when Funes needs you or is paused. The menu has **Remember…**, the Inbox count, **Pending requests** with minutes left, **Pause Funes Vault** (for 1 hour, until tomorrow or until you resume, kept across relaunches), **Open Funes Vault** and **Settings…**.
- **Search on your Mac**: hybrid keyword and semantic search with the bundled [bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) embedding model, run with Core ML on the CPU. No download, no API key, nothing leaves the Mac.
- **Settings ▸ AI Models**: embeddings are built in. Classification uses Apple's on-device model by default, or a provider you add: Anthropic, OpenAI, Ollama, LM Studio or another OpenAI-compatible server, with its key in the Keychain and **Test Connection**.
  - Each choice shows where it runs and, for cloud ones, what it sends. Classification sends only new captures and your category names and descriptions; agent suggestions and imports are never sent.
  - Nothing above the cloud limit (Internal by default), and nothing that looks like a secret, goes to a cloud model.
  - Usage counts per provider, with **Reset Usage**.
- **More settings**
  - **General**: open at login, show Funes in the Dock, and optional notifications: a request expired, a suggestion is waiting, an agent was refused more than 5 times in 10 minutes.
  - **MCP**: turn agent access on or off, change the port, see the address, the launcher (optionally linked as `~/.local/bin/funes-mcp`) and traffic counts.
  - **Data**: daily backups of the vault (keeping 7), restore a backup, export and import, show the data folder, and erase everything.
  - **Updates**: signed updates from GitHub through Sparkle, checked daily; installing always takes a click.
  - **Advanced**: how long Activity keeps rows, and bringing back the setup checklist.
- **Moving to Applications**: run from Downloads or a disk image, the app offers to move itself to Applications.
- **Accessibility**: every control works from the keyboard and has a VoiceOver label; panels, the capture box's errors and short notices are announced; badges and cards get stronger outlines with Increase Contrast, and notices don't fade with Reduce Motion.
- **Licences in the app**: the bundled embedding model ships inside the app with its MIT licence, and the app includes the licence texts of GRDB.swift, Sparkle and the model alongside its own `LICENSE` and `NOTICE`.
- **Open source**: the code, the product definition in `spec/`, and the tests are public under the Apache License 2.0. See [Testing](docs/TESTING.md) for what has been checked.

[Unreleased]: https://github.com/bereciartua/funes-vault-app/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bereciartua/funes-vault-app/releases/tag/v0.1.0
