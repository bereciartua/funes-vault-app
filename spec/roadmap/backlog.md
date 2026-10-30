# Backlog

Epics map requirements to phases.
- **Size:** S ≤ 2 h, M ≤ 5 h, L > 5 h.
- **Priority:** M/S/C/L as in [requirements](../product/03-requirements.md).

## E0: Foundations (Phase 0–1)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Spike 2: search quality benchmark | FR-V-10, FR-AI-01 | 0 | M | M |
| Spike 3: agent approval-wait behaviour | FR-D-03, FR-D-05 | 0 | S | M |
| Quick checks: hotkey, Services, Foundation Models, GRDB FTS, notarize hello-world | — | 0 | M | M |
| Repo, Xcode project, packages, CI skeleton, CLAUDE.md | project setup | 0 | M | M |

## E1: Vault core (Phase 1)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Models, enums, input limits | domain model | 1 | S | M |
| VaultStore + schema v1 + migrations + FTS triggers + backups | FR-V-01..04, NFR-REL-01/02 | 1 | M | M |
| Categories (built-in seed) | FR-V-05 | 1 | S | M |
| Secret scanner | NFR-SEC-06 | 1 | S | M |
| Hybrid search: FTS5 porter + bundled bge-small Core ML (WordPiece, index, min-max fusion) + Spike 2b recall regression | FR-V-10, FR-AI-01 | 1 | M | M |
| `keywords` on `request_memory` (schema, retrieval, panel) | FR-D-01 | 2 | M | S |
| Provider embedding model as a second index, re-embedding, calibration (ADR-0023) | FR-AI-09, FR-AI-11 | 6c | M | M |
| Model providers for classification: protocols, ModelRouter, Apple / OpenAI-compatible / Anthropic adapters, guardrails, Keychain keys | FR-AI-05..08, 10 | 1 | M | M |
| Provenance | FR-V-12 | 1 | S | M |
| What a change did in Activity and History; earlier versions of memories (ADR-0027) | FR-L-02, FR-V-12, FR-V-16 | 8 | M | S |

## E2: Policy and disclosure (Phase 1)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| PolicyEngine (gate, eligibility, decision, scope) | FR-D-01, T1–T12, T27–T33 | 1 | M | M |
| BundleCompiler | FR-D-09, FR-D-11 | 1 | S | M |
| DisclosureService (snapshot, approve, deliver, expire) | FR-D-04..08, FR-D-10 | 1 | M | M |
| SuggestionService + CaptureService | FR-S-01..06, FR-C-05 | 1 | M | M |
| AgentService (keys, access, revision) | FR-A-03..06 | 1 | S | M |

## E3: MCP (Phase 2)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Create `bridgekit` repo; move tier-1 code + tests; reference harness; tag 0.1.0 | ADR-0013 | 2 | L | M |
| EK Bridge adopts BridgeKitCore (build.sh linking, proof: tests unchanged, patch release) | ADR-0013 | 2 | M | M |
| Copy tier-2 UI pieces into `Packages/BridgeUI` + PROVENANCE | ADR-0013 | 2 | S | M |
| Tool contract JSON + golden fixture + visibility | FR-M-04 | 2 | S | M |
| Handlers (5 tools) | FR-D, FR-S | 2 | M | M |
| Pipeline + rate limits + endpoint file | FR-M-01, FR-M-05 | 2 | S | M |
| Launcher `funes-mcp` | FR-M-02 | 2 | S | M |
| Python MCP harness | testing | 2 | M | M |

## E4: Approval UX (Phase 2–3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Share panel (partial approval, countdown, arming) | FR-D-03, FR-D-04 | 2 | M | M |
| Save panel (non-blocking) | FR-S-02 | 2 | S | M |
| Pending requests list | FR-D-05 | 3 | S | M |
| Access-request panel + throttle | FR-A-10 | 3 | S | S |
| Allow window | FR-D-12 | later | S | C |

## E5: Mac app shell and vault UI (Phase 3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Menu bar, main window, settings, pause all, login item, AppMover | FR-G-01/02, FR-A-11, FR-O-03 | 3 | M | M |
| Vault list, search, filters, detail editor, provenance | FR-V-01..12 | 3 | L | M |
| Recently Deleted | FR-V-04 | 3 | S | M |
| Custom categories UI | FR-V-06 | 3 | S | S |
| Bulk actions, duplicate hint, "still true" | FR-V-13..15 | 3 | S | S/C |

