# Phase 4b follow-up 2: share Tailscale Funnel's port 443 by path (v0.1.2)

**Supersedes** [Funnel ports](phase-4b-funnel-ports.md) (BridgeKit 0.3.0, Funes 0.1.1, EK Bridge 0.11.3; all three built, the two app releases left as drafts).

**Problem:** the live check of 0.1.1 on 2026-10-19 failed.
- Funes's guide correctly skipped 443 (EK Bridge) and 8443 (a tailnet-only Serve entry) and used 10000.
- The tunnel worked end to end: through Tailscale's public Funnel relays, `:10000` reached Funes as `:443` reaches EK Bridge.
- **claude.ai and ChatGPT both failed** with "couldn't reach". claude.ai's backend only connects out on port 443: an Anthropic maintainer said so on [anthropics/claude-ai-mcp#373](https://github.com/anthropics/claude-ai-mcp/issues/373), closed as not planned. ChatGPT behaved the same in the user's test.

So a second app on another public port can't serve the two main cloud agents.

**Goal:** every app on the Mac uses Funnel's port 443.
- Each app adds only **its own paths**, never the whole port.
- Every other path keeps going wherever it went before, such as an existing EK Bridge entry at `/`.
- Addresses stay `https://<mac>.<tailnet>.ts.net` with no port, and the MCP URL stays `…/r/<secret>/mcp`.

**Decision:** the user chose this ("option A") on 2026-10-19, in BridgeKitRemote so EK Bridge gets it too.

**Duration:** about 12–16 h. **Blocks:** publishing Funes 0.1.x and EK Bridge's next release.

## What the test showed (2026-10-19, Tailscale 1.102.4)

Two test path entries were added to Funnel's port 10000, next to its `/` entry to Funes, and pointed at a local echo server. They were fetched through a public relay (209.177.145.97), then removed. 443 and 8443 weren't touched.

1. **Paths are kept.** `--set-path /r/S http://127.0.0.1:P/r/S` forwards these exactly as sent:
   - `/r/S/mcp`, `/r/S`, `/r/S/` and `/r/S/oauth/token`;
   - query strings and POSTs.
   Host stays the public name, with the port when it isn't 443.
2. **The most specific path wins.** Every other path, including `/`, still went to the port's `/` entry.
3. **Matching is by whole path segment.** `/r/SX/mcp` and `/r/Se/mcp` didn't match `/r/S`. One app's secret can't catch another's.
4. **Discovery needs its own entries.** `/.well-known/oauth-protected-resource/r/S/mcp` matched only because that entry existed; `/.well-known/oauth-authorization-server/r/S` fell through to `/`.
5. **`tailscale funnel --https=P --set-path X off` removes only that path.** Tailscale's own hint, `tailscale funnel --https=P off`, turns off the **whole port**. On 443 that would cut off every app, so ours always names the path.
6. `tailscale funnel status --json`:
   - lists each path under `Web["host:port"].Handlers`, with `Proxy` including the path, such as `http://127.0.0.1:47699/r/S`;
   - turns `AllowFunnel` on for the whole `host:port`.

## Rules

1. **The paths an app serves**, from BridgeKitRemote's gate and OAuth server (one list in code, used by both):
   - `/r/<secret>`: MCP, health, sign-in pages, token, and `/r/<secret>/.well-known/openid-configuration`;
   - `/.well-known/oauth-protected-resource/r/<secret>`;
   - `/.well-known/oauth-authorization-server/r/<secret>`;
   - `/.well-known/openid-configuration/r/<secret>`.
