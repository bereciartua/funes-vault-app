# Spike 2 search benchmark

Date: 2026-10-16T23:50:37Z
Host: Version 27.0.1 (Build 26A434), 8 cores, 8 GB
Corpus: 200 fixture memories, 30 queries; big corpus 10000 (6791 paraphrases, 3009 mixtures)

## Models

| Model | Details | Embed ms/memory (200) | Embed ms/memory (10000) | Embed ms/query |
|---|---|---|---|---|
| nl-sentence | NLEmbedding.sentenceEmbedding(en) revision 1, dims 512 | 9.71 | 17.91 | 10.43 |
| nl-contextual | NLContextualEmbedding(en) 5C45D94E-BAB4-4927-94B6-8B5745C46289 revision 1, dims 512, max 256 tokens | 19.58 | 25.82 | 32.27 |

Ollama and OpenAI embeddings: not run (no local Ollama server, no API key on this machine).

Foundation Models query expansion: 3761 ms p50, 5041 ms p95, 5460 ms max per query (greedy sampling); 0 of 30 refused.

Recall@k: share of each query's relevant memories in the top k, averaged over the 30 queries. At 10000, a paraphrase counts as its source memory.

## Quality: original queries (no threshold)

| Method | R@5 (200) | R@10 (200) | MRR (200) | R@5 (10000) | MRR (10000) |
|---|---|---|---|---|---|
| fts5 | 0.456 | 0.528 | 0.587 | 0.278 | 0.471 |
| fts5-porter | 0.567 | 0.606 | 0.714 | 0.300 | 0.504 |
| nl-sentence | 0.250 | 0.306 | 0.375 | 0.228 | 0.310 |
| nl-sentence-centered | 0.233 | 0.333 | 0.376 | 0.261 | 0.345 |
| nl-contextual | 0.411 | 0.533 | 0.500 | 0.283 | 0.419 |
| nl-contextual-centered | 0.389 | 0.483 | 0.459 | 0.294 | 0.463 |
| nl-sentence + fts5 0.45/0.55 | 0.472 | 0.556 | 0.642 | 0.278 | 0.525 |
| nl-sentence + fts5-porter 0.45/0.55 | 0.522 | 0.672 | 0.729 | 0.311 | 0.578 |
| nl-sentence + fts5 0.30/0.70 | 0.433 | 0.550 | 0.633 | 0.300 | 0.547 |
| nl-sentence + fts5-porter 0.30/0.70 | 0.478 | 0.639 | 0.700 | 0.322 | 0.585 |
| nl-sentence-centered + fts5 0.45/0.55 | 0.456 | 0.556 | 0.656 | 0.344 | 0.573 |
| nl-sentence-centered + fts5-porter 0.45/0.55 | 0.522 | 0.661 | 0.711 | 0.333 | 0.634 |
| nl-sentence-centered + fts5 0.30/0.70 | 0.417 | 0.522 | 0.630 | 0.339 | 0.584 |
| nl-sentence-centered + fts5-porter 0.30/0.70 | 0.467 | 0.606 | 0.697 | 0.350 | 0.596 |
| nl-contextual + fts5 0.45/0.55 | 0.456 | 0.567 | 0.631 | 0.278 | 0.480 |
| nl-contextual + fts5-porter 0.45/0.55 | 0.583 | 0.628 | 0.761 | 0.300 | 0.525 |
| nl-contextual + fts5 0.30/0.70 | 0.467 | 0.567 | 0.633 | 0.278 | 0.467 |
| nl-contextual + fts5-porter 0.30/0.70 | 0.583 | 0.628 | 0.757 | 0.311 | 0.513 |
| nl-contextual-centered + fts5 0.45/0.55 | 0.439 | 0.550 | 0.643 | 0.300 | 0.510 |
| nl-contextual-centered + fts5-porter 0.45/0.55 | 0.567 | 0.656 | 0.789 | 0.328 | 0.637 |
| nl-contextual-centered + fts5 0.30/0.70 | 0.433 | 0.611 | 0.689 | 0.333 | 0.559 |
| nl-contextual-centered + fts5-porter 0.30/0.70 | 0.533 | 0.683 | 0.774 | 0.356 | 0.644 |

## Quality: Foundation Models–expanded queries (no threshold)

