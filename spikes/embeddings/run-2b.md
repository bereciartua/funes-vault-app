# Spike 2b: open embedding models

Date: 2026-10-17T01:20:35Z
Host: Version 27.0.1 (Build 26A434), 8 cores, 8 GB
Corpus: 200 fixture memories; big corpus 10000. Query sets: original, agent (task + keywords), agent+categories (same text, pool narrowed to the agent's categories), spanish.

## Models

| Model | HF id | Dims | Licence | Size on disk | Runtime | Embed ms/memory | Embed ms/query p50 / p95 |
|---|---|---|---|---|---|---|---|
| bge-small | BAAI/bge-small-en-v1.5 | 384 | mit | 127 MB | PyTorch 2.14.1 mps float32 | 2.39 | 16.5 / 22.3 |
| bge-small-coreml-cpu | BAAI/bge-small-en-v1.5 | 384 | mit | 63 MB | Core ML from Swift, fp16, computeUnits=cpu, incl. tokenization | 4.70 | 3.6 / 6.0 |
| bge-small-noinst | BAAI/bge-small-en-v1.5 | 384 | mit | 127 MB | PyTorch 2.14.1 mps float32 | 2.31 | 15.6 / 17.2 |
| e5-small | intfloat/e5-small-v2 | 384 | mit | 127 MB | PyTorch 2.14.1 mps float32 | 2.17 | 15.7 / 17.5 |
| me5-small | intfloat/multilingual-e5-small | 384 | mit | 449 MB | PyTorch 2.14.1 mps float32 | 2.52 | 15.9 / 17.3 |
| nomic-v1.5 | nomic-ai/nomic-embed-text-v1.5 | 768 | apache-2.0 | 522 MB | PyTorch 2.14.1 mps float32 | 11.20 | 24.4 / 29.7 |
| qwen3-0.6b | Qwen/Qwen3-Embedding-0.6B | 1024 | apache-2.0 | 1136 MB | PyTorch 2.14.1 mps float16 | 54.95 | 86.0 / 96.3 |

## Quality: original queries

| Method | R@5 | R@10 | MRR | R@5 (10000) | MRR (10000) |
|---|---|---|---|---|---|
| fts5-porter | 0.567 | 0.606 | 0.714 | 0.561 | 0.717 |
| apple-contextual-centered alone | 0.389 | 0.483 | 0.459 | 0.328 | 0.497 |
| + fts5-porter 0.45/0.55 | 0.567 | 0.656 | 0.789 | 0.539 | 0.729 |
| + fts5-porter 0.30/0.70 | 0.533 | 0.683 | 0.774 | 0.533 | 0.740 |
| + fts5-porter best 0.50/0.50 | 0.583 | 0.656 | 0.789 | 0.539 | 0.729 |
| + fts5-porter min-max 0.45/0.55 | 0.567 | 0.644 | 0.775 | 0.556 | 0.725 |
| + fts5-porter min-max 0.30/0.70 | 0.533 | 0.667 | 0.774 | 0.533 | 0.740 |
| + fts5-porter RRF | 0.511 | 0.650 | 0.705 | 0.544 | 0.708 |
| bge-small alone | 0.767 | 0.839 | 0.810 | 0.689 | 0.816 |
| + fts5-porter 0.45/0.55 | 0.594 | 0.700 | 0.755 | 0.594 | 0.704 |
| + fts5-porter 0.30/0.70 | 0.617 | 0.728 | 0.818 | 0.594 | 0.716 |
| + fts5-porter best 0.00/1.00 | 0.767 | 0.839 | 0.810 | 0.689 | 0.816 |
| + fts5-porter min-max 0.45/0.55 | 0.639 | 0.739 | 0.807 | 0.672 | 0.725 |
| + fts5-porter min-max 0.30/0.70 | 0.689 | 0.844 | 0.830 | 0.639 | 0.763 |
| + fts5-porter RRF | 0.622 | 0.717 | 0.734 | 0.683 | 0.793 |
| bge-small-coreml-cpu alone | 0.767 | 0.839 | 0.827 | 0.689 | 0.816 |
| + fts5-porter 0.45/0.55 | 0.594 | 0.700 | 0.755 | 0.594 | 0.704 |
| + fts5-porter 0.30/0.70 | 0.617 | 0.728 | 0.818 | 0.606 | 0.717 |
| + fts5-porter best 0.00/1.00 | 0.767 | 0.839 | 0.827 | 0.689 | 0.816 |
| + fts5-porter min-max 0.45/0.55 | 0.639 | 0.739 | 0.807 | 0.672 | 0.725 |
| + fts5-porter min-max 0.30/0.70 | 0.689 | 0.844 | 0.831 | 0.639 | 0.763 |
| + fts5-porter RRF | 0.622 | 0.717 | 0.732 | 0.672 | 0.793 |
| bge-small-noinst alone | 0.761 | 0.811 | 0.774 | 0.656 | 0.816 |
| + fts5-porter 0.45/0.55 | 0.594 | 0.700 | 0.755 | 0.594 | 0.704 |
| + fts5-porter 0.30/0.70 | 0.617 | 0.739 | 0.796 | 0.594 | 0.720 |
| + fts5-porter best 0.05/0.95 | 0.767 | 0.856 | 0.787 | 0.650 | 0.791 |
| + fts5-porter min-max 0.45/0.55 | 0.639 | 0.756 | 0.804 | 0.611 | 0.735 |
| + fts5-porter min-max 0.30/0.70 | 0.706 | 0.828 | 0.829 | 0.628 | 0.755 |
| + fts5-porter RRF | 0.606 | 0.717 | 0.713 | 0.656 | 0.782 |
| e5-small alone | 0.717 | 0.817 | 0.821 | 0.700 | 0.877 |
| + fts5-porter 0.45/0.55 | 0.583 | 0.661 | 0.732 | 0.572 | 0.721 |
| + fts5-porter 0.30/0.70 | 0.583 | 0.683 | 0.733 | 0.583 | 0.726 |
| + fts5-porter best 0.00/1.00 | 0.717 | 0.817 | 0.821 | 0.700 | 0.877 |
| + fts5-porter min-max 0.45/0.55 | 0.617 | 0.728 | 0.786 | 0.683 | 0.771 |
| + fts5-porter min-max 0.30/0.70 | 0.628 | 0.756 | 0.811 | 0.644 | 0.796 |
| + fts5-porter RRF | 0.589 | 0.700 | 0.772 | 0.678 | 0.828 |
| me5-small alone | 0.561 | 0.717 | 0.733 | 0.722 | 0.825 |
| + fts5-porter 0.45/0.55 | 0.567 | 0.628 | 0.730 | 0.572 | 0.719 |
| + fts5-porter 0.30/0.70 | 0.583 | 0.639 | 0.750 | 0.583 | 0.719 |
| + fts5-porter best 0.05/0.95 | 0.617 | 0.739 | 0.796 | 0.606 | 0.846 |
| + fts5-porter min-max 0.45/0.55 | 0.594 | 0.689 | 0.804 | 0.639 | 0.762 |
| + fts5-porter min-max 0.30/0.70 | 0.617 | 0.739 | 0.798 | 0.628 | 0.844 |
| + fts5-porter RRF | 0.561 | 0.683 | 0.748 | 0.689 | 0.876 |
| nomic-v1.5 alone | 0.722 | 0.783 | 0.897 | 0.700 | 0.881 |
| + fts5-porter 0.45/0.55 | 0.594 | 0.683 | 0.765 | 0.617 | 0.736 |
| + fts5-porter 0.30/0.70 | 0.606 | 0.694 | 0.780 | 0.606 | 0.750 |
| + fts5-porter best 0.05/0.95 | 0.778 | 0.839 | 0.859 | 0.661 | 0.838 |
| + fts5-porter min-max 0.45/0.55 | 0.678 | 0.756 | 0.814 | 0.650 | 0.771 |
| + fts5-porter min-max 0.30/0.70 | 0.700 | 0.828 | 0.832 | 0.694 | 0.845 |
| + fts5-porter RRF | 0.617 | 0.706 | 0.766 | 0.717 | 0.836 |
| qwen3-0.6b alone | 0.722 | 0.833 | 0.837 | 0.767 | 0.872 |
| + fts5-porter 0.45/0.55 | 0.594 | 0.700 | 0.795 | 0.606 | 0.748 |
| + fts5-porter 0.30/0.70 | 0.617 | 0.739 | 0.806 | 0.650 | 0.776 |
| + fts5-porter best 0.10/0.90 | 0.739 | 0.856 | 0.834 | 0.700 | 0.844 |
| + fts5-porter min-max 0.45/0.55 | 0.644 | 0.772 | 0.834 | 0.650 | 0.776 |
| + fts5-porter min-max 0.30/0.70 | 0.728 | 0.828 | 0.842 | 0.667 | 0.819 |
| + fts5-porter RRF | 0.622 | 0.706 | 0.788 | 0.672 | 0.831 |

## Quality: agent queries

| Method | R@5 | R@10 | MRR | R@5 (10000) | MRR (10000) |
|---|---|---|---|---|---|
| fts5-porter | 0.828 | 0.906 | 0.896 | 0.789 | 0.938 |
| apple-contextual-centered alone | 0.689 | 0.789 | 0.730 | 0.644 | 0.708 |
| + fts5-porter 0.45/0.55 | 0.867 | 0.967 | 0.936 | 0.783 | 0.952 |
| + fts5-porter 0.30/0.70 | 0.889 | 0.911 | 0.928 | 0.822 | 0.936 |
| + fts5-porter best 0.55/0.45 | 0.894 | 0.967 | 0.934 | 0.806 | 0.940 |
| + fts5-porter min-max 0.45/0.55 | 0.867 | 0.978 | 0.936 | 0.783 | 0.946 |
| + fts5-porter min-max 0.30/0.70 | 0.872 | 0.911 | 0.928 | 0.839 | 0.936 |
| + fts5-porter RRF | 0.850 | 0.900 | 0.906 | 0.789 | 0.919 |
| bge-small alone | 0.894 | 0.933 | 0.983 | 0.822 | 0.958 |
| + fts5-porter 0.45/0.55 | 0.878 | 0.967 | 0.936 | 0.817 | 0.968 |
| + fts5-porter 0.30/0.70 | 0.900 | 0.967 | 0.939 | 0.800 | 0.969 |
| + fts5-porter best 0.15/0.85 | 0.939 | 0.967 | 0.967 | 0.783 | 0.955 |
| + fts5-porter min-max 0.45/0.55 | 0.911 | 0.967 | 0.950 | 0.800 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.967 | 0.967 | 0.789 | 0.955 |
| + fts5-porter RRF | 0.900 | 0.967 | 0.958 | 0.811 | 0.978 |
| bge-small-coreml-cpu alone | 0.894 | 0.933 | 0.983 | 0.839 | 0.958 |
| + fts5-porter 0.45/0.55 | 0.878 | 0.967 | 0.936 | 0.817 | 0.968 |
| + fts5-porter 0.30/0.70 | 0.900 | 0.967 | 0.939 | 0.800 | 0.969 |
| + fts5-porter best 0.15/0.85 | 0.939 | 0.967 | 0.967 | 0.800 | 0.955 |
| + fts5-porter min-max 0.45/0.55 | 0.911 | 0.967 | 0.950 | 0.800 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.967 | 0.967 | 0.800 | 0.955 |
| + fts5-porter RRF | 0.883 | 0.967 | 0.958 | 0.811 | 0.978 |
| bge-small-noinst alone | 0.850 | 0.933 | 0.950 | 0.817 | 0.944 |
| + fts5-porter 0.45/0.55 | 0.889 | 0.967 | 0.936 | 0.800 | 0.951 |
| + fts5-porter 0.30/0.70 | 0.900 | 0.967 | 0.944 | 0.844 | 0.969 |
| + fts5-porter best 0.15/0.85 | 0.956 | 0.967 | 0.967 | 0.806 | 0.955 |
| + fts5-porter min-max 0.45/0.55 | 0.911 | 0.967 | 0.967 | 0.817 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.967 | 0.967 | 0.794 | 0.955 |
| + fts5-porter RRF | 0.867 | 0.967 | 0.961 | 0.833 | 0.983 |
| e5-small alone | 0.872 | 0.933 | 0.950 | 0.817 | 0.954 |
| + fts5-porter 0.45/0.55 | 0.844 | 0.939 | 0.908 | 0.806 | 0.922 |
| + fts5-porter 0.30/0.70 | 0.878 | 0.939 | 0.911 | 0.822 | 0.929 |
| + fts5-porter best 0.05/0.95 | 0.922 | 0.950 | 0.967 | 0.828 | 0.973 |
| + fts5-porter min-max 0.45/0.55 | 0.900 | 0.956 | 0.939 | 0.789 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.922 | 0.950 | 0.950 | 0.772 | 0.971 |
| + fts5-porter RRF | 0.911 | 0.939 | 0.922 | 0.822 | 0.975 |
| me5-small alone | 0.856 | 0.933 | 0.983 | 0.839 | 0.983 |
| + fts5-porter 0.45/0.55 | 0.828 | 0.939 | 0.906 | 0.817 | 0.942 |
| + fts5-porter 0.30/0.70 | 0.894 | 0.950 | 0.915 | 0.844 | 0.945 |
| + fts5-porter best 0.10/0.90 | 0.944 | 0.967 | 0.942 | 0.850 | 0.968 |
| + fts5-porter min-max 0.45/0.55 | 0.944 | 0.967 | 0.944 | 0.867 | 0.968 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.950 | 0.983 | 0.839 | 0.969 |
| + fts5-porter RRF | 0.911 | 0.950 | 0.961 | 0.856 | 0.969 |
| nomic-v1.5 alone | 0.883 | 0.939 | 0.983 | 0.867 | 0.936 |
| + fts5-porter 0.45/0.55 | 0.900 | 0.950 | 0.919 | 0.822 | 0.935 |
| + fts5-porter 0.30/0.70 | 0.928 | 0.967 | 0.961 | 0.839 | 0.969 |
| + fts5-porter best 0.20/0.80 | 0.956 | 0.967 | 0.967 | 0.861 | 0.970 |
| + fts5-porter min-max 0.45/0.55 | 0.956 | 0.967 | 0.967 | 0.833 | 0.970 |
| + fts5-porter min-max 0.30/0.70 | 0.944 | 0.967 | 0.967 | 0.906 | 0.958 |
| + fts5-porter RRF | 0.900 | 0.967 | 0.940 | 0.878 | 0.961 |
| qwen3-0.6b alone | 0.911 | 0.961 | 0.978 | 0.867 | 0.983 |
| + fts5-porter 0.45/0.55 | 0.906 | 0.978 | 0.944 | 0.844 | 0.952 |
| + fts5-porter 0.30/0.70 | 0.944 | 0.978 | 0.967 | 0.856 | 0.955 |
| + fts5-porter best 0.30/0.70 | 0.944 | 0.978 | 0.967 | 0.856 | 0.955 |
| + fts5-porter min-max 0.45/0.55 | 0.944 | 0.978 | 0.967 | 0.856 | 0.953 |
| + fts5-porter min-max 0.30/0.70 | 0.933 | 1.000 | 0.983 | 0.872 | 1.000 |
| + fts5-porter RRF | 0.894 | 0.978 | 0.939 | 0.872 | 0.983 |

## Quality: agent+categories queries

| Method | R@5 | R@10 | MRR | R@5 (10000) | MRR (10000) |
|---|---|---|---|---|---|
| fts5-porter | 0.878 | 0.939 | 0.910 | 0.817 | 0.916 |
| apple-contextual-centered alone | 0.706 | 0.806 | 0.736 | 0.656 | 0.732 |
| + fts5-porter 0.45/0.55 | 0.867 | 0.989 | 0.942 | 0.828 | 0.927 |
| + fts5-porter 0.30/0.70 | 0.889 | 0.928 | 0.933 | 0.822 | 0.909 |
| + fts5-porter best 0.55/0.45 | 0.906 | 0.967 | 0.942 | 0.817 | 0.917 |
| + fts5-porter min-max 0.45/0.55 | 0.878 | 0.989 | 0.942 | 0.828 | 0.921 |
| + fts5-porter min-max 0.30/0.70 | 0.872 | 0.911 | 0.933 | 0.822 | 0.909 |
| + fts5-porter RRF | 0.867 | 0.928 | 0.911 | 0.806 | 0.894 |
| bge-small alone | 0.906 | 0.933 | 0.983 | 0.833 | 0.958 |
| + fts5-porter 0.45/0.55 | 0.911 | 0.978 | 0.944 | 0.844 | 0.947 |
| + fts5-porter 0.30/0.70 | 0.911 | 0.978 | 0.950 | 0.828 | 0.969 |
| + fts5-porter best 0.15/0.85 | 0.939 | 0.967 | 0.967 | 0.817 | 0.955 |
| + fts5-porter min-max 0.45/0.55 | 0.922 | 0.978 | 0.950 | 0.828 | 0.970 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.978 | 0.967 | 0.817 | 0.955 |
| + fts5-porter RRF | 0.900 | 0.967 | 0.961 | 0.839 | 0.978 |
| bge-small-coreml-cpu alone | 0.906 | 0.933 | 0.983 | 0.850 | 0.958 |
| + fts5-porter 0.45/0.55 | 0.911 | 0.978 | 0.944 | 0.844 | 0.947 |
| + fts5-porter 0.30/0.70 | 0.911 | 0.978 | 0.950 | 0.828 | 0.969 |
| + fts5-porter best 0.10/0.90 | 0.939 | 0.978 | 0.967 | 0.833 | 0.958 |
| + fts5-porter min-max 0.45/0.55 | 0.922 | 0.978 | 0.950 | 0.828 | 0.970 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.978 | 0.967 | 0.817 | 0.955 |
| + fts5-porter RRF | 0.900 | 0.967 | 0.961 | 0.839 | 0.978 |
| bge-small-noinst alone | 0.861 | 0.933 | 0.950 | 0.817 | 0.928 |
| + fts5-porter 0.45/0.55 | 0.911 | 0.978 | 0.944 | 0.828 | 0.930 |
| + fts5-porter 0.30/0.70 | 0.911 | 0.978 | 0.950 | 0.872 | 0.969 |
| + fts5-porter best 0.15/0.85 | 0.956 | 0.978 | 0.967 | 0.850 | 0.955 |
| + fts5-porter min-max 0.45/0.55 | 0.922 | 0.978 | 0.967 | 0.844 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.956 | 0.978 | 0.967 | 0.850 | 0.955 |
| + fts5-porter RRF | 0.883 | 0.967 | 0.961 | 0.861 | 0.983 |
| e5-small alone | 0.872 | 0.944 | 0.950 | 0.817 | 0.943 |
| + fts5-porter 0.45/0.55 | 0.911 | 0.950 | 0.914 | 0.833 | 0.901 |
| + fts5-porter 0.30/0.70 | 0.911 | 0.967 | 0.917 | 0.822 | 0.913 |
| + fts5-porter best 0.10/0.90 | 0.939 | 0.967 | 0.944 | 0.811 | 0.970 |
| + fts5-porter min-max 0.45/0.55 | 0.939 | 0.978 | 0.944 | 0.817 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.933 | 0.950 | 0.950 | 0.822 | 0.971 |
| + fts5-porter RRF | 0.911 | 0.939 | 0.922 | 0.861 | 0.958 |
| me5-small alone | 0.872 | 0.944 | 0.983 | 0.806 | 0.971 |
| + fts5-porter 0.45/0.55 | 0.878 | 0.950 | 0.910 | 0.817 | 0.921 |
| + fts5-porter 0.30/0.70 | 0.928 | 0.967 | 0.919 | 0.828 | 0.926 |
| + fts5-porter best 0.10/0.90 | 0.956 | 0.967 | 0.944 | 0.856 | 0.969 |
| + fts5-porter min-max 0.45/0.55 | 0.944 | 0.967 | 0.950 | 0.872 | 0.969 |
| + fts5-porter min-max 0.30/0.70 | 0.939 | 0.967 | 0.983 | 0.867 | 0.969 |
| + fts5-porter RRF | 0.922 | 0.967 | 0.967 | 0.883 | 0.969 |
| nomic-v1.5 alone | 0.883 | 0.950 | 0.983 | 0.867 | 0.936 |
| + fts5-porter 0.45/0.55 | 0.939 | 0.967 | 0.928 | 0.828 | 0.910 |
| + fts5-porter 0.30/0.70 | 0.950 | 0.967 | 0.967 | 0.839 | 0.969 |
| + fts5-porter best 0.20/0.80 | 0.956 | 0.967 | 0.967 | 0.861 | 0.970 |
| + fts5-porter min-max 0.45/0.55 | 0.956 | 0.967 | 0.967 | 0.833 | 0.970 |
| + fts5-porter min-max 0.30/0.70 | 0.944 | 0.978 | 0.967 | 0.906 | 0.958 |
| + fts5-porter RRF | 0.900 | 0.967 | 0.942 | 0.878 | 0.961 |
| qwen3-0.6b alone | 0.933 | 0.972 | 0.978 | 0.883 | 1.000 |
| + fts5-porter 0.45/0.55 | 0.967 | 0.978 | 0.950 | 0.861 | 0.936 |
| + fts5-porter 0.30/0.70 | 0.956 | 0.978 | 0.967 | 0.872 | 0.955 |
| + fts5-porter best 0.35/0.65 | 0.967 | 0.978 | 0.967 | 0.872 | 0.953 |
| + fts5-porter min-max 0.45/0.55 | 0.967 | 0.989 | 0.967 | 0.872 | 0.953 |
| + fts5-porter min-max 0.30/0.70 | 0.944 | 1.000 | 0.983 | 0.889 | 1.000 |
| + fts5-porter RRF | 0.894 | 0.978 | 0.939 | 0.900 | 0.967 |

## Quality: spanish queries

| Method | R@5 | R@10 | MRR | R@5 (10000) | MRR (10000) |
|---|---|---|---|---|---|
| fts5-porter | 0.189 | 0.239 | 0.194 | 0.167 | 0.207 |
| apple-contextual-centered alone | 0.339 | 0.422 | 0.376 | 0.306 | 0.452 |
| + fts5-porter 0.45/0.55 | 0.372 | 0.461 | 0.348 | 0.294 | 0.384 |
| + fts5-porter 0.30/0.70 | 0.372 | 0.461 | 0.383 | 0.356 | 0.406 |
| + fts5-porter best 0.15/0.85 | 0.400 | 0.511 | 0.442 | 0.378 | 0.499 |
| + fts5-porter min-max 0.45/0.55 | 0.389 | 0.450 | 0.384 | 0.339 | 0.407 |
| + fts5-porter min-max 0.30/0.70 | 0.400 | 0.500 | 0.406 | 0.389 | 0.468 |
| + fts5-porter RRF | 0.378 | 0.461 | 0.432 | 0.367 | 0.493 |
| bge-small alone | 0.400 | 0.456 | 0.366 | 0.361 | 0.417 |
| + fts5-porter 0.45/0.55 | 0.350 | 0.417 | 0.320 | 0.239 | 0.284 |
| + fts5-porter 0.30/0.70 | 0.361 | 0.417 | 0.322 | 0.239 | 0.275 |
| + fts5-porter best 0.05/0.95 | 0.417 | 0.450 | 0.344 | 0.300 | 0.349 |
| + fts5-porter min-max 0.45/0.55 | 0.372 | 0.417 | 0.329 | 0.239 | 0.271 |
| + fts5-porter min-max 0.30/0.70 | 0.372 | 0.450 | 0.337 | 0.261 | 0.307 |
| + fts5-porter RRF | 0.383 | 0.417 | 0.357 | 0.239 | 0.293 |
| bge-small-coreml-cpu alone | 0.400 | 0.456 | 0.366 | 0.361 | 0.417 |
| + fts5-porter 0.45/0.55 | 0.350 | 0.417 | 0.320 | 0.239 | 0.284 |
| + fts5-porter 0.30/0.70 | 0.361 | 0.417 | 0.322 | 0.239 | 0.275 |
| + fts5-porter best 0.05/0.95 | 0.417 | 0.450 | 0.344 | 0.300 | 0.366 |
| + fts5-porter min-max 0.45/0.55 | 0.372 | 0.417 | 0.329 | 0.239 | 0.271 |
| + fts5-porter min-max 0.30/0.70 | 0.372 | 0.450 | 0.337 | 0.261 | 0.307 |
| + fts5-porter RRF | 0.383 | 0.417 | 0.357 | 0.239 | 0.293 |
| bge-small-noinst alone | 0.361 | 0.411 | 0.297 | 0.356 | 0.375 |
| + fts5-porter 0.45/0.55 | 0.328 | 0.400 | 0.286 | 0.239 | 0.256 |
| + fts5-porter 0.30/0.70 | 0.344 | 0.400 | 0.284 | 0.239 | 0.246 |
| + fts5-porter best 0.10/0.90 | 0.378 | 0.433 | 0.317 | 0.289 | 0.314 |
| + fts5-porter min-max 0.45/0.55 | 0.356 | 0.400 | 0.292 | 0.239 | 0.243 |
| + fts5-porter min-max 0.30/0.70 | 0.367 | 0.422 | 0.320 | 0.272 | 0.307 |
| + fts5-porter RRF | 0.367 | 0.400 | 0.321 | 0.267 | 0.298 |
| e5-small alone | 0.350 | 0.406 | 0.437 | 0.300 | 0.409 |
| + fts5-porter 0.45/0.55 | 0.328 | 0.444 | 0.337 | 0.250 | 0.317 |
| + fts5-porter 0.30/0.70 | 0.328 | 0.444 | 0.338 | 0.250 | 0.336 |
| + fts5-porter best 0.15/0.85 | 0.356 | 0.444 | 0.349 | 0.239 | 0.336 |
| + fts5-porter min-max 0.45/0.55 | 0.328 | 0.444 | 0.363 | 0.228 | 0.335 |
| + fts5-porter min-max 0.30/0.70 | 0.361 | 0.456 | 0.409 | 0.272 | 0.364 |
| + fts5-porter RRF | 0.339 | 0.433 | 0.386 | 0.306 | 0.367 |
| me5-small alone | 0.539 | 0.656 | 0.758 | 0.572 | 0.743 |
| + fts5-porter 0.45/0.55 | 0.478 | 0.594 | 0.553 | 0.367 | 0.518 |
| + fts5-porter 0.30/0.70 | 0.478 | 0.594 | 0.554 | 0.367 | 0.550 |
| + fts5-porter best 0.05/0.95 | 0.572 | 0.661 | 0.708 | 0.506 | 0.747 |
| + fts5-porter min-max 0.45/0.55 | 0.517 | 0.606 | 0.604 | 0.394 | 0.557 |
| + fts5-porter min-max 0.30/0.70 | 0.572 | 0.661 | 0.708 | 0.494 | 0.656 |
| + fts5-porter RRF | 0.528 | 0.594 | 0.644 | 0.506 | 0.655 |
| nomic-v1.5 alone | 0.339 | 0.517 | 0.443 | 0.361 | 0.429 |
| + fts5-porter 0.45/0.55 | 0.350 | 0.461 | 0.353 | 0.217 | 0.349 |
| + fts5-porter 0.30/0.70 | 0.378 | 0.461 | 0.371 | 0.217 | 0.333 |
| + fts5-porter best 0.10/0.90 | 0.389 | 0.461 | 0.390 | 0.256 | 0.413 |
| + fts5-porter min-max 0.45/0.55 | 0.389 | 0.461 | 0.395 | 0.228 | 0.340 |
| + fts5-porter min-max 0.30/0.70 | 0.389 | 0.472 | 0.394 | 0.256 | 0.396 |
| + fts5-porter RRF | 0.389 | 0.461 | 0.415 | 0.294 | 0.384 |
| qwen3-0.6b alone | 0.644 | 0.750 | 0.777 | 0.750 | 0.893 |
| + fts5-porter 0.45/0.55 | 0.567 | 0.617 | 0.622 | 0.461 | 0.590 |
| + fts5-porter 0.30/0.70 | 0.567 | 0.650 | 0.675 | 0.528 | 0.684 |
| + fts5-porter best 0.05/0.95 | 0.661 | 0.733 | 0.781 | 0.717 | 0.864 |
| + fts5-porter min-max 0.45/0.55 | 0.567 | 0.672 | 0.677 | 0.533 | 0.681 |
| + fts5-porter min-max 0.30/0.70 | 0.622 | 0.733 | 0.751 | 0.672 | 0.811 |
| + fts5-porter RRF | 0.567 | 0.617 | 0.693 | 0.628 | 0.739 |

## Weight sweep (200; R@5, original / agent)

| wk/ws | apple-contextual-centered | bge-small | bge-small-coreml-cpu | bge-small-noinst | e5-small | me5-small | nomic-v1.5 | qwen3-0.6b |
|---|---|---|---|---|---|---|---|---|
| 0.0/1.0 | 0.39 / 0.69 | 0.77 / 0.89 | 0.77 / 0.89 | 0.76 / 0.85 | 0.72 / 0.87 | 0.56 / 0.86 | 0.72 / 0.88 | 0.72 / 0.91 |
| 0.1/0.9 | 0.51 / 0.79 | 0.74 / 0.91 | 0.74 / 0.92 | 0.69 / 0.92 | 0.63 / 0.90 | 0.59 / 0.94 | 0.69 / 0.92 | 0.74 / 0.90 |
| 0.2/0.8 | 0.53 / 0.86 | 0.66 / 0.93 | 0.66 / 0.93 | 0.64 / 0.92 | 0.58 / 0.88 | 0.58 / 0.89 | 0.66 / 0.96 | 0.64 / 0.93 |
| 0.3/0.7 | 0.53 / 0.89 | 0.62 / 0.90 | 0.62 / 0.90 | 0.62 / 0.90 | 0.58 / 0.88 | 0.58 / 0.89 | 0.61 / 0.93 | 0.62 / 0.94 |
| 0.4/0.6 | 0.57 / 0.87 | 0.59 / 0.90 | 0.59 / 0.90 | 0.59 / 0.90 | 0.58 / 0.84 | 0.58 / 0.84 | 0.59 / 0.90 | 0.59 / 0.93 |
| 0.5/0.5 | 0.58 / 0.87 | 0.59 / 0.89 | 0.59 / 0.89 | 0.59 / 0.88 | 0.57 / 0.84 | 0.57 / 0.83 | 0.58 / 0.89 | 0.59 / 0.91 |
| 0.6/0.4 | 0.57 / 0.88 | 0.58 / 0.88 | 0.58 / 0.88 | 0.58 / 0.89 | 0.57 / 0.83 | 0.57 / 0.83 | 0.58 / 0.89 | 0.59 / 0.91 |
| 0.7/0.3 | 0.58 / 0.84 | 0.58 / 0.83 | 0.58 / 0.83 | 0.58 / 0.84 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.84 | 0.59 / 0.89 |
| 0.8/0.2 | 0.58 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.84 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.84 | 0.58 / 0.86 |
| 0.9/0.1 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.84 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.84 | 0.57 / 0.84 |
| 1.0/0.0 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 | 0.57 / 0.83 |

## Similarity distribution (200, original queries)

| Model | relevant p10 | relevant median | other median | other p90 | other p99 |
|---|---|---|---|---|---|
| apple-contextual-centered | 0.09 | 0.29 | -0.01 | 0.20 | 0.38 |
| bge-small | 0.50 | 0.64 | 0.45 | 0.54 | 0.62 |
| bge-small-coreml-cpu | 0.50 | 0.64 | 0.45 | 0.54 | 0.61 |
| bge-small-noinst | 0.55 | 0.65 | 0.46 | 0.56 | 0.64 |
| e5-small | 0.78 | 0.83 | 0.76 | 0.79 | 0.82 |
| me5-small | 0.80 | 0.82 | 0.77 | 0.80 | 0.83 |
| nomic-v1.5 | 0.51 | 0.62 | 0.47 | 0.55 | 0.62 |
| qwen3-0.6b | 0.31 | 0.42 | 0.18 | 0.28 | 0.40 |

## Thresholds (200, 0.45/0.55; keep if keyword > 0 or semantic ≥ T)

Vault = recall of every kept result and mean kept per query; retrieval = recall@30 of the kept results. Original / agent queries.

### apple-contextual-centered

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 0.961 | 57.7 | 0.850 | 1.000 | 67.4 | 0.989 |
| 0.15 | 0.933 | 43.9 | 0.850 | 1.000 | 57.3 | 0.989 |
| 0.20 | 0.861 | 33.5 | 0.850 | 1.000 | 50.2 | 0.989 |
| 0.25 | 0.806 | 27.3 | 0.794 | 1.000 | 44.9 | 0.989 |
| 0.30 | 0.794 | 23.2 | 0.783 | 1.000 | 41.1 | 0.989 |
| 0.35 | 0.783 | 20.6 | 0.783 | 1.000 | 38.0 | 0.989 |
| 0.40 | 0.728 | 19.3 | 0.728 | 1.000 | 36.3 | 1.000 |
| 0.45 | 0.717 | 18.7 | 0.717 | 0.989 | 35.1 | 0.989 |
| 0.50 | 0.706 | 18.4 | 0.706 | 0.989 | 34.7 | 0.989 |
| 0.55 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.60 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.65 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.70 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### bge-small

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 200.0 | 0.911 | 1.000 | 200.0 | 0.978 |
| 0.15 | 1.000 | 200.0 | 0.911 | 1.000 | 200.0 | 0.978 |
| 0.20 | 1.000 | 200.0 | 0.911 | 1.000 | 200.0 | 0.978 |
| 0.25 | 1.000 | 199.8 | 0.911 | 1.000 | 199.9 | 0.978 |
| 0.30 | 1.000 | 198.8 | 0.911 | 1.000 | 199.5 | 0.978 |
| 0.35 | 0.989 | 188.0 | 0.911 | 1.000 | 195.3 | 0.978 |
| 0.40 | 0.989 | 152.7 | 0.911 | 1.000 | 172.2 | 0.978 |
| 0.45 | 0.978 | 99.3 | 0.911 | 1.000 | 120.4 | 0.978 |
| 0.50 | 0.944 | 52.5 | 0.911 | 1.000 | 71.0 | 0.978 |
| 0.55 | 0.894 | 27.9 | 0.878 | 0.989 | 44.3 | 0.978 |
| 0.60 | 0.822 | 20.0 | 0.806 | 0.978 | 35.6 | 0.978 |
| 0.65 | 0.733 | 18.4 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.70 | 0.717 | 18.3 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### bge-small-coreml-cpu

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 200.0 | 0.911 | 1.000 | 200.0 | 0.978 |
| 0.15 | 1.000 | 200.0 | 0.911 | 1.000 | 200.0 | 0.978 |
| 0.20 | 1.000 | 200.0 | 0.911 | 1.000 | 200.0 | 0.978 |
| 0.25 | 1.000 | 199.8 | 0.911 | 1.000 | 199.9 | 0.978 |
| 0.30 | 1.000 | 198.8 | 0.911 | 1.000 | 199.5 | 0.978 |
| 0.35 | 0.989 | 187.9 | 0.911 | 1.000 | 195.2 | 0.978 |
| 0.40 | 0.989 | 152.6 | 0.911 | 1.000 | 172.2 | 0.978 |
| 0.45 | 0.978 | 99.2 | 0.911 | 1.000 | 120.5 | 0.978 |
| 0.50 | 0.944 | 52.5 | 0.911 | 1.000 | 70.8 | 0.978 |
| 0.55 | 0.894 | 27.9 | 0.878 | 0.989 | 44.4 | 0.978 |
| 0.60 | 0.822 | 20.0 | 0.806 | 0.978 | 35.6 | 0.978 |
| 0.65 | 0.733 | 18.4 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.70 | 0.717 | 18.3 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### bge-small-noinst

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 200.0 | 0.933 | 1.000 | 200.0 | 0.989 |
| 0.15 | 1.000 | 200.0 | 0.933 | 1.000 | 200.0 | 0.989 |
| 0.20 | 1.000 | 200.0 | 0.933 | 1.000 | 200.0 | 0.989 |
| 0.25 | 1.000 | 199.9 | 0.933 | 1.000 | 200.0 | 0.989 |
| 0.30 | 1.000 | 199.4 | 0.933 | 1.000 | 199.8 | 0.989 |
| 0.35 | 1.000 | 192.1 | 0.933 | 1.000 | 197.4 | 0.989 |
| 0.40 | 0.989 | 165.3 | 0.933 | 1.000 | 183.4 | 0.989 |
| 0.45 | 0.989 | 116.9 | 0.933 | 1.000 | 143.0 | 0.989 |
| 0.50 | 0.978 | 67.2 | 0.922 | 1.000 | 88.1 | 0.989 |
| 0.55 | 0.911 | 35.3 | 0.894 | 1.000 | 51.5 | 0.989 |
| 0.60 | 0.883 | 21.8 | 0.867 | 0.989 | 37.2 | 0.978 |
| 0.65 | 0.772 | 18.8 | 0.756 | 0.978 | 34.6 | 0.978 |
| 0.70 | 0.717 | 18.3 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### e5-small

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.15 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.20 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.25 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.30 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.35 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.40 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.45 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.50 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.55 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.60 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.65 | 1.000 | 200.0 | 0.956 | 1.000 | 200.0 | 0.989 |
| 0.70 | 1.000 | 195.6 | 0.956 | 1.000 | 198.9 | 0.989 |
| 0.75 | 0.989 | 133.1 | 0.956 | 1.000 | 149.1 | 0.989 |
| 0.80 | 0.906 | 26.8 | 0.906 | 0.989 | 42.0 | 0.978 |
| 0.85 | 0.717 | 18.3 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### me5-small

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.15 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.20 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.25 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.30 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.35 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.40 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.45 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.50 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.55 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.60 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.65 | 1.000 | 200.0 | 0.900 | 1.000 | 200.0 | 0.989 |
| 0.70 | 1.000 | 199.4 | 0.900 | 1.000 | 199.7 | 0.989 |
| 0.75 | 1.000 | 162.7 | 0.900 | 1.000 | 165.3 | 0.989 |
| 0.80 | 0.906 | 38.9 | 0.872 | 1.000 | 49.0 | 0.989 |
| 0.85 | 0.717 | 18.4 | 0.717 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### nomic-v1.5

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 200.0 | 0.922 | 1.000 | 200.0 | 0.978 |
| 0.15 | 1.000 | 200.0 | 0.922 | 1.000 | 200.0 | 0.978 |
| 0.20 | 1.000 | 200.0 | 0.922 | 1.000 | 200.0 | 0.978 |
| 0.25 | 1.000 | 200.0 | 0.922 | 1.000 | 200.0 | 0.978 |
| 0.30 | 1.000 | 199.9 | 0.922 | 1.000 | 200.0 | 0.978 |
| 0.35 | 1.000 | 198.2 | 0.922 | 1.000 | 198.8 | 0.978 |
| 0.40 | 0.989 | 184.3 | 0.922 | 1.000 | 191.3 | 0.978 |
| 0.45 | 0.989 | 135.3 | 0.922 | 1.000 | 155.4 | 0.978 |
| 0.50 | 0.956 | 70.5 | 0.911 | 1.000 | 93.5 | 0.978 |
| 0.55 | 0.928 | 34.2 | 0.911 | 0.989 | 52.8 | 0.978 |
| 0.60 | 0.811 | 20.6 | 0.811 | 0.989 | 37.2 | 0.978 |
| 0.65 | 0.761 | 18.6 | 0.761 | 0.978 | 34.5 | 0.978 |
| 0.70 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

### qwen3-0.6b

| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |
|---|---|---|---|---|---|---|
| 0.10 | 1.000 | 179.7 | 0.944 | 1.000 | 179.2 | 1.000 |
| 0.15 | 1.000 | 138.0 | 0.944 | 1.000 | 136.2 | 1.000 |
| 0.20 | 0.989 | 84.9 | 0.944 | 1.000 | 87.2 | 1.000 |
| 0.25 | 0.978 | 46.9 | 0.933 | 1.000 | 55.4 | 1.000 |
| 0.30 | 0.978 | 28.1 | 0.933 | 0.989 | 41.3 | 0.989 |
| 0.35 | 0.883 | 21.8 | 0.867 | 0.989 | 36.2 | 0.989 |
| 0.40 | 0.778 | 19.3 | 0.778 | 0.978 | 34.8 | 0.978 |
| 0.45 | 0.717 | 18.4 | 0.717 | 0.978 | 34.5 | 0.978 |
| 0.50 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.55 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.60 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.65 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.70 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.75 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.80 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.85 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |
| 0.90 | 0.706 | 18.3 | 0.706 | 0.978 | 34.4 | 0.978 |

Keyword > 0 alone: original recall 0.706, kept 18.3; agent recall 0.978, kept 34.4.

## Search latency at 10000 without the query embedding (ms; 30 agent queries × 5 runs; 0.45/0.55, top 30)

Add the model's per-query embedding time (Models table, or the Core ML section) for the end-to-end figure.

| Model | FTS5 p50 | dot p50 | rank p50 | search p50 | search p95 | + embed p50 = total p50 |
|---|---|---|---|---|---|---|
| apple-contextual-centered | 3.70 | 0.82 | 2.41 | 6.91 | 10.52 | 11.9 → 18.9 |
| bge-small | 3.66 | 0.41 | 2.96 | 6.89 | 10.70 | 16.5 → 23.4 |
| bge-small-coreml-cpu | 3.65 | 0.40 | 2.95 | 6.88 | 10.71 | 3.6 → 10.5 |
| bge-small-noinst | 3.66 | 0.40 | 2.85 | 6.94 | 10.42 | 15.6 → 22.5 |
| e5-small | 3.67 | 0.40 | 3.07 | 7.14 | 10.02 | 15.7 → 22.8 |
| me5-small | 3.67 | 0.41 | 2.53 | 6.53 | 10.28 | 15.9 → 22.4 |
| nomic-v1.5 | 3.70 | 1.01 | 3.19 | 7.75 | 12.39 | 24.4 → 32.1 |
| qwen3-0.6b | 3.65 | 1.47 | 2.41 | 7.44 | 11.01 | 86.0 → 93.5 |

Threshold used for latency: each model's 'other p90' cosine. Vector memory at 10000: apple-contextual-centered 19.5 MB, bge-small 14.6 MB, bge-small-coreml-cpu 14.6 MB, bge-small-noinst 14.6 MB, e5-small 14.6 MB, me5-small 14.6 MB, nomic-v1.5 29.3 MB, qwen3-0.6b 39.1 MB

## Dump: bge-small-coreml-cpu + fts5-porter 0.00/1.00, original

q01 Write a commit message for my latest change
   relevant: sd_commits@1 cs_no_emoji@9
   top5: sd_commits sd_ci cs_slack f_late sd_branching
q02 Plan a week of dinners for me
   relevant: pp_vegetarian@63 h_peanut@196 pp_cooking@1
   top5: pp_cooking pc_ideas pp_weekend_offline pc_book pc_cowork
q03 Draft an email reminding the sailing club treasurer that last month's invoice is overdue
   relevant: f_late@2 pc_harbor_client@3 cs_email_tone@22
   top5: f_invoicing f_late pc_harbor_client l_dispute f_subscriptions
q04 Book train tickets and somewhere to stay for a weekend in Porto
   relevant: pp_travel_style@1 f_cards@5
   top5: pp_travel_style pp_sailing pp_parents pp_japan f_cards
q05 What should I order at a café this afternoon?
   relevant: h_caffeine@3 pp_coffee@5 h_lactose@38
   top5: pp_cafe pp_coffee_home h_caffeine pp_cuisine pp_coffee
q06 Set up a new Python project that parses bank statement exports
   relevant: sd_python@3 pc_ledgerly@1
   top5: pc_ledgerly pc_ledgerly_next sd_python cs_proposals sd_learning
q07 Review this pull request for the Nordwind dispatch service
   relevant: sd_review@12 pc_atlas@1 pc_atlas_nda@4
   top5: pc_atlas pc_atlas_people sd_ci pc_atlas_nda pc_q4
q08 Suggest a running plan for the next four weeks
   relevant: h_knee@19 pc_marathon@2 h_heart_rate@42
   top5: pc_ideas pc_marathon pp_running pc_q4 pc_book
q09 Find a time next week for an intro call with a prospective client
   relevant: pp_morning@3 cs_calls@25
   top5: pc_capacity cs_proposals pp_morning pc_atlas_people pp_weekend_offline
q10 The doctor wants to prescribe antibiotics. Is there anything they should know?
   relevant: h_penicillin@2
   top5: h_vaccines h_penicillin h_vitamin_d h_gp h_hayfever
q11 Help me get my paperwork together for this year's income tax filing
   relevant: f_irs@1 f_accountant@3 f_expenses@9
   top5: f_irs f_social_security f_accountant pv_finance f_invoicing
q12 Help me write a blog post about building the Harbor app
   relevant: cs_writing_voice@10 pc_blog@2 pc_harbor@1
   top5: pc_harbor pc_blog pc_q4 pc_ideas pc_harbor_dates
q13 A client sent a contract with a 12-month non-compete. Should I sign it?
   relevant: l_noncompete@1 l_lawyer@4 l_contracts@2
   top5: l_noncompete l_contracts l_dispute l_lawyer l_nda
q14 Summarize the terms and conditions of this new service
   relevant: l_tos@1
   top5: l_tos sd_api_design cs_meeting_notes cs_headings cs_proposals
q15 Build a settings screen for my SwiftUI app
   relevant: sd_swiftui@1 sd_accessibility@7 sd_swift_style@4
   top5: sd_swiftui pc_harbor_stack sd_editor sd_swift_style pc_ideas
q16 What should I get Jordan for their birthday?
   relevant: pp_gifts@1 pp_birthdays@2
   top5: pp_gifts pp_birthdays pp_partner l_will pv_partner
q17 My head hurts after a long day at the computer. Any advice?
   relevant: h_migraine@24 h_eyes@2 h_stress@1
   top5: h_stress h_eyes h_water pp_desk pc_travel_work
q18 How much should I put into savings and investments this month?
   relevant: f_savings@4 f_invest@6 f_budget@1
   top5: f_budget f_flat f_parents f_savings f_income
q19 Write the privacy policy for my iOS app
   relevant: l_privacy_labels@1 pv_analytics@2
   top5: l_privacy_labels pv_analytics pv_partner pv_screenshots pv_location
q20 Help me write a message to my mum about my next visit
   relevant: cs_spanish_family@1 pp_parents@2
   top5: cs_spanish_family pp_parents f_parents f_late cs_writing_voice
q21 Set up automated builds and tests for my open-source library
   relevant: sd_ci@5 pc_gpx@1
   top5: pc_gpx sd_docs sd_learning sd_license sd_ci
q22 Where should I deploy the server for the booking app?
   relevant: sd_infra@4 pc_harbor_stack@5
   top5: pc_harbor_bug pc_harbor sd_sql sd_infra pc_harbor_stack
q23 Prepare a quote for a three-week freelance engagement
   relevant: pc_rate@1 pc_capacity@7 cs_proposals@3
   top5: pc_rate pc_book cs_proposals f_social_security pc_blog
q24 The landlord asked whether we'll stay in the flat after the contract ends
   relevant: l_lease@1 f_rent@4
   top5: l_lease f_flat l_dispute f_rent l_lawyer
q25 Write up the notes from today's standup
   relevant: cs_meeting_notes@1 pc_atlas_people@5
   top5: cs_meeting_notes cs_reading_lists cs_writing_voice cs_presentations pc_atlas_people
q26 Can I paste the client's database schema into ChatGPT to debug a query?
   relevant: pc_atlas_nda@18 pv_ai_training@82
   top5: sd_sql pc_android sd_docs cs_headings pc_ledgerly_next
q27 Make slides for my Porto conference talk
   relevant: cs_presentations@2 pc_talk@1
   top5: pc_talk cs_presentations cs_meeting_notes cs_club_language cs_headings
q28 Find a recipe I can cook tonight in half an hour
   relevant: pp_cooking@1 pp_vegetarian@40 cs_units@57
   top5: pp_cooking h_caffeine pc_book pp_morning pc_ideas
q29 What should I pack for a day out on the water?
   relevant: h_sun@4 pp_sailing@3
   top5: h_water pc_ideas pp_sailing h_sun pp_gifts
q30 How much can we spend on remodelling the kitchen, and how will we pay for it?
   relevant: pc_kitchen@1 f_kitchen_funding@2
   top5: pc_kitchen f_kitchen_funding f_flat f_budget pc_rate

## Dump: bge-small-coreml-cpu + fts5-porter 0.00/1.00, agent

q01 Write a commit message for my latest change commit message conventions git commit style conventional commits version control tone changelog
   relevant: sd_commits@1 cs_no_emoji@3
   top5: sd_commits cs_slack cs_no_emoji sd_ci sd_ai_code
q02 Plan a week of dinners for me diet dietary restrictions food allergies food preferences favourite cuisines cooking recipes meal planning nutrition grocery budget
   relevant: pp_vegetarian@8 h_peanut@74 pp_cooking@1
   top5: pp_cooking pp_cuisine pc_book cs_bullets pc_ideas
q03 Draft an email reminding the sailing club treasurer that last month's invoice is overdue invoice overdue payment payment reminder late payment client treasurer sailing club email tone email signature billing terms
   relevant: f_late@2 pc_harbor_client@3 cs_email_tone@13
   top5: f_invoicing f_late pc_harbor_client l_dispute cs_club_language
q04 Book train tickets and somewhere to stay for a weekend in Porto travel preferences train hotel accommodation seat preference travel budget payment card weekend trip
   relevant: pp_travel_style@1 f_cards@2
   top5: pp_travel_style f_cards f_bank pp_sailing f_japan_budget
q05 What should I order at a café this afternoon? coffee tea drink preferences caffeine milk dietary restrictions food allergies snacks
   relevant: h_caffeine@1 pp_coffee@4 h_lactose@6
   top5: h_caffeine pp_cafe pp_coffee_home pp_coffee pp_cuisine
q06 Set up a new Python project that parses bank statement exports Python project setup coding conventions linting type hints testing CSV bank statements parsing budgeting dependencies
   relevant: sd_python@1 pc_ledgerly@2
   top5: sd_python pc_ledgerly pc_ledgerly_next sd_learning cs_proposals
q07 Review this pull request for the Nordwind dispatch service code review pull request review style Nordwind client project coding standards TypeScript testing
   relevant: sd_review@5 pc_atlas@1 pc_atlas_nda@2
   top5: pc_atlas pc_atlas_nda sd_ci cs_slack sd_review
q08 Suggest a running plan for the next four weeks running training plan fitness level injuries race goal marathon weekly mileage heart rate schedule
   relevant: h_knee@5 pc_marathon@1 h_heart_rate@4
   top5: pc_marathon pp_running h_physio h_heart_rate h_knee
q09 Find a time next week for an intro call with a prospective client calendar availability working hours meeting preferences calls time zone schedule client focus time
   relevant: pp_morning@1 cs_calls@13
   top5: pp_morning pc_capacity cs_proposals pc_harbor_bug cs_time_format
q10 The doctor wants to prescribe antibiotics. Is there anything they should know? allergies drug allergies medication medical history current medications health conditions side effects
   relevant: h_penicillin@1
   top5: h_penicillin h_vitamin_d h_hayfever h_vaccines h_blood_test
q11 Help me get my paperwork together for this year's income tax filing income tax tax return accountant receipts invoices deductions business expenses freelance income tax deadlines
   relevant: f_irs@1 f_accountant@2 f_expenses@3
   top5: f_irs f_accountant f_expenses f_social_security f_invoicing
q12 Help me write a blog post about building the Harbor app blog writing style tone Harbor app project details audience post length app development
   relevant: cs_writing_voice@4 pc_blog@1 pc_harbor@3
   top5: pc_blog cs_slack pc_harbor cs_writing_voice pc_ideas
q13 A client sent a contract with a 12-month non-compete. Should I sign it? contract non-compete clause legal review lawyer contract terms freelance contracts negotiation
   relevant: l_noncompete@1 l_lawyer@2 l_contracts@3
   top5: l_noncompete l_lawyer l_contracts l_dispute l_nda
q14 Summarize the terms and conditions of this new service terms of service summary format privacy data sharing legal terms subscriptions auto-renewal
   relevant: l_tos@1
   top5: l_tos f_insurance sd_api_design cs_headings l_gdpr_harbor
q15 Build a settings screen for my SwiftUI app SwiftUI Swift style iOS macOS UI conventions accessibility architecture state management design
   relevant: sd_swiftui@1 sd_accessibility@2 sd_swift_style@3
   top5: sd_swiftui sd_accessibility sd_swift_style sd_editor pc_harbor_stack
q16 What should I get Jordan for their birthday? Jordan gift ideas birthday partner interests hobbies likes and dislikes budget
   relevant: pp_gifts@1 pp_birthdays@3
   top5: pp_gifts pp_partner pp_birthdays pv_partner l_will
q17 My head hurts after a long day at the computer. Any advice? headache migraine eye strain screen time posture breaks sleep hydration stress medication
   relevant: h_migraine@5 h_eyes@1 h_stress@2
   top5: h_eyes h_stress h_water h_caffeine h_migraine
q18 How much should I put into savings and investments this month? savings investments budget emergency fund income expenses financial goals retirement risk tolerance
   relevant: f_savings@1 f_invest@4 f_budget@2
   top5: f_savings f_budget f_flat f_invest f_parents
q19 Write the privacy policy for my iOS app privacy policy data collection analytics tracking App Store GDPR user data app details
   relevant: l_privacy_labels@1 pv_analytics@2
   top5: l_privacy_labels pv_analytics l_gdpr_harbor pc_blog pv_screenshots
q20 Help me write a message to my mum about my next visit mother parents family language tone travel plans visit
   relevant: cs_spanish_family@1 pp_parents@3
   top5: cs_spanish_family f_parents pp_parents cs_writing_voice cs_club_language
q21 Set up automated builds and tests for my open-source library continuous integration CI GitHub Actions testing build open-source library project licence
   relevant: sd_ci@1 pc_gpx@5
   top5: sd_ci sd_license sd_secrets sd_deps pc_gpx
q22 Where should I deploy the server for the booking app? hosting deployment server cloud provider infrastructure Docker booking app backend budget
   relevant: sd_infra@1 pc_harbor_stack@2
   top5: sd_infra pc_harbor_stack pc_harbor pc_harbor_bug sd_sql
q23 Prepare a quote for a three-week freelance engagement rate pricing day rate availability proposal scope payment terms currency VAT contract
   relevant: pc_rate@1 pc_capacity@4 cs_proposals@2
   top5: pc_rate cs_proposals l_contracts pc_capacity f_currency
q24 The landlord asked whether we'll stay in the flat after the contract ends lease rental contract rent landlord tenancy notice period housing moving
   relevant: l_lease@1 f_rent@5
   top5: l_lease f_flat l_dispute f_late f_rent
q25 Write up the notes from today's standup meeting notes standup format action items team project summary
   relevant: cs_meeting_notes@1 pc_atlas_people@7
   top5: cs_meeting_notes cs_reading_lists pc_book cs_presentations pc_ideas
q26 Can I paste the client's database schema into ChatGPT to debug a query? client data confidentiality NDA privacy AI tools data sharing database security
   relevant: pc_atlas_nda@1 pv_ai_training@29
   top5: pc_atlas_nda sd_review pv_client_data pc_ledgerly_next sd_api_design
q27 Make slides for my Porto conference talk presentation slides talk conference presentation style slide design speaker notes
   relevant: cs_presentations@1 pc_talk@3
   top5: cs_presentations cs_meeting_notes pc_talk cs_bullets cs_headings
q28 Find a recipe I can cook tonight in half an hour recipe quick dinner diet dietary restrictions allergies cooking equipment cuisine measurement units
   relevant: pp_cooking@1 pp_vegetarian@22 cs_units@3
   top5: pp_cooking pp_cuisine cs_units pc_ideas pc_book
q29 What should I pack for a day out on the water? boating sailing packing list sun protection weather gear water activities
   relevant: h_sun@1 pp_sailing@2
   top5: h_sun pp_sailing pc_ideas h_water l_gdpr_harbor
q30 How much can we spend on remodelling the kitchen, and how will we pay for it? kitchen renovation remodel budget savings financing loan home improvement costs
   relevant: pc_kitchen@2 f_kitchen_funding@1
   top5: f_kitchen_funding pc_kitchen f_flat f_budget f_japan_budget
MODE=2b MODELS= DUMP_MODEL=bge-small-coreml-cpu .build/release/search-spike    282.77s user 15.62s system 124% cpu 4:00.38 total
