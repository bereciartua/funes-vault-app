#!/usr/bin/env python3
"""Spike E harness: runs memory processing §5.3/§5.5/§9.3 against a provider and stores raw results.

  python3 run.py <provider> <experiment> [--only in01,in02] [--jobs N] [--chunk 2000] [--tag name]

Providers: apple, apple-permissive, ollama, codex (GPT-6-Luna), codex-terra (GPT-5.6-Terra). Experiments:
  extract          extraction with the input's prompt variant (two-call path, step 1)
  extract-swapped  extraction with the other variant (question 5)
  decide           one decision call per input on `extract`'s validated pieces (two-call path, step 2)
  onecall          extraction and linking in one call per chunk
  tidy             one call per tidy-up cluster
  tidy-v2          the same with the second tidy-up prompt (archive superseded copies instead of rewriting them)
Results: results/<provider>/<experiment>[-<tag>].jsonl, one line per input or cluster; reruns skip done ids.
"""
import argparse
import json
import re
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import prompts
from finder import Embeddings, Finder
from providers import make
from validate import scan_secrets, validate_actions, validate_pieces

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"
SEED_QUESTIONS = {
    "collaboration_style": "How do you like AI assistants to collaborate with you?",
    "communication_preferences": "What tone, level of detail, or format do you usually prefer?",
    "software_development_preferences": "What should coding assistants know about how you build software?",
    "current_projects": "Which current projects should your vault remember, and why do they matter?",
    "life_constraints": "Are there practical constraints that often shape your work or availability?",
    "long_term_goals": "What long-term goals should assistants keep in mind when helping you?",
}
# Decision-call batch size per provider: Apple's 4k window and Ollama's 8k context can't take every piece of a
# long input with 5 related memories each.
DECISION_BATCH = {"apple": 3, "ollama": 4, "codex": 100}
MAX_PIECES_PER_INPUT = 40


def load():
    inputs = json.loads((FIX / "inputs.json").read_text())["inputs"]
    vault = json.loads((FIX / "vault.json").read_text())["memories"]
    clusters = json.loads((FIX / "clusters.json").read_text())["clusters"]
    return inputs, vault, clusters


def chunks(text, size):
    """Cut on paragraph, then sentence boundaries into pieces of at most ~size characters."""
    if len(text) <= size:
        return [text]
    units = []
    for para in re.split(r"\n\s*\n", text):
        units.extend(s for s in re.split(r"(?<=[.!?])\s+", para.strip()) if s)
        units.append("\n\n")
    out, cur = [], ""
    for u in units:
        if u == "\n\n":
            cur = cur.rstrip() + "\n\n" if cur else cur
            continue
        if cur and len(cur) + len(u) + 1 > size:
            out.append(cur.strip())
            cur = ""
        cur += (" " if cur and not cur.endswith("\n") else "") + u
    if cur.strip():
        out.append(cur.strip())
    return out


def sentences(text):
    return [s for s in re.split(r"(?<=[.!?;])\s+|\n+", text) if len(s.strip()) > 3]


def hint_of(inp):
    h = inp.get("hint")
    if not h:
        return None
    return {"question": SEED_QUESTIONS[h["seedId"]], "kind": h["kind"], "category": h["category"]}


def rebuild(rec, inp, with_link=False):
    """Validates an extraction record's raw model output (§5.4) into rec["pieces"] and rec["dropped"]. Also used by
    score.py, so a validation change applies to stored results without new calls."""
    raw = []
    for call in rec.get("calls") or []:
        if call.get("ok"):
            for p in (call.get("raw") or {}).get("pieces") or []:
                p = dict(p)
                p["chunk"] = call["chunk"]
                raw.append(p)
    hint = (inp.get("hint") or {}).get("sensitivity")
    declared = inp.get("declaredSensitivity")
    kept, dropped = validate_pieces(raw, inp["text"], hint, declared)
    _, dropped_lenient = validate_pieces(raw, inp["text"], hint, declared, evidence_mode="lenient")
    rec["evidenceLenientKept"] = len(raw) - len(dropped_lenient)
    rec.pop("truncatedPieces", None)
    if len(kept) > MAX_PIECES_PER_INPUT:
        rec["truncatedPieces"] = len(kept) - MAX_PIECES_PER_INPUT
        kept = kept[:MAX_PIECES_PER_INPUT]
    if with_link:
        for p in kept:
            cand = rec["calls"][p["chunk"]].get("candidates") or []
            p["linkValid"] = True
            if p.get("action") not in ("create", "update", "duplicate", "retract"):
                p["action"], p["linkValid"] = "create", False
            if p["action"] != "create" and p.get("target") not in cand:
                p["action"], p["linkValid"] = "create", False
    rec["pieces"], rec["dropped"] = kept, dropped


