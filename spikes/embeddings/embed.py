"""Spike 2b: embed the benchmark corpus and queries with open models (PyTorch, MPS).

Usage: .venv/bin/python -I embed.py corpus.json vectors/ bge-small e5-small ...
Writes vectors/<name>/{docs,q_original,q_agent,q_spanish}.f32 (float32, L2-normalized, row-major)
and meta.json for the Swift benchmark (MODE=2b).
"""
import gc, json, statistics, sys, time
from pathlib import Path

import numpy as np
import torch
from huggingface_hub import model_info, snapshot_download
from sentence_transformers import SentenceTransformer

QWEN_TASK = "Given a task that an AI assistant received, retrieve the user's personal notes that help with the task"
MODELS = {
    # name: (hf id, query prefix, document prefix, kwargs)
    "bge-small": ("BAAI/bge-small-en-v1.5", "Represent this sentence for searching relevant passages: ", "", {}),
    "bge-small-noinst": ("BAAI/bge-small-en-v1.5", "", "", {}),
    "e5-small": ("intfloat/e5-small-v2", "query: ", "passage: ", {}),
    "me5-small": ("intfloat/multilingual-e5-small", "query: ", "passage: ", {}),
    "nomic-v1.5": ("nomic-ai/nomic-embed-text-v1.5", "search_query: ", "search_document: ", {"trust_remote_code": True}),
    "embeddinggemma": ("google/embeddinggemma-300m", "task: search result | query: ", "title: none | text: ", {}),
    "qwen3-0.6b": ("Qwen/Qwen3-Embedding-0.6B", f"Instruct: {QWEN_TASK}\nQuery:", "", {"model_kwargs": {"torch_dtype": torch.float16}}),
}
MAX_TOKENS = 256  # spec: embedding input truncated to 256 tokens


def _extended_attention_mask(self, attention_mask, input_shape=None, device=None, dtype=None):
    """transformers 4.x helper, removed in 5.x but still called by nomic's remote code."""
    dtype = dtype or self.dtype
    ext = attention_mask[:, None, :, :] if attention_mask.dim() == 3 else attention_mask[:, None, None, :]
    return (1.0 - ext.to(dtype)) * torch.finfo(dtype).min


import transformers  # noqa: E402

if not hasattr(transformers.PreTrainedModel, "get_extended_attention_mask"):
    transformers.PreTrainedModel.get_extended_attention_mask = _extended_attention_mask


def weights_mb(hf_id: str) -> float:
    path = Path(snapshot_download(hf_id, local_files_only=True))
    files = [p for p in path.rglob("*") if p.suffix in (".safetensors", ".bin") and "onnx" not in p.parts]
    return sum(p.resolve().stat().st_size for p in files) / 1_048_576


def main() -> None:
    corpus = json.loads(Path(sys.argv[1]).read_text())
    out_root = Path(sys.argv[2])
    docs = [d["text"] for d in corpus["docs"]]
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    for name in sys.argv[3:]:
        hf_id, qp, dp, kwargs = MODELS[name]
        print(f"== {name} ({hf_id}) on {device}", flush=True)
        model = SentenceTransformer(hf_id, device=device, **kwargs)
        model.max_seq_length = MAX_TOKENS
        out = out_root / name
        out.mkdir(parents=True, exist_ok=True)

        def enc(texts, prefix, batch=32):
            v = model.encode([prefix + t for t in texts], batch_size=batch, normalize_embeddings=True,
                             convert_to_numpy=True, show_progress_bar=False)
            return np.ascontiguousarray(v, dtype=np.float32)

        enc(docs[:64], dp)  # warm up
        t = time.perf_counter()
        dv = enc(docs, dp)
        doc_ms = (time.perf_counter() - t) * 1000 / len(docs)
        dv.tofile(out / "docs.f32")
        for set_name, texts in corpus["queries"].items():
            enc(texts, qp).tofile(out / f"q_{set_name}.f32")
        times = []
        for _ in range(3):  # one query at a time, as at search time
            for q in corpus["queries"]["agent"]:
                t = time.perf_counter()
                enc([q], qp, batch=1)
                times.append((time.perf_counter() - t) * 1000)
        times.sort()
        try:
            license_ = (model_info(hf_id).card_data or {}).get("license", "unknown")
        except Exception as e:  # noqa: BLE001
            license_ = f"unknown ({type(e).__name__})"
        meta = {
            "name": name, "hf_id": hf_id, "dims": int(dv.shape[1]),
            "runtime": f"PyTorch {torch.__version__} {device} {str(next(model.parameters()).dtype).replace('torch.', '')}",
            "doc_ms": doc_ms, "query_ms_p50": statistics.median(times), "query_ms_p95": times[int(0.95 * (len(times) - 1))],
            "size_mb": weights_mb(hf_id), "license": str(license_),
            "query_prefix": qp, "doc_prefix": dp,
        }
        (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        print(json.dumps(meta), flush=True)
        del model
        gc.collect()
        if device == "mps":
            torch.mps.empty_cache()


if __name__ == "__main__":
    main()
