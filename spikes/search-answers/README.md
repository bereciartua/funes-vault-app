# Spike G: search answer quality

Throwaway harness for [Phase 9.2](../../spec/plans/phase-9-search-answers.md#92-spike-g-answer-quality--½-weekend).
Results: the "Spike G" section of [spike results](../../spec/plans/spike-results.md). Everything in the fixtures is
invented (the repo is public).

## Fixtures
- `fixtures/vault.json`: Spike E's 200 memories (the Spike 2 persona, with dates, sensitivity, source and trust) plus 8
  added ones: a fact buried in a long import, a newer value that disagrees with an older one, an older title, an
  injection inside an agent's memory, facts about other people. Built by `build_fixtures.py`.
- `fixtures/questions.json`: 42 questions (direct facts, negation, other people, superseded values and conflicts, buried
  facts, an injection, two above the cloud limit, four with no answer, three in Spanish) with the facts a correct
  answer states (regex keys, as Spike E scored) and the claims that would be wrong. `build_fixtures.py`'s docstring
  gives the matching rules.
- `fixtures/questions-astra.json`, `fixtures/vault-astra.json`: the held-out set written blind by GPT-6-Astra
  (`author_astra.py`).
- `fixtures/search.json`: each question's top results as the answer call carries them, from FunesCore's real vault
  search and passage code (`swift/`, `answer-input`), with the bundled bge-small when it's fetched.

## Running
```bash
swift build -c release --package-path swift
```
```bash
swift/.build/release/answer-input fixtures/vault.json fixtures/questions.json fixtures/search.json ~/Library/Caches/com.funesvault.dev/bge-small-en-v1.5-5c38ec7
```
```bash
python3 run.py claude-haiku
```
```bash
python3 score.py
```
- `run.py <provider> [--set main|astra] [--only ids] [--dry]`: one call per question with §10.3's prompt, §10.4's
  validation; raw results in `results/<provider>/<set>.jsonl`, resumable. Providers: `claude-haiku` (Claude Code),
  `codex-terra` and `codex-luna` (Codex), `apple` (Spike E's `fm-runner`; build `../memory-processing/swift` first).
- `score.py`: `results/report.md` against the gates (correct claims ≥ 95%, right "no answer" ≥ 90%, answered ≥ 80%
  of answerable, p95 ≤ 15 s). Claims that match no expected fact are listed for labelling in `labels.json`.
- `answer.py`: the prompt, the schema and the validation; `providers.py`: the CLIs, as Spike E ran them.
