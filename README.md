<h1 align="center">Funes Vault</h1>
<p align="center"><b>Give AI agents your memory. Not all of it.</b><br>
A free, open-source Mac menu bar app that keeps your personal context in a private vault on your Mac, and shares it with Claude, Cursor, Codex and other AI agents only as you allow.</p>

<!--
Badges, once the listings exist:
<p align="center">
  <a href="https://github.com/bereciartua/funes-vault-app/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/bereciartua/funes-vault-app?label=release"></a>
  <img alt="macOS 15 or later" src="https://img.shields.io/badge/macOS-15%2B-black">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/bereciartua/funes-vault-app"></a>
  MCP Registry (com.funesvault/funes), mcpservers.org and glama.ai badges go here.
</p>
-->

<p align="center">
  <a href="https://github.com/bereciartua/funes-vault-app/releases/latest/download/FunesVault.dmg"><b>Download for Mac</b></a> ·
  <a href="#get-started">Get started</a> ·
  <a href="docs/MCP.md">Agent setups</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/vault-memory-dark.png">
  <img alt="The Funes Vault window: the Vault list with search and filters, and one memory open with its text, categories, sensitivity level and how often it was shared." src="docs/images/vault-memory-light.png" width="720">
</picture>
</p>

- **Each agent gets only what you choose.** Its own key, and the access you set: read, suggest or save; up to a sensitivity level; in the categories you pick. A new agent can start with nothing.
- **You approve the exact text.** Before a memory goes to an agent, a small panel shows it, and you can untick what shouldn't go. An approval is used once, within 15 minutes, and is cancelled if anything changes.
- **Agents suggest; you decide.** What an agent wants to remember waits in your Inbox, where you edit it, apply it or reject it.
- **Everything stays on your Mac.** No account, no server, no cloud copy. Search runs on a small model built into the app.

**Status:** public preview (v0.1), with best-effort support. **Works with** Claude Code, Claude Desktop, Cursor and Codex, with ready-made setups for VS Code (Copilot), Gemini CLI, Zed, Cline, JetBrains AI Assistant, Devin Desktop and any other MCP client.

## Get started

