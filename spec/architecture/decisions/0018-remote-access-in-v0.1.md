# ADR-0018: Remote Access for cloud agents in v0.1, with the same policy on every channel

**Status:** Accepted · 2026-10-19 · **Amends** [ADR-0002](0002-local-mcp-server.md) (no cloud agents until v0.3) and [ADR-0013](0013-shared-bridgekit-core.md) (when tier 3 is extracted)

**Context.**
- **The user mainly uses agents in the cloud:** ChatGPT and claude.ai. A v0.1 that serves only agents on the Mac leaves out the agents the user relies on most.
- **EK Bridge already has Remote Access** (since 0.5.0, about 3,400 lines plus 1,300 of UI at `e753b22`), and the user uses it daily through ChatGPT and Claude. They report it works. Its formal live matrix in EK Bridge's `docs/TESTING.md` is still unticked, but daily use replaces the spike ADR-0013 asked for. In short:
  - **A second loopback port** (EK Bridge: 47616), on only while Remote Access is on. Only a tunnel the user runs forwards to it: Tailscale Funnel (recommended, because TLS ends on the Mac), Cloudflare Tunnel, ngrok, or a Cloudflare quick tunnel for testing. The app never starts a tunnel.
  - **A secret path:** every route lives under `/r/<22 characters, 128 bits>`, and anything else gets 404 before `Host` or a credential is read. The `Host` must be the saved public host or loopback (421).
  - **OAuth 2.1 for claude.ai, ChatGPT and Gemini Enterprise:** the app is its own authorization server (RFC 9728 and 8414 metadata, PKCE S256, rotating refresh tokens with reuse detection, access tokens bound to the MCP URL for an hour). Clients are identified by a client metadata document (CIMD), with dynamic registration as claude.ai's fallback, or set up ahead for Gemini Enterprise. A sign-in is considered only while the user has opened a 10-minute **pairing** window for one connection, and the user approves it on the Mac by matching a six-digit code shown in the browser.
  - **A separate remote token per connection** for agents that send a header: the Anthropic and OpenAI APIs, Claude Managed Agents, Claude Code on the web, Cursor and Copilot cloud agents, Devin. Local tokens don't work remotely, and remote credentials don't work on the local port.
  - **A per-connection "Allow cloud access" switch,** off by default.
  - **Tunnel health checks** (read-only, on the Mac: is the tunnel running, where does it forward, is it public), a reachability test through the tunnel with a one-time nonce, **Switch Tunnel…** and a guided four-step setup.
- **BridgeKitCore already has the seams:** `MCPAuthentication(remote:)`, `ToolCall.remote`, and `RateLimiter`'s remote buckets and per-address lockout shipped in 0.1.0.
- **Funes's rules must hold on any channel:** the [access policy](../../domain/access-policy.md), exact-text approval, the 45 s in-call wait, the 15-minute pending list, single use, withheld counts.
- **What changes for the user:** with Remote Access on, the vault is reachable through a public tunnel, and text released to a cloud agent goes to that vendor's servers.

**Decision.**
1. **Remote Access ships in v0.1,** before the public launch, labelled **experimental**. It's off by default and turning it on asks first.
2. **The same policy on every channel.** A remote agent is a Funes agent like any other, and follows exactly the access configured for it:
   - the same Ask before sharing and Ask before saving, the same panels on the Mac, the same 45 s in-call wait and 15-minute pending list;
   - if the user isn't at the Mac, requests wait or expire. That's how the user configured it;
   - the per-agent **Ask before sharing** and **Ask before saving** switches are the only auto-approve mechanism, for local and remote agents alike;
   - no remote-specific policy, ceilings or defaults. The policy engine never sees the transport, and the per-agent rate limits are the same.

   Only network hygiene differs on the remote port: the secret path, the `Host` check, and the failed-authentication lockout per forwarded address.
3. **A remote listener on `127.0.0.1:47627`** (changeable in Settings), separate from the local port. 47625 (Funes MCP) keeps refusing tunnel and forwarding headers with 403, unchanged. The 47627 default avoids these ports:
   - Funes: 47625 (MCP) and 47626 (the companion);
   - EK Bridge: 47615 and 47616;
   - the EK Bridge Test copy: 47625 and 47626.

   47627 is the first free port after Funes's own. The EK Bridge Test copy (an `EVENTKIT_LIVE_TEST` build) already overlaps Funes on 47625 and 47626. Only that development build is affected, so don't run it next to Funes.