| Method | R@5 (200) | R@10 (200) | MRR (200) | R@5 (10000) | MRR (10000) |
|---|---|---|---|---|---|
| fts5 | 0.533 | 0.694 | 0.778 | 0.339 | 0.552 |
| fts5-porter | 0.667 | 0.756 | 0.841 | 0.367 | 0.632 |
| nl-sentence | 0.322 | 0.450 | 0.357 | 0.128 | 0.215 |
| nl-sentence-centered | 0.356 | 0.439 | 0.374 | 0.217 | 0.289 |
| nl-contextual | 0.517 | 0.644 | 0.709 | 0.278 | 0.426 |
| nl-contextual-centered | 0.600 | 0.694 | 0.727 | 0.311 | 0.520 |
| nl-sentence + fts5 0.45/0.55 | 0.550 | 0.683 | 0.805 | 0.367 | 0.611 |
| nl-sentence + fts5-porter 0.45/0.55 | 0.667 | 0.722 | 0.834 | 0.344 | 0.666 |
| nl-sentence + fts5 0.30/0.70 | 0.550 | 0.639 | 0.777 | 0.367 | 0.684 |
| nl-sentence + fts5-porter 0.30/0.70 | 0.622 | 0.717 | 0.809 | 0.378 | 0.684 |
| nl-sentence-centered + fts5 0.45/0.55 | 0.567 | 0.694 | 0.808 | 0.383 | 0.745 |
| nl-sentence-centered + fts5-porter 0.45/0.55 | 0.633 | 0.717 | 0.815 | 0.417 | 0.705 |
| nl-sentence-centered + fts5 0.30/0.70 | 0.572 | 0.656 | 0.790 | 0.394 | 0.744 |
| nl-sentence-centered + fts5-porter 0.30/0.70 | 0.561 | 0.700 | 0.802 | 0.428 | 0.726 |
| nl-contextual + fts5 0.45/0.55 | 0.550 | 0.717 | 0.794 | 0.328 | 0.571 |
| nl-contextual + fts5-porter 0.45/0.55 | 0.667 | 0.756 | 0.846 | 0.367 | 0.632 |
| nl-contextual + fts5 0.30/0.70 | 0.572 | 0.722 | 0.796 | 0.344 | 0.585 |
| nl-contextual + fts5-porter 0.30/0.70 | 0.644 | 0.772 | 0.831 | 0.350 | 0.636 |
| nl-contextual-centered + fts5 0.45/0.55 | 0.683 | 0.778 | 0.831 | 0.378 | 0.649 |
| nl-contextual-centered + fts5-porter 0.45/0.55 | 0.739 | 0.817 | 0.871 | 0.394 | 0.679 |
| nl-contextual-centered + fts5 0.30/0.70 | 0.689 | 0.761 | 0.835 | 0.417 | 0.673 |
| nl-contextual-centered + fts5-porter 0.30/0.70 | 0.744 | 0.817 | 0.883 | 0.411 | 0.698 |

## Weight sweep: original queries (200, fts5-porter; R@5 / MRR)

| wk/ws | nl-sentence | nl-sentence-centered | nl-contextual | nl-contextual-centered |
|---|---|---|---|---|
| 0.00/1.00 | 0.25 / 0.37 | 0.23 / 0.38 | 0.41 / 0.50 | 0.39 / 0.46 |
| 0.05/0.95 | 0.30 / 0.50 | 0.29 / 0.43 | 0.57 / 0.78 | 0.44 / 0.57 |
| 0.10/0.90 | 0.39 / 0.60 | 0.34 / 0.54 | 0.57 / 0.76 | 0.51 / 0.65 |
| 0.15/0.85 | 0.39 / 0.64 | 0.37 / 0.59 | 0.57 / 0.77 | 0.54 / 0.70 |
| 0.20/0.80 | 0.46 / 0.65 | 0.42 / 0.62 | 0.57 / 0.76 | 0.53 / 0.72 |
| 0.25/0.75 | 0.45 / 0.69 | 0.48 / 0.66 | 0.57 / 0.76 | 0.53 / 0.78 |
| 0.30/0.70 | 0.48 / 0.70 | 0.47 / 0.70 | 0.58 / 0.76 | 0.53 / 0.77 |
| 0.35/0.65 | 0.49 / 0.73 | 0.51 / 0.71 | 0.58 / 0.76 | 0.55 / 0.77 |
| 0.40/0.60 | 0.49 / 0.73 | 0.52 / 0.70 | 0.58 / 0.76 | 0.57 / 0.77 |
| 0.45/0.55 | 0.52 / 0.73 | 0.52 / 0.71 | 0.58 / 0.76 | 0.57 / 0.79 |
| 0.50/0.50 | 0.52 / 0.73 | 0.54 / 0.73 | 0.57 / 0.74 | 0.58 / 0.79 |
| 0.55/0.45 | 0.54 / 0.73 | 0.54 / 0.73 | 0.57 / 0.74 | 0.58 / 0.78 |
| 0.60/0.40 | 0.55 / 0.74 | 0.54 / 0.73 | 0.57 / 0.74 | 0.57 / 0.77 |
| 0.65/0.35 | 0.55 / 0.74 | 0.57 / 0.73 | 0.57 / 0.72 | 0.57 / 0.77 |
| 0.70/0.30 | 0.57 / 0.74 | 0.57 / 0.73 | 0.57 / 0.72 | 0.58 / 0.75 |
| 0.75/0.25 | 0.57 / 0.74 | 0.57 / 0.73 | 0.57 / 0.72 | 0.58 / 0.74 |
| 0.80/0.20 | 0.57 / 0.74 | 0.57 / 0.74 | 0.57 / 0.72 | 0.58 / 0.74 |
| 0.85/0.15 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.72 | 0.58 / 0.75 |
| 0.90/0.10 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.73 |
| 0.95/0.05 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.72 |
| 1.00/0.00 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.72 | 0.57 / 0.72 |

## Weight sweep: expanded queries (200, fts5-porter; R@5 / MRR)

