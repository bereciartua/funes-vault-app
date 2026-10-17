"""Developer tool, not run in CI: regenerates the committed reference data for the bundled model.

  - scripts/embedding_model/reference.json: sentence-transformers (PyTorch fp32) vectors for a few
    texts; convert.py checks the converted Core ML model against them.
  - Packages/FunesCore/Tests/FunesCoreTests/fixtures/tokenizer-bge-small.json: Hugging Face token ids
    for every benchmark text (memories, raw and expanded queries) plus edge cases; the Swift
    WordPieceTokenizer must match them exactly.

Needs sentence-transformers and transformers (for example the Spike 2b venv in spikes/embeddings):
  python -I make_fixtures.py <hf-dir> <repo-root>
"""
import json
import sys
from pathlib import Path

from sentence_transformers import SentenceTransformer
from transformers import AutoTokenizer

hf_dir, root = sys.argv[1], Path(sys.argv[2])
fixtures = root / "Packages/FunesCore/Tests/FunesCoreTests/fixtures"
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
NAMES = {
    "communication_style": "Communication style", "personal_preferences": "Personal preferences",
    "software_development": "Software development", "project_context": "Project context",
    "privacy_preferences": "Privacy preferences", "health": "Health", "finance": "Finance", "legal": "Legal",
}

memories = json.loads((fixtures / "memories-200.json").read_text())["memories"]
raw = json.loads((fixtures / "queries-30.json").read_text())["queries"]
expanded = json.loads((fixtures / "queries-30-expanded.json").read_text())["queries"]


def memory_text(m):  # spec/domain/memory-processing.md §2
    cats = ", ".join(NAMES[c] for c in m["categories"])
    return f"{m['title']}\n{m['kind'].replace('_', ' ')}\n{cats}\n{m['body']}"


edge = [
    "Café crème, naïve résumé, Ångström, Øresund, ﬁancée",
    "日本語のテキストと中文混合 with English",
    "Emoji 👩‍💻 and flags 🇦🇷 and symbols ™ © ½ → ≥",
    "Punctuation: (a) [b] {c} <d> \"e\" 'f' — g – h … i; j: k! l? m/n\\o @p #q $r %s ^t &u *v _w +x =y |z ~",
    "tabs\tand\nnew lines\r\nand non-breaking spaces​zero-width",
    "Supercalifragilisticexpialidocious antidisestablishmentarianism pneumonoultramicroscopicsilicovolcanoconiosis",
    "x" * 120,
    " ".join(["long"] * 400),
]
texts = ([memory_text(m) for m in memories] + [QUERY_PREFIX + q["query"] for q in raw]
         + [QUERY_PREFIX + " ".join([q["query"]] + q["keywords"]) for q in expanded] + edge)
tok = AutoTokenizer.from_pretrained(hf_dir)
items = [{"text": t, "ids": tok(t, truncation=True, max_length=256)["input_ids"]} for t in texts]
rows = ",\n".join(json.dumps(i, ensure_ascii=False, separators=(", ", ": ")) for i in items)
(fixtures / "tokenizer-bge-small.json").write_text(
    '{"format": "funes.fixture.tokenizer.v1", "model": "BAAI/bge-small-en-v1.5", "max_length": 256, "items": [\n'
    + rows + "\n]}\n")

model = SentenceTransformer(hf_dir, device="cpu")
model.max_seq_length = 256  # as Funes truncates
ref_texts = [QUERY_PREFIX + raw[1]["query"], QUERY_PREFIX + " ".join([expanded[1]["query"]] + expanded[1]["keywords"]),
             memory_text(memories[0]), memory_text(memories[47]), memory_text(memories[135]), edge[0], edge[7]]
vecs = model.encode(ref_texts, normalize_embeddings=True)
(Path(__file__).parent / "reference.json").write_text(json.dumps(
    {"format": "funes.embedding.reference.v1", "model": "BAAI/bge-small-en-v1.5", "runtime": "sentence-transformers, PyTorch fp32, CPU",
     "items": [{"text": t, "vector": [round(float(x), 6) for x in v]} for t, v in zip(ref_texts, vecs)]}) + "\n")
print(f"{len(items)} tokenizer items, {len(ref_texts)} reference vectors")
