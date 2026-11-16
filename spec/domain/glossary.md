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
| **Profile** | The user's own details, shown as **About you**: given and family name, the called name (preferred, else given), pronouns, languages, location, time zone, occupation. One per vault, not a memory. Each agent receives the **profile fields** the user ticks for it, with its `request_memory` answers ([ADR-0026](../architecture/decisions/0026-about-you-profile.md)). From v0.10 its names also identify the user in memories, matched on the Mac for learned facts; they're replaced by "the user" in any memory text sent to a model, never added. |
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
| **Learned facts** / **Facts about you** | v0.10 ([ADR-0032](../architecture/decisions/0032-facts-about-you.md)). What Funes learns from the user's memories about the people in their life and where they've worked, for their own search and answers only; agents never use them. Settings ▸ AI ▸ Features ▸ **Facts** (working name), off by default, with *Learn from memories*, *Use in search and answers* and **Remove learned facts**. Shown in Vault ▸ **People & history** ([memory processing §11](memory-processing.md#11-facts-about-you)). |
| **Entity** | A person, organization, place or thing memories mention, named or unnamed, with its aliases. One entity is *you*, with no stored name. Not to be confused with the domain model's list of record types. |
| **Role group** | An entity standing for several people under one role ("your sisters", "my parents"), with an optional count, until its members are named. A mention linked to a group is never shown with a name. |
| **Fact** | You → predicate → entity ("Lucía is your sister", "you worked at Acme"), with typed qualifiers (your word for it, a job's title and kind), order edges and evidence from the memories that state or mention it. Only facts about you in v0.10. |
| **Predicate** | A kind of fact (partner, sibling, manager, works at, client…), defined as data in the versioned registry that ships with the app: its object's kind, flags, language data, call group and uses (recorded, linked, timeline). No code names a predicate. |
| **Episode** | One interval of a fact, derived from what memories assert, with dates as ranges at the precision written ("2019" is the whole year). Never stored: the timeline, "previous" and role phrases all read episodes. |
| **Link** | A memory's mention ("my sister", "Alex") resolved to an entity, with a basis. Links admit search results without boosting them, and show a **why line** ("my sister → Maria (only sister Funes knows)"). |
| **Basis** | How sure a link or a date is. A resolution basis says which entity a mention means (`confirmed`, `named`, `stated_unique`, `context`, `sole_known` ("probably"), `candidates`, `ambiguous`, `untrusted`, `rejected`); a time basis says how a date or order was found (`stated`, `ordered`, `inferred`, `gap`, `ambiguous`). The weakest in a chain decides. |
| **Bridge** | In a timeline answer ("What was my job before Acme?"), one of up to 2 memories that state the answer fact, added on top of the 10 results: "Read 10 results and 2 from your history". |
| **Inferred claim** | A search answer claim that rests on Funes's inference rather than only on the text it quotes: it names an entity or states a fact the cited text doesn't, or cites a bridge. Code marks it from structured data, never from the model's wording, and offers **Not <name>** and **Not this**. |
| **Not <name>** / **Not this** | The corrections on every why line and inferred claim: the mention isn't that entity; the fact isn't right. Made from a memory, they're keyed to it and the quoted span, and survive edits that keep the span; made without one, they apply everywhere. Manual entries and corrections win over inference and survive Remove learned facts and purges (what they reference stays as a tombstone). |
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