| wk/ws | nl-sentence | nl-sentence-centered | nl-contextual | nl-contextual-centered |
|---|---|---|---|---|
| 0.00/1.00 | 0.32 / 0.36 | 0.36 / 0.37 | 0.52 / 0.71 | 0.60 / 0.73 |
| 0.05/0.95 | 0.44 / 0.52 | 0.39 / 0.44 | 0.69 / 0.88 | 0.63 / 0.79 |
| 0.10/0.90 | 0.49 / 0.67 | 0.49 / 0.62 | 0.68 / 0.86 | 0.67 / 0.79 |
| 0.15/0.85 | 0.56 / 0.75 | 0.54 / 0.74 | 0.66 / 0.86 | 0.72 / 0.83 |
| 0.20/0.80 | 0.54 / 0.80 | 0.58 / 0.77 | 0.64 / 0.84 | 0.76 / 0.84 |
| 0.25/0.75 | 0.58 / 0.81 | 0.58 / 0.81 | 0.64 / 0.84 | 0.76 / 0.87 |
| 0.30/0.70 | 0.62 / 0.81 | 0.56 / 0.80 | 0.64 / 0.83 | 0.74 / 0.88 |
| 0.35/0.65 | 0.65 / 0.81 | 0.62 / 0.80 | 0.66 / 0.83 | 0.74 / 0.88 |
| 0.40/0.60 | 0.67 / 0.82 | 0.63 / 0.81 | 0.67 / 0.83 | 0.73 / 0.87 |
| 0.45/0.55 | 0.67 / 0.83 | 0.63 / 0.81 | 0.67 / 0.85 | 0.74 / 0.87 |
| 0.50/0.50 | 0.67 / 0.83 | 0.67 / 0.83 | 0.67 / 0.84 | 0.71 / 0.87 |
| 0.55/0.45 | 0.68 / 0.83 | 0.67 / 0.84 | 0.67 / 0.84 | 0.71 / 0.86 |
| 0.60/0.40 | 0.68 / 0.83 | 0.68 / 0.84 | 0.67 / 0.84 | 0.68 / 0.85 |
| 0.65/0.35 | 0.69 / 0.83 | 0.68 / 0.83 | 0.67 / 0.84 | 0.67 / 0.85 |
| 0.70/0.30 | 0.70 / 0.83 | 0.69 / 0.83 | 0.67 / 0.84 | 0.67 / 0.83 |
| 0.75/0.25 | 0.70 / 0.83 | 0.69 / 0.83 | 0.67 / 0.84 | 0.69 / 0.83 |
| 0.80/0.20 | 0.67 / 0.83 | 0.67 / 0.83 | 0.67 / 0.84 | 0.67 / 0.83 |
| 0.85/0.15 | 0.67 / 0.84 | 0.67 / 0.83 | 0.67 / 0.84 | 0.67 / 0.84 |
| 0.90/0.10 | 0.67 / 0.84 | 0.67 / 0.84 | 0.67 / 0.84 | 0.67 / 0.84 |
| 0.95/0.05 | 0.67 / 0.84 | 0.67 / 0.84 | 0.67 / 0.84 | 0.67 / 0.84 |
| 1.00/0.00 | 0.67 / 0.84 | 0.67 / 0.84 | 0.67 / 0.84 | 0.67 / 0.84 |

## Similarity distribution (200, original queries)

Cosine of each query against its relevant memories vs all other memories.

| Model | relevant min | relevant p10 | relevant median | other median | other p90 | other p99 | other max |
|---|---|---|---|---|---|---|---|
| nl-sentence | 0.03 | 0.19 | 0.34 | 0.22 | 0.38 | 0.50 | 0.62 |
| nl-sentence-centered | -0.19 | -0.02 | 0.15 | -0.01 | 0.17 | 0.31 | 0.44 |
| nl-contextual | 0.82 | 0.84 | 0.89 | 0.85 | 0.89 | 0.92 | 0.94 |
| nl-contextual-centered | -0.05 | 0.09 | 0.29 | -0.01 | 0.20 | 0.38 | 0.59 |

## Thresholds: original queries (200, fts5-porter; keep if keyword > 0 or semantic ≥ T)

Vault: every kept result (recall, mean kept per query). Retrieval: top 30 of the kept results (recall@30).

### nl-sentence

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.728 | 0.711 |
| 0.05 | 1.000 | 187.5 | 0.728 | 0.711 |
| 0.10 | 0.989 | 172.1 | 0.728 | 0.711 |
| 0.15 | 0.978 | 148.5 | 0.728 | 0.711 |
| 0.20 | 0.933 | 117.7 | 0.728 | 0.711 |
| 0.25 | 0.872 | 88.4 | 0.728 | 0.711 |
| 0.30 | 0.856 | 61.0 | 0.728 | 0.711 |
| 0.35 | 0.789 | 41.9 | 0.728 | 0.711 |
| 0.40 | 0.789 | 29.6 | 0.728 | 0.711 |
| 0.45 | 0.756 | 23.0 | 0.728 | 0.728 |
| 0.50 | 0.706 | 19.4 | 0.694 | 0.694 |
| 0.55 | 0.706 | 18.4 | 0.694 | 0.694 |
| 0.60 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.65 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.70 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.706 |

### nl-sentence-centered

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.744 | 0.778 |
| 0.05 | 0.911 | 76.5 | 0.744 | 0.778 |
| 0.10 | 0.861 | 54.9 | 0.744 | 0.778 |
| 0.15 | 0.800 | 39.8 | 0.744 | 0.778 |
| 0.20 | 0.767 | 29.1 | 0.744 | 0.756 |
| 0.25 | 0.750 | 22.6 | 0.728 | 0.739 |
| 0.30 | 0.739 | 20.0 | 0.728 | 0.728 |
| 0.35 | 0.739 | 18.7 | 0.739 | 0.728 |
| 0.40 | 0.706 | 18.4 | 0.706 | 0.694 |
| 0.45 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.50 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.55 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.60 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.65 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.70 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.694 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.694 |

### nl-contextual

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.05 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.10 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.15 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.20 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.25 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.30 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.35 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.40 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.45 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.50 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.55 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.60 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.65 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.70 | 1.000 | 200.0 | 0.794 | 0.794 |
| 0.75 | 1.000 | 199.4 | 0.794 | 0.794 |
| 0.80 | 1.000 | 183.3 | 0.794 | 0.794 |
| 0.85 | 0.911 | 100.2 | 0.794 | 0.794 |
| 0.90 | 0.767 | 25.0 | 0.750 | 0.750 |

