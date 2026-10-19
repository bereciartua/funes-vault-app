# Phase 4b follow-up: Tailscale Funnel ports shared by several apps (v0.1.1)

**Problem:** found installing the 0.1.0 draft on a Mac where EK Bridge's Remote Access already uses Tailscale Funnel.
- Guide step 2 offers `tailscale funnel --bg 47627`. That takes Funnel's port 443, replacing EK Bridge's entry and cutting off its cloud connectors.
- The tunnel check reads EK Bridge's entry (443 → 47616) as "Wrong port" and suggests the same command.
- The safe command (`--https=8443`) appears only in the ⓘ note.

The same can happen the other way round: EK Bridge's guide would replace Funes's entry if Funes took 443 first.

**Goal:** neither app ever offers a Funnel command that replaces something already served on this Mac.
- Each app finds which of Funnel's three public ports (443, 8443, 10000) are free and uses the first free one.
- Its guide, commands and address follow from that port.
- Whichever app is set up first gets the plain address (443); the next one adapts.

**Decision:** option B, chosen by the user on 2026-10-19 over option A (Funes fixed on 8443). The logic goes in BridgeKitRemote, so both apps get it.

**Duration:** about 10–14 h. **Blocks:** publishing Funes 0.1.x. 0.1.0 stays a draft; this ships as 0.1.1.

## Rules

1. **A public port is free only if Tailscale serves nothing on it**, neither Funnel nor tailnet-only Serve nor TCP forwarding.
   - `tailscale funnel --https=<p>` replaces the root handler on `<p>` and makes the whole port public. On a port with someone's Serve entry, it would cut that app off and expose its other paths to the internet.
2. **Already running wins.** If a Funnel entry on any of the three ports forwards to the app's Remote Access port, that's the tunnel (Running, with its address). Nothing else is suggested.
3. **Otherwise use the first free port, in the order 443, 8443, 10000.** Both apps use the same order.
4. **All three taken:** no command is offered. The guide names what each port forwards to and says to turn one off or choose another tunnel.
5. **Another app's entry isn't "Wrong port."** A Funnel or Serve entry that forwards elsewhere belongs to something else on this Mac.
   - `.wrongPort` stays only for ports the app knows are a mistake: its own local MCP port (47626 for Funes, 47615 for EK Bridge), so "Forwards to 47626, the local MCP port" keeps working.
6. **Status unknown** (the CLI is missing, times out or prints no JSON): show the 443 command, plus a short line saying that if Funnel already serves another app, the guide can't tell which port is free. The ⓘ note's manual `--https=8443` hint goes away; this line replaces it.
7. **The turn-off command targets the app's own port:**
   - the port in the saved address (`https://host:8443` → 8443, no port → 443), else the running entry's port;
   - never a bare `tailscale funnel … off`, which could switch off another app.
8. **Read-only.** The check still only runs `tailscale status --json` and `tailscale funnel status --json`. The apps never run `tailscale funnel` themselves (no Start for me; out of scope as before).

## Part A: BridgeKitRemote 0.3.0

Changing the public tunnel types breaks source compatibility, so this is a minor bump under 0.x.

### F.1 Ports in the Tailscale parser · 3 h
- [x] `FunnelPorts.parse`: parse every entry of `funnel status --json` into the ports in use. Per public port: the local port(s) it forwards to (nil for file and text handlers or remote targets), whether Funnel is on, and whether it's Web or TCP.
- [x] `TunnelHealth` for Tailscale follows the rules above. Another app's Funnel is no longer `.wrongPort`. New `NotRunningReason.allPortsTaken`, carrying the three ports' targets.
- [x] `parse(status:funnel:port:mistakenPorts:)`: `.wrongPort` only for an entry forwarding to one of `mistakenPorts`.
- [x] The Tailscale check result also carries the chosen public port: the running entry's, else the first free one, else nil. Done as `TunnelCheckResult { health, funnel: FunnelPorts? }`, with `FunnelPorts.publicPort`, `.running` and `.inTheWay`. The apps don't recompute it.

### F.2 Commands in one place · 1 h
- [x] `TailscaleFunnelCommand.start(port:publicPort:)` and `.off(port:publicPort:)`. 443 keeps today's exact text: `tailscale funnel --bg <port>` and `… off`. Other ports give `tailscale funnel --bg --https=<p> <port>` and `tailscale funnel --https=<p> off`, with the exact `off` syntax checked against `tailscale funnel --help` of the current Tailscale.
- [x] `publicPort(fromAddress:)`: the port in a saved address, 443 when it has none.
- [x] `TunnelSwitchSummary`: the off commands for the tunnel being left use that address's port.

