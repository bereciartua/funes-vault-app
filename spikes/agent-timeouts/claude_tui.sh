#!/bin/sh
# Interactive Claude Code against the spike server, with a throwaway config
# (--strict-mcp-config: your own MCP servers and settings files are untouched).
# Registers funes-waits and funes-approval as in README.md, and starts with the
# checklist prompt for the chosen test. Watch the tool row while a call runs.
#
# Usage: sh claude_tui.sh [waits|progress|approval]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/logs"
case "${1:-waits}" in
  waits) PROMPT="Call the funes-waits wait_seconds tool with seconds=45, then 60, then 120, one after another, never in parallel. Don't retry a call that fails. Report each result or the exact error." ;;
  progress) PROMPT="Call the funes-waits wait_seconds tool once with seconds=30 and progress=true." ;;
  approval) PROMPT="I'm starting a new TypeScript library. Use the funes-approval request_memory tool to get my coding preferences, then tell me which package manager and test runner I prefer." ;;
  *) echo "usage: sh claude_tui.sh [waits|progress|approval]" >&2; exit 2 ;;
esac
cfg="$HERE/logs/claude-tui.mcp.json"
cat > "$cfg" <<EOF
{"mcpServers": {
  "funes-waits": {"type": "stdio", "command": "python3", "args": ["$HERE/server.py"],
    "env": {"SPIKE_AGENT": "claude-code:tui", "SPIKE_TOOLS": "wait_seconds"}},
  "funes-approval": {"type": "stdio", "command": "python3", "args": ["$HERE/server.py"],
    "env": {"SPIKE_AGENT": "claude-code:tui", "SPIKE_TOOLS": "request_memory,get_memory_request",
            "SPIKE_INCALL_WAIT": "45", "SPIKE_APPROVE_AFTER": "60"}}}}
EOF
exec env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" TERM="${TERM:-xterm-256color}" LANG=en_US.UTF-8 \
  claude --mcp-config "$cfg" --strict-mcp-config \
  --allowedTools "mcp__funes-waits__wait_seconds" "mcp__funes-approval__request_memory" \
  "mcp__funes-approval__get_memory_request" -- "$PROMPT"