### nl-contextual-centered

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.850 | 0.828 |
| 0.05 | 0.989 | 75.5 | 0.850 | 0.828 |
| 0.10 | 0.961 | 57.7 | 0.850 | 0.828 |
| 0.15 | 0.933 | 43.9 | 0.850 | 0.828 |
| 0.20 | 0.861 | 33.5 | 0.850 | 0.850 |
| 0.25 | 0.806 | 27.3 | 0.794 | 0.794 |
| 0.30 | 0.794 | 23.2 | 0.783 | 0.783 |
| 0.35 | 0.783 | 20.6 | 0.783 | 0.783 |
| 0.40 | 0.728 | 19.3 | 0.728 | 0.728 |
| 0.45 | 0.717 | 18.7 | 0.717 | 0.717 |
| 0.50 | 0.706 | 18.4 | 0.706 | 0.706 |
| 0.55 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.60 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.65 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.70 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.706 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.706 |

Keyword > 0 alone: recall 0.706, mean kept 18.3.

## Thresholds: expanded queries (200, fts5-porter; keep if keyword > 0 or semantic ≥ T)

Vault: every kept result (recall, mean kept per query). Retrieval: top 30 of the kept results (recall@30).

### nl-sentence

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.878 | 0.833 |
| 0.05 | 1.000 | 198.5 | 0.878 | 0.833 |
| 0.10 | 1.000 | 195.4 | 0.878 | 0.833 |
| 0.15 | 1.000 | 188.3 | 0.878 | 0.833 |
| 0.20 | 1.000 | 174.8 | 0.878 | 0.833 |
| 0.25 | 1.000 | 155.0 | 0.878 | 0.833 |
| 0.30 | 1.000 | 132.3 | 0.878 | 0.833 |
| 0.35 | 0.983 | 106.1 | 0.878 | 0.833 |
| 0.40 | 0.939 | 82.3 | 0.878 | 0.833 |
| 0.45 | 0.917 | 64.2 | 0.878 | 0.833 |
| 0.50 | 0.906 | 50.5 | 0.878 | 0.844 |
| 0.55 | 0.894 | 42.5 | 0.867 | 0.833 |
| 0.60 | 0.883 | 38.1 | 0.872 | 0.872 |
| 0.65 | 0.883 | 36.8 | 0.872 | 0.872 |
| 0.70 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.75 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.80 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.85 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.90 | 0.883 | 36.4 | 0.872 | 0.872 |

### nl-sentence-centered

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.856 | 0.833 |
| 0.05 | 0.983 | 86.7 | 0.856 | 0.833 |
| 0.10 | 0.983 | 72.6 | 0.856 | 0.833 |
| 0.15 | 0.950 | 59.9 | 0.856 | 0.833 |
| 0.20 | 0.928 | 51.4 | 0.856 | 0.833 |
| 0.25 | 0.906 | 44.4 | 0.867 | 0.850 |
| 0.30 | 0.894 | 40.4 | 0.856 | 0.856 |
| 0.35 | 0.894 | 38.4 | 0.872 | 0.856 |
| 0.40 | 0.883 | 37.3 | 0.861 | 0.872 |
| 0.45 | 0.883 | 36.7 | 0.861 | 0.872 |
| 0.50 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.55 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.60 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.65 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.70 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.75 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.80 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.85 | 0.883 | 36.4 | 0.872 | 0.872 |
| 0.90 | 0.883 | 36.4 | 0.872 | 0.872 |

### nl-contextual

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.05 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.10 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.15 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.20 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.25 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.30 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.35 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.40 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.45 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.50 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.55 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.60 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.65 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.70 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.75 | 1.000 | 200.0 | 0.894 | 0.906 |
| 0.80 | 1.000 | 197.1 | 0.894 | 0.906 |
| 0.85 | 0.989 | 140.1 | 0.894 | 0.906 |
| 0.90 | 0.950 | 48.5 | 0.883 | 0.894 |

### nl-contextual-centered

| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |
|---|---|---|---|---|
| 0.00 | 1.000 | 200.0 | 0.933 | 0.933 |
| 0.05 | 1.000 | 83.3 | 0.933 | 0.933 |
| 0.10 | 1.000 | 68.4 | 0.933 | 0.933 |
| 0.15 | 0.972 | 57.9 | 0.933 | 0.933 |
| 0.20 | 0.972 | 50.0 | 0.933 | 0.933 |
| 0.25 | 0.972 | 44.6 | 0.933 | 0.933 |
| 0.30 | 0.956 | 41.0 | 0.917 | 0.917 |
| 0.35 | 0.906 | 38.7 | 0.883 | 0.883 |
| 0.40 | 0.883 | 37.4 | 0.861 | 0.861 |
| 0.45 | 0.883 | 36.7 | 0.861 | 0.861 |
| 0.50 | 0.883 | 36.5 | 0.861 | 0.861 |
| 0.55 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.60 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.65 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.70 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.75 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.80 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.85 | 0.883 | 36.4 | 0.861 | 0.861 |
| 0.90 | 0.883 | 36.4 | 0.861 | 0.861 |

Keyword > 0 alone: recall 0.883, mean kept 36.4.

## Query latency (ms; 30 queries × 5 runs after a warm-up; fts5-porter, weights 0.3/0.7, top 30)

Thresholds: 0.35 raw, 0.20 for -centered. Expansion time is not included here; see above.

