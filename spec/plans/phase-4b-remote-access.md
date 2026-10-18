# Phase 4b: Remote Access for cloud agents (v0.1)

**Goal:**
- Extract EK Bridge's Remote Access into **BridgeKitRemote**, with EK Bridge adopting it first as the proof.
- Then let cloud agents (ChatGPT, claude.ai and the header-based ones) reach the Funes vault through a tunnel the user runs, with **the same policy as local agents** ([ADR-0018](../architecture/decisions/0018-remote-access-in-v0.1.md)).

**Duration:** about 42 h, 4–5 weekends (+ 1 buffer weekend of daily use). **Depends on:** Phase 3 and Phase 4's prepared release. The v0.1 launch ([4.4 and 4.5](phase-4-ship-mac-preview.md)) waits for this phase. Specs: [MCP server §12](../architecture/mcp-server.md#12-remote-transport), [security](../architecture/security-and-privacy.md), [reuse §3](../architecture/ek-bridge-reuse.md#3-tier-3-bridgekitremote-extracted-now-for-funes-v01), [UX: Mac](../product/04-ux-mac.md#remote-access-experimental), [FR-AI-04](../product/03-requirements.md).

## Part A: BridgeKitRemote 0.2.0 (weekend 1)

### 4b.1 Product and seams · 2 h
- [ ] `Package.swift`: product `BridgeKitRemote` (static, like BridgeKitCore), target depending on BridgeKitCore only, no UI, no other dependencies.
- [ ] `RemoteBridgeConfiguration`:
  - the default port;
  - the token prefixes (remote token, OAuth access, refresh and client secret);
  - the OAuth scope;
  - the display name for the sign-in pages and the CIMD `User-Agent`;
  - the store's folder;
  - texts for 401s and pages.
- [ ] `RemoteAuthenticator` (the app's storage, the kit's crypto): remote token → agent id, and "does this agent have cloud access". It replaces EK Bridge's direct `ClientRegistry` calls.

