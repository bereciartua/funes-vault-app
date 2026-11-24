#!/bin/sh
# The 13a.2 Gates' code freeze (Phase 13 plan): the blind work fixture and the canary are written by GPT-6-Astra after it,
# and nothing that runs may change once they exist (ADR-0032's canary row: "no source file changed, checked mechanically").
#
#   sh scripts/facts_freeze.sh write     records the sha256 of every code file in spikes/people/freeze-13a2.txt (refuses
#                                        if a freeze exists: `write --force` replaces it, only by the author's decision)
#   sh scripts/facts_freeze.sh check     fails, listing them, if any code file changed, appeared or went since
#
# Code is every file git tracks or would track (build output and other ignored files excluded) under Packages/, Apps/,
# scripts/, FunesVault.xcodeproj/, spikes/people/*.py and spikes/people/swift/, the registry and prompt included, and the
# data the gates read (spikes/people/registry.json, port_fidelity_known.json); not the fixtures, results, qualification
# records or this freeze file, which the Gates step adds after the freeze.
set -eu
cd "$(dirname "$0")/.."
FREEZE=${FACTS_FREEZE:-spikes/people/freeze-13a2.txt}    # 13e.2's timeline gate keeps its own: FACTS_FREEZE=spikes/people/freeze-13e2.txt
digests() {
    git -c core.quotePath=false ls-files -co --exclude-standard -- Packages Apps scripts FunesVault.xcodeproj 'spikes/people/*.py' \
        spikes/people/swift spikes/people/registry.json spikes/people/port_fidelity_known.json \
        | grep -v -e '/Resources/facts-qualification.json$' | LC_ALL=C sort | while read -r f; do
        [ -f "$f" ] && printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
    done
}
case "${1:-check}" in
    write)
        if [ -f "$FREEZE" ] && [ "${2:-}" != --force ]; then echo "facts_freeze.sh: $FREEZE exists (write --force replaces it)" >&2; exit 2; fi
        digests > "$FREEZE"; echo "facts_freeze.sh: $(wc -l < "$FREEZE" | tr -d ' ') files frozen in $FREEZE" ;;
    check)
        [ -f "$FREEZE" ] || { echo "facts_freeze.sh: no $FREEZE (write it at the freeze)" >&2; exit 2; }
        if digests | diff -u "$FREEZE" - > /tmp/facts-freeze.$$.diff; then
            rm -f /tmp/facts-freeze.$$.diff; echo "facts_freeze.sh: no code changed since the freeze"
        else
            grep -E '^[-+][0-9a-f]{64}' /tmp/facts-freeze.$$.diff | sed 's/^\([-+]\)[0-9a-f]*  /\1 /' >&2
            rm -f /tmp/facts-freeze.$$.diff; echo "facts_freeze.sh: code changed since the freeze" >&2; exit 1
        fi ;;
    *) echo "usage: facts_freeze.sh write|check" >&2; exit 2 ;;
esac