1. **Install.** Download [`FunesVault.dmg`](https://github.com/bereciartua/funes-vault-app/releases/latest/download/FunesVault.dmg), open it and drag Funes Vault to **Applications**. If you open it from the disk image or Downloads instead, it offers to move itself there. Or use [Homebrew](https://brew.sh):

   ```sh
   brew install --cask bereciartua/tap/funes-vault
   ```

   Funes Vault needs **macOS 15 or later**, on Apple silicon or Intel.

2. **Open the app.** It lives in the menu bar. The Vault opens with a short setup checklist:
   1. **Seed your vault.** Answer a few optional questions, import your ChatGPT memories or paste Claude's, or import a Markdown file. Everything goes to the Inbox first, and anything that looks like a secret is never imported.
   2. **Review the Inbox.** Apply what's right; edit or reject the rest.
   3. **Add an agent.** Pick its tile (agents found on your Mac are marked) and a starting access. The default, **Read low-sensitivity memories, ask first**, lets it read memories up to Low and asks you before each share.
   4. **Connect it.** **Add to Claude Code…** (or Claude Desktop, Cursor or Codex) shows the exact change to the agent's settings first, keeps a backup and never writes the key into them. For other agents, copy the setup from the agent's **Connect** tab. The step is done when the agent's first request arrives.

3. **Ask your agent.** For example: *"Plan a week of dinners for me"* or *"Set up this TypeScript project the way I like it."* The agent asks Funes for context, you see the panel, and you choose what to share.

You can also capture a thought at any time with **⌥⌘M**, **Remember…** in the menu, or **Services ▸ Remember in Funes** in any app.

Setups for every agent, the tool reference and troubleshooting are in the [MCP guide](docs/MCP.md).

## How you stay in control

Funes is the only thing that holds your memories. Agents talk to it, never to the vault directly, and it checks every request against what you allowed.

### You choose what each agent may see

Every agent has its own access: whether it may **Read**, **Suggest** or **Write**; a **maximum sensitivity** (Public, Low, Internal, Sensitive, Restricted or Secret); the categories it may or may not use (a denied category always wins); whether Funes **asks before sharing** and **asks before saving**; and an optional expiry date. Health, Finance and Legal memories are Sensitive by default.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/agents-access-dark.png">
  <img alt="An agent's Access tab: switches for Read, Suggest and Write, the maximum sensitivity, allowed and denied categories, Ask before sharing, Ask before saving and an expiry date." src="docs/images/agents-access-light.png" width="640">
</picture>

### You approve the exact text

When an agent asks for context, Funes finds the memories that match its task and are allowed for that agent. If asking is on, a panel shows each one with a checkbox, what the agent says it's for, how long it keeps what it gets, and how many more matched but can't go to it. **Share** sends only what you ticked; **Deny** sends nothing. The agent waits up to 45 seconds. If you don't answer in time, the request waits in **Pending requests** for up to 15 minutes, and the agent picks up your answer later.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/share-panel-dark.png">
  <img alt="The Share panel: an agent wants to use your memories for a task, with the keywords it is looking for, its stated purpose, a checkbox per memory with its sensitivity, a countdown, and Deny and Share buttons." src="docs/images/share-panel-light.png" width="400">
</picture>

Nothing an agent writes in its task or purpose changes what it may see. Those words only help find relevant memories.

### Agents suggest, you decide

Agents propose memories, and by default each one waits in the **Inbox** as a card you can edit before **Apply**, **Reject** or **Later**. Cards say who proposed what, quote the agent's reasons as reported, point out similar memories, and show a correction as old and new text. Your own captures and imports land there too.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/inbox-dark.png">
  <img alt="The Inbox: suggestion cards from agents and captures, each with its proposed title, text, categories and sensitivity, and Apply, Reject and Later buttons." src="docs/images/inbox-light.png" width="720">
</picture>

### You see everything, and stop anything

**Activity** lists what each agent asked for and what happened, by day, with filters. Funes stores only ids and reason codes, never text: it shows the memories involved by their current title when you open a row, says what was withheld and why, and links to fix a refusal. **Pause** an agent to refuse its requests while keeping its setup, **Remove** it to cut it off, or **Pause Funes Vault** from the menu bar for an hour, until tomorrow or until you resume.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/activity-dark.png">
  <img alt="Activity grouped by day: each row has the time, the agent, what it asked for and the result, such as shared, denied by you or refused. The selected row's details list the memories by title and what was withheld." src="docs/images/activity-light.png" width="720">
</picture>

### Under the hood

- **Local only.** The MCP server listens on `127.0.0.1:47625`, never on a network interface. No account, no analytics, no server of ours.
- **A key per agent.** Each agent has its own 256-bit key in a private file; the vault stores only its hash. The recommended setups read the file instead of putting the key in the agent's config.
- **Fail closed.** Any doubt about an agent or a request is a refusal. Refusals tell the agent *how many* memories were withheld and why, never which ones.
- **Single use.** An approved share is delivered once, within 15 minutes, and only if the memories and the agent's access are unchanged.
- **Secrets stay out.** A secret scanner checks captures, suggestions and imports, and everything sent to a model you chose.
- **Signed updates.** Updates come from GitHub, signed for Funes Vault and checked before they install. Installing always takes a click.
- **Open source.** Read the code, the [architecture](docs/ARCHITECTURE.md) and the [test record](docs/TESTING.md).

**What it doesn't protect against:** another program running as your macOS user can read the same vault and key files. Access settings separate the agents you connect; they aren't a defense against malware already on your Mac. Details are in [Security boundary](#security-boundary).

## What agents can do

Agents see four main tools, and only the ones their access allows:

| Tool | What it does | Needs |
| --- | --- | --- |
| `list_memory_categories` | Lists your categories and what this agent may do in each. No memories, no counts. | Always available |
| `request_memory` | Asks for memories relevant to a task, with keywords for the kinds of context that would help. Returns them, asks you first, or refuses with a reason. | Read |
| `get_memory_request` | Picks up a request you answered after the agent stopped waiting. Delivered once. | Read |
| `suggest_memory` | Proposes a memory or a correction. It goes to your Inbox, or straight into the vault if you let that agent save without asking. | Suggest or Write |

A fifth, `open_in_funes`, only brings Funes to the front at one of the agent's own pending requests or suggestions. The [MCP guide](docs/MCP.md#tools) has every argument and outcome.

## FAQ

<details>
<summary><b>Is it free?</b></summary>

Yes. Funes Vault is open source under the Apache License 2.0, with no account or trial.
</details>

<details>
<summary><b>Do my memories leave my Mac?</b></summary>

Only what you share with an agent, which then goes to that agent and its AI provider under their terms. Funes itself has no server. Search, and the proposals for new captures, run on your Mac by default. If you choose a cloud model for those proposals, Funes says what it sends, and never sends anything above your cloud limit (Internal by default). [Privacy](#privacy) lists every connection the app makes.
</details>

<details>
<summary><b>Does it always ask before sharing?</b></summary>

By default, yes: every starting access asks before each share. You can turn **Ask before sharing** off for an agent you trust; it then gets the memories it's allowed to read without a panel, and each share still shows in Activity.
</details>

<details>
<summary><b>What if I'm not at my Mac when an agent asks?</b></summary>

The agent waits 45 seconds, then is told the request is waiting for your approval. The request stays in **Pending requests** in the menu bar menu for 15 minutes. If you share it in that time, the agent gets the memories the next time it checks.
</details>

<details>
<summary><b>Can an agent change or delete my memories?</b></summary>

No. Agents can only propose new memories and corrections. An agent you give **Write** with **Ask before saving** off can save new memories directly, within its categories and sensitivity limit; its corrections still wait in your Inbox.
</details>

<details>
<summary><b>Does it need Apple Intelligence?</b></summary>

No. Search uses a small model built into the app (bge-small, on your Mac). Apple's on-device model, when your Mac has it (macOS 26 or later with Apple Intelligence), proposes titles, categories and sensitivity for captures; otherwise simple rules do. You can also choose Ollama, LM Studio, Anthropic, OpenAI or another OpenAI-compatible server for that in **Settings ▸ AI Models**.
</details>

<details>
<summary><b>Is there an iPhone app?</b></summary>

Not yet. An iPhone companion that captures thoughts and searches the vault when your Mac is reachable is planned for v0.2.
</details>

<details>
<summary><b>Is it made by Apple, Anthropic or OpenAI?</b></summary>

No. Funes Vault is an independent open-source project, not affiliated with or endorsed by any of them.
</details>

Something else? Open an [issue](https://github.com/bereciartua/funes-vault-app/issues).

## Security boundary

- **MCP server.** Runs while **Settings ▸ MCP ▸ Let agents connect** is on (the default), and listens only on `127.0.0.1` (port 47625 unless you change it in the same pane). Every request needs an agent's own key; the vault stores only its SHA-256 hash. Requests with a foreign `Host`, any `Origin` (web pages) or tunnel forwarding headers are refused, and repeated failed sign-ins are locked out for a minute. Paused and expired agents are refused; removed agents' keys no longer work.
- **Agent keys.** Each key is a file only you can read (mode 0600, in a 0700 folder) under `~/Library/Application Support/FunesVault/agent-keys/`. The `funes-mcp` launcher sends it only after checking that the program on the port is your own Funes Vault. **Rotate Key…** replaces it at once.
- **Access decisions.** Made inside Funes from the agent's access, each memory's sensitivity and categories, and your answer, never from what the agent writes. An approval is bound to the exact memories and versions you saw.
- **Data at rest.** The vault is an SQLite file in your Application Support folder, protected by FileVault, not by its own encryption. Backups stay in the same folder.
- **Models.** Text goes to a model provider only if you added one and chose it, never above your cloud limit for a cloud provider, and never when it looks like a secret.

**These controls do not isolate another process running as the same macOS user.** Such a process can read the vault, the backups and the key files. Funes also can't recall or control text after you've shared it with an agent. An access setting is a boundary between the agents you connect, not a defense against a compromised user account. See the [threat model](docs/ARCHITECTURE.md#threat-model).

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

## Privacy

The app has **no analytics, telemetry or crash reporting**, and no account. Your memories, agents, keys and Activity stay on your Mac. These are the connections it makes:

| Connection | When |
| --- | --- |
| MCP server, listening on `127.0.0.1:47625` | While **Let agents connect** is on. Loopback only: other computers can't connect. |
| `funes-mcp` connecting to `127.0.0.1` | When an agent on your Mac starts it, to reach the MCP server. |
| One HTTPS request to GitHub for `appcast.xml` | Once a day while **Settings ▸ Updates ▸ Check for updates every day** is on, and when you choose **Check for Updates…**. GitHub sees your IP address and the app's version. A copy built from source never checks. |
| Downloading an update from GitHub | Only after you click to install it. |
| The model provider you added | Only if you add one in **Settings ▸ AI Models** and choose it: to propose a title, categories and sensitivity for each capture, and for **Load Models** and **Test Connection** (which send none of your data). A local server (Ollama, LM Studio) stays on your Mac or local network; a cloud provider gets only captures at or below your cloud limit that passed the secret scanner. |

Notifications, shown by macOS, never include memory text. What an agent receives through Funes goes to that agent and its AI provider, under their privacy terms, so give each agent only what it needs. The full statement is in [PRIVACY.md](PRIVACY.md) and at [funesvault.com/privacy](https://funesvault.com/privacy).

## Docs

| Goal | Guide |
| --- | --- |
| Connect an agent; the tools, limits and troubleshooting | [MCP guide](docs/MCP.md) |
| How it's built, where data lives, the threat model | [Architecture](docs/ARCHITECTURE.md) |
| What was tested, and how | [Testing](docs/TESTING.md) |
| Everything that leaves the Mac | [Privacy](PRIVACY.md) |
| Report a vulnerability | [Security](SECURITY.md) |
| Contribute, or maintain and release | [Contributing](CONTRIBUTING.md), [Maintaining](docs/MAINTAINING.md) |
| The full product definition: requirements, access policy, decisions | [spec/](spec/README.md) |

## Building from source

You need macOS 15 or later, Xcode 27 and Python 3.11 (to convert the embedding model once).

```sh
sh scripts/fetch_embedding_model.sh
sh scripts/test.sh
```

The first command downloads the bundled embedding model ([bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5)) at a pinned revision, checks its checksums and converts it to Core ML in `~/Library/Caches/com.funesvault.dev/`; it isn't in git. The second runs the package tests, the MCP harness and the other checks, and builds the app unsigned. To work on the app, open `FunesVault.xcodeproj` in Xcode and run the **FunesMac** scheme. Debug builds honour `FUNES_DATA_DIR`, so a development vault never touches your real one. See [Contributing](CONTRIBUTING.md).

## Uninstall

1. Quit Funes Vault from its menu.
2. Remove Funes from your agents' configs (for example `claude mcp remove --scope user funes`).
3. Delete the app from Applications, and its data: `~/Library/Application Support/FunesVault` (the vault, backups, agent keys and Activity). If you linked the launcher, delete `~/.local/bin/funes-mcp`. API keys for model providers you added are in the Keychain under `com.funesvault.provider`.

To start over without uninstalling, **Settings ▸ Data ▸ Erase All Data…** deletes every memory, suggestion, agent and key, Activity, backups and provider keys, then relaunches empty.

Installed with Homebrew, `brew uninstall --cask funes-vault` removes the app; `brew uninstall --zap --cask funes-vault` also moves the data folder, caches and preferences to the Trash (provider API keys stay in the Keychain).

## License

Funes Vault is licensed under the [Apache License 2.0](LICENSE); see [NOTICE](NOTICE). The app bundles GRDB.swift, Sparkle and the bge-small-en-v1.5 model by BAAI, each under the MIT License; their licence texts ship in the app. The license doesn't grant rights to the project's name or icon. Apple, Mac and macOS are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple, Anthropic, OpenAI or BAAI.

Funes Vault is made by [Martin Bereciartua](https://www.linkedin.com/in/bereciartua/), who also makes [EK Bridge](https://github.com/bereciartua/ek-bridge).
