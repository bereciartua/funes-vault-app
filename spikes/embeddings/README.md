# Spike 2b: local open-source embeddings (throwaway)

Embeds the search benchmark with open models and converts the winner to Core ML. Scoring, FTS5 and latency run in Swift (`spikes/search`, `MODE=2b` and `MODE=coreml`). Results and conclusions: [`spec/plans/spike-results.md`](../../spec/plans/spike-results.md#spike-2b-local-open-source-embeddings); raw output: `run-2b.md` (`run-2b-1.md` is an earlier pass without the Core ML vectors).

Weights download to the Hugging Face cache (`~/.cache/huggingface`); the venv, vectors and Core ML packages are git-ignored.

```bash
cd spikes/embeddings && /opt/homebrew/bin/python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt
```
```bash
cd spikes/search && swift build -c release && MODE=2b EXPORT=../embeddings/corpus.json .build/release/search-spike ../../Packages/FunesCore/Tests/FunesCoreTests/fixtures 10000
```
```bash
cd spikes/embeddings && .venv/bin/python -I embed.py corpus.json vectors bge-small bge-small-noinst e5-small me5-small nomic-v1.5 qwen3-0.6b
```
```bash
cd spikes/embeddings && .venv/bin/python -I convert_coreml.py BAAI/bge-small-en-v1.5 cls out/bge-small.mlpackage
```
Then `MODE=coreml` (see the variables at the top of `runCoreMLBench` in `spikes/search/Sources/search-spike/CoreMLBench.swift`) writes `vectors/bge-small-coreml-<units>/`, and:
```bash
cd spikes/search && MODE=2b MODELS=bge-small,bge-small-coreml-cpu,bge-small-noinst,e5-small,me5-small,nomic-v1.5,qwen3-0.6b .build/release/search-spike ../../Packages/FunesCore/Tests/FunesCoreTests/fixtures 10000
```

- `make_query_variants.py` wrote `queries-30-expanded.json` (FunesCore fixture) and `queries-30-es.json` (here).
- `tokcheck.py` writes Hugging Face token ids to check the Swift WordPiece tokenizer (`TOKCHECK=`).
- EmbeddingGemma-300m is listed in `embed.py` but wasn't run. The repository is gated: even signed in, the download returns 403 until the account accepts the Gemma terms at huggingface.co/google/embeddinggemma-300m.

## Phase 6c.1: provider embeddings as a second index

`bench6c.py` embeds the English and Spanish fixtures (`memories-200-es.json`, `queries-30-es-expanded.json`) and scores bge-small with a second index as `SearchService.rank` does. Results: [`spec/plans/spike-results.md`](../../spec/plans/spike-results.md#phase-6c1-provider-embeddings-as-a-second-index); raw output: `run-6c.md`. Vectors go to `vectors6c/` (git-ignored).

```bash
cd spikes/embeddings && HF_HUB_OFFLINE=1 .venv/bin/python -I bench6c.py embed bge-small nomic-v1.5 nomic-v1.5-noprefix me5-small qwen3-0.6b
```
```bash
cd spikes/embeddings && .venv/bin/python -I bench6c.py score nomic-v1.5 nomic-v1.5-noprefix me5-small qwen3-0.6b oai-3-small oai-3-large > run-6c.md
```
Cloud models read `OPENAI_API_KEY` / `GEMINI_API_KEY` from the environment and send only the synthetic fixtures (`bench6c.py tokens` prints the input size):
```bash
cd spikes/embeddings && .venv/bin/python -I bench6c.py embed oai-3-small oai-3-large
```