4. **Cloud credentials map to Funes agents.** An agent gets **Allow cloud access** (off by default). With it on, the agent can have a remote token and OAuth-connected cloud apps, and they use exactly that agent's access, revision, rate limits and pending list. How a sign-in finds its agent:
   - **(a) Chosen before the sign-in:** pairing is opened from one agent's Cloud section, so the sign-in attaches to that agent. **Add Agent** gets cloud tiles (claude.ai, ChatGPT, …) that create a new agent with cloud access on and the chosen starting access, then open pairing.
   - **(b) Created by the sign-in:** Allow on the six-digit-code panel creates a new agent, asking for its name and starting access there.
   - **(c) Picked on the panel:** the code panel offers existing agents and "New agent".

   **(a)** is chosen because:
   - nothing from the internet makes the Mac ask anything unless the user opened pairing for a named agent;
   - the code panel then decides only "is this the app I'm connecting", never what it may read;
   - access is set in the same editor as for any agent, which keeps one policy everywhere;
   - it's EK Bridge's tested flow as is, since a pairing window is bound to one connection.

   (b) and (c) put an access decision on the panel that phishing targets, and change tested code. One agent per cloud app is recommended, as in EK Bridge, but an agent may hold a local key and cloud credentials together; they then share its access and pending list. See [MCP server §12](../mcp-server.md#12-remote-transport).
5. **Tier 3 is extracted now as `BridgeKitRemote`,** a new product in BridgeKit **0.2.0**, under ADR-0013's rules:
   - the tests move with the code;
   - EK Bridge adopts it first, with its tests and fixtures unchanged, and its daily remote use as the proof;
   - only then does Funes build on it.

   The Remote Access views stay app-side: Funes copies them into `Packages/BridgeUI` (tier 2), and they join BridgeKitUI after v0.1. Plan: [Phase 4b](../../plans/phase-4b-remote-access.md).
6. **iPhone approvals go into v0.2** (reverses [Q16](../../plans/open-questions.md)): a notification to approve each request on the phone. No memory text goes through Apple or a relay, only "you have a request" and an id. The phone fetches the details over the companion channel. The push channel is open question Q24.

**Consequences.**
- **v0.1 serves the user's main agents.** The launch waits for Phase 4b, about 4–5 weekends plus a buffer; the target stays early Jan 2027.
- **The threat model grows:** tunnel exposure, OAuth consent phishing, stolen remote credentials, the CIMD fetch, edge decryption by some tunnels, and vendor-side retention of released text ([security](../security-and-privacy.md)).
- **Cloud agents often run while the user is away.** With Ask before sharing on (the default), their requests wait for the Mac and expire. That's intended. Approving from the iPhone (v0.2) is the planned relief, not a looser policy.
- **Cloud agents' tool-call timeouts are unmeasured.** Spike 3 measured local agents only. Phase 4b's live check records how long claude.ai and ChatGPT wait. A shorter wait changes nothing in the policy: the request moves to the pending list and `get_memory_request` collects it.
- **Three releases in order:** BridgeKit 0.2.0, then EK Bridge, then Funes.
- **The local port is untouched.** Its tests stay as they are, plus new ones that it refuses remote and OAuth credentials.
- **User-facing docs** (README, `docs/MCP.md`, PRIVACY, the site) change when the code lands, not with this decision.

**Alternatives considered.**
- **Stay with v0.3:** keeps v0.1 smaller, but launches without the agents the user uses most, and keeps the tier-3 code in EK Bridge alone for longer.
- **A remote-specific policy** (lower ceilings, forced asking, or auto-deny when the user is away): it makes the same agent and request get different answers depending on the channel, which is harder to explain and to test. The user's per-agent settings already say what each agent may do.
- **A hosted relay instead of the user's tunnel:** works with the Mac behind NAT and needs no tunnel setup, but it's a server of ours carrying memory traffic. That contradicts "no server, no cloud copy" ([ADR-0003](0003-mac-is-the-only-source-of-truth.md)) and adds an operator who could read or log traffic.
- **OAuth on the local port too:** local agents already have keys and the launcher; EK Bridge's MCP threat review found no gain against same-Mac threats.