## E6: Inbox and capture (Phase 3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Inbox cards, apply/edit/reject, badge | FR-I-01, 02, 04 | 3 | M | M |
| Bulk review, stale suggestions | FR-I-03, 05 | 3 | S | S |
| Correction diff (Replace / Keep both) | FR-S-06 | 3 | S | M |
| Hotkey capture box + menu item | FR-C-01, 02 | 3 | S | M |
| Services provider | FR-C-03 | 3 | S | S |
| Classification via ModelRouter (default Foundation Models + rules) | FR-C-04, FR-AI-02 | 3 | M | S |
| AI Models settings: Classification picker, providers + Keychain keys, test connection, cloud limit, disclosures, usage | FR-AI-05..08, 10, 12 | 3 | M | M |

## E7: Agents UI and setup (Phase 3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Add agent + detection + presets | FR-A-01, 02 | 3 | M | M |
| Access editor | FR-A-03 | 3 | M | M |
| Connect tab: one-click (4 agents) + snippets | FR-A-07, 08 | 3 | M | M |
| Status, first request, pause/remove/rotate | FR-A-04..06, 09 | 3 | S | M |

## E8: Activity (Phase 3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| ActivityStore adaptation + retention | FR-L-01, 03 | 2–3 | S | M |
| Activity view + live lookup + deep links | FR-L-02 | 3 | M | M |
| Notifications | FR-L-04 | 3 | S | S |

## E9: Onboarding, import and export (Phase 3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Setup checklist | FR-O-01 | 3 | S | M |
| Seed questions | FR-O-02 | 3 | S | M |
| Import ChatGPT / Claude / Markdown + preview | FR-X-01..04 | 1/3 | M | S |
| Export / import funesvault.export.v1 | FR-X-05, 06 | 1/3 | S | M/S |
| Backups UI, Erase All Data | FR-G-04, 05 | 3 | S | S/M |

## E10: Ship v0.1 (Phase 4)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Release script + CI workflows + attestation | NFR-SEC-07 | 4 | M | M |
| Sparkle updates | FR-G-03 | 4 | S | M |
| Homebrew cask + MCP Registry + directories | FR-M-06 | 4 | S | M |
| Docs: README, ARCHITECTURE, MCP, TESTING, SECURITY, PRIVACY | NFR-MAINT-03 | 4 | M | M |
| Live matrix (4 local agents, plus ChatGPT and claude.ai after Phase 4b) | testing | 4 | S | M |
| Accessibility pass + UI snapshots | NFR-A11Y | 3–4 | M | M |

## E10b: Remote Access for cloud agents (Phase 4b, before the v0.1 launch)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| BridgeKitRemote: move tier 3 + tests + remote harness; tag 0.2.0 | ADR-0013, ADR-0018 | 4b | L | M |
| EK Bridge adopts BridgeKitRemote (proof: tests and goldens unchanged, daily remote use, release) | ADR-0018 | 4b | M | M |
| Agents: cloud access, remote token, revision bumps, schema migration | FR-AI-04 | 4b | S | M |
| Remote listener on 47627, same pipeline and rate limits | FR-AI-04, NFR-SEC-01/02 | 4b | S | M |
| OAuth pairing → agent, sign-in sheet, connected apps, Revoke | FR-AI-04 | 4b | S | M |
| Remote Access page, guided tunnel setup, Switch Tunnel, menu bar state | FR-AI-04 | 4b | M | M |
| Agent Cloud section, cloud setups + goldens, cloud tiles in Add Agent | FR-AI-04 | 4b | S | M |
| Activity rows marked remote | FR-AI-04, FR-L-01 | 4b | S | M |
| Harness: remote paths + "same decision local vs remote" | FR-AI-04 | 4b | M | M |
| Docs when the code lands; live check with ChatGPT and claude.ai | NFR-MAINT-03 | 4b | S | M |

## E11: iPhone companion (Phase 5)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Spike 1: companion transport | ADR-0011 | 5 | L | M |
| FunesProtocol companion types + crypto + fuzz | NFR-SEC-04 | 5 | M | M |
| Mac companion server + pairing + devices + Bonjour | FR-P-01..06 | 5 | L | M |
| iPhone foundation: keys, client, discovery | FR-iOS-01 | 5 | M | M |
| Capture + queue + delivery + extensions | FR-iOS-02..05 | 5 | L | M |
| Search, detail, edit, Inbox | FR-iOS-06..09 | 5 | M | M |
| Demo mode + App Store submission | FR-iOS-10 | 5 | M | M |
| Unpair / revoke flows | FR-iOS-11, FR-P-03 | 5 | S | M |

## E11b: Approvals from the iPhone (Phase 5)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Decide the push channel (CloudKit doorbell or APNs relay) and measure its delivery time; ADR | Q24 | 5 | S | M |
| Mac: doorbell with no text, fetch-and-answer companion methods, first answer wins | FR-iOS-12 | 5 | M | M |
| iPhone: notification (worded on the phone), Share and Save panels, unlock to answer | FR-iOS-12 | 5 | M | M |
| Tests: no text in the push, races, revoked device | FR-iOS-12 | 5 | S | M |

