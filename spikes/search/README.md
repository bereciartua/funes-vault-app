# Spike 2: search benchmark (throwaway)

Compares FTS5 BM25, Apple `NLEmbedding` / `NLContextualEmbedding`, hybrids, and Foundation Models query expansion and re-ranking on the fixtures in `Packages/FunesCore/Tests/FunesCoreTests/fixtures/`. Not part of any shipping target, and not run by `scripts/test.sh` or CI.

```bash
cd spikes/search && swift run -c release search-spike ../../Packages/FunesCore/Tests/FunesCoreTests/fixtures 10000
```

`MODE=2b` runs Spike 2b (open embedding models; see `../embeddings/README.md`), and `MODE=coreml` embeds with a Core ML model from Swift. `DUMP=1` adds per-query rankings; `RERANK=0` skips the slow re-rank step. The full run takes 10–20 minutes on an M1. Results and conclusions: [`spec/plans/spike-results.md`](../../spec/plans/spike-results.md); raw output: `run-1.md`, `run-2.md`.
