# Phase 6c.1: provider embeddings as a second index

Date: 2026-10-24 13:15. Fixtures: memories-200 (EN) and memories-200-es (ES translation), queries-30 (raw EN), queries-30-expanded (EN task + keywords), queries-30-es (raw ES), queries-30-es-expanded (ES task + ES keywords). Cloud limit `internal`: 141 of 200 memories get a provider vector; 59 keep only bge, holding 26 of 71 relevant labels.

Methods: **hybrid** = the model's vectors on every memory (as for a local model, or a cloud limit of Secret); **dual@limit** = ADR-0023: provider score where the memory has a provider vector (within the limit), bge-small's otherwise, each min-max normalized over its own pool (bge over the whole vault); **dual-b@limit** = the same with bge normalized over the bge-only memories; **ens** = mean of the two normalized scores where both exist. **dualz** / **dualq** = the same with each index z-scored / percentile-ranked over its own pool. "R@5 bge-only" = micro recall@5 of the relevant labels on memories above the limit.

| Model | Model id | Dims | Threshold (raw cosine) | Query ms p50 | Runtime |
|---|---|---|---|---|---|
| bge-small | BAAI/bge-small-en-v1.5 | 384 | 0.55 | 16.4 | sentence-transformers, PyTorch 2.14.1 mps fp32 |
| nomic-v1.5 | nomic-ai/nomic-embed-text-v1.5 | 768 | 0.55 | 30.4 | sentence-transformers, PyTorch 2.14.1 mps fp32 |
| nomic-v1.5-noprefix | nomic-ai/nomic-embed-text-v1.5 | 768 | 0.48 | 27.7 | sentence-transformers, PyTorch 2.14.1 mps fp32 |
| me5-small | intfloat/multilingual-e5-small | 384 | 0.80 | 14.6 | sentence-transformers, PyTorch 2.14.1 mps fp32 |
| qwen3-0.6b | Qwen/Qwen3-Embedding-0.6B | 1024 | 0.28 | 95.2 | sentence-transformers, PyTorch 2.14.1 mps fp16 |
| oai-3-small | text-embedding-3-small | 1536 | 0.25 | 208.7 | https://api.openai.com/v1 (openai) |
| oai-3-large | text-embedding-3-large | 3072 | 0.22 | 236.6 | https://api.openai.com/v1 (openai) |

## EN vault, raw EN tasks

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.567 | 0.706 | 0.714 | 0.462 |
| bge-small hybrid (today) | 0.689 | 0.894 | 0.825 | 0.731 |
| nomic-v1.5 alone | 0.722 | 0.939 | 0.897 | 0.731 |
| nomic-v1.5 hybrid | 0.700 | 0.911 | 0.832 | 0.731 |
| nomic-v1.5 dual@limit | 0.672 | 0.911 | 0.815 | 0.692 |
| nomic-v1.5 dual-b@limit | 0.656 | 0.911 | 0.813 | 0.692 |
| nomic-v1.5 dualz@limit | 0.717 | 0.911 | 0.825 | 0.731 |
| nomic-v1.5 dualq@limit | 0.611 | 0.911 | 0.789 | 0.538 |
| nomic-v1.5 ens@all | 0.717 | 0.939 | 0.823 | 0.769 |
| nomic-v1.5 ens@limit | 0.700 | 0.928 | 0.819 | 0.769 |
| nomic-v1.5-noprefix alone | 0.750 | 0.967 | 0.921 | 0.808 |
| nomic-v1.5-noprefix hybrid | 0.761 | 0.922 | 0.829 | 0.769 |
| nomic-v1.5-noprefix dual@limit | 0.728 | 0.911 | 0.815 | 0.731 |
| nomic-v1.5-noprefix dual-b@limit | 0.694 | 0.911 | 0.810 | 0.731 |
| nomic-v1.5-noprefix dualz@limit | 0.756 | 0.928 | 0.823 | 0.731 |
| nomic-v1.5-noprefix dualq@limit | 0.583 | 0.928 | 0.785 | 0.462 |
| nomic-v1.5-noprefix ens@all | 0.744 | 0.939 | 0.841 | 0.808 |
| nomic-v1.5-noprefix ens@limit | 0.700 | 0.928 | 0.835 | 0.769 |
| me5-small alone | 0.561 | 0.883 | 0.733 | 0.538 |
| me5-small hybrid | 0.617 | 0.883 | 0.798 | 0.538 |
| me5-small dual@limit | 0.639 | 0.872 | 0.798 | 0.615 |
| me5-small dual-b@limit | 0.667 | 0.883 | 0.800 | 0.692 |
| me5-small dualz@limit | 0.711 | 0.894 | 0.811 | 0.769 |
| me5-small dualq@limit | 0.622 | 0.894 | 0.769 | 0.500 |
| me5-small ens@all | 0.650 | 0.928 | 0.815 | 0.654 |
| me5-small ens@limit | 0.672 | 0.928 | 0.811 | 0.692 |
| qwen3-0.6b alone | 0.722 | 0.956 | 0.837 | 0.692 |
| qwen3-0.6b hybrid | 0.728 | 0.961 | 0.842 | 0.731 |
| qwen3-0.6b dual@limit | 0.694 | 0.939 | 0.855 | 0.692 |
| qwen3-0.6b dual-b@limit | 0.678 | 0.939 | 0.854 | 0.731 |
| qwen3-0.6b dualz@limit | 0.756 | 0.956 | 0.825 | 0.731 |
| qwen3-0.6b dualq@limit | 0.594 | 0.944 | 0.786 | 0.538 |
| qwen3-0.6b ens@all | 0.722 | 0.961 | 0.842 | 0.731 |
| qwen3-0.6b ens@limit | 0.678 | 0.939 | 0.858 | 0.692 |
| oai-3-small alone | 0.850 | 0.933 | 0.936 | 0.846 |
| oai-3-small hybrid | 0.767 | 0.939 | 0.872 | 0.769 |
| oai-3-small dual@limit | 0.772 | 0.928 | 0.836 | 0.769 |
| oai-3-small dual-b@limit | 0.733 | 0.928 | 0.832 | 0.769 |
| oai-3-small dualz@limit | 0.778 | 0.928 | 0.830 | 0.731 |
| oai-3-small dualq@limit | 0.628 | 0.928 | 0.788 | 0.500 |
| oai-3-small ens@all | 0.750 | 0.939 | 0.850 | 0.769 |
| oai-3-small ens@limit | 0.711 | 0.928 | 0.840 | 0.731 |
| oai-3-large alone | 0.861 | 0.972 | 0.942 | 0.846 |
| oai-3-large hybrid | 0.822 | 0.939 | 0.911 | 0.808 |
| oai-3-large dual@limit | 0.772 | 0.928 | 0.859 | 0.769 |
| oai-3-large dual-b@limit | 0.728 | 0.928 | 0.855 | 0.769 |
| oai-3-large dualz@limit | 0.772 | 0.928 | 0.854 | 0.692 |
| oai-3-large dualq@limit | 0.611 | 0.928 | 0.770 | 0.500 |
| oai-3-large ens@all | 0.750 | 0.939 | 0.853 | 0.808 |
| oai-3-large ens@limit | 0.733 | 0.928 | 0.843 | 0.731 |

