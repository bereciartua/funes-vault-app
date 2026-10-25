#!/bin/sh
# Spike F: every run behind the "Spike F" section of spike-results.md. Each line resumes where it stopped.
set -e
cd "$(dirname "$0")"
case "$1" in
extract)
  # Episodes, five variants, three engines (Claude and Codex in parallel).
  (for m in claude-haiku claude-opus; do for v in A A+ B C D; do python3 spike_f.py extract $m $v --jobs 4; done; done) &
  (for v in A A+ B C D; do python3 spike_f.py extract codex-terra $v --jobs 4; done) &
  wait
  # GPT-6-Sol, added at the author's request after the first run.
  for v in A A+ B C D B2 C2; do python3 spike_f.py extract codex-sol $v --jobs 3; done ;;
judge)
  # GPT-6-Luna judges every piece; Claude Opus 5.5 judges GPT-5.6-Terra's A and B pieces as a second opinion.
  python3 spike_f.py read codex --jobs 4
  python3 spike_f.py grade codex --jobs 4
  python3 spike_f.py read claude-opus --extractors codex-terra --variants A,B --jobs 4
  python3 spike_f.py grade claude-opus --extractors codex-terra --variants A,B --effort low --jobs 4 ;;
regression)
  # Spike E's fixtures (both sets) with B and C; variant A is Spike E's extract-v2/decide-v2.
  for set in "" astra; do
    export SPIKE_SET=$set
    (for m in claude-haiku claude-opus; do for v in fB fC; do python3 run.py $m extract-$v --jobs 4; done; done) &
    (for v in fB fC; do python3 run.py codex-terra extract-$v --jobs 4; done) &
    wait
  done ;;
decide)
  # Decisions for the winning variant only ($2: fB or fC).
  for set in "" astra; do
    export SPIKE_SET=$set
    (for m in claude-haiku claude-opus; do python3 run.py $m decide-$2 --jobs 4; done) &
    python3 run.py codex-terra decide-$2 --jobs 4 &
    wait
  done ;;
round2)
  # Second round, after the first run: time anchors only for episodes and moments, names from the context block.
  (for m in claude-haiku claude-opus; do for v in B2 C2; do python3 spike_f.py extract $m $v --jobs 4; done; done) &
  (for v in B2 C2; do python3 spike_f.py extract codex-terra $v --jobs 4; done) &
  wait
  python3 spike_f.py read codex --variants B2,C2 --jobs 4
  python3 spike_f.py grade codex --variants B2,C2 --jobs 4 ;;
round3)
  # Third round: C2 with a filter that keeps every fact about the subject itself.
  (for m in claude-haiku claude-opus; do python3 spike_f.py extract $m C3 --jobs 4; done) &
  (for m in codex-terra codex-sol; do python3 spike_f.py extract $m C3 --jobs 3; done) &
  wait
  python3 spike_f.py read codex --variants C3 --jobs 4
  python3 spike_f.py grade codex --variants C3 --jobs 4 ;;
regression2)
  # The winner ($2: fB2, fC2 or fC3) on Spike E's fixtures, with decisions.
  for set in "" astra; do
    export SPIKE_SET=$set
    (for m in claude-haiku claude-opus; do python3 run.py $m extract-$2 --jobs 4; python3 run.py $m decide-$2 --jobs 4; done) &
    (for m in codex-terra codex-sol; do python3 run.py $m extract-$2 --jobs 4; python3 run.py $m decide-$2 --jobs 4; done
   # GPT-6-Sol's baseline: the shipped prompt (Spike E's extract-v2 and decide-v2).
   python3 run.py codex-sol extract-v2 --jobs 4) &
    wait
  done ;;
esac
