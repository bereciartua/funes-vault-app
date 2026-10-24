#!/bin/sh
# Spike E: every run behind spike-results.md. Each line resumes where it stopped.
# Codex (remote) runs alongside Apple; Ollama runs last and alone (8 GB Mac: two local models thrash).
set -e
cd "$(dirname "$0")"
case "$1" in
codex)
  python3 run.py codex extract --jobs 4
  python3 run.py codex tidy --jobs 4
  python3 run.py codex decide --jobs 4
  python3 run.py codex onecall --jobs 4
  python3 run.py codex extract-swapped --jobs 4
  python3 run.py codex tidy-v2 --jobs 3 ;;
codex-terra)
  python3 run.py codex-terra extract --jobs 4
  python3 run.py codex-terra decide --jobs 4
  python3 run.py codex-terra tidy-v2 --jobs 3 ;;
apple)
  # ~60 s a call on the 8 GB M1 under memory pressure: secondary experiments on the inputs that answer them.
  SENS=in14,in23,in24,in29,in38,in39,in40,in41,in42,in43,in72,in77,in79
  VARIANT=in12,in13,in21,in22,in23,in24,in25,in26,in27,in28,in29,in30,in31,in32,in33,in34,in35,in39,in47,in48,in54,in56,in57,in58,in61,in62,in66,in70,in75,in76,in77,in81,in83
  ONECALL=in04,in05,in06,in07,in08,in10,in12,in13,in15,in17,in21,in29,in30,in38,in39,in40,in43,in44,in50,in54,in55,in56,in58,in59,in60,in69,in70,in71,in73,in76
  python3 run.py apple extract
  python3 run.py apple tidy
  python3 run.py apple decide
  python3 run.py apple-permissive extract --only "$SENS,$(python3 failed.py apple extract guardrail)"
  python3 run.py apple onecall --only "$ONECALL"
  python3 run.py apple extract-swapped --only "$VARIANT"
  python3 run.py apple extract --chunk 700 --context 300 --tag c700 --only in25,in80,in81,in83 ;;
ollama)
  # ~2 min a call under the same memory pressure: decisions on Apple's 30-input subset only.
  python3 run.py ollama extract
  python3 run.py ollama tidy
  python3 run.py ollama decide --only in04,in05,in06,in07,in08,in10,in12,in13,in15,in17,in21,in29,in30,in38,in39,in40,in43,in44,in50,in54,in55,in56,in58,in59,in60,in69,in70,in71,in73,in76 ;;
claude)
  # Anthropic through the Claude CLI on the user's subscription, low effort like the Codex models' low reasoning.
  for m in claude-haiku claude-opus; do
    python3 run.py $m extract --jobs 4
    python3 run.py $m decide --jobs 4
    python3 run.py $m tidy-v2 --jobs 4
  done ;;
astra)
  # The second author's fixtures (GPT-6-Astra, blind), on the four cloud models; Codex and Claude in parallel.
  export SPIKE_SET=astra
  (for m in codex codex-terra; do python3 run.py $m extract --jobs 4; python3 run.py $m decide --jobs 4; python3 run.py $m tidy-v2 --jobs 4; done) &
  (for m in claude-haiku claude-opus; do python3 run.py $m extract --jobs 4; python3 run.py $m decide --jobs 4; python3 run.py $m tidy-v2 --jobs 4; done) &
  wait ;;
v2)
  # The user's compound-claim rule, on both fixture sets, for the four cloud models (Codex and Claude in parallel).
  for set in "" astra; do
    export SPIKE_SET=$set
    (for m in codex codex-terra; do python3 run.py $m extract-v2 --jobs 4; python3 run.py $m decide-v2 --jobs 4; done) &
    (for m in claude-haiku claude-opus; do python3 run.py $m extract-v2 --jobs 4; python3 run.py $m decide-v2 --jobs 4; done) &
    wait
  done ;;
esac