## EN vault, EN task + keywords

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.828 | 0.978 | 0.896 | 0.885 |
| bge-small hybrid (today) | 0.939 | 0.989 | 0.967 | 0.962 |
| nomic-v1.5 alone | 0.883 | 0.989 | 0.983 | 0.923 |
| nomic-v1.5 hybrid | 0.944 | 0.989 | 0.967 | 0.962 |
| nomic-v1.5 dual@limit | 0.911 | 0.989 | 0.961 | 0.885 |
| nomic-v1.5 dual-b@limit | 0.894 | 0.989 | 0.961 | 0.885 |
| nomic-v1.5 dualz@limit | 0.928 | 0.989 | 0.967 | 0.923 |
| nomic-v1.5 dualq@limit | 0.889 | 0.978 | 0.917 | 0.885 |
| nomic-v1.5 ens@all | 0.928 | 0.989 | 0.967 | 0.962 |
| nomic-v1.5 ens@limit | 0.928 | 0.989 | 0.967 | 0.962 |
| nomic-v1.5-noprefix alone | 0.878 | 1.000 | 0.950 | 0.923 |
| nomic-v1.5-noprefix hybrid | 0.944 | 0.989 | 0.967 | 0.962 |
| nomic-v1.5-noprefix dual@limit | 0.900 | 1.000 | 0.961 | 0.885 |
| nomic-v1.5-noprefix dual-b@limit | 0.872 | 1.000 | 0.961 | 0.846 |
| nomic-v1.5-noprefix dualz@limit | 0.944 | 1.000 | 0.967 | 0.962 |
| nomic-v1.5-noprefix dualq@limit | 0.872 | 0.989 | 0.911 | 0.885 |
| nomic-v1.5-noprefix ens@all | 0.928 | 1.000 | 0.967 | 0.962 |
| nomic-v1.5-noprefix ens@limit | 0.928 | 1.000 | 0.967 | 0.962 |
| me5-small alone | 0.856 | 0.961 | 0.983 | 0.885 |
| me5-small hybrid | 0.939 | 0.978 | 0.983 | 0.962 |
| me5-small dual@limit | 0.911 | 0.989 | 0.978 | 0.846 |
| me5-small dual-b@limit | 0.894 | 0.989 | 0.978 | 0.846 |
| me5-small dualz@limit | 0.950 | 0.989 | 0.983 | 0.962 |
| me5-small dualq@limit | 0.872 | 0.978 | 0.917 | 0.885 |
| me5-small ens@all | 0.911 | 1.000 | 0.967 | 0.962 |
| me5-small ens@limit | 0.922 | 1.000 | 0.967 | 0.962 |
| qwen3-0.6b alone | 0.911 | 1.000 | 0.978 | 0.962 |
| qwen3-0.6b hybrid | 0.933 | 1.000 | 0.983 | 0.962 |
| qwen3-0.6b dual@limit | 0.933 | 1.000 | 0.961 | 0.885 |
| qwen3-0.6b dual-b@limit | 0.894 | 1.000 | 0.961 | 0.885 |
| qwen3-0.6b dualz@limit | 0.944 | 1.000 | 0.967 | 0.962 |
| qwen3-0.6b dualq@limit | 0.872 | 1.000 | 0.916 | 0.885 |
| qwen3-0.6b ens@all | 0.944 | 1.000 | 0.967 | 0.962 |
| qwen3-0.6b ens@limit | 0.967 | 1.000 | 0.967 | 0.962 |
| oai-3-small alone | 0.922 | 1.000 | 1.000 | 0.962 |
| oai-3-small hybrid | 0.928 | 1.000 | 0.983 | 0.962 |
| oai-3-small dual@limit | 0.928 | 1.000 | 0.978 | 0.923 |
| oai-3-small dual-b@limit | 0.900 | 1.000 | 0.978 | 0.923 |
| oai-3-small dualz@limit | 0.928 | 1.000 | 0.983 | 0.923 |
| oai-3-small dualq@limit | 0.889 | 0.989 | 0.905 | 0.885 |
| oai-3-small ens@all | 0.967 | 1.000 | 0.967 | 0.962 |
| oai-3-small ens@limit | 0.967 | 1.000 | 0.967 | 0.962 |
| oai-3-large alone | 0.933 | 1.000 | 0.983 | 0.923 |
| oai-3-large hybrid | 0.950 | 1.000 | 0.983 | 0.962 |
| oai-3-large dual@limit | 0.944 | 1.000 | 0.978 | 0.923 |
| oai-3-large dual-b@limit | 0.906 | 1.000 | 0.978 | 0.923 |
| oai-3-large dualz@limit | 0.956 | 1.000 | 0.983 | 0.923 |
| oai-3-large dualq@limit | 0.883 | 0.989 | 0.905 | 0.885 |
| oai-3-large ens@all | 0.956 | 1.000 | 0.967 | 0.962 |
| oai-3-large ens@limit | 0.956 | 1.000 | 0.967 | 0.962 |

