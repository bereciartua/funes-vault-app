"""Phase 6c.1: provider embedding models as a second index next to bge-small (ADR-0023).

Usage (from spikes/embeddings):
  .venv/bin/python -I bench6c.py tokens                      # input size, for cloud cost estimates
  .venv/bin/python -I bench6c.py embed bge-small nomic-v1.5  # writes vectors6c/<model>/
  .venv/bin/python -I bench6c.py score nomic-v1.5 me5-small  # markdown report on stdout

Cloud models read their key from the environment (OPENAI_API_KEY, GEMINI_API_KEY) and send only
the synthetic fixtures. Scoring mirrors FunesCore's SearchService.rank: FTS5 porter BM25 divided
by the best score, the cosine min-max normalized over the pool, 0.30 × keyword + 0.70 × semantic,
and a memory kept if keyword ≥ 0.15 or its raw cosine reaches its index's threshold.

Second index (ADR-0023 decision 2): memories within the cloud limit have a provider vector and use
its score, min-max normalized over the provider pool; the others use bge-small's score, normalized
over the whole vault ("dual") or over the bge-only memories ("dual-b"). "ens" averages the two
normalized scores where both exist (not the ADR design; measured as an alternative).
"""
import gc, json, os, re, sqlite3, statistics, sys, time, urllib.request
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
FIX = HERE.parents[1] / "Packages/FunesCore/Tests/FunesCoreTests/fixtures"
OUT = HERE / "vectors6c"
MAX_TOKENS = 256
KW_W, SEM_W, KW_FLOOR, TOP = 0.30, 0.70, 0.15, 30
BGE_THRESHOLD, BGE_VAULT_THRESHOLD = 0.55, 0.50  # bge-small's thresholds (EmbeddingModelInfo)
ORDER = ["public", "low", "internal", "sensitive", "restricted", "secret"]
CLOUD_LIMIT = "internal"  # the recommended default

QWEN_TASK = "Given a task that an AI assistant received, retrieve the user's personal notes that help with the task"
BGE_Q = "Represent this sentence for searching relevant passages: "
MODELS = {
    # name: (backend, model id, query prefix, document prefix, options)
    "bge-small": ("st", "BAAI/bge-small-en-v1.5", BGE_Q, "", {}),
    "nomic-v1.5": ("st", "nomic-ai/nomic-embed-text-v1.5", "search_query: ", "search_document: ", {"trust_remote_code": True}),
    "nomic-v1.5-noprefix": ("st", "nomic-ai/nomic-embed-text-v1.5", "", "", {"trust_remote_code": True}),
    "me5-small": ("st", "intfloat/multilingual-e5-small", "query: ", "passage: ", {}),
    "qwen3-0.6b": ("st", "Qwen/Qwen3-Embedding-0.6B", f"Instruct: {QWEN_TASK}\nQuery:", "", {"fp16": True}),
    "oai-3-small": ("openai", "text-embedding-3-small", "", "", {"base": "https://api.openai.com/v1", "key": "OPENAI_API_KEY"}),
    "oai-3-large": ("openai", "text-embedding-3-large", "", "", {"base": "https://api.openai.com/v1", "key": "OPENAI_API_KEY"}),
    "ollama-qwen3-0.6b": ("openai", "qwen3-embedding:0.6b", f"Instruct: {QWEN_TASK}\nQuery:", "", {"base": "http://127.0.0.1:11434/v1", "key": None}),
    "gemini-001": ("openai", "gemini-embedding-001", "", "", {"base": "https://generativelanguage.googleapis.com/v1beta/openai", "key": "GEMINI_API_KEY"}),
    "gemini-001-task": ("gemini", "gemini-embedding-001", "RETRIEVAL_QUERY", "RETRIEVAL_DOCUMENT", {"key": "GEMINI_API_KEY"}),
}
EN_CATEGORIES = {
    "communication_style": "Communication style", "personal_preferences": "Personal preferences",
    "software_development": "Software development", "project_context": "Project context",
    "privacy_preferences": "Privacy preferences", "health": "Health", "finance": "Finance", "legal": "Legal",
}
STOPWORDS = set("""a about above after again all am an and any are as at be because been before being below
between both but by can could did do does doing don down during each few for from further had has have having
he her here hers him his how i if in into is it its just me more most my myself no nor not now of off on once
only or other our out over own same she should so some such than that the their them then there these they this
those through to too under until up very was we were what when where which while who whom why will with would
you your yours anything something s t ll ve re d m""".split())


