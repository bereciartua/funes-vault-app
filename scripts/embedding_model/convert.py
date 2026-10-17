"""Converts bge-small-en-v1.5 (BERT, safetensors) to a Core ML ML Program (fp16 compute; int8
weights with the int8 flag) with CLS pooling and L2 normalization inside, then checks it against
reference vectors (ADR-0016).

Run by scripts/fetch_embedding_model.sh. Usage:
  python -I convert.py <hf-dir> <out.mlpackage> <reference.json> [int8]
Inputs: input_ids, attention_mask (int32, [1, L], L in 16/32/64/128/256). Output: embedding [1, 384].

The forward pass is written out in plain torch over the checkpoint's tensors, so no transformers
dependency is needed (and transformers' own BertModel traces to ops coremltools can't convert).
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from safetensors.torch import load_file
from tokenizers import Tokenizer

hf_dir, out, reference = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
int8 = len(sys.argv) > 4 and sys.argv[4] == "int8"
LENGTHS = [16, 32, 64, 128, 256]
config = json.loads((hf_dir / "config.json").read_text())
weights = load_file(str(hf_dir / "model.safetensors"))
torch.manual_seed(0)


class BGE(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.d = config["hidden_size"]
        self.heads = config["num_attention_heads"]
        self.layers = config["num_hidden_layers"]
        self.eps = config["layer_norm_eps"]
        for k, v in weights.items():
            if k.startswith("pooler.") or k.endswith("position_ids"):
                continue
            self.register_buffer(k.replace(".", "__"), v.float())

    def w(self, name):
        return getattr(self, name.replace(".", "__"))

    def linear(self, x, name):
        return x @ self.w(name + ".weight").T + self.w(name + ".bias")

    def norm(self, x, name):
        return torch.nn.functional.layer_norm(x, (self.d,), self.w(name + ".weight"), self.w(name + ".bias"), self.eps)

    def forward(self, input_ids, attention_mask):
        pos = torch.cumsum(torch.ones_like(input_ids), dim=1) - 1  # no shape-dependent ops: they break conversion
        x = (torch.nn.functional.embedding(input_ids, self.w("embeddings.word_embeddings.weight"))
             + torch.nn.functional.embedding(pos, self.w("embeddings.position_embeddings.weight"))
             + self.w("embeddings.token_type_embeddings.weight")[0])
        x = self.norm(x, "embeddings.LayerNorm")
        bias = (1.0 - attention_mask[:, None, None, :].to(x.dtype)) * -1e4  # fp16-safe
        hd = self.d // self.heads
        for i in range(self.layers):
            p = f"encoder.layer.{i}."

            def split(t):
                return t.reshape(1, -1, self.heads, hd).transpose(1, 2)

            q = split(self.linear(x, p + "attention.self.query"))
            k = split(self.linear(x, p + "attention.self.key"))
            v = split(self.linear(x, p + "attention.self.value"))
            a = torch.softmax(q @ k.transpose(-1, -2) / hd ** 0.5 + bias, dim=-1)
            ctx = (a @ v).transpose(1, 2).reshape(1, -1, self.d)
            x = self.norm(self.linear(ctx, p + "attention.output.dense") + x, p + "attention.output.LayerNorm")
            h = torch.nn.functional.gelu(self.linear(x, p + "intermediate.dense"))
            x = self.norm(self.linear(h, p + "output.dense") + x, p + "output.LayerNorm")
        return torch.nn.functional.normalize(x[:, 0], dim=-1)  # CLS pooling, L2-normalized


model = BGE().eval()
ids = torch.zeros((1, 32), dtype=torch.int32)
mask = torch.ones((1, 32), dtype=torch.int32)
traced = torch.jit.trace(model, (ids, mask), strict=False)
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
if int8:
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
    mlmodel = linear_quantize_weights(mlmodel, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))
mlmodel.short_description = "BAAI/bge-small-en-v1.5, CLS pooling, L2-normalized (Funes Vault, ADR-0016)"
mlmodel.license = "MIT (BAAI)"
mlmodel.save(out)

# Check against reference vectors from sentence-transformers (PyTorch fp32), on the CPU as Funes runs it.
tok = Tokenizer.from_file(str(hf_dir / "tokenizer.json"))
tok.no_padding()
tok.enable_truncation(max_length=256)
loaded = ct.models.MLModel(out, compute_units=ct.ComputeUnit.CPU_ONLY)
worst = 1.0
for item in json.loads(reference.read_text())["items"]:
    enc = tok.encode(item["text"]).ids
    n = next(L for L in LENGTHS if L >= len(enc))
    a = np.zeros((1, n), dtype=np.int32)
    m = np.zeros((1, n), dtype=np.int32)
    a[0, : len(enc)] = enc
    m[0, : len(enc)] = 1
    got = loaded.predict({"input_ids": a, "attention_mask": m})["embedding"][0].astype(np.float64)
    ref = np.array(item["vector"], dtype=np.float64)
    worst = min(worst, float(got @ ref / (np.linalg.norm(got) * np.linalg.norm(ref))))
floor = 0.999
print(f"convert.py: worst cosine(Core ML, reference) = {worst:.5f} (floor {floor})")
if worst < floor:
    sys.exit("convert.py: the converted model doesn't match the reference vectors")
