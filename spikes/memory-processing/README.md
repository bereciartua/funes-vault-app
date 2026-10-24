# Spikes E and F: extraction and tidy-up quality

Throwaway harness for [Phase 6.0](../../spec/plans/phase-6-0-spike-e.md). Results: the "Spike E" section of
[spike results](../../spec/plans/spike-results.md). The fixtures are kept for 6a and 6b's tests.

## Fixtures (synthetic; the repo is public)
- `fixtures/inputs.json`: 82 inputs (typed, dictated and shared captures, seed answers, agent suggestions written like
  ChatGPT's memory paragraph, Claude, Markdown and ChatGPT import items) with their expected pieces, link decisions
  and wrong claims to catch. Built by `build_fixtures.py`, whose docstring gives the matching rules.
- `fixtures/inputs-astra.json`, `fixtures/clusters-astra.json`: a second set (40 inputs, 40 clusters) written blind by
  GPT-6-Astra (`author_astra.py`, converted and checked by `check_astra.py`). Run and score it with `SPIKE_SET=astra`;
  `compare_sets.py` puts both sets side by side.
- Compound claims follow the user's own labels (21 items, recorded in `build_fixtures.py` and in `check_astra.py`'s
  `USER_LABELS`; the same rule applied to the other single claims is `RULE_LABELS`). `extract-v2` and `decide-v2` run
  the extraction rule built from them (`./run_all.sh v2`).
- `fixtures/vault.json`: the 200 Spike 2 memories with dates, source and trust: the vault the inputs link against.
- `fixtures/clusters.json`: 100 tidy-up clusters with expected, acceptable and forbidden actions (k41–k100 held out from the
  second tidy-up prompt's design).

## Running
```bash
swift build -c release --package-path swift
```
`swift/` holds `fm-runner` (Apple Foundation Models over JSON lines, macOS 26.4+) and `bge-embed` (FunesCore's
bundled bge-small; needs `scripts/fetch_embedding_model.sh` first).
```bash
./run_all.sh codex
```
```bash
./run_all.sh apple
```
```bash
./run_all.sh ollama
```
```bash
python3 score.py
```
```bash
python3 related.py
```
- `run.py`: one provider and experiment at a time (see its docstring); raw results in `results/<provider>/*.jsonl`,
  resumable.
- `score.py`: scores every result file into `results/report.md`.
- `related.py`: question 8, the finder's "related" threshold (`related.py codex` for a provider's real pieces).
- `autoapply_new.py`: §5.7 auto-apply simulated per gate, for the target precision.
- `revalidate.py`: re-applies validation to stored results after a validation change; `failed.py` lists ids whose calls failed.
- Providers: Apple on-device (`apple`, and `apple-permissive` with `.permissiveContentTransformations`
  guardrails), Ollama (`qwen3:4b-instruct-2507-q4_K_M`, 4k context), and OpenAI GPT-6-Luna (`codex`) and GPT-5.6-Terra
  (`codex-terra`) through the Codex CLI (`codex exec --output-schema`, the task instructions as
  `model_instructions_file`) on a ChatGPT subscription.
  Anthropic Claude Haiku 5.5 (`claude-haiku`) and Opus 5.5 (`claude-opus`) through `claude -p --json-schema` on a Claude
  subscription. Gemini wasn't run (no API key).
- Code: `prompts.py` (the prompts and schemas), `validate.py` (§1 secret scanner port, §5.4 and §9.4 validation),
  `finder.py` (§5.5 related-memories finder), `providers.py`.

## Spike F: pieces that make sense alone
Results: the "Spike F" section of [spike results](../../spec/plans/spike-results.md).
- `fixtures/episodes.json`: 10 long agent-written memories, one episode or entity each (two hiring processes and an
  interview outcome, a confidential recruiter pitch, a trip, a knee injury, a side project, a contract, a lease, a
  conference talk, a wedding in Spanish), 167 labelled facts. Built by `build_episodes.py`, whose docstring gives the
  labels (keep, drop, either; timed; about something else) and matching rules.
- `spike_f.py`: extraction with five variants (A as shipped; A+ with the memory's title and date; B pieces name their
  subject, time and status; C B plus a durability filter; D topic-level), the two-step judge (a blind reader that sees
  only `title: body`, then a grader with the original), `score` (`results/spike-f/report.md`) and `sample`
  (`results/spike-f/spot-check.md`).
- `run.py` experiments `extract-fB`, `extract-fC`, `decide-fB`, `decide-fC`: Spike E's fixtures with B and C.
- `./run_f.sh extract|judge|regression|decide fB` reruns everything.