# MARK: Fixtures

def load():
    en = json.loads((FIX / "memories-200.json").read_text())["memories"]
    es_file = json.loads((HERE / "memories-200-es.json").read_text())
    es = es_file["memories"]
    assert [m["id"] for m in en] == [m["id"] for m in es]
    q = json.loads((FIX / "queries-30.json").read_text())["queries"]
    qx = json.loads((FIX / "queries-30-expanded.json").read_text())["queries"]
    qes = json.loads((HERE / "queries-30-es.json").read_text())["queries"]
    qesx = json.loads((HERE / "queries-30-es-expanded.json").read_text())["queries"]
    assert [x["id"] for x in q] == [x["id"] for x in qx] == [x["id"] for x in qes] == [x["id"] for x in qesx]

    def text(m, names):
        cats = ", ".join(names.get(c, c) for c in m["categories"])
        return f"{m['title']}\n{m['kind'].replace('_', ' ')}\n{cats}\n{m['body']}"

    docs = {"en": [text(m, EN_CATEGORIES) for m in en], "es": [text(m, es_file["category_names"]) for m in es]}
    fts = {"en": [(m["title"], m["body"]) for m in en], "es": [(m["title"], m["body"]) for m in es]}
    queries = {
        "original": [x["query"] for x in q],
        "agent": [" ".join([x["query"]] + x["keywords"]) for x in qx],
        "es": [x["query"] for x in qes],
        "es_agent": [" ".join([x["query"]] + x["keywords"]) for x in qesx],
    }
    return en, docs, fts, queries, [set(x["relevant"]) for x in q]


# MARK: Embedding

def embed_st(name, hf_id, qp, dp, opts, docs, queries):
    import torch
    from sentence_transformers import SentenceTransformer
    import transformers

    if not hasattr(transformers.PreTrainedModel, "get_extended_attention_mask"):  # nomic's remote code, transformers 5.x
        def ext(self, mask, input_shape=None, device=None, dtype=None):
            dtype = dtype or self.dtype
            e = mask[:, None, :, :] if mask.dim() == 3 else mask[:, None, None, :]
            return (1.0 - e.to(dtype)) * torch.finfo(dtype).min
        transformers.PreTrainedModel.get_extended_attention_mask = ext

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    kwargs = {"trust_remote_code": True} if opts.get("trust_remote_code") else {}
    if opts.get("fp16"):
        kwargs["model_kwargs"] = {"torch_dtype": torch.float16}
    model = SentenceTransformer(hf_id, device=device, **kwargs)
    model.max_seq_length = MAX_TOKENS

    def enc(texts, prefix, batch=32):
        return model.encode([prefix + t for t in texts], batch_size=batch, normalize_embeddings=True,
                            convert_to_numpy=True, show_progress_bar=False)

    enc(docs["en"][:32], dp)
    out = {f"docs_{k}": enc(v, dp) for k, v in docs.items()}
    out.update({f"q_{k}": enc(v, qp) for k, v in queries.items()})
    times = []
    for t in queries["agent"]:
        s = time.perf_counter()
        enc([t], qp, batch=1)
        times.append((time.perf_counter() - s) * 1000)
    meta = {"runtime": f"sentence-transformers, PyTorch {torch.__version__} {device}" + (" fp16" if opts.get("fp16") else " fp32"),
            "query_ms_p50": statistics.median(times)}
    del model
    gc.collect()
    return out, meta


