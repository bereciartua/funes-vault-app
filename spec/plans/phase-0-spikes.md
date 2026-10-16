# Phase 0: Spikes

**Goal:** answer the three riskiest technical questions with throwaway code **before** building the product. Each spike has a pass/fail criterion and a fallback that changes the plan.

**Budget:** 1 weekend for spikes 2 and 3; spike 1 can wait until just before Phase 5 (it only affects v0.2). Write results in `plans/spike-results.md` (create it when done).

---

## Spike 1: Companion transport (pairing, encryption, offline capture)
**Question:** can an iPhone app pair with a Mac menu bar app via QR code, send signed and HPKE-encrypted requests over the same Wi-Fi and over Tailscale, and deliver queued captures exactly once after the Mac wakes?

**Build (throwaway):**
1. **Mac:** a minimal menu bar app with an `NWListener` on 47626, a Bonjour advertisement `_funes._tcp`, P-256 keys in the Keychain, and a QR code view (CoreImage `CIQRCodeGenerator`).
2. **iPhone:** a minimal app that:
   - scans the QR code (VisionKit `DataScannerViewController`);
   - creates a Secure Enclave P-256 signing key and a Keychain HPKE key;
   - implements the [pairing](../architecture/companion-protocol.md#2-pairing) and the [envelope](../architecture/companion-protocol.md#3-request-envelope-every-call-after-pairing);
   - keeps a SQLite capture queue;
   - sends `captures.submit`.
3. **Mac:** verifies, decrypts, stores receipts in SQLite, and replies sealed.

**Test matrix:**
| # | Scenario | Pass |
|---|---|---|
| 1a | Pair on the same Wi-Fi | Paired in < 10 s, including the Allow click |
| 1b | Capture → delivered on the same Wi-Fi | Arrives once; the phone deletes it after the acknowledgement |
| 1c | The Mac's response is dropped after the commit (kill the connection) | Resend → accepted as a duplicate, one receipt |
| 1d | The Mac asleep: capture 3 on the phone, wake the Mac, open the app | All 3 arrive once |
| 1e | Tailscale (phone on cellular) | Reaches the Mac by its 100.x IP; ATS allows it |
| 1f | Tampered ciphertext, replayed nonce, skewed clock | All rejected with the right code |
| 1g | Local Network permission prompt and Bonjour on iOS | Works after the prompt is allowed; clear failure if denied |
| 1h | Background delivery (`BGAppRefreshTask`) | Delivered at least once within a few hours (best effort; informational) |

**Pass:** 1a–1g green.

**Fallbacks:**
- Secure Enclave problems → software P-256 keys in the Keychain.
- HPKE export problems → a separate response HPKE seal to the device key.
- ATS trouble with Tailscale IPs → use the tunnel only for remote access.
- If the whole approach fails → reconsider [ADR-0003](../architecture/decisions/0003-mac-is-the-only-source-of-truth.md): CloudKit as a capture mailbox only.

**Estimate:** 1–2 weekends.

---

## Spike 2: Search quality and speed
**Question:** are Apple's on-device embeddings good enough for retrieval over personal memories, and what weights and thresholds work?

**Setup:**
1. Write **200 synthetic memories** across the 8 categories, with realistic overlaps (preferences, projects, health, finance). Store them as `Tests/fixtures/memories-200.json`; they become a permanent test fixture.
2. Write **30 queries** (tasks agents might send), each with 1–3 relevant memory ids, as `queries-30.json`.
3. Compare:
   - FTS5 BM25 alone;
   - `NLEmbedding` sentence embeddings;
   - `NLContextualEmbedding` mean-pooled;
   - for per-model thresholds ([ADR-0014](../architecture/decisions/0014-user-selectable-models.md)): one local server model (Ollama `nomic-embed-text`) and one cloud model (OpenAI `text-embedding-3-small`), using synthetic data only;
   - each embedding combined with FTS5 at weights 0.45/0.55 and 0.3/0.7.

**Measure:**
- Recall@5 and MRR.
- Query latency at 200 and at 10,000 memories (the 10,000 synthesized by paraphrase or duplication).
- Embedding time per memory.
- Vector dimensions on macOS, and on iOS for information.

**Pass:** the best hybrid gets recall@5 ≥ 0.85 with latency < 150 ms at 10,000 memories on an M1.

**Outputs:**
- the chosen model;
- the weights;
- the vault threshold (0.30) and the retrieval threshold (0.35), confirmed or changed;
- recorded constants plus a regression test.

**Fallback:** if embeddings are poor, use FTS5 plus query expansion with Foundation Models (on macOS 26+), and re-rank the top 50 with Foundation Models.

**Estimate:** about 1 weekend.

---

## Spike 3: Agent timeouts and the in-call approval
**Question:** will the target agents wait about 45 s for a tool call while the approval panel is open? And how do they behave with `needs_approval` plus `get_memory_request`?

**Setup:**
- Write a tiny MCP server (Python or Swift; EK Bridge's harness is a good base) with:
  - one tool that sleeps N seconds (15, 30, 45, 60);
  - one tool that returns `needs_approval` and later succeeds on a second tool.
- Connect it to Claude Code, Claude Desktop, Cursor, Codex, VS Code Copilot and Gemini CLI.

**Record per agent:**
- the maximum wait before its tool-call timeout;
- whether it shows progress;
- whether it retries automatically;
- whether, given instructions in `message`, it calls `get_memory_request` later on its own;
- whether it surfaces the "waiting for your approval in Funes" message to the user.

**Pass:** the main agents (Claude Code, Claude Desktop, Cursor) wait at least 45 s.

**Fallback:**
- If some agents time out earlier, make the in-call wait **per agent kind** (for example 20 s for Cursor), or 0 s (return `needs_approval` immediately and rely on the pending list plus the agent calling back).
- Document per-agent behaviour in `docs/MCP.md`.

**Estimate:** half a weekend.

---

## Name and domain chores (do first, about 1 hour)
- [x] Bought **funesvault.com** (Hover, 2026-10-16; expires 2027-10-16). Turn on auto-renew and WHOIS privacy.
- [x] Registered App IDs `com.funesvault.ios`, `com.funesvault.mac`, `com.funesvault.ios.share`, `com.funesvault.ios.intents` and App Group `group.com.funesvault` (2026-10-16). Check that App Groups is configured on all three iOS IDs.
- [x] Reserved **"Funes Vault"** in App Store Connect (iOS app record with `com.funesvault.ios`, 2026-10-16). The name was available. **Keep it:** upload a TestFlight build before about **14 Apr 2027** (Apple has historically released names with no build after 180 days).
- [ ] Trademark search for "FUNES VAULT" and "FUNES" in classes 9 and 42 ([USPTO](https://tmsearch.uspto.gov), [EUIPO TMview](https://www.tmdn.org/tmview)).
- [ ] DNS for funesvault.com: hosting for the site (Phase 4), MX or forwarding for `support@` and `security@`, and the MCP Registry TXT record (when publishing).
- [ ] Optional: register `funesvault.app` and redirect it to the .com.
- [x] Created the repo `bereciartua/funes-vault-app` (private for now). Apache-2.0 `LICENSE` and `NOTICE` added with the repo setup (2026-10-16).

## Also verify in Phase 0 (quick checks, under 1 hour each)
- **Global hotkey without Accessibility permission** via Carbon `RegisterEventHotKey` on macOS 15 and 26. Expected: works.
- **Services menu provider** in a menu bar app (`NSServices` in Info.plist). Expected: works after login or `pbs -update`.
- **Foundation Models guided generation** for classification on 20 sample captures: check quality and latency, and that it degrades cleanly when Apple Intelligence is off. Run the same 20 through one cloud model with JSON-schema structured output, for a quality comparison.
- **GRDB plus FTS5 external-content triggers:** a minimal correctness test.
- **`xcodebuild archive` → Developer ID export → notarize → staple** for a hello-world menu bar app, using EK Bridge's notary profile.
- **EK Bridge's `swiftc` build linking a Swift package** ([ADR-0013](../architecture/decisions/0013-shared-bridgekit-core.md)): build a toy package product with `swift build` for arm64 and x86_64, then link it into a `swiftc`-built app and command-line tool, universal and signed. If this is painful, plan a minimal Xcode project for EK Bridge instead.