class Runner:
    def __init__(self, provider_name, experiment, chunk_size, context_chars, tag):
        self.provider_name = provider_name
        base = provider_name.split("-")[0]
        self.base = base
        kw = {"apple-permissive": {"guardrails": "permissive"}, "codex-terra": {"model": "gpt-5.6-terra"}}.get(provider_name, {})
        self.p = make(base, **kw)
        self.experiment = experiment
        self.chunk_size = chunk_size
        self.context_chars = context_chars
        self.out_dir = HERE / "results" / provider_name
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.out = self.out_dir / f"{experiment}{'-' + tag if tag else ''}.jsonl"
        self.done = {json.loads(l)["id"] for l in self.out.read_text().splitlines()} if self.out.exists() else set()
        self.lock = threading.Lock()
        self.inputs, self.vault, self.clusters = load()
        self._finder = None

    @property
    def finder(self):
        if self._finder is None:
            self._finder = Finder(self.vault, Embeddings())
        return self._finder

    def save(self, rec):
        with self.lock:
            with self.out.open("a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def floors(self, inp):
        hint = (inp.get("hint") or {}).get("sensitivity")
        return hint, inp.get("declaredSensitivity")

    # --- extraction ---------------------------------------------------------------------------------
    def extract(self, inp, variant, with_link=False):
        rec = {"id": inp["id"], "variant": variant, "calls": []}
        secrets = scan_secrets(inp["text"])
        if secrets:
            rec["rejected"] = secrets
            return rec
        cs = chunks(inp["text"], self.chunk_size)
        for ci, c in enumerate(cs):
            ctx = cs[ci - 1][-self.context_chars:] if ci > 0 and self.context_chars else None
            if with_link:
                cand = self.onecall_candidates(c)
                ins = prompts.one_call_instructions(variant)
                pr = prompts.one_call_prompt(c, [self.finder.by_id[m] for m in cand], ctx, hint_of(inp))
            else:
                cand = None
                ins = prompts.extraction_instructions(variant)
                pr = prompts.extraction_prompt(c, ctx, hint_of(inp))
            r = self.p.generate(ins, pr, prompts.extraction_schema(with_link))
            call = {k: r.get(k) for k in ("ok", "errorKind", "error", "promptTokens", "outputTokens", "reasoningTokens",
                                          "schemaTokens", "ms", "truncated") if r.get(k) is not None}
            call["chunk"] = ci
            call["chunkChars"] = len(c)
            if cand is not None:
                call["candidates"] = cand
            call["raw"] = r.get("content")
            rec["calls"].append(call)
        rebuild(rec, inp, with_link)
        return rec

    def onecall_candidates(self, chunk):
        best = {}
        for s in sentences(chunk):
            ids, cos, kw = self.finder.find("", "fact", [], s, k=3)
            for m in ids:
                score = 0.7 * cos[m] + 0.3 * kw.get(m, 0)
                best[m] = max(best.get(m, 0), score)
        return [m for m, _ in sorted(best.items(), key=lambda x: -x[1])[:15]]

    # --- decision ------------------------------------------------------------------------------------
    def decide(self, inp, ext):
        rec = {"id": inp["id"], "calls": [], "decisions": []}
        pieces = ext.get("pieces") or []
        if not pieces:
            return rec
        cands = {}
        for i, p in enumerate(pieces):
            ids, _, _ = self.finder.find(p.get("title", ""), p.get("kind", "fact"), p.get("categoryKeys", []), p["body"])
            cands[i] = ids
        rec["candidates"] = cands
        batch = DECISION_BATCH[self.base]
        idx = list(range(len(pieces)))
        got = {}
        for b in range(0, len(idx), batch):
            part = [(i, pieces[i]) for i in idx[b:b + batch]]
            pr = prompts.decision_prompt(part, {i: [self.finder.by_id[m] for m in cands[i]] for i, _ in part})
            r = self.p.generate(prompts.DECISION_RULES, pr, prompts.decision_schema())
            call = {k: r.get(k) for k in ("ok", "errorKind", "error", "promptTokens", "outputTokens", "reasoningTokens",
                                          "ms", "truncated") if r.get(k) is not None}
            call["pieces"] = [i for i, _ in part]
            call["raw"] = r.get("content")
            rec["calls"].append(call)
            if r.get("ok"):
                for d in (r["content"] or {}).get("decisions") or []:
                    if isinstance(d.get("piece"), int) and d["piece"] in cands and d["piece"] not in got:
                        got[d["piece"]] = d
        for i in idx:
            d = dict(got.get(i) or {"action": "create", "target": "", "missing": True})
            d["piece"] = i
            d["valid"] = True
            if d.get("action") not in ("create", "update", "duplicate", "retract"):
                d["action"], d["valid"] = "create", False
            if d["action"] != "create" and d.get("target") not in cands[i]:
                d["action"], d["valid"] = "create", False
            rec["decisions"].append(d)
        return rec

    # --- tidy-up ---------------------------------------------------------------------------------------
    def tidy(self, cl):
        rules = prompts.TIDY_RULES_V2 if self.experiment == "tidy-v2" else prompts.TIDY_RULES
        r = self.p.generate(rules, prompts.tidy_prompt(cl["memories"]), prompts.tidy_schema())
        call = {k: r.get(k) for k in ("ok", "errorKind", "error", "promptTokens", "outputTokens", "reasoningTokens",
                                      "ms") if r.get(k) is not None}
        rec = {"id": cl["id"], "calls": [call], "raw": r.get("content")}
        if r.get("ok"):
            kept, blocked = validate_actions((r["content"] or {}).get("actions"), cl)
            rec["actions"], rec["blocked"] = kept, blocked
        return rec

    def run(self, only, jobs):
        if self.experiment in ("tidy", "tidy-v2"):
            items = [c for c in self.clusters if c["id"] not in self.done and (not only or c["id"] in only)]
            work = self.tidy
        else:
            items = [i for i in self.inputs if i["id"] not in self.done and (not only or i["id"] in only)]
            if self.experiment == "extract":
                work = lambda i: self.extract(i, i["variant"])
            elif self.experiment == "extract-swapped":
                other = {"first_person": "about_user", "about_user": "first_person"}
                work = lambda i: self.extract(i, other[i["variant"]])
            elif self.experiment == "onecall":
                work = lambda i: self.extract(i, i["variant"], with_link=True)
            elif self.experiment == "decide":
                ext_path = self.out_dir / "extract.jsonl"
                ext = {json.loads(l)["id"]: json.loads(l) for l in ext_path.read_text().splitlines()}
                items = [i for i in items if i["id"] in ext]
                work = lambda i: self.decide(i, ext[i["id"]])
            else:
                sys.exit(f"unknown experiment {self.experiment}")
        print(f"{self.provider_name} {self.experiment}: {len(items)} to run", flush=True)
        if self.experiment == "decide" or self.experiment == "onecall":
            self.finder  # build once before threads

        def one(item):
            rec = work(item)
            rec["chunkSize"] = self.chunk_size
            self.save(rec)
            calls = rec.get("calls") or []
            bad = [c.get("errorKind") for c in calls if not c.get("ok")]
            print(f"  {item['id']}: {len(calls)} calls{' FAILED ' + str(bad) if bad else ''}", flush=True)

        if jobs > 1:
            with ThreadPoolExecutor(jobs) as ex:
                list(ex.map(one, items))
        else:
            for it in items:
                one(it)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("provider")
    ap.add_argument("experiment")
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--chunk", type=int, default=2000)
    ap.add_argument("--context", type=int, default=2000, help="characters of the previous chunk given as context")
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    Runner(a.provider, a.experiment, a.chunk, a.context, a.tag).run(only, a.jobs)


if __name__ == "__main__":
    main()