def post(url, body, headers):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", **headers})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 503) and attempt < 4:
                time.sleep(2 ** attempt * 2)
                continue
            raise RuntimeError(f"{e.code}: {e.read()[:300]!r}") from None


def embed_remote(name, backend, model_id, qp, dp, opts, docs, queries):
    key = os.environ[opts["key"]] if opts["key"] else None
    usage = {"tokens": 0}

    def enc(texts, role):  # role: the prefix (OpenAI-compatible) or the task type (Gemini native)
        vecs = []
        for i in range(0, len(texts), 96):
            batch = texts[i:i + 96]
            if backend == "openai":
                r = post(f"{opts['base']}/embeddings", {"model": model_id, "input": [role + t for t in batch]}, {"Authorization": f"Bearer {key}"} if key else {})
                usage["tokens"] += (r.get("usage") or {}).get("prompt_tokens", 0)
                vecs += [d["embedding"] for d in sorted(r["data"], key=lambda d: d["index"])]
            else:  # Gemini native, with task types
                url = f"https://generativelanguage.googleapis.com/v1beta/models/{model_id}:batchEmbedContents"
                reqs = [{"model": f"models/{model_id}", "content": {"parts": [{"text": t}]}, "taskType": role} for t in batch]
                r = post(url, {"requests": reqs}, {"x-goog-api-key": key})
                vecs += [e["values"] for e in r["embeddings"]]
        v = np.asarray(vecs, dtype=np.float32)
        return v / np.linalg.norm(v, axis=1, keepdims=True)

    out = {f"docs_{k}": enc(v, dp) for k, v in docs.items()}
    out.update({f"q_{k}": enc(v, qp) for k, v in queries.items()})
    times = []
    for t in queries["agent"][:10]:
        s = time.perf_counter()
        enc([t], qp)
        times.append((time.perf_counter() - s) * 1000)
    return out, {"runtime": f"{opts.get('base', 'Gemini API')} ({backend})", "query_ms_p50": statistics.median(times),
                 "billed_tokens": usage["tokens"]}


