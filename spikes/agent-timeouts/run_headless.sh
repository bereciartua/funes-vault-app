#!/bin/sh
# Headless runs of the spike against Claude Code (claude -p) and Codex (codex exec).
# Neither touches global agent configs: Claude Code gets --strict-mcp-config with a
# generated file, Codex gets -c overrides. Results: logs/events.jsonl (read with
# report.py) and logs/<scenario>.out (the agent's own transcript).
#
# Usage: sh run_headless.sh SCENARIO...
#   cc-waits        Claude Code: wait_seconds 15, 30, 45, 60, 120 in sequence
#   cc-wait-300     Claude Code: one 300 s wait
#   cc-approval     Claude Code: needs_approval at once, MCP tools only
#   cc-approval-45  Claude Code: 45 s in-call wait, then needs_approval, MCP tools only
#   cc-approval-sleep  Claude Code: 45 s in-call wait, Bash(sleep) also allowed
#   cx-waits        Codex: wait_seconds 30, 45, 60, 90 in sequence (default tool timeout)
#   cx-approval     Codex: needs_approval at once
#   cx-approval-45  Codex: 45 s in-call wait (progress every 5 s), then needs_approval
#   cx-progress     Codex: one 30 s wait with progress notifications
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LOGS="$HERE/logs"
mkdir -p "$LOGS"
# A plain terminal environment: no variables from a parent Claude session.
CLEAN="env -i HOME=$HOME USER=${USER:-} PATH=$PATH TERM=xterm-256color LANG=en_US.UTF-8"

TASK="I'm starting a new TypeScript library. Use the funes-spike request_memory tool to get my coding \
preferences, then tell me which package manager and test runner I prefer and the exact text you received."

cc() { # scenario incall_wait allowed_tools prompt
  cfg="$LOGS/$1.mcp.json"
  cat > "$cfg" <<EOF
{"mcpServers": {"funes-spike": {"type": "stdio", "command": "python3", "args": ["$HERE/server.py"],
  "env": {"SPIKE_AGENT": "claude-code:$1", "SPIKE_INCALL_WAIT": "$2", "SPIKE_APPROVE_AFTER": "60",
          "SPIKE_TOOLS": "$TOOLS"}}}}
EOF
  start=$(date +%s)
  $CLEAN claude -p "$4" --mcp-config "$cfg" --strict-mcp-config --allowedTools "$3" \
    --output-format stream-json --verbose > "$LOGS/$1.out" 2> "$LOGS/$1.err" || true
  echo "$1: $(( $(date +%s) - start )) s"
}

cx() { # scenario incall_wait prompt
  start=$(date +%s)
  $CLEAN codex exec --skip-git-repo-check --sandbox read-only \
    -c "mcp_servers.funes_spike.command=\"python3\"" \
    -c "mcp_servers.funes_spike.args=[\"$HERE/server.py\"]" \
    -c "mcp_servers.funes_spike.env={SPIKE_AGENT=\"codex:$1\",SPIKE_INCALL_WAIT=\"$2\",SPIKE_APPROVE_AFTER=\"60\",SPIKE_TOOLS=\"$TOOLS\"}" \
    "$3" > "$LOGS/$1.out" 2> "$LOGS/$1.err" < /dev/null || true
  echo "$1: $(( $(date +%s) - start )) s"
}

WAITS="Call the funes-spike wait_seconds tool five times, one after another (never in parallel): \
seconds=15, then 30, then 45, then 60, then 120. Do not retry a call that fails. After each call, note \
whether it succeeded or what error you got. Finish with a table of the five results, quoting the errors."

APPROVAL_TOOLS="request_memory,get_memory_request"
for s in "$@"; do
  case "$s" in
    *approval*) TOOLS=$APPROVAL_TOOLS ;;
    *) TOOLS=wait_seconds ;;
  esac
  case "$s" in
    cc-waits) cc "$s" 0 "mcp__funes-spike__wait_seconds" "$WAITS" ;;
    cc-wait-300) cc "$s" 0 "mcp__funes-spike__wait_seconds" \
      "Call the funes-spike wait_seconds tool once with seconds=300. Do not retry. Report the result or the exact error." ;;
    cc-approval) cc "$s" 0 "mcp__funes-spike__request_memory mcp__funes-spike__get_memory_request" "$TASK" ;;
    cc-approval-45) cc "$s" 45 "mcp__funes-spike__request_memory mcp__funes-spike__get_memory_request" "$TASK" ;;
    cc-approval-sleep) cc "$s" 45 "mcp__funes-spike__request_memory mcp__funes-spike__get_memory_request Bash(sleep:*)" "$TASK" ;;
    cx-waits) cx "$s" 0 "Call the funes_spike wait_seconds tool four times, one after another (never in parallel): \
seconds=30, then 45, then 60, then 90. Do not retry a call that fails. Finish with a table of the results, quoting any errors." ;;
    cx-approval) cx "$s" 0 "$TASK" ;;
    cx-approval-45) cx "$s" 45 "$TASK" ;;
    cx-progress) cx "$s" 0 "Call the funes_spike wait_seconds tool once with seconds=30 and progress=true. Report the result." ;;
    *) echo "unknown scenario: $s" >&2; exit 2 ;;
  esac
done