| Corpus | Method | embed p50 | FTS5 p50 | dot p50 | rank p50 | total p50 | total p95 | total max |
|---|---|---|---|---|---|---|---|---|
| 200 | fts5-porter only | 0.00 | 0.20 | 0.00 | 0.01 | 0.20 | 0.31 | 0.44 |
| 200 | fts5-porter only (expanded text) | 0.00 | 0.50 | 0.00 | 0.03 | 0.53 | 0.82 | 0.93 |
| 200 | nl-sentence + fts5-porter | 8.47 | 0.53 | 0.03 | 0.06 | 9.22 | 13.22 | 15.37 |
| 200 | nl-sentence + fts5-porter (expanded text) | 21.52 | 1.19 | 0.03 | 0.22 | 23.06 | 32.40 | 40.32 |
| 200 | nl-sentence-centered + fts5-porter | 9.08 | 0.55 | 0.03 | 0.06 | 9.82 | 13.20 | 18.71 |
| 200 | nl-sentence-centered + fts5-porter (expanded text) | 17.62 | 1.00 | 0.03 | 0.10 | 18.67 | 26.45 | 31.90 |
| 200 | nl-contextual + fts5-porter | 16.49 | 0.45 | 0.03 | 0.27 | 17.16 | 29.80 | 118.65 |
| 200 | nl-contextual + fts5-porter (expanded text) | 17.87 | 0.73 | 0.03 | 0.23 | 18.80 | 23.09 | 25.19 |
| 200 | nl-contextual-centered + fts5-porter | 15.21 | 0.41 | 0.02 | 0.05 | 15.70 | 17.48 | 18.45 |
| 200 | nl-contextual-centered + fts5-porter (expanded text) | 18.14 | 0.75 | 0.02 | 0.08 | 18.96 | 23.28 | 25.25 |
| 10000 | fts5-porter only | 0.00 | 1.99 | 0.00 | 1.03 | 3.02 | 6.49 | 8.75 |
| 10000 | fts5-porter only (expanded text) | 0.00 | 4.28 | 0.00 | 2.25 | 6.47 | 11.84 | 12.53 |
| 10000 | nl-sentence + fts5-porter | 5.40 | 2.54 | 0.88 | 3.41 | 12.46 | 20.76 | 22.11 |
| 10000 | nl-sentence + fts5-porter (expanded text) | 12.28 | 6.07 | 0.91 | 8.96 | 29.23 | 37.25 | 40.92 |
| 10000 | nl-sentence-centered + fts5-porter | 5.98 | 2.88 | 0.72 | 2.97 | 12.66 | 18.27 | 22.73 |
| 10000 | nl-sentence-centered + fts5-porter (expanded text) | 14.13 | 6.84 | 0.75 | 5.42 | 27.25 | 35.55 | 41.82 |
| 10000 | nl-contextual + fts5-porter | 12.20 | 2.37 | 0.90 | 12.50 | 27.89 | 30.49 | 32.89 |
| 10000 | nl-contextual + fts5-porter (expanded text) | 15.20 | 5.28 | 0.91 | 12.25 | 33.94 | 37.90 | 39.65 |
| 10000 | nl-contextual-centered + fts5-porter | 13.50 | 2.60 | 0.91 | 3.15 | 20.21 | 24.90 | 27.86 |
| 10000 | nl-contextual-centered + fts5-porter (expanded text) | 16.00 | 5.40 | 0.90 | 4.55 | 27.61 | 32.64 | 38.39 |

Vector memory at 10000: nl-sentence 512 dims = 19.5 MB, nl-contextual 512 dims = 19.5 MB

## Expansions (Foundation Models, greedy)