2. **Commands:** one per path, `tailscale funnel --bg --set-path <path> http://127.0.0.1:<port><path>` (with `--https=<p>` when the public port isn't 443). Turning off is one `tailscale funnel --https=<p> --set-path <path> off` per path. Never a bare `… off`.
3. **Which public port:** 443 when it's free or already public through Funnel.
   - Adding a Funnel path to a port turns Funnel on for the whole port. If 443 has a **tailnet-only** Serve entry, adding our paths would make that app's entry public, so 443 is out.
   - Then use the next of 8443 and 10000 on the same terms, with a warning that claude.ai and ChatGPT only connect to 443.
   - If none qualifies, offer no command.
   - A raw TCP forwarder takes its port entirely.
4. **Running:** all four paths (or the whole `/` of a port, as existing EK Bridge setups have) forward to the Remote Access port on a Funnel port.
   - Some of the four, but not all: **Incomplete**. The Tunnel row says that sign-in won't work and shows the commands again (adding a path that exists is harmless).
   - Paths forwarding elsewhere belong to someone else and are never "Wrong port". Wrong port stays only for the local MCP port.
5. **Existing setups keep working.** EK Bridge on `/` of 443 is Running as before. Nothing asks the user to change it, and Funes's paths coexist with it (test result 2).
6. **The secret is part of the tunnel's setup now.** Reset Path… (a new secret) shows, before resetting:
   - the commands that remove the old secret's paths;
   - the commands that add the new ones.
   The page's tunnel check then follows the new secret. The secret path also appears in `tailscale serve status`; it's already in every cloud app's MCP URL.
7. **Read-only, as before.** The apps run only `tailscale status --json` and `tailscale funnel status --json`, and never `tailscale funnel`.

## Part A: BridgeKitRemote 0.4.0

### P.1 One list of public paths · 1 h
- [x] `RemoteConfiguration.publicPaths`: the four paths of rule 1, derived from `secretPrefix`. The gate and `OAuthServer`'s routes use the same constants.
- [x] A test that every route the gate and OAuth server accept is under one of them, and nothing outside them is.

### P.2 Path entries in the Tailscale parser · 4 h
- [x] `ToolJSON.localPort` accepts a path after the port (`http://127.0.0.1:47627/r/S`).
- [x] `FunnelPorts.Entry`: one per `host:port`, with its handlers by path (path → local port and target path) and whether Funnel is on.
- [x] `FunnelPorts` decides for an app's port and public paths:
  - **running**: all paths, or `/`, on a Funnel port;
  - **incomplete**, listing the missing paths;
  - **the public port to use** (rule 3);
  - whether that port lets claude.ai and ChatGPT in (443).
- [x] `TunnelHealth`: new `.incomplete(address:, missing: Int)` and `NotRunningReason.noSharablePort` (replacing `allPortsTaken`). `TailscaleStatus.result` carries `FunnelPorts` with `pathsToAdd`.
- [x] `TunnelChecks.check(provider, port, publicPaths, done)`. The check needs the secret's paths; breaking, hence 0.4.0.

### P.3 Commands · 1 h
- [x] `TailscaleFunnelCommand.start(port:publicPort:paths:)` and `.off(port:publicPort:paths:)`. The old single-path forms go.
- [x] `TailscaleFunnelCommand.off(_:address:paths:)` for `TunnelSwitchSummary`'s off commands, including a whole-port `/` from before, and `resetPath` (old paths off, new paths on; nothing for a `/` entry). No separate `ResetPathSummary` type.

### P.4 Tests, docs, release · 3 h
- [x] Fixtures:
  - today's real config, with path entries;
  - EK Bridge on `/` with Funes's four paths;
  - three of four paths (incomplete);
  - 443 tailnet-only (not sharable, so 8443 with the warning);
  - all ports unsharable;
  - another app's path entries;
  - legacy `/` → our port.
- [x] The commands for 443 and other ports, and a path never off without `--set-path`.
- [x] The listed paths only: `RemoteGateTests.publicPaths` checks every served route is under them and that other discovery names and paths are 404. `remote_test.py`'s 86 checks pass unchanged.
- [x] README, CHANGELOG `## 0.4.0`, PR (bridgekit#4), CI green, merged as `45f8382`.
- [x] Tag `0.4.0` on `45f8382` after both apps are green against it (with the user's OK).

## Part B: Funes 0.1.2

- [x] Guide step 2:
  - the four commands as one Copy block;
  - one line saying they add only Funes Vault's own paths to port 443, so other apps keep theirs;
  - the claude.ai and ChatGPT warning when 443 isn't sharable.
- [x] Step 3's example address has no port on 443.
- [x] The Tunnel row: **Running**; **Incomplete**, with the commands; **No sharable port**.
- [x] Reset Path…: its alert says Funnel forwards the secret path too. The page then shows the commands that remove the old paths and add the new ones, until a check finds the new paths or you click Done.
- [x] Step 2 shows the four off commands under the start commands (To turn it off later). Turning Remote Access off runs nothing, as before.
- [x] Goldens, `RemoteSetupTests`, `RemoteAccessControllerTests`, String Catalog.
- [x] Spec:
  - mcp-server §12 (replace the ports rule);
  - this plan's results in [spike results](spike-results.md) next to 4b.15 (claude.ai and ChatGPT reach only 443);
  - docs/MCP.md's Tailscale row;
  - CHANGELOG `[0.1.2]` (0.1.0 and 0.1.1 were drafts only);
  - version 0.1.2 (3), `server.json`;
  - [x] pin BridgeKit `exact: 0.4.0`.

## Part C: EK Bridge 0.11.4

- [x] Adopt 0.4.0: commands, Incomplete, Reset Path's commands, the warning; EK Bridge's words.
- [x] Existing users on `/` stay Running with no change. With 443 free, a new setup shows the four path commands instead of `tailscale funnel --bg 47616`, so the tunnel goldens change.
- [x] docs/MCP.md, CHANGELOG `[0.11.4]` (0.11.3 was a draft only), version 0.11.4 (21), `server.json`.

## Checks

- [x] `test.sh` green in all three repos, and CI green (Funes with both toolchains).
- [x] **Live, on the user's Mac** (the user runs every `tailscale` command), on the 0.1.2 and 0.11.4 drafts, 2026-10-19:
  1. Funes's guide offers its four path commands on 443, and nothing about `/`. Not seen live: Funes was already set up (0.1.1's `:10000`), so the four commands were run by hand and the address changed with Address ▸ Edit…. The guide's commands are covered by the goldens. An existing setup on 8443 or 10000 doesn't suggest moving to 443; that's a follow-up.
  2. After running them, `tailscale funnel status` shows EK Bridge's `/` and Funes's four paths on 443. Both Tunnel rows show Running.
  3. **claude.ai and ChatGPT connect to Funes** at `https://<mac>.ts.net/r/<secret>/mcp` and sign in through pairing. This is the 4b.15 check.
  4. EK Bridge's ChatGPT and claude.ai connectors still work.
  5. Reset Path… in Funes: the old paths' off commands and the new paths' commands, then reconnect.
  6. The leftover port-10000 entry from 0.1.1's test is removed with `tailscale funnel --https=10000 --set-path / off`, or left if the user prefers.
- [x] Then draft releases Funes `v0.1.2` and EK Bridge `v0.11.4`, installed from GitHub. Still to do: publish them, and delete the unpublished 0.1.0, 0.1.1 and 0.11.3 drafts if the user wants.

## Open questions

- Tailscale versions before 1.102 weren't tested. Path entries (`--set-path`) have existed since the CLI's Serve rewrite (1.52), and the parser reads the same JSON. The live check covers 1.102.
