# Security policy

Funes Vault keeps personal memories on your Mac and gives AI agents scoped access to them through a local MCP server. Please report security problems privately.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x (public preview) | Yes: the latest 0.1 release |
| Older builds, and builds from source | No |

Fixes ship as a new release, are listed in the [changelog](CHANGELOG.md), and reach installed copies through the in-app updater.

## Report a vulnerability

Use **GitHub private vulnerability reporting:** **Security ▸ Report a vulnerability** in this repository, or [open a draft advisory](https://github.com/bereciartua/funes-vault-app/security/advisories/new) directly. Only the maintainer sees it.

Please don't open a public issue, discussion or pull request for a vulnerability.

Include the app version (Settings ▸ Updates), your macOS version, whether the Mac has Apple silicon or Intel, the agent and how it connects (launcher or direct HTTP), and the steps to reproduce.

**Never include real secrets or personal data**, even in a private report:

- agent keys (anything starting with `fns_mcp_v1_`) or the contents of `agent-keys/`
- API keys for model providers
- `vault.sqlite`, its backups, or a `funesvault.export.v1` file from your own vault
- memory text, task text, or screenshots of the Vault, the Inbox or a panel that show your memories
- `activity/activity.jsonl` (it holds memory and agent ids, never text, but still describes what you shared)

Reproduce with a throwaway agent and a few made-up memories, and replace anything secret with `REDACTED`. A Debug build with `FUNES_DATA_DIR` pointing at an empty folder and `--dev-seed` gives you a development vault with sample memories that never touches your real one.

This is a personal project with best-effort support. You'll get a reply as soon as the maintainer can, and credit in the advisory and the changelog if you'd like it.

## Scope

In scope:

- The access policy: agent gates, per-memory eligibility (sensitivity ceilings, allowed and denied categories), approvals and their snapshots, single-use delivery and invalidation, and what refusals reveal (withheld counts, never ids).
- The local MCP server on `127.0.0.1:47625`: key authentication, the `Host`, `Origin` and forwarding-header checks, input validation, rate limits and the failed-sign-in lockout.
- The `funes-mcp` launcher: key-file handling, the check of the listening app, and the `headers` command.
- Remote Access (experimental, off by default): the remote listener's secret path, `Host` check and per-address lockout; remote tokens and their separation from local keys; the OAuth server (pairing, the six-digit code panel, PKCE, refresh rotation and reuse detection, revocation); the client-metadata fetch (SSRF); and any way a cloud agent gets a different decision than the same agent locally.
- Suggestions: validation, the secret scanner, and an agent planting memories outside its scope.
- File permissions of the vault, backups, key files and Activity in `~/Library/Application Support/FunesVault/`.
- What reaches a model provider: the secret scanner and the cloud limit in front of every model call.
- Logs and Activity leaking memory text, task text or keys.
- One-click agent setup writing anything other than the shown change, or writing a key.
- The build, signing and release pipeline, and in-app updates.

Out of scope, as described in the [threat model](docs/ARCHITECTURE.md#threat-model):

- A malicious process running as the same macOS user. It can read the vault, the backups and the key files; the app's checks separate the agents you connect, not processes of one user.
- What an AI agent, or its provider, does with memories you shared with it, including a cloud agent's vendor and a tunnel provider that ends TLS at its edge.
- The security of the tunnel software you run (Tailscale, cloudflared, ngrok).
- What a model provider you chose does with the text Funes sent it within your cloud limit.
- An attacker with physical access to an unlocked Mac, an administrator account, a Mac without FileVault, or System Integrity Protection turned off.
- Bugs in BridgeKit itself that don't depend on how Funes uses it: report those to [`bereciartua/bridgekit`](https://github.com/bereciartua/bridgekit/security/advisories/new). If you're unsure, report here.