## EN vault, raw ES tasks (cross-lingual)

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.189 | 0.250 | 0.194 | 0.077 |
| bge-small hybrid (today) | 0.306 | 0.417 | 0.265 | 0.115 |
| nomic-v1.5 alone | 0.339 | 0.633 | 0.440 | 0.346 |
| nomic-v1.5 hybrid | 0.272 | 0.306 | 0.272 | 0.115 |
| nomic-v1.5 dual@limit | 0.272 | 0.306 | 0.262 | 0.115 |
| nomic-v1.5 dual-b@limit | 0.272 | 0.306 | 0.259 | 0.115 |
| nomic-v1.5 dualz@limit | 0.272 | 0.306 | 0.261 | 0.115 |
| nomic-v1.5 dualq@limit | 0.261 | 0.306 | 0.241 | 0.115 |
| nomic-v1.5 ens@all | 0.317 | 0.417 | 0.307 | 0.115 |
| nomic-v1.5 ens@limit | 0.317 | 0.417 | 0.303 | 0.115 |
| nomic-v1.5-noprefix alone | 0.406 | 0.656 | 0.485 | 0.346 |
| nomic-v1.5-noprefix hybrid | 0.400 | 0.444 | 0.390 | 0.231 |
| nomic-v1.5-noprefix dual@limit | 0.339 | 0.361 | 0.329 | 0.115 |
| nomic-v1.5-noprefix dual-b@limit | 0.339 | 0.361 | 0.327 | 0.115 |
| nomic-v1.5-noprefix dualz@limit | 0.339 | 0.361 | 0.331 | 0.115 |
| nomic-v1.5-noprefix dualq@limit | 0.317 | 0.361 | 0.309 | 0.115 |
| nomic-v1.5-noprefix ens@all | 0.361 | 0.511 | 0.333 | 0.154 |
| nomic-v1.5-noprefix ens@limit | 0.328 | 0.428 | 0.307 | 0.115 |
| me5-small alone | 0.539 | 0.794 | 0.757 | 0.462 |
| me5-small hybrid | 0.467 | 0.539 | 0.636 | 0.385 |
| me5-small dual@limit | 0.389 | 0.461 | 0.511 | 0.115 |
| me5-small dual-b@limit | 0.389 | 0.461 | 0.509 | 0.115 |
| me5-small dualz@limit | 0.389 | 0.461 | 0.514 | 0.115 |
| me5-small dualq@limit | 0.378 | 0.461 | 0.433 | 0.115 |
| me5-small ens@all | 0.411 | 0.550 | 0.452 | 0.192 |
| me5-small ens@limit | 0.389 | 0.472 | 0.436 | 0.115 |
| qwen3-0.6b alone | 0.644 | 0.906 | 0.777 | 0.577 |
| qwen3-0.6b hybrid | 0.622 | 0.889 | 0.750 | 0.538 |
| qwen3-0.6b dual@limit | 0.472 | 0.661 | 0.597 | 0.115 |
| qwen3-0.6b dual-b@limit | 0.472 | 0.661 | 0.594 | 0.115 |
| qwen3-0.6b dualz@limit | 0.472 | 0.661 | 0.597 | 0.115 |
| qwen3-0.6b dualq@limit | 0.472 | 0.661 | 0.532 | 0.115 |
| qwen3-0.6b ens@all | 0.583 | 0.844 | 0.622 | 0.423 |
| qwen3-0.6b ens@limit | 0.478 | 0.633 | 0.529 | 0.115 |
| oai-3-small alone | 0.778 | 0.900 | 0.954 | 0.808 |
| oai-3-small hybrid | 0.667 | 0.800 | 0.839 | 0.654 |
| oai-3-small dual@limit | 0.478 | 0.594 | 0.634 | 0.115 |
| oai-3-small dual-b@limit | 0.478 | 0.594 | 0.633 | 0.115 |
| oai-3-small dualz@limit | 0.467 | 0.594 | 0.633 | 0.077 |
| oai-3-small dualq@limit | 0.467 | 0.594 | 0.563 | 0.115 |
| oai-3-small ens@all | 0.594 | 0.800 | 0.690 | 0.462 |
| oai-3-small ens@limit | 0.461 | 0.594 | 0.570 | 0.115 |
| oai-3-large alone | 0.739 | 0.950 | 0.931 | 0.731 |
| oai-3-large hybrid | 0.717 | 0.861 | 0.845 | 0.654 |
| oai-3-large dual@limit | 0.517 | 0.639 | 0.649 | 0.115 |
| oai-3-large dual-b@limit | 0.500 | 0.639 | 0.638 | 0.115 |
| oai-3-large dualz@limit | 0.506 | 0.639 | 0.642 | 0.077 |
| oai-3-large dualq@limit | 0.478 | 0.639 | 0.564 | 0.115 |
| oai-3-large ens@all | 0.644 | 0.833 | 0.692 | 0.500 |
| oai-3-large ens@limit | 0.494 | 0.639 | 0.578 | 0.115 |

