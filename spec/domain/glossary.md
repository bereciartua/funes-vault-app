# Glossary

| Term | Meaning |
|---|---|
| **Funes Vault** | The product: the Mac app (Funes Vault for Mac) and the iPhone companion (Funes Vault for iPhone). "Funes" is the short form. Not to be confused with **the web version** (`funes-vault` repo), the earlier self-hosted project of the same name. |
| **Vault** | All of the user's memories, stored on the Mac. |
| **Memory** | One durable piece of personal context: a title plus a body, with kind, categories, sensitivity and optional expiry. |
| **Kind** | What sort of memory it is: fact, preference, instruction, goal, project context, relationship, constraint, event, summary. |
| **Category** | A topic tag used for access rules (e.g. Software Development, Health). There are 8 built-in categories, and custom ones are possible. |
| **Sensitivity** | An ordered level from Public to Secret. Each agent has a maximum. |
| **Agent** | An MCP client the user added (Claude Code, Cursor…). It has its own key and its own access. "Client" in protocol terms; "connection" in EK Bridge. |
| **Access** | One agent's rules: operations, maximum sensitivity, allowed and denied categories, ask before sharing or saving, and expiry. |
| **Profile** | The user's own details, shown as **About you**: given and family name, the called name (preferred, else given), pronouns, languages, location, time zone, occupation. One per vault, not a memory. Each agent receives the **profile fields** the user ticks for it, with its `request_memory` answers ([ADR-0026](../architecture/decisions/0026-about-you-profile.md)). |
| **Operation** | Read (receive memories), Suggest (propose memories for review), Write (save directly, if ask before saving is off). |
| **Ask before sharing** | Every release of memories to this agent needs the user's approval in a panel. On by default. |
| **Request** / **Disclosure** | An agent asking for memories for a task (`request_memory`), and the record of what was decided and released. |
| **Eligible** | A retrieved memory that passes all of an agent's access checks. |
| **Withheld** | A retrieved memory that didn't pass. Reported to the agent only as counts by reason. |
| **Release** / **Bundle** | The set of memory texts sent to an agent, with instructions, within a token budget. |
| **Approval** | The user choosing which eligible memories to release. Single use, valid 15 minutes, invalidated by changes. |
| **Pending request** | A request that is waiting for approval after the panel timed out. It can be approved for up to 15 minutes. |
| **Suggestion** | A proposed new memory, or a change to one, from an agent, a capture, an import, a seed question or the daily tidy-up. Waits in the Inbox, unless the user lets Funes apply it automatically. |
| **Atomic memory** | A memory that holds one independent claim. New memories processing splits input into atomic pieces (Phase 6). |
| **New memories processing** | Splitting every new input (captures, agent suggestions and writes, imports) into atomic pieces, classifying each and linking it to related memories (create, update, already saved, retract). Settings ▸ AI ▸ Features ▸ New memories. |
| **Daily tidy-up** | The daily job that compares changed memories with related ones and proposes updates, merges, splits, archives and conflicts. It replaces the earlier "consolidation" design. |
| **Auto-apply** | The user's setting (Off · Duplicates only · Everything except conflicts) that lets Funes apply its own proposals, with Undo for 30 days. Never on the strength of untrusted text; conflicts always go to the user. |
| **Trusted / untrusted memory** | Where a memory's text came from: trusted if the user typed, dictated or applied it; untrusted if an agent saved it directly, or auto-apply saved it from an import or shared text. |
| **Daily cap** | The most cloud generation requests Funes makes in a day (300 by default); embeddings don't count. |
| **Subscription provider** | A model provider reached through the user's own Claude Code or Codex, signed in to their Claude or ChatGPT plan, instead of an API key. Funes never handles the plan's credentials, and runs the CLI with every tool off. |
| **Capture** | A quick note from the hotkey, the Services menu or the iPhone. It becomes a suggestion. |
| **Inbox** | Where suggestions are reviewed: apply, edit, reject. |
| **Activity** | The append-only log of everything that happened. It stores ids, never memory text. |
| **Provenance** | A memory's own history (created, edited, shared…), with labels only. |
| **Reason code** | A machine-readable explanation for a decision (e.g. `above_sensitivity_ceiling`). |
| **Revision** | An agent's change counter. Approvals and allow windows are bound to it. |
| **Version** | A memory's change counter. Approvals are bound to it. |
| **Allow window** | An optional 15-minute period in which one agent gets LOW and PUBLIC memories without asking. |
| **Key** | An agent's secret token (`fns_mcp_v1_…`). Lives in a 0600 file; the database stores only its hash. |
| **Launcher** | `funes-mcp`: the stdio program agents run. It relays to the local HTTP MCP server. |
| **Device** / **Owner device** | A paired iPhone. It acts as the user, with full access, and is logged and revocable. |
| **Pairing** | One-time QR-code setup that exchanges keys between the Mac and an iPhone. |
| **Companion API** | The HTTP API the iPhone uses to talk to the Mac. Signed and end-to-end encrypted. |
| **Capture queue** | Captures waiting on the iPhone until the Mac acknowledges them. |
| **Same Wi-Fi / Tailscale / Public tunnel** | The three ways the iPhone can reach the Mac. |
| **BridgeKit** | The shared Swift library used by Funes and EK Bridge (repo `bereciartua/bridgekit`). Product **BridgeKitCore**: HTTP, MCP protocol, keys, limits, launcher, safe files, config writer. **BridgeKitRemote** (0.2.0): Remote Access. Later **BridgeKitUI**. |
| **Remote Access** | The second loopback listener (47627) that a tunnel the user runs makes reachable to cloud agents. Experimental, off by default ([ADR-0018](../architecture/decisions/0018-remote-access-in-v0.1.md)). |
| **Cloud access** | A per-agent switch letting that agent's remote token and OAuth-connected cloud apps use Remote Access. It never changes the agent's access. |
| **BridgeUI** | Funes's local package of UI pieces copied from EK Bridge (approvals, activity, agent setup UI, app shell). Becomes BridgeKitUI after v0.1. |
| **FunesCore** | The Swift package with the vault logic: store, policy, search, processing. Mac only. |
| **Model provider** | Where an AI task runs: Apple on-device (default), Apple Private Cloud Compute, a local server (Ollama, LM Studio), or a cloud provider (OpenAI, Anthropic, Gemini, OpenRouter, custom). Added in Settings ▸ AI ▸ Models & Accounts (an account or plan, with its list of models); each task picks an account and one of its models in Settings ▸ AI ▸ Features. |
| **Cloud sensitivity limit** | The highest sensitivity Funes will ever send to a non-local model provider (default Internal). Memories above it are keyword-search only under a cloud embedding model. |
| **FunesProtocol** | The Swift package shared by the Mac and the iPhone: companion API types, crypto, secret scanner. |
| **Spike** | A short, throwaway experiment that answers one risky technical question before building. |
