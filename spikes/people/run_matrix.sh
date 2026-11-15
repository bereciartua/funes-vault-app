#!/bin/sh
# Spike H: engines (default all four), two independent runs each, on one set (main or astra). One engine at a time;
# two stories in parallel.   ./run_matrix.sh main ["claude-haiku claude-opus"]
set -u
SET=${1:-main}
ENGINES=${2:-"claude-haiku claude-opus codex-luna codex-terra"}
for engine in $ENGINES; do
  for run in 1 2; do
    python3 run.py "$engine" --set "$SET" --run "$run" --workers 2 || echo "FAILED $engine run $run"
  done
done
echo "matrix $SET ($ENGINES) done"
