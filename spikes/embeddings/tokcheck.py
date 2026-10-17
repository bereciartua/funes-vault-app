"""Writes Hugging Face token ids for the queries and a sample of documents, to check the Swift WordPiece."""
import json, sys
from pathlib import Path
from transformers import AutoTokenizer

tok = AutoTokenizer.from_pretrained(sys.argv[1])
prefix_q, prefix_d = sys.argv[3], sys.argv[4]
corpus = json.loads(Path(sys.argv[2]).read_text())
texts = [prefix_q + q for qs in corpus["queries"].values() for q in qs] + [prefix_d + d["text"] for d in corpus["docs"][:2000]]
items = [{"text": t, "ids": tok(t, truncation=True, max_length=256)["input_ids"]} for t in texts]
Path(sys.argv[5]).write_text(json.dumps(items, ensure_ascii=False))
print(len(items))