## ES vault, raw ES tasks

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.556 | 0.706 | 0.738 | 0.423 |
| bge-small hybrid (today) | 0.578 | 0.783 | 0.748 | 0.462 |
| nomic-v1.5 alone | 0.517 | 0.789 | 0.645 | 0.423 |
| nomic-v1.5 hybrid | 0.556 | 0.817 | 0.679 | 0.462 |
| nomic-v1.5 dual@limit | 0.561 | 0.794 | 0.684 | 0.462 |
| nomic-v1.5 dual-b@limit | 0.544 | 0.761 | 0.681 | 0.500 |
| nomic-v1.5 dualz@limit | 0.561 | 0.789 | 0.687 | 0.462 |
| nomic-v1.5 dualq@limit | 0.539 | 0.789 | 0.725 | 0.423 |
| nomic-v1.5 ens@all | 0.583 | 0.822 | 0.702 | 0.462 |
| nomic-v1.5 ens@limit | 0.561 | 0.822 | 0.722 | 0.462 |
| nomic-v1.5-noprefix alone | 0.550 | 0.794 | 0.612 | 0.462 |
| nomic-v1.5-noprefix hybrid | 0.594 | 0.789 | 0.692 | 0.500 |
| nomic-v1.5-noprefix dual@limit | 0.533 | 0.778 | 0.687 | 0.423 |
| nomic-v1.5-noprefix dual-b@limit | 0.528 | 0.772 | 0.685 | 0.462 |
| nomic-v1.5-noprefix dualz@limit | 0.544 | 0.789 | 0.688 | 0.423 |
| nomic-v1.5-noprefix dualq@limit | 0.522 | 0.789 | 0.758 | 0.423 |
| nomic-v1.5-noprefix ens@all | 0.600 | 0.789 | 0.704 | 0.500 |
| nomic-v1.5-noprefix ens@limit | 0.561 | 0.800 | 0.704 | 0.462 |
| me5-small alone | 0.511 | 0.750 | 0.625 | 0.462 |
| me5-small hybrid | 0.583 | 0.817 | 0.758 | 0.500 |
| me5-small dual@limit | 0.550 | 0.761 | 0.726 | 0.462 |
| me5-small dual-b@limit | 0.539 | 0.761 | 0.744 | 0.462 |
| me5-small dualz@limit | 0.567 | 0.794 | 0.762 | 0.462 |
| me5-small dualq@limit | 0.528 | 0.794 | 0.739 | 0.423 |
| me5-small ens@all | 0.578 | 0.828 | 0.748 | 0.462 |
| me5-small ens@limit | 0.578 | 0.794 | 0.731 | 0.462 |
| qwen3-0.6b alone | 0.722 | 0.939 | 0.775 | 0.731 |
| qwen3-0.6b hybrid | 0.672 | 0.939 | 0.787 | 0.692 |
| qwen3-0.6b dual@limit | 0.567 | 0.861 | 0.765 | 0.462 |
| qwen3-0.6b dual-b@limit | 0.583 | 0.844 | 0.781 | 0.500 |
| qwen3-0.6b dualz@limit | 0.606 | 0.861 | 0.791 | 0.462 |
| qwen3-0.6b dualq@limit | 0.556 | 0.861 | 0.801 | 0.423 |
| qwen3-0.6b ens@all | 0.611 | 0.900 | 0.785 | 0.615 |
| qwen3-0.6b ens@limit | 0.567 | 0.844 | 0.795 | 0.462 |
| oai-3-small alone | 0.756 | 0.928 | 0.879 | 0.769 |
| oai-3-small hybrid | 0.711 | 0.944 | 0.849 | 0.769 |
| oai-3-small dual@limit | 0.600 | 0.861 | 0.784 | 0.500 |
| oai-3-small dual-b@limit | 0.583 | 0.861 | 0.786 | 0.500 |
| oai-3-small dualz@limit | 0.600 | 0.889 | 0.804 | 0.462 |
| oai-3-small dualq@limit | 0.544 | 0.878 | 0.799 | 0.385 |
| oai-3-small ens@all | 0.656 | 0.917 | 0.819 | 0.615 |
| oai-3-small ens@limit | 0.578 | 0.861 | 0.795 | 0.462 |
| oai-3-large alone | 0.761 | 0.933 | 0.921 | 0.769 |
| oai-3-large hybrid | 0.772 | 0.956 | 0.885 | 0.769 |
| oai-3-large dual@limit | 0.611 | 0.861 | 0.806 | 0.423 |
| oai-3-large dual-b@limit | 0.539 | 0.872 | 0.823 | 0.500 |
| oai-3-large dualz@limit | 0.650 | 0.872 | 0.792 | 0.462 |
| oai-3-large dualq@limit | 0.572 | 0.856 | 0.780 | 0.423 |
| oai-3-large ens@all | 0.700 | 0.917 | 0.825 | 0.654 |
| oai-3-large ens@limit | 0.600 | 0.861 | 0.797 | 0.462 |

