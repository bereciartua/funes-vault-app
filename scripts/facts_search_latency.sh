#!/bin/sh
# Phase 13b's latency row on your own vault: search with learned facts' links within FR-V-10's
# 150 ms at p95. Run it yourself; it's never run by CI or an agent.
#
#   sh scripts/facts_search_latency.sh <queries.txt> [vault folder]
#
# <queries.txt>: your searches, one per line (the plan asks for 50). Keep the file outside the
# repository. The vault folder defaults to ~/Library/Application Support/FunesVault. The vault is
# copied (SQLite's backup) into a private temporary folder, the test runs in release on the copy,
# and the copy is deleted. Only timings are printed: p50, p95 and max with and without links, and
# the first search with a cold index. Never a query, a memory, a title or a name.
set -eu

if [ $# -lt 1 ]; then
    echo "usage: sh scripts/facts_search_latency.sh <queries.txt> [vault folder]" >&2
    exit 64
fi
queries=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
vault=${2:-"$HOME/Library/Application Support/FunesVault"}
[ -f "$vault/vault.sqlite" ] || { echo "no vault.sqlite in that folder" >&2; exit 66; }

copy=$(mktemp -d)
chmod 700 "$copy"
trap 'rm -rf "$copy"' EXIT INT TERM
sqlite3 "$vault/vault.sqlite" ".backup '$copy/vault.sqlite'"

cd "$(dirname "$0")/.."
FUNES_FACTS_LATENCY_VAULT="$copy" FUNES_FACTS_LATENCY_QUERIES="$queries" \
    swift test -c release -Xswiftc -enable-testing --package-path Packages/FunesCore \
    --filter FactsSearchPrivateLatencyTests 2>&1 | grep -E '^facts-latency:|^✘|^✔ Test' || true