## E13: Memory processing (Phase 6, v0.3)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Spike E: extraction, linking and tidy-up quality per provider; synthetic fixtures | ADR-0020, ADR-0021 | 6.0 | M | M |
| Per-action apply (archive, duplicate, split, merge, conflict) everywhere; version-checked targets; Mac editor expected version | FR-I-02, FR-I-03 | 6.1 | M | M |
| Schema v4: trust, watermark, groups, targets, jobs, undo, runs, dismissals, provenance links | ADR-0020, ADR-0021 | 6.1 | M | M |
| Durable processing queue for every ingest path (iPhone captures included) | FR-AI-13 | 6.1 | M | M |
| Multi-item cloud guard, on-device pre-screen for agent and import text, new cloud limit levels, daily cap | FR-AI-07, FR-AI-15 | 6.1 | M | M |
| Undo log with purge; Activity events; export and restore of status and links | FR-AI-14, FR-V-04 | 6.1 | M | M |
| iPhone: unknown actions as "Review on your Mac"; per-action `inbox.apply` | FR-iOS-09 | 6.1 | S | M |
| Subscription providers: Claude Code and Codex CLIs, isolated and fail-closed (ADR-0024) | FR-AI-16 | 6a | M | M |
| Extraction, validation, linking, groups, agent policy (scope flags, direct writes) | FR-AI-13 | 6a | L | M |
| Auto-apply for new memories; Inbox group cards; Applied automatically with Undo; Settings | FR-AI-14, FR-I-01 | 6a | M | M |
| Daily tidy-up: scheduling, clusters, model call, validation, auto-apply, Inbox section, notifications | FR-AI-03, FR-AI-14 | 6b | L | M |
| Provider embeddings: benchmark, adapter, second index, re-embedding, calibration | FR-AI-09, FR-AI-11 | 6c | M | S |

## E14: Home and widgets (Phase 7, v0.4)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| iPhone status bar above the tab bar, only when something needs you; banner removed | FR-iOS-06 | 7.1 | S | S |
| `VaultOverview` (counts only), benchmark, `overview.get`, the iPhone's overview cache, demo counts | FR-H-01, FR-H-05, ADR-0025 | 7.2 | M | S |
| Mac Home: composer, pulse card, cards, empty states; dictation in Home and the capture box | FR-H-02, FR-H-03 | 7.3 | L | S |
| iPhone Home: replaces Capture; pulse with scrubbing, tiles, Who reads, cached states | FR-H-04 | 7.4 | M | S |
| iPhone widgets: Pulse, Remember, Rhythm | FR-H-06 | 7.5 | M | C |

## E15: About you (Phase 8, v0.5)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| Profile, `v6_profile`, profile fields per agent, §3.10 in the request path, T36–T46, export and import | FR-U-01, FR-U-03, FR-X-05, FR-X-06, ADR-0026 | 8.1 | M | S |
| `profile` in `request_memory`'s contract and server instructions; harness | FR-U-03 | 8.2 | S | S |
| Settings ▸ About You, greeting, Access checkboxes, Share panel line, Activity, seed page | FR-U-01..04 | 8.3 | M | S |
| iPhone greeting by name (`status.get`) | FR-U-05 | 8.4 | S | C |
| Edit About You on the iPhone | FR-U-01 | later | S | C |

## E16: Search answers (Phase 9, v0.6)
| Item | Covers | Phase | Size | Pri |
|---|---|---|---|---|
| `BodyMatches` (FTS5 `highlight()`), matching snippets in the Vault and `memories.search` with `snippetMatches`, highlighting on both apps | FR-V-17 | 9.1 | M | S |
| Spike G: answer quality per provider, synthetic questions and a held-out set | FR-AI-17 | 9.2 | M | S |
| `SearchAnswerer`, `QuoteLocator`, validation, `ModelItem` kinds, ModelRouter task, cap, cancellation, Activity, guardrail tests | FR-AI-17, ADR-0028 | 9.3 | L | S |
| Mac: Settings row, Ask row and ⌘⏎, answer card, highlight in the detail | FR-AI-17 | 9.4 | M | S |
| iPhone: `memories.answer` on both sides, per-method timeout, `SearchModel` answer state, pill and card, Settings, demo questions and answers | FR-iOS-13 | 9.5 | M | S |
| Automatically for questions, behind a latency gate | FR-AI-17 | 9.7 | S | C |

## E12: Later
| Item | Covers | Size |
|---|---|---|
| BridgeKitUI extraction (after v0.1), with the Remote Access views | ADR-0013 | L |
| `funes` CLI | Q18 | M |
| Localization (Spanish) | Q19 | M |
