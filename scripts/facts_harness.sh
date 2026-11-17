#!/bin/sh
# The facts fixture harness (Phase 13a.2): plays a spike story set through the Swift pipeline and scores it with the
# spike's own scorers. Replays the spike's recorded model calls by default; never calls a model unless asked.
#
#   sh scripts/facts_harness.sh mixed                          replay results-h3b's recorded calls for the set
#   sh scripts/facts_harness.sh mixed schedule                 Swift's own schedule answered from them (counts calls)
#   FUNES_FACTS_HARNESS_LIVE=1 sh scripts/facts_harness.sh mixed live=claude:haiku
#                                                              a live run (only with the author's go-ahead)
#
# Output goes to build/facts-harness/<label>/<set>.jsonl, with score.py's report.md and score_facts.py's output.
set -eu
cd "$(dirname "$0")/.."
SET="${1:-mixed}"
MODE="${2:-replay}"
OUT="$PWD/build/facts-harness"
mkdir -p "$OUT"
export PYTHONPYCACHEPREFIX="$PWD/build/pycache"
case "$SET" in
    main) FIXTURE=stories.json; RESULTS=claude-haiku-people/main.jsonl ;;
    astra) FIXTURE=stories-astra.json; RESULTS=claude-haiku-people/astra.jsonl ;;
    mixed) FIXTURE=stories-mixed.json; RESULTS=claude-haiku-separate/mixed.jsonl ;;
    canary) FIXTURE=stories-canary.json; RESULTS=../results-h3b/fresh/claude-haiku-people-h3b-canary/canary.jsonl ;;
    *) echo "facts_harness.sh: unknown set $SET" >&2; exit 2 ;;
esac
if [ "$MODE" = replay ] || [ "$MODE" = schedule ]; then
    (cd spikes/people && python3 export_replay.py "results-h3b/$RESULTS" "fixtures/$FIXTURE" "$OUT/export-$SET.jsonl")
    SPEC="set=$SET;replay=$OUT/export-$SET.jsonl;out=$OUT;tag=$SET"
    [ "$MODE" = schedule ] && SPEC="$SPEC;schedule=1"
else
    SPEC="set=$SET;$MODE;out=$OUT"
fi
FUNES_FACTS_HARNESS="$SPEC" swift test --package-path Packages/FunesCore --filter FactsHarnessTests/fullRun
cat "$OUT"/*/"$SET-summary.txt"
(cd spikes/people && RESULTS_DIR="$OUT" python3 score.py --set "$SET" > /dev/null && echo "score.py: $OUT/report.md")
for f in "$OUT"/*/"$SET.jsonl"; do
    echo "score_facts.py stories $f:"
    (cd spikes/people && python3 score_facts.py stories "$f" "fixtures/$FIXTURE") || true
done
