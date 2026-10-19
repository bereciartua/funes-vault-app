# Changelog

Notable changes to Funes Vault, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `MARKETING_VERSION` in the Xcode project. Release notes come from this file.

## [Unreleased]

## [0.1.1] - 2026-10-19

The first public preview. 0.1.0 was built as a draft release only and never published: everything in it below is in 0.1.1, with this fix.

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
  - A request left unanswered says so on screen and waits in **Pending requests** for 15 minutes, where **Review** opens it again with the minutes it has left.
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
  - A row's details show the memories involved by their current title, what was withheld and why, and links to fix a refusal. Pending requests sit at the top with **Review**.
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
  - Usage counts per provider, with **Reset**.
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