## ES vault, ES task + keywords

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.772 | 0.933 | 0.884 | 0.731 |
| bge-small hybrid (today) | 0.833 | 0.933 | 0.881 | 0.808 |
| nomic-v1.5 alone | 0.744 | 0.928 | 0.933 | 0.692 |
| nomic-v1.5 hybrid | 0.822 | 0.956 | 0.911 | 0.731 |
| nomic-v1.5 dual@limit | 0.811 | 0.933 | 0.890 | 0.692 |
| nomic-v1.5 dual-b@limit | 0.767 | 0.917 | 0.907 | 0.692 |
| nomic-v1.5 dualz@limit | 0.844 | 0.933 | 0.892 | 0.808 |
| nomic-v1.5 dualq@limit | 0.811 | 0.922 | 0.899 | 0.769 |
| nomic-v1.5 ens@all | 0.844 | 0.956 | 0.906 | 0.808 |
| nomic-v1.5 ens@limit | 0.822 | 0.933 | 0.886 | 0.731 |
| nomic-v1.5-noprefix alone | 0.744 | 0.894 | 0.928 | 0.577 |
| nomic-v1.5-noprefix hybrid | 0.828 | 0.956 | 0.933 | 0.846 |
| nomic-v1.5-noprefix dual@limit | 0.811 | 0.944 | 0.907 | 0.692 |
| nomic-v1.5-noprefix dual-b@limit | 0.756 | 0.911 | 0.923 | 0.692 |
| nomic-v1.5-noprefix dualz@limit | 0.844 | 0.933 | 0.923 | 0.769 |
| nomic-v1.5-noprefix dualq@limit | 0.783 | 0.922 | 0.899 | 0.769 |
| nomic-v1.5-noprefix ens@all | 0.856 | 0.961 | 0.906 | 0.846 |
| nomic-v1.5-noprefix ens@limit | 0.833 | 0.917 | 0.892 | 0.808 |
| me5-small alone | 0.694 | 0.911 | 0.748 | 0.654 |
| me5-small hybrid | 0.844 | 0.939 | 0.890 | 0.846 |
| me5-small dual@limit | 0.811 | 0.928 | 0.876 | 0.731 |
| me5-small dual-b@limit | 0.778 | 0.917 | 0.892 | 0.692 |
| me5-small dualz@limit | 0.822 | 0.928 | 0.894 | 0.769 |
| me5-small dualq@limit | 0.811 | 0.928 | 0.896 | 0.769 |
| me5-small ens@all | 0.861 | 0.950 | 0.900 | 0.808 |
| me5-small ens@limit | 0.861 | 0.939 | 0.886 | 0.808 |
| qwen3-0.6b alone | 0.872 | 0.972 | 0.983 | 0.923 |
| qwen3-0.6b hybrid | 0.883 | 0.983 | 0.967 | 0.962 |
| qwen3-0.6b dual@limit | 0.817 | 0.972 | 0.922 | 0.731 |
| qwen3-0.6b dual-b@limit | 0.761 | 0.956 | 0.939 | 0.731 |
| qwen3-0.6b dualz@limit | 0.850 | 0.961 | 0.942 | 0.731 |
| qwen3-0.6b dualq@limit | 0.800 | 0.950 | 0.893 | 0.769 |
| qwen3-0.6b ens@all | 0.883 | 0.983 | 0.928 | 0.846 |
| qwen3-0.6b ens@limit | 0.850 | 0.983 | 0.908 | 0.808 |
| oai-3-small alone | 0.900 | 1.000 | 0.983 | 0.923 |
| oai-3-small hybrid | 0.906 | 1.000 | 0.967 | 0.923 |
| oai-3-small dual@limit | 0.850 | 0.989 | 0.923 | 0.731 |
| oai-3-small dual-b@limit | 0.806 | 0.972 | 0.940 | 0.731 |
| oai-3-small dualz@limit | 0.861 | 0.967 | 0.942 | 0.731 |
| oai-3-small dualq@limit | 0.839 | 0.967 | 0.907 | 0.769 |
| oai-3-small ens@all | 0.911 | 1.000 | 0.944 | 0.885 |
| oai-3-small ens@limit | 0.889 | 0.989 | 0.908 | 0.808 |
| oai-3-large alone | 0.883 | 1.000 | 0.983 | 0.923 |
| oai-3-large hybrid | 0.950 | 1.000 | 0.967 | 0.962 |
| oai-3-large dual@limit | 0.894 | 0.961 | 0.923 | 0.769 |
| oai-3-large dual-b@limit | 0.789 | 0.961 | 0.940 | 0.769 |
| oai-3-large dualz@limit | 0.883 | 0.967 | 0.942 | 0.731 |
| oai-3-large dualq@limit | 0.839 | 0.967 | 0.899 | 0.769 |
| oai-3-large ens@all | 0.928 | 0.983 | 0.950 | 0.885 |
| oai-3-large ens@limit | 0.906 | 0.983 | 0.908 | 0.808 |