### F.3 Tests, docs, release · 2 h
- [x] Fixtures in `Tests/BridgeKitRemoteTests` for:
  - the anonymized real config already in the fixtures (Funnel 443 → 47616, plus a tailnet-only Serve entry on 8443 → 4000). Not captured fresh: the sandbox can't reach Tailscale, so the live check confirms the current config;
  - 443 taken → 8443, and 443 and 8443 taken → 10000;
  - a Serve-only entry counts as taken, and so does a TCP entry;
  - all three taken;
  - our port already on 10000 → Running at `:10000`;
  - the local MCP port → wrong port;
  - unknown.
- [x] The commands for each port, and the off command from an address.
- [x] README, CHANGELOG `## 0.3.0`, PR (bridgekit#3), CI green, merged as `577e742`.
- [ ] Tag `0.3.0` on `577e742`, after both apps are green against it (with the user's OK).

## Part B: Funes 0.1.1

### F.4 Guide, Tunnel row and wording · 3 h
- [x] `RemoteWords`: `commands`, `offCommands` and `runCommand` take the public port from the check's result (rules 2, 3 and 6) and the turn-off port from the saved address (rule 7).
- [x] Step 2 shows which port it will use and why, in one line above the command. For example: "Funnel's port 443 already serves another app on this Mac (it forwards to 47616), so Funes Vault uses 8443."
- [x] Step 3's address hint expects the matching `:<port>`.
- [x] All taken (rule 4): a list of the three ports and their targets, and "Turn one off, or choose another tunnel." No Copy button.
- [x] The Tunnel row and the menu's "tunnel down" use the same states. `mistakenPorts: [47626]`.
- [x] `CloudSetup` notes: drop the manual 8443 note and add rule 6's line.
- [x] String Catalog, goldens for each state (`tunnel-*`), `RemoteSetupTests` and `RemoteAccessControllerTests`.

### F.5 Spec, docs, version · 1 h
- [x] [MCP server §12](../architecture/mcp-server.md#12-remote-transport) gets the port rule, and [reuse §3](../architecture/ek-bridge-reuse.md#3-tier-3-bridgekitremote-extracted-now-for-funes-v01) BridgeKit 0.3.0.
- [x] docs/MCP.md's Tailscale row (the guide picks the port; the commands per port) and README if needed.
- [x] [spike-results 4b.15](spike-results.md): the procedure follows the guide instead of a hand-typed `--https=8443`.
- [x] `MARKETING_VERSION` 0.1.1, build 2, `server.json`, CHANGELOG `## [0.1.1]` (the 0.1.0 entry stays, never published).
- [ ] Pin BridgeKit `exact: 0.3.0` in the Xcode project, BridgeUI and FunesMCP, and resolve. Until the tag, all three pin the branch's commit `8077dbf`.

## Part C: EK Bridge

### F.6 Adopt 0.3.0 · 2 h
- [x] `scripts/bridgekit.sh` → 0.3.0 at `577e742` (the merge commit, to be tagged). `AgentSetup` commands use `TailscaleFunnelCommand` with the checked port. `mistakenPorts: [47615]`.
- [x] Wording for the new states, the same meaning as Funes's in EK Bridge's words. With 443 free, every command, golden and harness stays byte-for-byte the same. New goldens only for "443 taken" and "all taken".
- [x] docs/MCP.md, CHANGELOG. A release only if the user wants one; it can just land on main.

## Checks

- [ ] `sh scripts/test.sh` green in all three repos, and CI green (Funes with both toolchains).
- [ ] **Live, on the user's Mac, with test builds and a scratch data folder for Funes.** The user runs every `tailscale` command themselves:
  1. With EK Bridge's Funnel on 443, Funes's guide offers the first free port (8443, or 10000 if 8443 has a Serve entry). Nothing it shows would touch 443.
  2. After running it, Funes's Tunnel row shows Running at `:<port>`, and EK Bridge's still shows Running on 443.
  3. EK Bridge's connectors in ChatGPT and claude.ai still work.
  4. Funes connects from claude.ai and ChatGPT at the `:<port>` address. This is also the 4b.15 check; whether both accept a non-443 port is the one thing this plan can't settle in tests.
- [ ] Then Funes `v0.1.1` → draft release, installed from GitHub, as for 0.1.0.

## Open questions

- If claude.ai or ChatGPT refuse an address with a port, every app after the first can't serve those two through Funnel. Fallbacks:
  - another tunnel for the second app (Cloudflare Tunnel or ngrok);
  - path routing on 443, which breaks OAuth discovery at the host root, so it's not planned.
