"""The related-memories finder of memory processing §5.5: hybrid search over the vault, always local.

Semantic: FunesCore's bundled bge-small (Core ML int8) through swift/.build/release/bge-embed, document
embeddings on both sides (piece vs memory), as the duplicate hint does. Keyword: BM25 over title and body
with light stemming, normalized by the best score per query (a stand-in for FTS5 porter). Candidates: raw
cosine >= the related threshold, or keyword >= the 0.15 floor; ranked by 0.30 x keyword + 0.70 x min-max
semantic; top K.
"""
import hashlib
import json
import math
import os
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from prompts import CATEGORIES

HERE = Path(__file__).resolve().parent
CACHE = HERE / "results" / "embeddings-cache.json"
MODEL_DIR = Path.home() / "Library/Caches/com.funesvault.dev/bge-small-en-v1.5-5c38ec7"
EMBED_BIN = HERE / "swift/.build/release/bge-embed"
CAT_NAME = {k: n for k, n, _ in CATEGORIES}
STOPWORDS = set("""a an the and or but of to in on at for with from by as is are was were be been am i me my we our you
your they them their he she his her it its this that these those not no do does did have has had will would can
could should may might just very also so than then there here what which who when where why how if about into over
under after before more most some any each all both other such own same only now user""".split())


def memory_text(title, kind, categories, body):
    return f"{title}\n{kind}\n{', '.join(CAT_NAME.get(c, c) for c in categories)}\n{body}"


class Embeddings:
    def __init__(self):
        self.cache = {}
        for _ in range(10):
            try:
                self.cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
                break
            except json.JSONDecodeError:
                time.sleep(1)  # another run is writing it

    @staticmethod
    def key(t):
        return hashlib.sha256(t.encode()).hexdigest()[:24]

    _lock = threading.Lock()

    def embed(self, texts):
        with self._lock:
            return self._embed(texts)

    def _embed(self, texts):
        missing = list(dict.fromkeys(t for t in texts if self.key(t) not in self.cache))
        if missing:
            with tempfile.TemporaryDirectory() as d:
                inp, out = Path(d) / "in.json", Path(d) / "out.json"
                inp.write_text(json.dumps(missing))
                subprocess.run([str(EMBED_BIN), str(MODEL_DIR), str(inp), str(out)], check=True)
                for t, v in zip(missing, json.loads(out.read_text())):
                    self.cache[self.key(t)] = [round(x, 6) for x in v]
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            # Atomic replace: parallel runs share this cache.
            tmp = CACHE.with_suffix(f".{os.getpid()}.tmp")
            tmp.write_text(json.dumps(self.cache))
            os.replace(tmp, CACHE)
        return [self.cache[self.key(t)] for t in texts]


def _tok(text):
    out = []
    for w in re.findall(r"[a-z0-9áéíóúñüç]+", text.lower()):
        if w in STOPWORDS or len(w) < 2:
            continue
        for suf in ("ing", "ed", "es", "s"):
            if len(w) > 4 and w.endswith(suf):
                w = w[: -len(suf)]
                break
        out.append(w)
    return out


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


class Finder:
    KEYWORD_FLOOR = 0.15

    def __init__(self, vault, embeddings, threshold=0.75, k=5):
        self.vault = vault
        self.by_id = {m["id"]: m for m in vault}
        self.emb = embeddings
        self.threshold = threshold
        self.k = k
        texts = [memory_text(m["title"], m["kind"], m["categories"], m["body"]) for m in vault]
        self.vectors = dict(zip([m["id"] for m in vault], embeddings.embed(texts)))
        self.docs = {m["id"]: _tok(m["title"] + " " + m["body"]) for m in vault}
        self.avgdl = sum(len(d) for d in self.docs.values()) / len(self.docs)
        df = {}
        for d in self.docs.values():
            for w in set(d):
                df[w] = df.get(w, 0) + 1
        n = len(self.docs)
        self.idf = {w: math.log(1 + (n - c + 0.5) / (c + 0.5)) for w, c in df.items()}

    def keyword_scores(self, text):
        q = set(_tok(text))
        raw = {}
        for mid, d in self.docs.items():
            s = 0.0
            for w in q:
                f = d.count(w)
                if f:
                    s += self.idf[w] * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * len(d) / self.avgdl))
            if s > 0:
                raw[mid] = s
        best = max(raw.values(), default=0)
        return {k: v / best for k, v in raw.items()} if best else {}

    def cosines(self, title, kind, categories, body):
        v = self.emb.embed([memory_text(title, kind, categories, body)])[0]
        return {mid: dot(v, mv) for mid, mv in self.vectors.items()}

    def find(self, title, kind, categories, body, exclude=(), threshold=None, k=None):
        threshold = self.threshold if threshold is None else threshold
        k = self.k if k is None else k
        cos = self.cosines(title, kind, categories, body)
        kw = self.keyword_scores(title + " " + body)
        pool = [m for m in cos if m not in exclude]
        lo, hi = min(cos[m] for m in pool), max(cos[m] for m in pool)
        scored = []
        for m in pool:
            if cos[m] >= threshold or kw.get(m, 0) >= self.KEYWORD_FLOOR:
                sem = (cos[m] - lo) / (hi - lo) if hi > lo else 0
                scored.append((0.30 * kw.get(m, 0) + 0.70 * sem, m))
        scored.sort(reverse=True)
        return [m for _, m in scored[:k]], cos, kw
