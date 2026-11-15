#!/bin/sh
# Spike H3b: replay every saved extraction through the current code and score it (no model calls).
set -e
for s in main main-run2 astra astra-run2; do set=${s%-run2}; fx=fixtures/stories.json; [ $set = main ] || fx=fixtures/stories-$set.json
  python3 replay.py results-h3/claude-haiku-people/$s.jsonl $fx results-h3b/claude-haiku-people/$s.jsonl >/dev/null; done
for g in separate merged; do python3 replay.py results-h3/claude-haiku-$g/mixed.jsonl fixtures/stories-mixed.json results-h3b/claude-haiku-$g/mixed.jsonl >/dev/null; done
for f in canary canary-run2; do FACTS_REGISTRY=registry-canary-datafix.json python3 replay.py results-h3/claude-haiku-people-canary/$f.jsonl fixtures/stories-canary.json results-h3b/claude-haiku-people-canary/$f.jsonl >/dev/null; done
python3 score_facts.py convert results-search/work-extract-fixture.jsonl fixtures/work-vault.json results-h3b/h2-converted.json >/dev/null
echo "== tests"; python3 test_facts.py | tail -1; python3 test_temporal.py | tail -1
echo "== canary CI"; python3 canary_ci.py registry-canary-datafix.json | head -1
for set in main astra mixed; do echo "== people links: $set"; RESULTS_DIR=results-h3b python3 score.py --set $set 2>/dev/null | grep -E "^## |full basis|sole_known right|untrusted right|Decidable role references linked|forbids|precision"; done
echo "== people links: canary"; FACTS_REGISTRY=registry-canary-datafix.json RESULTS_DIR=results-h3b python3 score.py --set canary 2>/dev/null | grep -E "full basis|sole_known right|untrusted right|Decidable role references linked|forbids|precision"
for g in separate merged; do echo "== timeline: mixed $g"; python3 score_facts.py stories results-h3b/claude-haiku-$g/mixed.jsonl fixtures/stories-mixed.json; done
for f in canary canary-run2; do echo "== timeline: canary $f"; FACTS_REGISTRY=registry-canary-datafix.json python3 score_facts.py stories results-h3b/claude-haiku-people-canary/$f.jsonl fixtures/stories-canary.json | grep -v organizations; done
for x in results-h3b/h2-converted.json results-h3/work-haiku-work.json; do echo "== timeline: work $x"; python3 score_facts.py work $x fixtures/work-queries.json | sed -n 2p; done
