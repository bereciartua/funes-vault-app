# ADR-0002: Local MCP server over loopback HTTP with a stdio launcher

**Status:** Accepted · 2026-10-16

**Context.** Agents speak MCP over stdio or HTTP. EK Bridge already has a hardened loopback HTTP server, a stdio launcher that verifies the listener, keys per agent and rate limits.

**Decision.**

Expose MCP at `http://127.0.0.1:47625/mcp` (Streamable HTTP, JSON responses, the stateless 2026-07-28 protocol plus legacy versions). Ship the `funes-mcp` stdio launcher inside the app bundle. Reuse EK Bridge's implementation via BridgeKit.

**Consequences.**

- Works with every MCP client, through stdio or HTTP.
- Config files never contain keys: the launcher or Claude Code's `headersHelper` reads them.
- Remote and cloud agents (claude.ai, ChatGPT) aren't supported until v0.3 (Remote Access with OAuth).

**Alternatives considered.**

- **The official MCP Swift SDK:** possible, but EK Bridge's own implementation is already hardened and tested against the target clients.
- **stdio only:** blocks HTTP-native clients.
