"""Spike 2b: convert a BERT-style sentence embedder to Core ML (ML Program, fp16) with pooling and
L2 normalization inside the model, then check it against PyTorch.

Usage: .venv/bin/python -I convert_coreml.py BAAI/bge-small-en-v1.5 cls out/bge-small.mlpackage
Inputs: input_ids, attention_mask (int32, shape [1, L], L in 16/32/64/128/256). Output: embedding [1, dims].
"""
import sys

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

hf_id, pooling, out = sys.argv[1], sys.argv[2], sys.argv[3]
LENGTHS = [16, 32, 64, 128, 256]


class Embedder(torch.nn.Module):
    """A minimal BERT forward pass over the Hugging Face weights. transformers 5's own BertModel
    traces to ops coremltools 9 can't convert (new_ones in its mask helpers)."""

    def __init__(self):
        super().__init__()
        self.hf = AutoModel.from_pretrained(hf_id, attn_implementation="eager").eval()
        self.heads = self.hf.config.num_attention_heads

    def forward(self, input_ids, attention_mask):
        e = self.hf.embeddings
        pos = torch.cumsum(torch.ones_like(input_ids), dim=1) - 1  # no shape-dependent ops: they break conversion
        x = e.word_embeddings(input_ids) + e.position_embeddings(pos) + e.token_type_embeddings(torch.zeros_like(input_ids))
        x = e.LayerNorm(x)
        bias = (1.0 - attention_mask[:, None, None, :].to(x.dtype)) * -1e4  # fp16-safe
        d = self.hf.config.hidden_size
        hd = d // self.heads
        for layer in self.hf.encoder.layer:
            a = layer.attention
            def split(t):
                return t.reshape(1, -1, self.heads, hd).transpose(1, 2)
            q, k, v = split(a.self.query(x)), split(a.self.key(x)), split(a.self.value(x))
            w = torch.softmax(q @ k.transpose(-1, -2) / hd ** 0.5 + bias, dim=-1)
            ctx = (w @ v).transpose(1, 2).reshape(1, -1, d)
            x = a.output.LayerNorm(a.output.dense(ctx) + x)
            h = torch.nn.functional.gelu(layer.intermediate.dense(x))
            x = layer.output.LayerNorm(layer.output.dense(h) + x)
        if pooling == "cls":
            v = x[:, 0]
        else:
            m = attention_mask.unsqueeze(-1).to(x.dtype)
            v = (x * m).sum(1) / m.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(v, dim=-1)


model = Embedder()
tok = AutoTokenizer.from_pretrained(hf_id)
example = tok(["an example sentence for tracing"], padding="max_length", max_length=32, return_tensors="pt")
traced = torch.jit.trace(model, (example["input_ids"], example["attention_mask"]), strict=False)
shapes = ct.EnumeratedShapes(shapes=[[1, n] for n in LENGTHS], default=[1, 32])
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=shapes, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shapes, dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
mlmodel.short_description = f"{hf_id}, {pooling} pooling, L2-normalized (Funes Spike 2b)"
mlmodel.save(out)

# Check: Core ML (fp16, all compute units) vs PyTorch fp32 on a few texts.
texts = ["Plan a week of dinners for me", "Vegetarian\nfact\nPersonal preferences, Health\nI've been vegetarian since 2019.",
         "The doctor wants to prescribe antibiotics. Is there anything they should know?"]
loaded = ct.models.MLModel(out, compute_units=ct.ComputeUnit.ALL)
for t in texts:
    enc = tok([t], truncation=True, max_length=256, return_tensors="np")
    n = next(L for L in LENGTHS if L >= enc["input_ids"].shape[1])
    ids = np.zeros((1, n), dtype=np.int32); mask = np.zeros((1, n), dtype=np.int32)
    ids[0, : enc["input_ids"].shape[1]] = enc["input_ids"][0]; mask[0, : enc["input_ids"].shape[1]] = 1
    got = loaded.predict({"input_ids": ids, "attention_mask": mask})["embedding"][0]
    with torch.no_grad():
        hidden = model.hf(input_ids=torch.tensor(enc["input_ids"]), attention_mask=torch.tensor(enc["attention_mask"])).last_hidden_state
        ref = (hidden[:, 0] if pooling == "cls" else hidden.mean(1))[0]
        ref = torch.nn.functional.normalize(ref, dim=-1).numpy()
    print(f"cosine(coreml, torch) = {float(np.dot(got, ref) / np.linalg.norm(got)):.5f}  len={enc['input_ids'].shape[1]} bucket={n}")