- q01 Write a commit message for my latest change → commit message template, latest change documentation, code update notes, version control commit guidelines, change summary format, developer communication protocols, revision tracking phrases, code modification descriptions
- q02 Plan a week of dinners for me → weekly meal planning, dinner menu, weekly meal ideas, weekly dinner schedule, meal planning tips, weekly meal prep, dinner recipes, weekly food planning
- q03 Draft an email reminding the sailing club treasurer that last month's invoice is overdue → invoice, overdue, treasurer, sailing club, payment reminder, financial record, billing, outstanding payment
- q04 Book train tickets and somewhere to stay for a weekend in Porto → train tickets, weekend accommodation, Porto travel, train booking, hotel reservations, weekend getaway, transportation, accommodation options
- q05 What should I order at a café this afternoon? → coffee, tea, dessert, pastries, brunch, afternoon menu, cafe menu, food preferences, dietary restrictions, energy boost
- q06 Set up a new Python project that parses bank statement exports → Python project, bank statement parsing, data extraction, financial data processing, CSV parsing, financial reports, data analysis, data handling
- q07 Review this pull request for the Nordwind dispatch service → pull request, Nordwind dispatch service, code review, project updates, service improvements, delivery logistics, system changes, project management
- q08 Suggest a running plan for the next four weeks → running schedule, four week fitness plan, weekly running routine, distance goals running, running frequency, training program running, endurance training plan, running consistency
- q09 Find a time next week for an intro call with a prospective client → intro call, prospective client, week, calendar, scheduling, meeting time
- q10 The doctor wants to prescribe antibiotics. Is there anything they should know? → antibiotics, prescribe, prescriptions, medication, prescribing guidelines, prescription requirements, doctor consultation, medical history, infection severity, allergy history, antimicrobial resistance, dosage considerations, side effects, resistance risk, infection type, treatment duration
- q11 Help me get my paperwork together for this year's income tax filing → tax forms, income tax documents, annual income tax filing, tax records, financial paperwork, tax returns, deductions documentation, income statements
- q12 Help me write a blog post about building the Harbor app → Harbor app development, building mobile app, app development process, software engineering blog, app design principles, development timeline, user experience in apps, app launch strategy
- q13 A client sent a contract with a 12-month non-compete. Should I sign it? → contract, non-compete, 12-month clause, legal obligations, client agreement, employment restrictions, business agreements, risk assessment
- q14 Summarize the terms and conditions of this new service → terms and conditions, service agreement, service terms, legal terms, service policy, contract details, service guidelines, terms overview
- q15 Build a settings screen for my SwiftUI app → SwiftUI settings screen, UI customization settings, configuration options SwiftUI, app preferences interface, settings layout design, configuration panel SwiftUI, user settings interface, settings UI design
- q16 What should I get Jordan for their birthday? → birthday gifts, Jordan birthday, gift ideas, personal gifts, gift preferences, birthday presents, gift selection, gift trends
- q17 My head hurts after a long day at the computer. Any advice? → headache, eye strain, computer use, screen time, ergonomics, posture, visual fatigue, digital wellness, workplace health
- q18 How much should I put into savings and investments this month? → savings, investments, monthly budget, financial planning, monthly savings goal, investment allocation, expenses, income, personal finances, money management
- q19 Write the privacy policy for my iOS app → iOS app privacy policy, data protection policy, user data handling, data usage guidelines, data collection practices, data security measures, app data protection, data consent process
- q20 Help me write a message to my mum about my next visit → visit schedule, mother communication, next visit details, family updates, message template, contact preferences, mother relationship, travel planning
- q21 Set up automated builds and tests for my open-source library → CI/CD, build automation, continuous integration, continuous testing, open-source projects, GitHub Actions, Travis CI, Jenkins, Makefile, shell scripts, version control, release processes, deployment pipelines, code quality
- q22 Where should I deploy the server for the booking app? → server location, deployment strategy, scalability, performance optimization, latency management, data center selection, regional data center, cloud infrastructure, user experience, network reliability, backup solutions, security protocols, operational costs, availability, geo-targeting, app performance
- q23 Prepare a quote for a three-week freelance engagement → freelance engagement, three-week project, quote preparation, billing structure, client agreement, time tracking, project scope, hourly rate
- q24 The landlord asked whether we'll stay in the flat after the contract ends → rental contract, lease renewal, living situation, property rights, housing options, tenancy status, lease terms, residential agreements
- q25 Write up the notes from today's standup → today's standup, notes, meeting summary, work update, team discussion, project tracking, daily agenda, collaboration notes
- q26 Can I paste the client's database schema into ChatGPT to debug a query? → database schema, query debugging, client data structure, SQL query, schema analysis, query optimization, data architecture, query troubleshooting
- q27 Make slides for my Porto conference talk → conference slides, Porto conference presentation, visual presentation design, presentation templates, slide structure, audience engagement, design principles, public speaking materials
- q28 Find a recipe I can cook tonight in half an hour → quick dinner recipe, fast cooking recipe, one-hour meal prep, easy recipe for tonight, speedy recipe ideas, short cooking time meals, fast food recipes, quick meal options
- q29 What should I pack for a day out on the water? → day trip packing, water activities essentials, outdoor adventure gear, sun protection equipment, hydration supplies, safety equipment, weather-appropriate clothing, navigation tools
- q30 How much can we spend on remodelling the kitchen, and how will we pay for it? → remodeling budget, kitchen renovation costs, home improvement expenses, financial planning for renovations, cost estimation for kitchen updates, payment options for home projects, home renovation funding, budget constraints for home upgrades

## Foundation Models re-rank of the top 30 (200)

| Pool | R@30 of pool | R@5 after re-rank | MRR after re-rank | re-rank ms p50 | p95 | guided / permissive retry / refused |
|---|---|---|---|---|---|---|
| nl-contextual-centered + fts5-porter 0.30/0.70, original | 0.828 | 0.611 | 0.865 | 8410 | 17983 | 29 / 1 / 0 |
| nl-contextual-centered + fts5-porter 0.30/0.70, expanded | 0.933 | 0.700 | 0.936 | 9149 | 15199 | 30 / 0 / 0 |

## Dump (original): nl-contextual + fts5-porter 0.45/0.55

q01 Write a commit message for my latest change
   relevant: sd_commits@1 cs_no_emoji@2
   top5: sd_commits cs_no_emoji cs_spanish_family sd_ai_code cs_questions
q02 Plan a week of dinners for me
   relevant: pp_vegetarian@33 h_peanut@71 pp_cooking@12
   top5: pp_japan f_retirement pp_bouldering pp_running pp_birthdays
q03 Draft an email reminding the sailing club treasurer that last month's invoice is overdue
   relevant: f_late@13 pc_harbor_client@1 cs_email_tone@16
   top5: pc_harbor_client f_invoicing cs_club_language pp_sailing f_accountant
q04 Book train tickets and somewhere to stay for a weekend in Porto
   relevant: pp_travel_style@5 f_cards@15
   top5: pv_ai_training pp_sailing pc_talk pc_marathon pp_travel_style
q05 What should I order at a café this afternoon?
   relevant: h_caffeine@4 pp_coffee@2 h_lactose@41
   top5: pp_cafe pp_coffee pp_parents h_caffeine pv_location
q06 Set up a new Python project that parses bank statement exports
   relevant: sd_python@3 pc_ledgerly@1
   top5: pc_ledgerly sd_platforms sd_python pc_gpx f_bank
