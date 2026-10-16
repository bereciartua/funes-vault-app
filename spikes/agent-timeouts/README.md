# Spike 3: agent timeouts and the in-call approval

Throwaway code for [Phase 0 Spike 3](../../spec/plans/phase-0-spikes.md#spike-3-agent-timeouts-and-the-in-call-approval). It decides open question Q10: how long `request_memory` should wait in-call while the approval panel is open. Results are in [spec/plans/spike-results.md](../../spec/plans/spike-results.md#spike-3-agent-timeouts-and-the-in-call-approval).

Python 3.9+ standard library only, stdio transport. Nothing here ships.

| File | What it is |
|---|---|
| `server.py` | MCP server with `wait_seconds`, `request_memory` (returns `needs_approval`) and `get_memory_request` (succeeds once the request is "approved") |
| `report.py` | Summarises `logs/events.jsonl` per server process: how each call ended, and each poll |
| `run_headless.sh` | The automated runs against `claude -p` and `codex exec` (no global config changes) |
| `claude_tui.sh` | Interactive Claude Code against the spike, with a throwaway config |
| `logs/` | Git-ignored. `events.jsonl` (every message in and out) plus per-run transcripts |

## The server

| Tool | Behaviour |
|---|---|
| `wait_seconds {seconds, progress?}` | Sleeps, then returns `{"waited_s": N}`. With `progress: true` and a client `progressToken`, sends `notifications/progress` every 5 s with the message "Waiting for your approval in Funes…" |
| `request_memory {task}` | Waits `SPIKE_INCALL_WAIT` seconds (sending progress every 5 s), then returns `status: needs_approval`, a `request_id`, and a `message` telling the agent to tell the user and call `get_memory_request` in about a minute |
| `get_memory_request {request_id}` | `needs_approval` until `SPIKE_APPROVE_AFTER` seconds after the request was created, then `delivered` once (the text contains the canary `ORCHID-7`), then `already_delivered`. Once per 5 s per id, else `rate_limited` |

| Variable | Default | Meaning |
|---|---|---|
| `SPIKE_AGENT` | client's `clientInfo.name` | Label in the log, so runs can be told apart |
| `SPIKE_TOOLS` | all three | Comma-separated tools to expose. Approval runs hide `wait_seconds`: when it is visible, agents use it as a timer |
| `SPIKE_INCALL_WAIT` | `0` | In-call wait before `needs_approval` (use `45` to mimic the spec) |
| `SPIKE_APPROVE_AFTER` | `20` | When the fake user "approves" |
| `SPIKE_LOG` | `logs/events.jsonl` | Log path |

The server logs the moment a client cancels a call (`notifications/cancelled`) or hangs up, so `report.py` shows a client-side timeout as "CANCELLED by client after N s" or "client hung up after N s".

## Setup per agent

Every agent gets two entries: **`funes-waits`** (only `wait_seconds`) and **`funes-approval`** (only the approval tools, with a 45 s in-call wait and approval after 60 s, as in the spec). The server path is:

```
/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py
```

Prefer the project-scoped or per-run options below, so global configs stay untouched. Remove the entries when done.

### Claude Code
Per run, no config change. `claude_tui.sh` registers both entries with `--strict-mcp-config` and starts with the checklist prompt for `waits`, `progress` or `approval`:
```bash
sh /Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/claude_tui.sh approval
```
Or register them in your local scope (this writes to `~/.claude.json`; remove them with `claude mcp remove funes-waits` and `claude mcp remove funes-approval`):
```bash
claude mcp add funes-waits -e SPIKE_AGENT=claude-code -e SPIKE_TOOLS=wait_seconds -- python3 /Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py
```
```bash
claude mcp add funes-approval -e SPIKE_AGENT=claude-code -e SPIKE_TOOLS=request_memory,get_memory_request -e SPIKE_INCALL_WAIT=45 -e SPIKE_APPROVE_AFTER=60 -- python3 /Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py
```
The default tool timeout is `MCP_TOOL_TIMEOUT` (ms, about 28 h); calls longer than 120 s may move to a background task in recent versions.

### Claude Desktop
Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (Settings ▸ Developer ▸ Edit Config), merge into `mcpServers`, then quit and reopen Claude:
```json
{
  "mcpServers": {
    "funes-waits": {
      "command": "python3",
      "args": ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"],
      "env": {"SPIKE_AGENT": "claude-desktop", "SPIKE_TOOLS": "wait_seconds"}
    },
    "funes-approval": {
      "command": "python3",
      "args": ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"],
      "env": {"SPIKE_AGENT": "claude-desktop", "SPIKE_TOOLS": "request_memory,get_memory_request",
              "SPIKE_INCALL_WAIT": "45", "SPIKE_APPROVE_AFTER": "60"}
    }
  }
}
```
If `python3` isn't found (Desktop doesn't use your shell's `PATH`), use `/usr/bin/python3`. Issue threads report a fixed, non-configurable ~60 s timeout.

### Cursor
Project-scoped: open `spikes/agent-timeouts` as the workspace and create `.cursor/mcp.json` there (or use `~/.cursor/mcp.json`). Enable both servers under Settings ▸ MCP:
```json
{
  "mcpServers": {
    "funes-waits": {
      "type": "stdio",
      "command": "python3",
      "args": ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"],
      "env": {"SPIKE_AGENT": "cursor", "SPIKE_TOOLS": "wait_seconds"}
    },
    "funes-approval": {
      "type": "stdio",
      "command": "python3",
      "args": ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"],
      "env": {"SPIKE_AGENT": "cursor", "SPIKE_TOOLS": "request_memory,get_memory_request",
              "SPIKE_INCALL_WAIT": "45", "SPIKE_APPROVE_AFTER": "60"}
    }
  }
}
```
Cursor staff report about 60 min in the IDE and a hardcoded 60 s in the Cursor CLI/ACP.

### Codex (CLI)
Per run, no config change (the same `-c` overrides work for `codex` and `codex exec`):
```bash
codex -c 'mcp_servers.funes_approval.command="python3"' -c 'mcp_servers.funes_approval.args=["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"]' -c 'mcp_servers.funes_approval.env={SPIKE_AGENT="codex",SPIKE_TOOLS="request_memory,get_memory_request",SPIKE_INCALL_WAIT="45",SPIKE_APPROVE_AFTER="60"}'
```
Or in `~/.codex/config.toml`:
```toml
[mcp_servers.funes_waits]
command = "python3"
args = ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"]
env = { SPIKE_AGENT = "codex", SPIKE_TOOLS = "wait_seconds" }

[mcp_servers.funes_approval]
command = "python3"
args = ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"]
env = { SPIKE_AGENT = "codex", SPIKE_TOOLS = "request_memory,get_memory_request", SPIKE_INCALL_WAIT = "45", SPIKE_APPROVE_AFTER = "60" }
```
Per-server `tool_timeout_sec`: the docs say 60 by default, but 0.160 waited 90 s without it (the source says 300).

### VS Code (GitHub Copilot agent mode)
Project-scoped: open `spikes/agent-timeouts` as the workspace and create `.vscode/mcp.json`; start the servers from the file's CodeLens or **MCP: List Servers**:
```json
{
  "servers": {
    "funes-waits": {
      "type": "stdio",
      "command": "python3",
      "args": ["${workspaceFolder}/server.py"],
      "env": {"SPIKE_AGENT": "vscode-copilot", "SPIKE_TOOLS": "wait_seconds"}
    },
    "funes-approval": {
      "type": "stdio",
      "command": "python3",
      "args": ["${workspaceFolder}/server.py"],
      "env": {"SPIKE_AGENT": "vscode-copilot", "SPIKE_TOOLS": "request_memory,get_memory_request",
              "SPIKE_INCALL_WAIT": "45", "SPIKE_APPROVE_AFTER": "60"}
    }
  }
}
```
The source shows no client-side timeout on `tools/call`, and progress messages are shown in the chat UI.

### Gemini CLI
Project-scoped: create `spikes/agent-timeouts/.gemini/settings.json` and run `gemini` from that folder (or use `~/.gemini/settings.json`):
```json
{
  "mcpServers": {
    "funes-waits": {
      "command": "python3",
      "args": ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"],
      "env": {"SPIKE_AGENT": "gemini-cli", "SPIKE_TOOLS": "wait_seconds"}
    },
    "funes-approval": {
      "command": "python3",
      "args": ["/Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/server.py"],
      "env": {"SPIKE_AGENT": "gemini-cli", "SPIKE_TOOLS": "request_memory,get_memory_request",
              "SPIKE_INCALL_WAIT": "45", "SPIKE_APPROVE_AFTER": "60"}
    }
  }
}
```
Per-server `timeout` is in ms, 600000 (10 min) by default. Gemini may ask you to trust the folder or confirm each tool call: allow it.

## Checklist (per agent)
Do these in a fresh chat for each agent. Note the clock time when you start, so you can filter the log with `--since` (epoch seconds, `date +%s`).

1. **Waits.** Send:
   > Call the funes-waits wait_seconds tool with seconds=45, then 60, then 120, one after another, never in parallel. Don't retry a call that fails. Report each result or the exact error.

   Record the largest wait that succeeded and the first that failed (with the error). Watch for automatic retries: the log shows a second `wait_seconds` with the same value.
2. **Progress.** Send:
   > Call the funes-waits wait_seconds tool once with seconds=30 and progress=true.

   While it runs, look at the tool row: does it show "Waiting for your approval in Funes…" or a progress bar, or just a spinner?
3. **Approval.** In a new chat, send:
   > I'm starting a new TypeScript library. Use the funes-approval request_memory tool to get my coding preferences, then tell me which package manager and test runner I prefer.

   The call blocks for 45 s (that's the in-call wait), then returns `needs_approval`. Record:
   - Did it wait the 45 s, or time out first?
   - Did it tell you "Waiting for your approval in Funes"?
   - Did it call `get_memory_request` on its own, without you typing anything, and when? Wait up to 3 minutes before nudging.
   - If it stopped, say "done" and check that it calls `get_memory_request` then.
   - Success = it answers **pnpm** and **Vitest** (the delivered text contains `ORCHID-7`).
4. Run:
   ```bash
   python3 /Users/mib/Projects/Personal/GIT/funes-vault-app/spikes/agent-timeouts/report.py --agent cursor
   ```
   (with the agent's `SPIKE_AGENT` label), and fill the row below.

## Results
Filled by Claude on 2026-10-16 for the two CLIs it could run headless. The rest is for manual runs. Full write-up: [spike-results.md](../../spec/plans/spike-results.md#spike-3-agent-timeouts-and-the-in-call-approval).

| Agent (version) | Max wait before timeout | Progress shown | Auto-retry | Calls `get_memory_request` on its own | Surfaces "waiting for your approval in Funes" |
|---|---|---|---|---|---|
| Claude Code 2.1.288 (`claude -p`) | **≥ 300 s** (15, 30, 45, 60, 120 and 300 all completed) | Headless: no server message; a generic heartbeat event at 30 s. Interactive: _not checked_ | No | **Partly:** it says it will check back and starts a background `sleep 60`, but the headless process exits first. Interactive: _not checked_ | **Yes**, 3 of 3 runs |
| Codex CLI 0.160.0 (`codex exec`) | **≥ 90 s** (30, 45, 60 and 90 completed with no `tool_timeout_sec`) | Headless: no | No | **Yes**: it used its built-in `sleep` tool (50–55 s), then polled, and got the text in 2 of 2 runs | **Yes**, 2 of 2 runs |
| Claude Desktop | _manual_ (issues report ~60 s) | | | | |
| Cursor | _manual_ (staff: ~60 min IDE, 60 s CLI) | | | | |
| VS Code Copilot | _manual_ (source: none) | | | | |
| Gemini CLI | _manual_ (docs: 600 s) | | | | |
