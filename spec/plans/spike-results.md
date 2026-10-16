# Spike results

Results of the [Phase 0 spikes](phase-0-spikes.md). Each section gives the question, what was run, the numbers, and the decision it feeds.

---

## Spike 3: Agent timeouts and the in-call approval
**Run:** 2026-10-16. **Code:** [`spikes/agent-timeouts/`](../../spikes/agent-timeouts/README.md), a throwaway stdio MCP server (Python standard library) plus a log reader.
**Status:** **provisional pass.** Claude Code passes, measured. Claude Desktop and Cursor still need a manual run (checklist in the spike README) before Q10 is closed.

### What was measured
The server has three tools:
- `wait_seconds` sleeps N seconds.
- `request_memory` optionally waits in-call, then returns `needs_approval`, a `request_id`, and a `message`.
- `get_memory_request` returns `needs_approval` until a fake approval 60 s after creation, then delivers a memory with a canary word.

The server logs every message, every `notifications/cancelled` and every hang-up, so a client-side timeout shows up as a cancellation time.

Claude ran the two CLIs headless (`claude -p`, `codex exec`), in a clean environment and with per-run configs, so no global agent config was changed. The others need a GUI and are left for a manual run.

### Results
| Agent (version) | Max wait before timeout | Progress shown | Auto-retry | Calls `get_memory_request` on its own | Surfaces "waiting for your approval in Funes" |
|---|---|---|---|---|---|
| Claude Code 2.1.288 | **≥ 300 s** measured (15, 30, 45, 60, 120, 300 all completed). Docs: `MCP_TOOL_TIMEOUT` ≈ 28 h | Headless: no server message, just a generic 30 s heartbeat. Interactive: not checked | No | **Partly.** In 3 of 3 runs it said it would check back and started a background `sleep 60`. The headless process then exited, so the follow-up call is unverified | **Yes** (3/3) |
| Codex CLI 0.160.0 | **≥ 90 s** measured (30, 45, 60, 90) with no `tool_timeout_sec`. Docs say 60 s; source says 300 s | Headless: no | No | **Yes.** It used its built-in `sleep` tool for 50–55 s, polled, and got the canary text: 2 of 2 runs, including with the 45 s in-call wait | **Yes** (2/2) |
| Claude Desktop | Manual. Issue threads report a fixed ~60 s | — | — | — | — |
| Cursor | Manual. Staff: ~60 min in the IDE, a hardcoded 60 s in the CLI/ACP | — | — | — | — |
| VS Code Copilot | Manual. Source: no client-side timeout | — | — | — | — |
| Gemini CLI | Manual. Docs: 600 s per server | — | — | — | — |

The figures marked docs, source, issues or staff come from a desk check on 2026-10-16. Sources:
- **Claude Code:** [env vars](https://code.claude.com/docs/en/env-vars) and [MCP](https://code.claude.com/docs/en/mcp) docs.
- **Claude Desktop:** issues [#22542](https://github.com/anthropics/claude-code/issues/22542) and [#63379](https://github.com/anthropics/claude-code/issues/63379).
- **Cursor:** [forum thread](https://forum.cursor.com/t/agent-acp-mcp-tools-call-times-out-at-60s-with-no-way-to-configure-it/163925).
- **Codex:** [`rmcp_client.rs`](https://github.com/openai/codex/blob/main/codex-rs/codex-mcp/src/rmcp_client.rs).
- **VS Code:** [`mcpServerRequestHandler.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/mcp/common/mcpServerRequestHandler.ts).
- **Gemini CLI:** [`mcp-server.md`](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md).

### Findings
1. **Nobody we measured times out at 45 s.** The tightest documented limit is Claude Desktop's reported ~60 s. A 45 s panel wait plus delivery fits under it, and the server's own 55 s "time to answer a call" limit ([mcp-server.md §9](../architecture/mcp-server.md#9-limits)) is already below 60 s.
2. **Progress notifications don't buy time.** Clients built on the MCP TypeScript SDK keep `resetTimeoutOnProgress` at its default `false`. Cursor staff confirmed Cursor doesn't reset; Gemini CLI and Codex don't reset either. Claude Code and Codex send a `progressToken` on every call anyway. Neither CLI showed the server's progress message headless. VS Code and Gemini CLI render progress, per their source. Sending "Waiting for your approval in Funes…" every 5 s during the in-call wait is cheap, but it's cosmetic only.
3. **The `needs_approval` message works when it's explicit.** The spike's message said: *Tell the user: "Waiting for your approval in Funes." Then call get_memory_request with request_id "…" in about a minute; it expires in 15 minutes.* Both agents repeated the sentence to the user every time, and both chose a ~1 min wait. Neither polled faster than the once-per-5-s limit.
4. **Agents improvise a timer.** Claude Code backgrounds a `sleep 60`, and Codex has a built-in `sleep`. With an unrelated "wait" tool visible, Claude Code tried to use that tool as its timer. Funes should not expose anything that looks like a wait tool.
5. **No automatic retries** of a `tools/call` in either CLI. A timed-out `request_memory` would not be re-sent behind the user's back. This matches the docs for the others.
6. **Client identification:** `clientInfo.name` is `claude-code` (protocol `2025-11-25`) and `codex-mcp-client` (protocol `2025-06-18`). That's enough to key a per-agent-kind wait later, if one is ever needed.
7. **Side note:** both CLIs advertise the `elicitation` capability (form and url). It isn't a substitute for the Funes panel: the user must see the exact text in Funes. Still, it's worth knowing for "open Funes" nudges.

### Caveats
- Transport: the spike used stdio. Funes serves Streamable HTTP, with stdio only through the `funes-mcp` launcher. Claude Code applies a 5 min idle timeout to network servers, which is well above 45 s. The Phase 2 Python harness should re-check a 45 s call over HTTP for Claude Code and Codex.
- Headless runs can't show UI progress or a follow-up turn that a background timer triggers. The interactive checks are in the README checklist (`claude_tui.sh approval` covers Claude Code).
- Versions move fast. Re-run the spike before the v0.1 live matrix (Phase 4).

### Recommendation for Q10
**45 s for all agents** (the current default). No per-agent-kind table in v0.1, and no immediate return. Supporting changes for Phase 2:
- Use the explicit message wording from finding 3 in `request_memory` and `get_memory_request` ([mcp-server.md §6.2](../architecture/mcp-server.md#62-request_memory)).
- Send `notifications/progress` with "Waiting for your approval in Funes…" during the in-call wait, when the client sent a `progressToken`. Don't rely on it to extend timeouts.
- Keep the in-call wait one constant. Log `clientInfo.name` with each request so a per-kind override can be added if a manual row comes in below ~50 s.
- Document per-agent behaviour in `docs/MCP.md` (Phase 4), from the completed table.

Fallback, unchanged from the plan: if Claude Desktop or Cursor turns out to cut off before ~50 s, make the wait per agent kind (for example 20 s for that client). If several do, return `needs_approval` immediately. Both measured agents handled the immediate-return path well.

**Before closing Q10:** fill the Claude Desktop and Cursor rows, plus Claude Code interactive (`claude_tui.sh approval`), using the spike README checklist. Then mark Q10 decided in [open-questions.md](open-questions.md).