q07 Review this pull request for the Nordwind dispatch service
   relevant: sd_review@8 pc_atlas@1 pc_atlas_nda@7
   top5: pc_atlas sd_perf sd_ci sd_branching pc_atlas_people
q08 Suggest a running plan for the next four weeks
   relevant: h_knee@9 pc_marathon@32 h_heart_rate@23
   top5: pp_running pp_japan f_savings f_retirement h_dentist
q09 Find a time next week for an intro call with a prospective client
   relevant: pp_morning@182 cs_calls@1
   top5: cs_calls pp_parents cs_email_tone pp_running pv_recordings
q10 The doctor wants to prescribe antibiotics. Is there anything they should know?
   relevant: h_penicillin@78
   top5: sd_languages f_crypto h_gp h_blood_test pc_ledgerly_users
q11 Help me get my paperwork together for this year's income tax filing
   relevant: f_irs@1 f_accountant@10 f_expenses@49
   top5: f_irs f_income h_stress f_donations sd_learning
q12 Help me write a blog post about building the Harbor app
   relevant: cs_writing_voice@3 pc_blog@2 pc_harbor@1
   top5: pc_harbor pc_blog cs_writing_voice pc_q4 pv_screenshots
q13 A client sent a contract with a 12-month non-compete. Should I sign it?
   relevant: l_noncompete@1 l_lawyer@2 l_contracts@3
   top5: l_noncompete l_lawyer l_contracts cs_email_tone l_nda
q14 Summarize the terms and conditions of this new service
   relevant: l_tos@1
   top5: l_tos cs_reading_lists pc_capacity l_dco pv_aliases
q15 Build a settings screen for my SwiftUI app
   relevant: sd_swiftui@3 sd_accessibility@19 sd_swift_style@24
   top5: pc_harbor pc_harbor_stack sd_swiftui l_privacy_labels pv_ai_training
q16 What should I get Jordan for their birthday?
   relevant: pp_gifts@2 pp_birthdays@1
   top5: pp_birthdays pp_gifts pv_partner pp_partner h_stress
q17 My head hurts after a long day at the computer. Any advice?
   relevant: h_migraine@24 h_eyes@1 h_stress@20
   top5: h_eyes cs_headings pc_rate h_water cs_slack
q18 How much should I put into savings and investments this month?
   relevant: f_savings@3 f_invest@1 f_budget@15
   top5: f_invest f_kitchen_funding f_savings f_income pv_address
q19 Write the privacy policy for my iOS app
   relevant: l_privacy_labels@1 pv_analytics@2
   top5: l_privacy_labels pv_analytics pc_harbor pv_partner sd_platforms
q20 Help me write a message to my mum about my next visit
   relevant: cs_spanish_family@1 pp_parents@22
   top5: cs_spanish_family cs_no_emoji pv_location h_hayfever sd_commits
q21 Set up automated builds and tests for my open-source library
   relevant: sd_ci@4 pc_gpx@1
   top5: pc_gpx sd_license pc_ledgerly sd_ci sd_swift_testing
q22 Where should I deploy the server for the booking app?
   relevant: sd_infra@90 pc_harbor_stack@13
   top5: sd_sql pc_harbor sd_logging h_gp l_privacy_labels
q23 Prepare a quote for a three-week freelance engagement
   relevant: pc_rate@1 pc_capacity@84 cs_proposals@37
   top5: pc_rate pp_running f_currency f_social_security pp_bouldering
q24 The landlord asked whether we'll stay in the flat after the contract ends
   relevant: l_lease@22 f_rent@2
   top5: f_flat f_rent l_contracts pv_client_data l_lawyer
q25 Write up the notes from today's standup
   relevant: cs_meeting_notes@3 pc_atlas_people@1
   top5: pc_atlas_people cs_presentations cs_meeting_notes sd_ai_code cs_spanish_family
q26 Can I paste the client's database schema into ChatGPT to debug a query?
   relevant: pc_atlas_nda@1 pv_ai_training@54
   top5: pc_atlas_nda sd_sql pv_passwords sd_learning pv_client_data
q27 Make slides for my Porto conference talk
   relevant: cs_presentations@2 pc_talk@1
   top5: pc_talk cs_presentations cs_apologies pp_coffee_home f_expenses
q28 Find a recipe I can cook tonight in half an hour
   relevant: pp_cooking@1 pp_vegetarian@43 cs_units@3
   top5: pp_cooking pc_ideas cs_units pc_mentoring h_sleep
q29 What should I pack for a day out on the water?
   relevant: h_sun@84 pp_sailing@50
   top5: h_water pc_rate pp_plants pc_ideas f_late
q30 How much can we spend on remodelling the kitchen, and how will we pay for it?
   relevant: pc_kitchen@3 f_kitchen_funding@1
   top5: f_kitchen_funding f_tracking pc_kitchen f_currency f_parents

## Dump (expanded): nl-contextual + fts5-porter 0.45/0.55

q01 Write a commit message for my latest change
   relevant: sd_commits@1 cs_no_emoji@2
   top5: sd_commits cs_no_emoji cs_meeting_notes cs_headings sd_formatting
q02 Plan a week of dinners for me
   relevant: pp_vegetarian@26 h_peanut@110 pp_cooking@15
   top5: pp_japan f_retirement pc_ideas h_insurance pc_kitchen
q03 Draft an email reminding the sailing club treasurer that last month's invoice is overdue
   relevant: f_late@3 pc_harbor_client@1 cs_email_tone@23
   top5: pc_harbor_client f_invoicing f_late cs_club_language pc_ideas
