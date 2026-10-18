# Funes Vault: project definition

> **Funes Vault: Give AI agents your memory. Not all of it.**
> A native Mac menu bar app that keeps your personal context in a private vault on your Mac and serves it to AI agents through a local MCP server, only as you allow. An iPhone companion captures thoughts anywhere and searches the vault when your Mac is reachable.

**Status:** definition; repo set up, Phase 0 next · drafted 2026-10-16 · owner: Martin Bereciartua.

This folder (`spec/` in the `funes-vault-app` repo) holds the requirements, design, architecture, plans and roadmap. It's the source you build from: tick the phase checklists and add ADRs here as work progresses.
- **Code:** the repo `bereciartua/funes-vault-app`.
- **Website:** funesvault.com.
- **Bundle IDs:** `com.funesvault.*` (see [project setup](plans/project-setup.md#targets-and-identifiers)).

## At a glance
- **What it is:**
  - A personal memory vault on your Mac.
  - Agents (Claude Code, Claude Desktop, Cursor, Codex, …) connect over MCP.
  - Cloud agents (ChatGPT, claude.ai, …) connect through **Remote Access** (experimental, off by default): a tunnel you run, with OAuth sign-ins you approve on the Mac.
  - Each agent gets **its own key and only the access you grant**: read, suggest or save; up to a sensitivity level; in chosen categories.
- **How sharing works:**
  - **You approve the exact text** in a small panel, and can untick what shouldn't go.
  - An approval is **single use**, valid for **15 minutes**, and **invalidated if anything changes**.
  - Denials tell agents only *how many* memories were withheld and why, never which ones.
- **How memories get in:**
  - Agents **suggest** memories, and you review them in the **Inbox**.
  - You capture with a hotkey, from the Services menu, or from your iPhone.
  - You can seed the vault from seven quick questions, or by importing ChatGPT or Claude memories.
- **What you can see:** the **Activity** log records everything (ids only, never text). You can pause or remove an agent in one click.
- **The same rules everywhere:** a cloud agent gets exactly the access, panels and waits you set for it, like a local one.
- **Privacy:**
  - **Everything is local:** no account, no server, no cloud copy. With Remote Access on, the vault answers through your tunnel, and what you share with a cloud agent goes to its vendor.
  - **AI is local by default:** search uses a small embedding model built into the app (bge-small, Core ML), and classification uses Apple's on-device models, with no API keys.
  - **Any model you prefer, per task:** a local server (Ollama, LM Studio) or a cloud model (Claude, GPT, Gemini…). Funes shows what it sends, never sends secrets, and never sends memories above your cloud sensitivity limit.
- **iPhone (v0.2):**
  - a **thin client** paired by QR code;
  - signed and end-to-end encrypted messages over the same Wi-Fi, Tailscale or an optional tunnel;
  - **capture always works** (offline queue, delivered exactly once);
  - search, edit and review when the Mac is reachable;
  - **approve agents' requests from the phone** (a notification with no memory text in it).
- **How it's built:**
  - Swift with SwiftUI in AppKit, SQLite through GRDB.
  - About 14K lines reused from **EK Bridge**: MCP server, launcher, approvals, activity, agent setup, Sparkle and the release pipeline.
  - The protocol and security core becomes a shared library, **BridgeKit**, used by both apps.
  - Developer ID plus Homebrew for the Mac; the App Store for the iPhone.
- **Relationship to the web version** (`funes-vault` repo, same name): a new product built from scratch, in a **new repo** (`funes-vault-app`). Nobody uses the web version, so nothing is migrated. Its rules and tests are reference material. `funes-vault` stays as a historical artifact, and gets a "no longer maintained" note once Funes App is production-ready.

## Read in this order
1. **Product**
   - [Vision](product/01-vision.md): problem, product, principles, non-goals, success.
   - [Users and use cases](product/02-users-and-use-cases.md): personas, jobs to be done, key scenarios.
   - [Requirements](product/03-requirements.md): 141 requirements (109 functional, 32 non-functional) with ids, priorities and acceptance criteria.
   - [UX: Mac](product/04-ux-mac.md) and [UX: iPhone](product/05-ux-iphone.md): screens, panels, flows, copy.
2. **Domain**
   - [Domain model](domain/domain-model.md): entities, enums, state machines.
   - [Access policy](domain/access-policy.md): **the core spec**, with 35 test vectors.
   - [Memory processing](domain/memory-processing.md): secret scanner, embeddings, ranking, classification, imports, consolidation.
   - [Glossary](domain/glossary.md).
3. **Architecture**
   - [Overview](architecture/overview.md): components, concurrency, sequence diagrams, repo layout.
   - [MCP server](architecture/mcp-server.md): transport, auth, the 5 tools with schemas, limits.
   - [Companion protocol](architecture/companion-protocol.md): pairing, HPKE envelope, methods, offline queue.
   - [Storage](architecture/storage.md): files, SQL schema, migrations, maintenance jobs.
   - [Security and privacy](architecture/security-and-privacy.md): threat model, guarantees, what leaves the Mac.
   - [AI model providers](architecture/model-providers.md): on-device by default, per-task model choice, guardrails, fallbacks, re-embedding.
   - [Reusing EK Bridge](architecture/ek-bridge-reuse.md): what to copy, what to rewrite, refactors.
   - [Decision records](architecture/decisions/README.md): 18 ADRs.
4. **Plans**
   - [Plans index](plans/README.md): Phase 0 spikes through Phase 5 (with Phase 4b, Remote Access, before the launch), plus project setup, testing, releases.
   - [Open questions](plans/open-questions.md): 24 decisions with recommendations. Already decided include Q1 (name), Q3 (license), Q4 (repo), Q5 (minimum macOS), Q8 (BridgeKit), Q9 (Xcode project), Q14 (AI models), Q15 (Remote Access in v0.1), Q16 (iPhone approvals in v0.2), Q17 (web version), Q23 (domain).
5. **Roadmap**
   - [Roadmap](roadmap/roadmap.md): timeline, milestones, release scopes.
   - [Backlog](roadmap/backlog.md): epics mapped to requirements and phases.

## Key decisions (summary)
| Decision | Choice | Record |
|---|---|---|
| Platform | Native macOS menu bar app; iPhone companion | [ADR-0001](architecture/decisions/0001-native-menu-bar-app.md) |
| Agent interface | Local MCP over loopback HTTP + `funes-mcp` stdio launcher | [ADR-0002](architecture/decisions/0002-local-mcp-server.md) |
| Cloud agents | Remote Access in v0.1 (experimental): a separate loopback port (47627) behind the user's tunnel, OAuth or remote token per agent, the same policy on every channel | [ADR-0018](architecture/decisions/0018-remote-access-in-v0.1.md) (amends 0002, 0013) |
| Data location | The Mac only; the iPhone is a thin client; no CloudKit | [ADR-0003](architecture/decisions/0003-mac-is-the-only-source-of-truth.md) |
| Storage | SQLite + FTS5 via GRDB | [ADR-0004](architecture/decisions/0004-sqlite-grdb.md) |
| AI models | Apple on-device by default; user-selectable per task (local servers or cloud providers) with a cloud sensitivity limit and disclosures | [ADR-0014](architecture/decisions/0014-user-selectable-models.md) (supersedes 0005) |
| Search | Hybrid: FTS5 with stemming + bundled bge-small embeddings (Core ML, on the Mac); agents add `keywords`; other embedding models later | [ADR-0016](architecture/decisions/0016-bundled-bge-small-embeddings.md) (supersedes 0015) |
| Build | Xcode project + local Swift packages | [ADR-0006](architecture/decisions/0006-xcode-project-and-packages.md) |
| Distribution | Developer ID, not sandboxed (Mac); App Store (iPhone) | [ADR-0007](architecture/decisions/0007-developer-id-not-sandboxed.md) |
| Code reuse | Shared library **BridgeKit** with EK Bridge: protocol and security core extracted now (`BridgeKitCore`, EK Bridge adopts it first); UI pieces copied, extracted after v0.1; Remote Access extracted now as `BridgeKitRemote` (0.2.0) | [ADR-0013](architecture/decisions/0013-shared-bridgekit-core.md) (supersedes 0008), [ADR-0018](architecture/decisions/0018-remote-access-in-v0.1.md) |
| Access model | Fail closed; paired devices act as owner | [ADR-0009](architecture/decisions/0009-fail-closed-owner-device.md) |
| Web version | Start from scratch; reference only | [ADR-0010](architecture/decisions/0010-start-from-scratch.md) |
| Phone ↔ Mac security | HPKE + P-256 (Secure Enclave) app-layer encryption | [ADR-0011](architecture/decisions/0011-app-layer-encryption-for-companion.md) |
| Denials | Withheld counts, never ids | [ADR-0012](architecture/decisions/0012-withheld-counts-not-ids.md) |

## Timeline (side project, about 1 weekend per week)
- **Phase 0:** spikes.
- **Phase 1:** FunesCore.
- **Phase 2:** BridgeKit (shared with EK Bridge) and MCP.
- **Phase 3:** Mac app.
- **Phase 4b:** Remote Access for cloud agents: BridgeKitRemote, EK Bridge adopts it, Funes integration (4–5 weekends, before the launch).
- **Phase 4:** ship **v0.1** (target early Jan 2027).
- **Phase 5:** iPhone companion with approvals from the phone, **v0.2** (Feb–Mar 2027).

Details are in the [roadmap](roadmap/roadmap.md).

## Sources this definition is based on
- **`bereciartua/funes-vault`** (web):
  - policy evaluator and reason codes;
  - disclosure and suggestion flows;
  - input limits;
  - default categories;
  - seed questions;
  - secret patterns;
  - privacy and threat model.
- **`bereciartua/ek-bridge`** v0.11.1:
  - MCP server, launcher, keys and limits;
  - approvals and activity;
  - agent setup;
  - release, Sparkle, Homebrew and MCP Registry;
  - docs layout.
- **Research notes** (outside this repo, in the author's iCloud Drive: `Projects (iCloud)/Personal/Apps Brainstorming/ideas/v4/research/`) (port inventory, EK Bridge reuse inventory, platform facts), plus the v4.2 plan in `Apps Brainstorming/ideas/v4/`.
- **Apple documentation:**
  - supported macOS capabilities (CloudKit for Developer ID; not used, kept for later);
  - CryptoKit HPKE;
  - NaturalLanguage `NLContextualEmbedding`;
  - Foundation Models;
  - Private Cloud Compute for developers.