## mixed vault (half ES), raw ES tasks

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.306 | 0.467 | 0.429 | 0.308 |
| bge-small hybrid (today) | 0.361 | 0.489 | 0.501 | 0.385 |
| nomic-v1.5 alone | 0.361 | 0.439 | 0.451 | 0.346 |
| nomic-v1.5 hybrid | 0.328 | 0.467 | 0.480 | 0.346 |
| nomic-v1.5 dual@limit | 0.339 | 0.478 | 0.446 | 0.385 |
| nomic-v1.5 dual-b@limit | 0.311 | 0.450 | 0.446 | 0.385 |
| nomic-v1.5 dualz@limit | 0.339 | 0.506 | 0.467 | 0.385 |
| nomic-v1.5 dualq@limit | 0.339 | 0.472 | 0.480 | 0.385 |
| nomic-v1.5 ens@all | 0.328 | 0.483 | 0.510 | 0.385 |
| nomic-v1.5 ens@limit | 0.328 | 0.483 | 0.492 | 0.385 |
| nomic-v1.5-noprefix alone | 0.306 | 0.472 | 0.478 | 0.346 |
| nomic-v1.5-noprefix hybrid | 0.328 | 0.522 | 0.499 | 0.385 |
| nomic-v1.5-noprefix dual@limit | 0.328 | 0.517 | 0.464 | 0.385 |
| nomic-v1.5-noprefix dual-b@limit | 0.300 | 0.494 | 0.463 | 0.385 |
| nomic-v1.5-noprefix dualz@limit | 0.328 | 0.533 | 0.466 | 0.385 |
| nomic-v1.5-noprefix dualq@limit | 0.317 | 0.483 | 0.485 | 0.385 |
| nomic-v1.5-noprefix ens@all | 0.328 | 0.511 | 0.513 | 0.385 |
| nomic-v1.5-noprefix ens@limit | 0.328 | 0.511 | 0.478 | 0.385 |
| me5-small alone | 0.361 | 0.656 | 0.555 | 0.462 |
| me5-small hybrid | 0.383 | 0.567 | 0.549 | 0.385 |
| me5-small dual@limit | 0.383 | 0.522 | 0.520 | 0.385 |
| me5-small dual-b@limit | 0.367 | 0.506 | 0.512 | 0.385 |
| me5-small dualz@limit | 0.383 | 0.544 | 0.523 | 0.385 |
| me5-small dualq@limit | 0.367 | 0.533 | 0.501 | 0.385 |
| me5-small ens@all | 0.378 | 0.561 | 0.526 | 0.385 |
| me5-small ens@limit | 0.378 | 0.517 | 0.522 | 0.385 |
| qwen3-0.6b alone | 0.672 | 0.922 | 0.738 | 0.654 |
| qwen3-0.6b hybrid | 0.661 | 0.889 | 0.641 | 0.692 |
| qwen3-0.6b dual@limit | 0.389 | 0.756 | 0.571 | 0.385 |
| qwen3-0.6b dual-b@limit | 0.361 | 0.706 | 0.566 | 0.385 |
| qwen3-0.6b dualz@limit | 0.478 | 0.783 | 0.611 | 0.385 |
| qwen3-0.6b dualq@limit | 0.378 | 0.783 | 0.514 | 0.385 |
| qwen3-0.6b ens@all | 0.383 | 0.694 | 0.551 | 0.385 |
| qwen3-0.6b ens@limit | 0.350 | 0.617 | 0.532 | 0.385 |
| oai-3-small alone | 0.678 | 0.833 | 0.797 | 0.654 |
| oai-3-small hybrid | 0.539 | 0.800 | 0.606 | 0.654 |
| oai-3-small dual@limit | 0.361 | 0.683 | 0.547 | 0.346 |
| oai-3-small dual-b@limit | 0.361 | 0.667 | 0.545 | 0.385 |
| oai-3-small dualz@limit | 0.467 | 0.700 | 0.580 | 0.385 |
| oai-3-small dualq@limit | 0.394 | 0.717 | 0.530 | 0.346 |
| oai-3-small ens@all | 0.417 | 0.622 | 0.545 | 0.462 |
| oai-3-small ens@limit | 0.394 | 0.589 | 0.527 | 0.385 |
| oai-3-large alone | 0.650 | 0.867 | 0.835 | 0.615 |
| oai-3-large hybrid | 0.556 | 0.772 | 0.621 | 0.615 |
| oai-3-large dual@limit | 0.400 | 0.639 | 0.534 | 0.385 |
| oai-3-large dual-b@limit | 0.350 | 0.622 | 0.523 | 0.385 |
| oai-3-large dualz@limit | 0.450 | 0.683 | 0.573 | 0.385 |
| oai-3-large dualq@limit | 0.389 | 0.689 | 0.502 | 0.385 |
| oai-3-large ens@all | 0.417 | 0.639 | 0.549 | 0.462 |
| oai-3-large ens@limit | 0.394 | 0.589 | 0.529 | 0.385 |

## mixed vault, raw EN tasks

| Method | R@5 | R@30 | MRR | R@5 bge-only labels |
|---|---|---|---|---|
| fts5-porter | 0.378 | 0.539 | 0.577 | 0.154 |
| bge-small hybrid (today) | 0.522 | 0.639 | 0.722 | 0.423 |
| nomic-v1.5 alone | 0.539 | 0.833 | 0.748 | 0.462 |
| nomic-v1.5 hybrid | 0.578 | 0.739 | 0.703 | 0.462 |
| nomic-v1.5 dual@limit | 0.544 | 0.694 | 0.697 | 0.462 |
| nomic-v1.5 dual-b@limit | 0.528 | 0.694 | 0.679 | 0.462 |
| nomic-v1.5 dualz@limit | 0.544 | 0.706 | 0.703 | 0.423 |
| nomic-v1.5 dualq@limit | 0.533 | 0.706 | 0.639 | 0.385 |
| nomic-v1.5 ens@all | 0.606 | 0.750 | 0.706 | 0.500 |
| nomic-v1.5 ens@limit | 0.572 | 0.706 | 0.708 | 0.462 |
| nomic-v1.5-noprefix alone | 0.550 | 0.828 | 0.809 | 0.423 |
| nomic-v1.5-noprefix hybrid | 0.561 | 0.783 | 0.761 | 0.462 |
| nomic-v1.5-noprefix dual@limit | 0.544 | 0.728 | 0.734 | 0.462 |
| nomic-v1.5-noprefix dual-b@limit | 0.528 | 0.728 | 0.713 | 0.462 |
| nomic-v1.5-noprefix dualz@limit | 0.544 | 0.728 | 0.721 | 0.423 |
| nomic-v1.5-noprefix dualq@limit | 0.517 | 0.728 | 0.619 | 0.385 |
| nomic-v1.5-noprefix ens@all | 0.594 | 0.767 | 0.734 | 0.462 |
| nomic-v1.5-noprefix ens@limit | 0.572 | 0.711 | 0.732 | 0.462 |
| me5-small alone | 0.494 | 0.761 | 0.640 | 0.423 |
| me5-small hybrid | 0.517 | 0.744 | 0.652 | 0.385 |
| me5-small dual@limit | 0.556 | 0.672 | 0.673 | 0.423 |
| me5-small dual-b@limit | 0.550 | 0.672 | 0.671 | 0.462 |
| me5-small dualz@limit | 0.550 | 0.672 | 0.679 | 0.462 |
| me5-small dualq@limit | 0.517 | 0.672 | 0.649 | 0.385 |
| me5-small ens@all | 0.594 | 0.800 | 0.682 | 0.462 |
| me5-small ens@limit | 0.572 | 0.706 | 0.718 | 0.462 |
| qwen3-0.6b alone | 0.722 | 0.956 | 0.795 | 0.692 |
| qwen3-0.6b hybrid | 0.711 | 0.900 | 0.778 | 0.692 |
| qwen3-0.6b dual@limit | 0.622 | 0.756 | 0.750 | 0.462 |
| qwen3-0.6b dual-b@limit | 0.622 | 0.756 | 0.733 | 0.462 |
| qwen3-0.6b dualz@limit | 0.606 | 0.756 | 0.722 | 0.462 |
| qwen3-0.6b dualq@limit | 0.550 | 0.783 | 0.648 | 0.385 |
| qwen3-0.6b ens@all | 0.650 | 0.900 | 0.754 | 0.577 |
| qwen3-0.6b ens@limit | 0.594 | 0.756 | 0.744 | 0.462 |
| oai-3-small alone | 0.756 | 0.911 | 0.867 | 0.731 |
| oai-3-small hybrid | 0.689 | 0.917 | 0.848 | 0.654 |
| oai-3-small dual@limit | 0.611 | 0.783 | 0.758 | 0.462 |
| oai-3-small dual-b@limit | 0.572 | 0.783 | 0.744 | 0.462 |
| oai-3-small dualz@limit | 0.600 | 0.783 | 0.744 | 0.423 |
| oai-3-small dualq@limit | 0.511 | 0.783 | 0.608 | 0.385 |
| oai-3-small ens@all | 0.661 | 0.906 | 0.761 | 0.577 |
| oai-3-small ens@limit | 0.589 | 0.772 | 0.731 | 0.462 |
| oai-3-large alone | 0.817 | 0.961 | 0.932 | 0.808 |
| oai-3-large hybrid | 0.800 | 0.928 | 0.839 | 0.769 |
| oai-3-large dual@limit | 0.639 | 0.783 | 0.775 | 0.462 |
| oai-3-large dual-b@limit | 0.606 | 0.783 | 0.753 | 0.462 |
| oai-3-large dualz@limit | 0.617 | 0.783 | 0.746 | 0.423 |
| oai-3-large dualq@limit | 0.567 | 0.783 | 0.625 | 0.385 |
| oai-3-large ens@all | 0.689 | 0.917 | 0.759 | 0.615 |
| oai-3-large ens@limit | 0.589 | 0.783 | 0.758 | 0.462 |

