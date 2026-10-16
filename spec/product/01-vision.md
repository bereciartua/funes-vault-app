# Vision

> **Funes Vault: Give AI agents your memory. Not all of it.**

## The problem

AI assistants keep forgetting you. Every new chat, coding agent or tool starts cold, so you repeat who you are, how you like to work, what you're building and which constraints matter. The fixes on offer pull in opposite directions:

- **Built-in memory in each assistant** (ChatGPT, Claude, Gemini) is locked to that vendor. It drifts between tools, and it decides on its own what to remember and when to use it. You can't easily see or control what a third-party tool receives.
- **Pasting context into every tool** gives away too much, too often, with no record of what went where.
- **Hosted "memory layers"** for agents (Mem0, Supermemory and others) are built for developers who build agents. They store your memory on someone else's server and are mostly about retrieval, not consent.

What's missing is a personal memory you own. It should live on your own device, work with every AI tool, and **share only what you allow, with whom you allow, with a record of every disclosure.**

## The product

**Funes** is a native Mac app that keeps your durable personal context (preferences, instructions, projects, constraints, goals, relationships) in a private vault on your Mac. It serves that context to AI agents through a **local MCP server** under rules you set.

- **Every agent starts with nothing.** You decide, per agent, whether it can read, suggest or save memories, up to which sensitivity, in which categories, and whether it must ask first.
- **You approve exact text.** When an agent needs context, a small panel shows the precise memories it would receive. You pick which ones go, and only those leave the vault. The approval works once.
- **Agents can suggest, you decide.** Agents propose new memories. They land in your Inbox, or in a "Save this memory?" panel, and become part of the vault only when you approve.
- **You can see everything.** The Activity log records every disclosure, refusal, suggestion and change, using ids only and never memory text, and lets you pause or cut off any agent instantly.
- **Your phone is a remote for the vault.** The Funes iPhone app pairs with your Mac. It captures thoughts anywhere, even when the Mac is asleep, and searches and reviews the vault when the Mac is reachable. Your memory never lives in anyone's cloud.

## Who it's for

- **v0.1:** people who use several AI agents every day (Claude Code, Claude Desktop, Cursor, Codex, ChatGPT, VS Code Copilot) and are tired of repeating themselves. They care where their personal context goes. Technical enough to install a Mac app and click "Add to Claude Code"; not necessarily developers.
- **Later:** privacy-minded professionals who use AI assistants for work and personal life and want one portable memory under their control.

See [users and use cases](02-users-and-use-cases.md).

## Principles

1. **Local first.** The vault lives on the Mac. There's no account, no server of ours and no cloud copy. The only traffic is what you enable: update checks, the paired iPhone talking to the Mac, and any AI model provider you choose.
2. **Consent is the product.** Storage and retrieval are commodities. Funes differs in deliberate disclosure: per-agent scopes, exact-text approval, single-use releases and a full audit trail.
3. **Fail closed.** An unknown agent, a missing grant, an expired permission or an unanswered prompt always means *no*.
4. **Agents' words are data, not instructions.** An agent's stated purpose or task text never changes an access decision. Memory text returned to agents is marked as context, not commands.
5. **Show, don't summarize.** Approval panels show the exact text being shared, never an AI paraphrase or the agent's own description.
6. **Ids, not content, in logs.** Logs record what happened, never the memory text itself.
7. **Local AI by default, your choice of model.** Classification and semantic search use Apple's on-device models by default: no API keys, no cost, nothing leaves the Mac. You can switch any task to a local server (Ollama, LM Studio) or a cloud model (Claude, GPT, Gemini…). Funes then shows what it sends, never sends secrets, and never sends memories above your cloud sensitivity limit.
8. **Native and quiet.** A menu bar app that stays out of the way, follows macOS conventions, and asks for attention only when an agent wants something.
9. **Built the EK Bridge way.** Same trust model, the same quality bar and as much shared code as possible with [EK Bridge](https://github.com/bereciartua/ek-bridge).

## Non-goals

- **Not a chat app.** Your AI agents are the chat. Funes doesn't host conversations, voice sessions or an assistant persona.
- **Not a note-taking app or second brain.** Memories are short, durable facts and instructions (a title plus up to 10,000 characters), not documents, files or a knowledge graph.
- **Not a sync service.** There's no multi-Mac replication and no web access. One Mac holds the vault.
- **Not a team product.** One person, one vault.
- **Not a memory layer for agent developers.** No SDK, no hosted API, no multi-tenancy.
- **Not automatic extraction.** Funes doesn't read your conversations or screen to mine memories. Memories come from you or from agent suggestions you approve.
- **Not a security product against malware.** Like EK Bridge, Funes separates the agents you connect from each other. It can't protect the vault from malicious software already running as your macOS user.

## Relationship to existing projects

- **The web version** (`bereciartua/funes-vault`, also called Funes Vault) is the earlier self-hosted web app. The native Funes Vault is a **new product built from scratch** in a new repo (`bereciartua/funes-vault-app`). The web app has no users, so nothing is migrated. Its policy rules, privacy guarantees and tests are used as **reference material**. The web repo stays as a **historical artifact**. Once Funes App is production-ready, its README gets a "no longer maintained" note pointing to the new repo (see [ADR-0010](../architecture/decisions/0010-start-from-scratch.md)).
- **EK Bridge** (`bereciartua/ek-bridge`) is the sibling app with the same shape: a menu bar app, a local MCP server, keys per agent, approval panels and an activity log. Funes reuses about 14K lines of its Swift. EK Bridge gives agents your calendar, not all of it; Funes gives them your memory, not all of it.

## What success looks like

- **v0.1, Mac public preview:** you use Funes every day with at least two agents instead of re-explaining context. A new user goes from download to the first successful agent request in under 5 minutes. No memory text ever appears in logs.
- **v0.2, iPhone companion:** a thought captured on the iPhone, even with the Mac asleep, reaches the Mac's Inbox exactly once after the Mac wakes. Search from the phone works on the same Wi-Fi and over Tailscale.
- **Adoption signals to watch:**
  - downloads per release (EK Bridge's baseline: about 15–25);
  - stars and Homebrew installs;
  - MCP Registry listing views;
  - issues filed by people other than the author.

## Name

**Funes Vault** (decided 2026-10-16, [Q1](../plans/open-questions.md)).
- **"Funes"** comes from Jorge Luis Borges's story *Funes the Memorious*, about a man who forgets nothing. **"Vault"** adds what sets the product apart: control over who gets what.
- **Short form:** "Funes", in UI copy where space is tight, and in technical names (MCP server key `funes`, launcher `funes-mcp`).
- **Assets:** the wordmark **funes.** and the existing logo system (`~/Downloads/funes_vault_logo_system`) carry over.
- **Domain:** funesvault.com.
- **App Store:** name "Funes Vault", subtitle "Private memory for AI agents". The subtitle carries the "memory" and "AI" keywords, and keeps the app from being mistaken for a photo or password vault.
- **Not to be confused with** the iPhone app "FUNES." (a 3D cultural-heritage archive by another developer).