### 4b.2 Move the code · 4 h
- [ ] Move the files in [reuse §3](../architecture/ek-bridge-reuse.md#3-tier-3-bridgekitremote-extracted-now-for-funes-v01) from EK Bridge `e753b22`: `RemoteMCPService`, `OAuthServer`, `OAuthStore`, `OAuthPages`, `OAuthTypes`, `CIMDFetcher`, `TunnelHealth`, `TunnelChecks`, `TunnelSwitch`, `RemoteAccessSupport`. Record them in `PROVENANCE.md`.
- [ ] Replace `ekb_` constants, the `calendar` scope, `AppIdentity` and `47616` with configuration.
- [ ] Tunnel status lines become typed results (`TunnelHealth`, the switch steps); the apps word them.
- [ ] Public only what the apps need.

### 4b.3 Move the tests · 3 h
- [ ] Convert to Swift Testing in `Tests/BridgeKitRemoteTests`, with their fixtures:
  - `OAuthServerTests`;
  - `CIMDFetcherTests`;
  - `TunnelHealthTests` (with `Tests/tunnel-health/*`);
  - `TunnelSwitchTests`;
  - the remote checks of `MCPGateTests`, including the 27 candidate-host checks.

### 4b.4 Reference harness and tag · 2 h
- [ ] The reference server gains a remote listener and a fake OAuth approver.
- [ ] Generalize `mcp_test.py`'s `run_remote` and `run_oauth` and run them against it.
- [ ] Tag **`0.2.0`**. BridgeKitCore only gains additions.

## Part B: EK Bridge adopts BridgeKitRemote (weekend 2, first half)

### 4b.5 Switch EK Bridge · 3 h
- [ ] Pin BridgeKit `0.2.0`. `scripts/bridgekit.sh` and `build.sh` also build and link `BridgeKitRemote`.
- [ ] Delete the moved sources. Put `ClientRegistry` behind `RemoteAuthenticator`, and EK Bridge's wording behind the typed tunnel results.

### 4b.6 Proof · 2 h
- [ ] These all pass, unchanged:
  - `test.sh` and its unit tests;
  - `Tests/mcp_test.py` (with `run_remote` and `run_oauth`);
  - the agent-setup goldens (`cloud-*.txt`, `tunnel-*.txt`);
  - `ui_test.sh`, and `ui_snapshots.sh` for the Remote Access screens;
  - the EK Bridge Test copy's quick-tunnel checks (`live_test.sh quicktunnel`, L2–L3 in `docs/TESTING.md`).
- [ ] The user's daily remote use through ChatGPT and Claude, on the adopted build, for a few days. This replaces the unticked live cloud matrix as the proof (ADR-0018).
- [ ] Release EK Bridge ("internal: uses BridgeKitRemote"). Users see no change.

## Part C: Funes integration (weekend 2, second half, to weekend 4)

### 4b.7 Agents: cloud access and remote tokens · 3 h
- [ ] Schema migration: `agent.cloud_access`, `remote_key_digest` and `remote_key_issued_at` ([domain model](../domain/domain-model.md#agent)); update [storage](../architecture/storage.md).
- [ ] The remote key file `agent-keys/<agentId>.remote.key` (0600).
- [ ] A `RemoteAuthenticator` backed by `AgentService`.
- [ ] Revision bumps for every cloud change.
- [ ] Turning cloud access off, or removing the agent, deletes the remote token and the agent's OAuth connections.
- [ ] The secret scanner learns the four new prefixes.

### 4b.8 Remote listener · 3 h
- [ ] `FunesRemoteServer` on 47627 with BridgeKitRemote, wired to the **same** dispatch, `FunesTools` and `RequestPipeline` as the local server.
- [ ] Remote calls count in the agent's own rate-limit buckets.
- [ ] Settings stored: on/off (default off), port, secret path, address, tunnel, automatic turn-off, keep awake.
- [ ] Quitting, pausing and the 3 s quit hold behave as for the local listener.
- [ ] The local server is unchanged. Add tests that it refuses remote and OAuth credentials (401) and tunnel headers (403).

### 4b.9 OAuth pairing → agent · 3 h
- [ ] **Connect a Cloud App…** on the agent's Cloud section opens pairing for that agent.
- [ ] The sign-in panel in BridgeUI ([UX](../product/04-ux-mac.md#app-wants-to-connect-cloud-sign-in)): agent, app as reported, metadata URL, return host, code; armed after 1 s; queued, never replaced.
- [ ] Connected apps with **Revoke**. Reset Path… and an address change disconnect them, with a warning naming them.
- [ ] Scope `memory`; prefixes `fns_oat_v1_`, `fns_ort_v1_`, `fns_ocs_v1_`; Gemini Enterprise's **Set Up OAuth Client…**.

### 4b.10 Remote Access page and guided tunnel setup · 5 h
- [ ] Copy `RemoteAccessView` and `TunnelSwitchView` into `Packages/BridgeUI/Upstream/` (`PROVENANCE.md`), and adapt them in `Sources/BridgeUI` to Funes's agents and wording.
- [ ] The four-step guide, the page's rows, **Switch Tunnel…**, **Test**.
- [ ] Re-adapt the tunnel commands from `Upstream/AgentSetup.swift` for 47627, with goldens.
- [ ] Menu bar globe, the menu's "Remote Access on" and **Turn Off Remote Access**, the sidebar's On / ⚠ Down, the optional "tunnel stopped" notification.
- [ ] Strings in `Localizable.xcstrings` (`sync_strings.sh`).

### 4b.11 The agent's Cloud section and cloud setups · 3 h
- [ ] **Allow cloud access** (off by default; asks first when turning it off would cut credentials).
- [ ] The cloud agent picker and setups (claude.ai, ChatGPT, Gemini Enterprise, Anthropic API, Managed Agents, OpenAI Responses API, Claude Code on the web, Cursor, Copilot, Devin), re-adapted from `Upstream/AgentSetup.swift`, with goldens that never contain a token.
- [ ] **Copy Remote Token…** and **Reset Remote Token…**.
- [ ] Cloud tiles in **Add Agent**: create the agent with cloud access on and the chosen preset, then open pairing or the token setup.

### 4b.12 Activity · 1 h
- [ ] `via: remote` on every remote row, the cloud icon and "via Remote Access", the Remote Access filter.
- [ ] The tunnel and forwarded address of the last 50 remote requests, in memory only.
- [ ] `check_log_privacy.sh` stays green.

### 4b.13 Harness and tests · 4 h
- [ ] `funes-mcp-test-server` also runs the remote listener (an `https` public origin faked through `Host`) and a fake sign-in approver.
- [ ] `Tests/mcp/mcp_test.py`, remote paths:
  - 404 outside the secret, 421 for a foreign `Host`, 403 for `Origin`;
  - a local key refused remotely, and remote credentials refused locally;
  - an agent without cloud access gets 401;
  - pairing closed: nothing shown;
  - OAuth: code, token, refresh, reuse revokes;
  - turning Remote Access off stops the URL.
- [ ] **Same decision, local vs remote:** one agent with a local key and a remote token. Replay the same requests through both listeners and compare the results field by field (status, reason, withheld, items, `estimated_tokens`; not ids). Cover:
  - each gate denial;
  - ALLOW and NEEDS_APPROVAL (approve, deny, timeout then `get_memory_request`);
  - `suggest_memory` queued and saved;
  - the rate limits shared across both listeners.
- [ ] A Swift test that `RequestPipeline` and `PolicyEngine` get the same inputs for local and remote calls, so `ToolCall.remote` only affects Activity.

### 4b.14 Docs · 2 h
- [ ] When the code lands, update the user-facing docs (they describe shipped behaviour):
  - README ("From cloud agents (experimental)", Privacy, Security boundary);
  - `docs/MCP.md` "Use from cloud agents";
  - `docs/ARCHITECTURE.md` with a Remote Access threat review;
  - PRIVACY.md, SECURITY.md, `docs/TESTING.md` (the live matrix rows below), CHANGELOG;
  - the site.

### 4b.15 Live check · 2 h
- [ ] On a signed build, with Tailscale Funnel to 47627 and a development vault:
  - **ChatGPT and claude.ai:** pair (codes match, Allow), list categories, request memory (approve, deny, timeout then get), suggest (queued), Revoke;
  - **one header agent** (the Anthropic API): the same requests with a remote token, then **Reset Remote Token…** makes the old one fail;
  - **Turn Off Remote Access** stops the URL.
- [ ] Record how long claude.ai and ChatGPT wait for a tool call (as [Spike 3](spike-results.md#spike-3-agent-timeouts-and-the-in-call-approval) did for local agents), and whether they send `keywords`. Nothing in the policy changes with the result.

## Exit criteria
- **BridgeKit `0.2.0`** is tagged with `BridgeKitRemote`, its moved tests and the remote harness green.
- **EK Bridge** is released on it, with its tests and goldens unchanged and green, and the user's daily remote use working.
- **Funes:**
  - the "same decision local vs remote" tests and the remote harness are green in CI;
  - the local port's tests are unchanged;
  - the live check is recorded.
- **The user connects ChatGPT and claude.ai to Funes and uses them daily** for at least a week, before the launch.

## If it runs long
- The time box: if EK Bridge's switch (Part B) isn't green after **2 extra evenings**, copy tier 3 into Funes (as ADR-0008 did for tier 1), ship, and finish the extraction after v0.1. Record that in ADR-0018's status.
- If Part C runs past the buffer weekend, launch v0.1 without Remote Access and ship it in v0.1.x. That's the user's call.