## Summary: R@5 (R@5 on bge-only labels)

| Method | EN vault, raw EN tasks | EN vault, EN task + keywords | EN vault, raw ES tasks (cross-lingual) | ES vault, raw ES tasks | ES vault, ES task + keywords | mixed vault (half ES), raw ES tasks | mixed vault, raw EN tasks |
|---|---|---|---|---|---|---|---|
| fts5-porter | 0.57 (0.46) | 0.83 (0.88) | 0.19 (0.08) | 0.56 (0.42) | 0.77 (0.73) | 0.31 (0.31) | 0.38 (0.15) |
| bge-small hybrid (today) | 0.69 (0.73) | 0.94 (0.96) | 0.31 (0.12) | 0.58 (0.46) | 0.83 (0.81) | 0.36 (0.38) | 0.52 (0.42) |
| nomic-v1.5 hybrid | 0.70 (0.73) | 0.94 (0.96) | 0.27 (0.12) | 0.56 (0.46) | 0.82 (0.73) | 0.33 (0.35) | 0.58 (0.46) |
| nomic-v1.5 dual@limit | 0.67 (0.69) | 0.91 (0.88) | 0.27 (0.12) | 0.56 (0.46) | 0.81 (0.69) | 0.34 (0.38) | 0.54 (0.46) |
| nomic-v1.5 dualz@limit | 0.72 (0.73) | 0.93 (0.92) | 0.27 (0.12) | 0.56 (0.46) | 0.84 (0.81) | 0.34 (0.38) | 0.54 (0.42) |
| nomic-v1.5 dualq@limit | 0.61 (0.54) | 0.89 (0.88) | 0.26 (0.12) | 0.54 (0.42) | 0.81 (0.77) | 0.34 (0.38) | 0.53 (0.38) |
| nomic-v1.5 ens@all | 0.72 (0.77) | 0.93 (0.96) | 0.32 (0.12) | 0.58 (0.46) | 0.84 (0.81) | 0.33 (0.38) | 0.61 (0.50) |
| nomic-v1.5 ens@limit | 0.70 (0.77) | 0.93 (0.96) | 0.32 (0.12) | 0.56 (0.46) | 0.82 (0.73) | 0.33 (0.38) | 0.57 (0.46) |
| nomic-v1.5-noprefix hybrid | 0.76 (0.77) | 0.94 (0.96) | 0.40 (0.23) | 0.59 (0.50) | 0.83 (0.85) | 0.33 (0.38) | 0.56 (0.46) |
| nomic-v1.5-noprefix dual@limit | 0.73 (0.73) | 0.90 (0.88) | 0.34 (0.12) | 0.53 (0.42) | 0.81 (0.69) | 0.33 (0.38) | 0.54 (0.46) |
| nomic-v1.5-noprefix dualz@limit | 0.76 (0.73) | 0.94 (0.96) | 0.34 (0.12) | 0.54 (0.42) | 0.84 (0.77) | 0.33 (0.38) | 0.54 (0.42) |
| nomic-v1.5-noprefix dualq@limit | 0.58 (0.46) | 0.87 (0.88) | 0.32 (0.12) | 0.52 (0.42) | 0.78 (0.77) | 0.32 (0.38) | 0.52 (0.38) |
| nomic-v1.5-noprefix ens@all | 0.74 (0.81) | 0.93 (0.96) | 0.36 (0.15) | 0.60 (0.50) | 0.86 (0.85) | 0.33 (0.38) | 0.59 (0.46) |
| nomic-v1.5-noprefix ens@limit | 0.70 (0.77) | 0.93 (0.96) | 0.33 (0.12) | 0.56 (0.46) | 0.83 (0.81) | 0.33 (0.38) | 0.57 (0.46) |
| me5-small hybrid | 0.62 (0.54) | 0.94 (0.96) | 0.47 (0.38) | 0.58 (0.50) | 0.84 (0.85) | 0.38 (0.38) | 0.52 (0.38) |
| me5-small dual@limit | 0.64 (0.62) | 0.91 (0.85) | 0.39 (0.12) | 0.55 (0.46) | 0.81 (0.73) | 0.38 (0.38) | 0.56 (0.42) |
| me5-small dualz@limit | 0.71 (0.77) | 0.95 (0.96) | 0.39 (0.12) | 0.57 (0.46) | 0.82 (0.77) | 0.38 (0.38) | 0.55 (0.46) |
| me5-small dualq@limit | 0.62 (0.50) | 0.87 (0.88) | 0.38 (0.12) | 0.53 (0.42) | 0.81 (0.77) | 0.37 (0.38) | 0.52 (0.38) |
| me5-small ens@all | 0.65 (0.65) | 0.91 (0.96) | 0.41 (0.19) | 0.58 (0.46) | 0.86 (0.81) | 0.38 (0.38) | 0.59 (0.46) |
| me5-small ens@limit | 0.67 (0.69) | 0.92 (0.96) | 0.39 (0.12) | 0.58 (0.46) | 0.86 (0.81) | 0.38 (0.38) | 0.57 (0.46) |
| qwen3-0.6b hybrid | 0.73 (0.73) | 0.93 (0.96) | 0.62 (0.54) | 0.67 (0.69) | 0.88 (0.96) | 0.66 (0.69) | 0.71 (0.69) |
| qwen3-0.6b dual@limit | 0.69 (0.69) | 0.93 (0.88) | 0.47 (0.12) | 0.57 (0.46) | 0.82 (0.73) | 0.39 (0.38) | 0.62 (0.46) |
| qwen3-0.6b dualz@limit | 0.76 (0.73) | 0.94 (0.96) | 0.47 (0.12) | 0.61 (0.46) | 0.85 (0.73) | 0.48 (0.38) | 0.61 (0.46) |
| qwen3-0.6b dualq@limit | 0.59 (0.54) | 0.87 (0.88) | 0.47 (0.12) | 0.56 (0.42) | 0.80 (0.77) | 0.38 (0.38) | 0.55 (0.38) |
| qwen3-0.6b ens@all | 0.72 (0.73) | 0.94 (0.96) | 0.58 (0.42) | 0.61 (0.62) | 0.88 (0.85) | 0.38 (0.38) | 0.65 (0.58) |
| qwen3-0.6b ens@limit | 0.68 (0.69) | 0.97 (0.96) | 0.48 (0.12) | 0.57 (0.46) | 0.85 (0.81) | 0.35 (0.38) | 0.59 (0.46) |
| oai-3-small hybrid | 0.77 (0.77) | 0.93 (0.96) | 0.67 (0.65) | 0.71 (0.77) | 0.91 (0.92) | 0.54 (0.65) | 0.69 (0.65) |
| oai-3-small dual@limit | 0.77 (0.77) | 0.93 (0.92) | 0.48 (0.12) | 0.60 (0.50) | 0.85 (0.73) | 0.36 (0.35) | 0.61 (0.46) |
| oai-3-small dualz@limit | 0.78 (0.73) | 0.93 (0.92) | 0.47 (0.08) | 0.60 (0.46) | 0.86 (0.73) | 0.47 (0.38) | 0.60 (0.42) |
| oai-3-small dualq@limit | 0.63 (0.50) | 0.89 (0.88) | 0.47 (0.12) | 0.54 (0.38) | 0.84 (0.77) | 0.39 (0.35) | 0.51 (0.38) |
| oai-3-small ens@all | 0.75 (0.77) | 0.97 (0.96) | 0.59 (0.46) | 0.66 (0.62) | 0.91 (0.88) | 0.42 (0.46) | 0.66 (0.58) |
| oai-3-small ens@limit | 0.71 (0.73) | 0.97 (0.96) | 0.46 (0.12) | 0.58 (0.46) | 0.89 (0.81) | 0.39 (0.38) | 0.59 (0.46) |
| oai-3-large hybrid | 0.82 (0.81) | 0.95 (0.96) | 0.72 (0.65) | 0.77 (0.77) | 0.95 (0.96) | 0.56 (0.62) | 0.80 (0.77) |
| oai-3-large dual@limit | 0.77 (0.77) | 0.94 (0.92) | 0.52 (0.12) | 0.61 (0.42) | 0.89 (0.77) | 0.40 (0.38) | 0.64 (0.46) |
| oai-3-large dualz@limit | 0.77 (0.69) | 0.96 (0.92) | 0.51 (0.08) | 0.65 (0.46) | 0.88 (0.73) | 0.45 (0.38) | 0.62 (0.42) |
| oai-3-large dualq@limit | 0.61 (0.50) | 0.88 (0.88) | 0.48 (0.12) | 0.57 (0.42) | 0.84 (0.77) | 0.39 (0.38) | 0.57 (0.38) |
| oai-3-large ens@all | 0.75 (0.81) | 0.96 (0.96) | 0.64 (0.50) | 0.70 (0.65) | 0.93 (0.88) | 0.42 (0.46) | 0.69 (0.62) |
| oai-3-large ens@limit | 0.73 (0.73) | 0.96 (0.96) | 0.49 (0.12) | 0.60 (0.46) | 0.91 (0.81) | 0.39 (0.38) | 0.59 (0.46) |