q04 Book train tickets and somewhere to stay for a weekend in Porto
   relevant: pp_travel_style@1 f_cards@2
   top5: pp_travel_style f_cards pc_harbor pc_travel_work pp_alcohol
q05 What should I order at a café this afternoon?
   relevant: h_caffeine@4 pp_coffee@2 h_lactose@29
   top5: pp_cafe pp_coffee pp_cuisine h_caffeine pv_location
q06 Set up a new Python project that parses bank statement exports
   relevant: sd_python@11 pc_ledgerly@1
   top5: pc_ledgerly sd_data pc_ledgerly_next pc_gpx l_gdpr_harbor
q07 Review this pull request for the Nordwind dispatch service
   relevant: sd_review@3 pc_atlas@1 pc_atlas_nda@4
   top5: pc_atlas sd_branching sd_review pc_atlas_nda sd_perf
q08 Suggest a running plan for the next four weeks
   relevant: h_knee@13 pc_marathon@3 h_heart_rate@23
   top5: pp_running pp_japan pc_marathon pp_bouldering h_physio
q09 Find a time next week for an intro call with a prospective client
   relevant: pp_morning@1 cs_calls@3
   top5: pp_morning pc_harbor_design cs_calls pp_parents cs_email_tone
q10 The doctor wants to prescribe antibiotics. Is there anything they should know?
   relevant: h_penicillin@8
   top5: h_vitamin_d cs_explain_level h_peanut h_hayfever sd_infra
q11 Help me get my paperwork together for this year's income tax filing
   relevant: f_irs@1 f_accountant@16 f_expenses@34
   top5: f_irs f_retirement pv_finance f_income sd_docs
q12 Help me write a blog post about building the Harbor app
   relevant: cs_writing_voice@3 pc_blog@1 pc_harbor@2
   top5: pc_blog pc_harbor cs_writing_voice pc_q4 pc_harbor_stack
q13 A client sent a contract with a 12-month non-compete. Should I sign it?
   relevant: l_noncompete@1 l_lawyer@2 l_contracts@3
   top5: l_noncompete l_lawyer l_contracts l_gdpr_harbor f_vat
q14 Summarize the terms and conditions of this new service
   relevant: l_tos@1
   top5: l_tos l_contracts cs_explain_level pc_atlas l_privacy_labels
q15 Build a settings screen for my SwiftUI app
   relevant: sd_swiftui@3 sd_accessibility@7 sd_swift_style@27
   top5: pc_harbor pc_harbor_stack sd_swiftui pv_ai_training pp_alcohol
q16 What should I get Jordan for their birthday?
   relevant: pp_gifts@1 pp_birthdays@2
   top5: pp_gifts pp_birthdays pv_partner cs_writing_voice pc_ideas
q17 My head hurts after a long day at the computer. Any advice?
   relevant: h_migraine@55 h_eyes@1 h_stress@3
   top5: h_eyes cs_time_format h_stress cs_headings cs_slack
q18 How much should I put into savings and investments this month?
   relevant: f_savings@5 f_invest@1 f_budget@2
   top5: f_invest f_budget pv_finance f_income f_savings
q19 Write the privacy policy for my iOS app
   relevant: l_privacy_labels@1 pv_analytics@3
   top5: l_privacy_labels sd_errors pv_analytics l_gdpr_harbor pc_harbor
q20 Help me write a message to my mum about my next visit
   relevant: cs_spanish_family@1 pp_parents@53
   top5: cs_spanish_family cs_calls pv_health_work pp_japan cs_presentations
q21 Set up automated builds and tests for my open-source library
   relevant: sd_ci@1 pc_gpx@3
   top5: sd_ci sd_license pc_gpx sd_swift_testing sd_secrets
q22 Where should I deploy the server for the booking app?
   relevant: sd_infra@74 pc_harbor_stack@30
   top5: sd_perf sd_logging sd_platforms pc_book sd_sql
q23 Prepare a quote for a three-week freelance engagement
   relevant: pc_rate@1 pc_capacity@42 cs_proposals@6
   top5: pc_rate f_currency pc_tracking l_contracts pp_running
q24 The landlord asked whether we'll stay in the flat after the contract ends
   relevant: l_lease@1 f_rent@8
   top5: l_lease l_tos l_residency l_contracts f_insurance
q25 Write up the notes from today's standup
   relevant: cs_meeting_notes@1 pc_atlas_people@10
   top5: cs_meeting_notes pc_tracking sd_backups cs_slack f_tracking
q26 Can I paste the client's database schema into ChatGPT to debug a query?
   relevant: pc_atlas_nda@1 pv_ai_training@16
   top5: pc_atlas_nda sd_data sd_sql pv_client_data sd_perf
q27 Make slides for my Porto conference talk
   relevant: cs_presentations@2 pc_talk@1
   top5: pc_talk cs_presentations pp_languages pc_rate pc_harbor_design
q28 Find a recipe I can cook tonight in half an hour
   relevant: pp_cooking@1 pp_vegetarian@65 cs_units@5
   top5: pp_cooking pc_ideas h_migraine cs_writing_voice cs_units
q29 What should I pack for a day out on the water?
   relevant: h_sun@1 pp_sailing@32
   top5: h_sun pc_ideas h_water pp_gifts f_japan_budget
q30 How much can we spend on remodelling the kitchen, and how will we pay for it?
   relevant: pc_kitchen@1 f_kitchen_funding@2
   top5: pc_kitchen f_kitchen_funding f_invest f_flat f_savings
DUMP=1 .build/release/search-spike  10000  695.97s user 117.49s system 67% cpu 20:08.59 total