def embed(names):
    _, docs, _, queries, _ = load()
    for name in names:
        backend, model_id, qp, dp, opts = MODELS[name]
        print(f"== {name}", flush=True)
        if backend == "st":
            vecs, meta = embed_st(name, model_id, qp, dp, opts, docs, queries)
        else:
            vecs, meta = embed_remote(name, backend, model_id, qp, dp, opts, docs, queries)
        d = OUT / name
        d.mkdir(parents=True, exist_ok=True)
        for k, v in vecs.items():
            np.ascontiguousarray(v, dtype=np.float32).tofile(d / f"{k}.f32")
        meta.update({"name": name, "model": model_id, "dims": int(vecs["docs_en"].shape[1]), "query_prefix": qp, "doc_prefix": dp})
        (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        print(json.dumps(meta), flush=True)


def tokens():
    _, docs, _, queries, _ = load()
    chars = sum(len(t) for v in docs.values() for t in v) + sum(len(t) for v in queries.values() for t in v)
    print(f"{sum(len(v) for v in docs.values())} documents, {sum(len(v) for v in queries.values())} queries, "
          f"{chars} characters ≈ {chars // 4} tokens per model (plus ~10 timing queries)")


# MARK: Scoring

def terms(text):
    seen, out = set(), []
    for t in "".join(c if c.isalpha() or c.isnumeric() else " " for c in text.lower()).split():
        if len(t) > 1 and t not in STOPWORDS and t not in seen:
            seen.add(t)
            out.append(t)
    return out


class Keyword:
    def __init__(self, rows):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript("""
            CREATE TABLE memory (seq INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL);
            CREATE VIRTUAL TABLE memory_fts USING fts5(title, body, content='memory', content_rowid='seq',
              tokenize='porter unicode61 remove_diacritics 2');""")
        for i, (t, b) in enumerate(rows):
            self.db.execute("INSERT INTO memory (seq, title, body) VALUES (?, ?, ?)", (i, t, b))
            self.db.execute("INSERT INTO memory_fts (rowid, title, body) VALUES (?, ?, ?)", (i, t, b))

    def scores(self, text):
        ts = terms(text)
        if not ts:
            return {}
        q = " OR ".join(f'"{t}"' for t in ts)
        raw = dict(self.db.execute("SELECT rowid, -bm25(memory_fts) FROM memory_fts WHERE memory_fts MATCH ?", (q,)))
        best = max(raw.values(), default=0)
        return {i: s / best for i, s in raw.items()} if best > 0 else {}


def minmax(c, mask):
    if not mask.any():
        return np.zeros_like(c)
    lo, hi = c[mask].min(), c[mask].max()
    return (c - lo) / (hi - lo) if hi > lo else np.zeros_like(c)


def rank(kw, sem, semkeep):
    """sem: normalized semantic per memory; semkeep: raw cosine reaches its index's threshold.
    Returns the kept indices, best first."""
    n = len(sem)
    k = np.zeros(n)
    for i, v in kw.items():
        k[i] = v
    keep = ((k >= KW_FLOOR) & (k > 0)) | semkeep
    score = KW_W * k + SEM_W * sem
    idx = np.nonzero(keep)[0]
    return idx[np.lexsort((idx, -score[idx]))]


def metrics(ranked_by_q, rel, ids, subset=None):
    """Mean R@5, R@30 (top-30 cut), MRR; and micro R@5 over labels in `subset` (memory ids)."""
    r5 = r30 = mrr = 0.0
    hit, tot = 0, 0
    for order, rs in zip(ranked_by_q, rel):
        got = [ids[i] for i in order[:TOP]]
        r5 += len(set(got[:5]) & rs) / len(rs)
        r30 += len(set(got) & rs) / len(rs)
        first = next((j for j, x in enumerate(got) if x in rs), None)
        mrr += 0 if first is None else 1 / (first + 1)
        if subset is not None:
            lab = rs & subset
            hit += len(set(got[:5]) & lab)
            tot += len(lab)
    n = len(rel)
    return {"r5": r5 / n, "r30": r30 / n, "mrr": mrr / n, "sub": (hit / tot if tot else float("nan")), "subn": tot}


def load_vecs(name):
    d = OUT / name
    meta = json.loads((d / "meta.json").read_text())
    v = {p.stem: np.fromfile(p, dtype=np.float32).reshape(-1, meta["dims"]) for p in d.glob("*.f32")}
    return meta, v


def score(names):
    mems, docs, fts, queries, rel = load()
    ids = [m["id"] for m in mems]
    n = len(ids)
    sens = np.array([ORDER.index(m["sensitivity"]) for m in mems])
    within = sens <= ORDER.index(CLOUD_LIMIT)
    bge_only_ids = {ids[i] for i in range(n) if not within[i]}
    mixed_es = np.arange(n) % 2 == 0  # mixed vault: every other memory in Spanish

    kw_idx = {"en": Keyword(fts["en"]), "es": Keyword(fts["es"]),
              "mixed": Keyword([fts["es"][i] if mixed_es[i] else fts["en"][i] for i in range(n)])}
    scenarios = [("en", "original"), ("en", "agent"), ("en", "es"), ("es", "es"), ("es", "es_agent"),
                 ("mixed", "es"), ("mixed", "original")]
    labels = {("en", "original"): "EN vault, raw EN tasks", ("en", "agent"): "EN vault, EN task + keywords",
              ("en", "es"): "EN vault, raw ES tasks (cross-lingual)", ("es", "es"): "ES vault, raw ES tasks",
              ("es", "es_agent"): "ES vault, ES task + keywords",
              ("mixed", "es"): "mixed vault (half ES), raw ES tasks", ("mixed", "original"): "mixed vault, raw EN tasks"}

    metas, vecs = {}, {}
    for name in ["bge-small"] + names:
        metas[name], vecs[name] = load_vecs(name)

    def docvecs(name, corpus):
        v = vecs[name]
        if corpus == "mixed":
            return np.where(mixed_es[:, None], v["docs_es"], v["docs_en"])
        return v[f"docs_{corpus}"]

    def cosines(name, corpus, qset):
        return vecs[name][f"q_{qset}"] @ docvecs(name, corpus).T  # (30, n)

    # Per-model thresholds, from the cosines of non-relevant memories (EN vault, raw EN tasks): retrieval
    # at their 90th percentile (bge: 0.54, shipped 0.55; bge's own p93 costs the cloud models 0.02-0.04
    # cross-lingually), vault at the percentile where bge's 0.50 sits. FunesCore's built-in thresholds
    # and Calibrate use the same rule.
    def others(name):
        c = cosines(name, "en", "original")
        return np.array([c[q, i] for q in range(len(rel)) for i in range(n) if ids[i] not in rel[q]])
    ob = others("bge-small")
    vault_pct, retrieval_pct = (ob < BGE_VAULT_THRESHOLD).mean() * 100, 90
    thresholds, vault_thresholds = {"bge-small": BGE_THRESHOLD}, {"bge-small": BGE_VAULT_THRESHOLD}
    for name in names:
        o = others(name)
        thresholds[name] = float(np.percentile(o, retrieval_pct))
        vault_thresholds[name] = float(np.percentile(o, vault_pct))

    kw_cache = {(c, q): [kw_idx[c].scores(t) for t in queries[q]] for c, q in scenarios}
    none = np.zeros(n, bool)
    allmask = np.ones(n, bool)

    def run(corpus, qset, method, name=None):
        kws = kw_cache[(corpus, qset)]
        out = []
        cb = cosines("bge-small", corpus, qset)
        cp = cosines(name, corpus, qset) if name else None
        for q in range(len(rel)):
            if method == "keyword":
                order = rank(kws[q], np.zeros(n), none)
            elif method == "alone":  # embedding only, no keyword, no threshold
                order = np.argsort(-cp[q], kind="stable")
            elif method == "hybrid":  # the model's index on every memory
                c = cp[q] if name else cb[q]
                order = rank(kws[q], minmax(c, allmask), c >= thresholds[name or "bge-small"])
            else:  # second index, provider vectors on memories within the cloud limit
                has = within if method.endswith("@limit") else allmask
                sp = minmax(cp[q], has)
                sb = minmax(cb[q], allmask if not method.startswith("dual-b") else ~has)
                pkeep = has & (cp[q] >= thresholds[name])
                bkeep = cb[q] >= BGE_THRESHOLD
                if method.startswith("dualz"):  # z-score per index over its own pool, then min-max of the merge
                    z = lambda c, m: (c - c[m].mean()) / max(c[m].std(), 1e-6)
                    order = rank(kws[q], minmax(np.where(has, z(cp[q], has), z(cb[q], allmask)), allmask),
                                 np.where(has, pkeep, bkeep))
                elif method.startswith("dualq"):  # percentile rank per index within its own pool
                    pr = lambda c, m: np.searchsorted(np.sort(c[m]), c, side="right") / m.sum()
                    order = rank(kws[q], np.where(has, pr(cp[q], has), pr(cb[q], allmask)), np.where(has, pkeep, bkeep))
                elif method.startswith("ens"):
                    order = rank(kws[q], np.where(has, (sp + sb) / 2, sb), pkeep | bkeep)
                else:
                    order = rank(kws[q], np.where(has, sp, sb), np.where(has, pkeep, bkeep))
            out.append(order)
        return metrics(out, rel, ids, bge_only_ids)

    f = lambda x: f"{x:.3f}"
    print("# Phase 6c.1: provider embeddings as a second index\n")
    print(f"Date: {time.strftime('%Y-%m-%d %H:%M')}. Fixtures: memories-200 (EN) and memories-200-es (ES translation), "
          f"queries-30 (raw EN), queries-30-expanded (EN task + keywords), queries-30-es (raw ES), queries-30-es-expanded "
          f"(ES task + ES keywords). Cloud limit `{CLOUD_LIMIT}`: {int(within.sum())} of {n} memories get a provider vector; "
          f"{len(bge_only_ids)} keep only bge, holding {sum(len(r & bge_only_ids) for r in rel)} of {sum(len(r) for r in rel)} relevant labels.\n")
    print("Methods: **hybrid** = the model's vectors on every memory (as for a local model, or a cloud limit of Secret); "
          "**dual@limit** = ADR-0023: provider score where the memory has a provider vector (within the limit), bge-small's "
          "otherwise, each min-max normalized over its own pool (bge over the whole vault); **dual-b@limit** = the same with "
          "bge normalized over the bge-only memories; **ens** = mean of the two normalized scores where both exist. "
          "**dualz** / **dualq** = the same with each index z-scored / percentile-ranked over its own pool. "
          "\"R@5 bge-only\" = micro recall@5 of the relevant labels on memories above the limit.\n")
    print(f"Thresholds: percentiles of non-relevant cosines on raw EN tasks: vault p{vault_pct:.1f} (where bge's 0.50 sits), retrieval p{retrieval_pct}.\n")
    print("| Model | Model id | Dims | Vault / retrieval threshold (raw cosine) | Query ms p50 | Runtime |")
    print("|---|---|---|---|---|---|")
    for name in ["bge-small"] + names:
        m = metas[name]
        print(f"| {name} | {m['model']} | {m['dims']} | {vault_thresholds[name]:.2f} / {thresholds[name]:.2f} | {m['query_ms_p50']:.1f} | {m['runtime']} |")
    print()

    summary = {}
    for corpus, qset in scenarios:
        print(f"## {labels[(corpus, qset)]}\n")
        print("| Method | R@5 | R@30 | MRR | R@5 bge-only labels |")
        print("|---|---|---|---|---|")
        rows = [("fts5-porter", run(corpus, qset, "keyword")), ("bge-small hybrid (today)", run(corpus, qset, "hybrid"))]
        for name in names:
            rows += [(f"{name} alone", run(corpus, qset, "alone", name)),
                     (f"{name} hybrid", run(corpus, qset, "hybrid", name)),
                     (f"{name} dual@limit", run(corpus, qset, "dual@limit", name)),
                     (f"{name} dual-b@limit", run(corpus, qset, "dual-b@limit", name)),
                     (f"{name} dualz@limit", run(corpus, qset, "dualz@limit", name)),
                     (f"{name} dualq@limit", run(corpus, qset, "dualq@limit", name)),
                     (f"{name} ens@all", run(corpus, qset, "ens@all", name)),
                     (f"{name} ens@limit", run(corpus, qset, "ens@limit", name))]
        for label, m in rows:
            print(f"| {label} | {f(m['r5'])} | {f(m['r30'])} | {f(m['mrr'])} | {f(m['sub'])} |")
            summary[(label, corpus, qset)] = m
        print()

    print("## Summary: R@5 (R@5 on bge-only labels)\n")
    print("| Method | " + " | ".join(labels[s] for s in scenarios) + " |")
    print("|---|" + "---|" * len(scenarios))
    for label in ["fts5-porter", "bge-small hybrid (today)"] + [f"{nm} {m}" for nm in names for m in ("hybrid", "dual@limit", "dualz@limit", "dualq@limit", "ens@all", "ens@limit")]:
        print(f"| {label} | " + " | ".join(f"{summary[(label, c, q)]['r5']:.2f} ({summary[(label, c, q)]['sub']:.2f})" for c, q in scenarios) + " |")


if __name__ == "__main__":
    cmd, *args = sys.argv[1:]
    {"embed": embed, "score": score, "tokens": lambda _: tokens()}[cmd](args)
