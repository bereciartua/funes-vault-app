# Testing strategy

Following EK Bridge's discipline: **tests are the specification for privacy guarantees**, golden fixtures pin the external contracts, and a recorded live matrix proves real-world behaviour.

## Layers
| Layer | Tool | What | Runs |
|---|---|---|---|
| Unit: FunesProtocol | Swift Testing | Secret scanner patterns; envelope crypto (seal/open, sign/verify, tamper, replay, skew); Codable round trips | CI, every push |
| Unit: FunesCore | Swift Testing | PolicyEngine (all [test vectors](../domain/access-policy.md#9-test-vectors)), BundleCompiler, DisclosureService (incl. races), SuggestionService, CaptureService idempotency, store invariants, migrations | CI |
| Model providers | Swift Testing + `URLProtocol` stubs | Adapter contracts (OpenAI-compatible, Anthropic), structured-output parsing, fallbacks, **guardrails** (no secret and nothing above the cloud limit in any captured outgoing request; capture pre-screen) | CI |
| Model providers, live | Manual, with the developer's keys | OpenAI, Anthropic, Gemini, Ollama, LM Studio smoke tests | Before releases that change adapters |
| Search regression | Swift Testing + fixtures | memories-200 / queries-30 / queries-30-expanded: hybrid recall@5 ≥ 0.92 (expanded) and ≥ 0.68 (raw), keyword-only ≥ 0.82 (expanded), MRR at or above the recorded baseline (ADR-0016); tokenizer ids match Hugging Face; latency budget at 10K (perf test, warn-only in CI) | CI |
| Unit: BridgeKitCore (in the `bridgekit` repo) | Swift Testing (moved from EK Bridge) + reference-server harness (`mcp_test.py`, `launcher_test.py`) | HTTP parsing, JSON-RPC, protocol versions, Host and Origin checks, rate limiter, schema validator, keys, safe files, launcher listener verification, config writer | bridgekit CI; both apps also run their own harnesses after each BridgeKit bump |
| Unit: BridgeUI | Swift Testing (ported EK Bridge tests) | Approval queue, timeouts, revision binding, activity retention | CI |
| MCP contract | Golden JSON | `tools.json` byte-for-byte; agent setup snippets | CI |
| MCP protocol | Python (`Tests/mcp/mcp_test.py`) against a `FUNES_MCP_TEST` build with a temporary vault and a fake approval responder | Protocol versions, auth (401), Host (421), Origin (403), limits (413, 429), every tool's paths, needs_approval → get_memory_request, single use, invalidation | CI (macOS runner) |
| Launcher | Python (`launcher_test.py`) | stdio relay, key-file reading, impostor-listener refusal, `headers`, `check` | CI |
| Companion protocol | Swift Testing + a Python client | Pairing paths, every method, error codes, exactly-once captures with a dropped response, revoked devices | CI |
| Fuzzing | Swift (libFuzzer-style harness, or randomized property tests) | Envelope decoder, MCP JSON parser, import parsers | Nightly / before release |
| UI snapshots | `FUNES_UI_REVIEW` build with fake data → PNGs in light and dark | Every main screen and panel | Before release; reviewed by eye |
| UI behaviour | XCTest UI tests (Mac) | Panel arming, keyboard-only flows, VoiceOver labels present | Before release |
| Live matrix | Manual checklist in `docs/TESTING.md` | Claude Code, Claude Desktop, Cursor, Codex (v0.1); iPhone transport matrix (v0.2) | Each release |
| Update test | Script (from EK Bridge's `update_test.sh`) | A Sparkle update between two local builds via a local feed | Before each release |

## Privacy assertions (dedicated tests)
- **No memory text, task text or key** appears in:
  - `activity.jsonl`;
  - provenance rows;
  - OSLog in test mode (captured);
  - export files (keys);
  - error messages to agents (withheld ids).

  A test writes a vault with sentinel strings (`SENTINEL-…`), exercises every flow, and then greps every output.
- **Purpose invariance:** randomized purposes and tasks with fixed retrieval results give identical decisions.
- **Fail closed:** every gate condition, crossed with every tool, gives a refusal.

## Test data
- `Tests/fixtures/memories-200.json`, `queries-30.json` (from Spike 2).
- Import fixtures: ChatGPT export variants, Claude paste samples, Markdown samples, `funesvault.export.v1`.
- A demo vault for the iPhone (about 20 memories) and for the Mac UI review build (about 60 memories, 4 agents, about 50 activity rows).

## Definition of done (per feature)
1. Requirements' acceptance criteria are met and the related test vectors are implemented.
2. Unit tests are green, and golden files are updated intentionally (diff reviewed).
3. No new log statements expose user content (CI check).
4. UI snapshots are updated where a screen changed.
5. CHANGELOG entry added; docs updated if the behaviour is user-visible.
