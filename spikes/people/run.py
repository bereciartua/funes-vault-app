#!/usr/bin/env python3
"""Spike H runner: plays each story's memories in order through the People pipeline (people.py) with one provider,
then records the final state: every role and name link with its basis, the people, relations and decisions.
After each memory, memories whose role phrases gained a second candidate are sent again (reconciliation, roles only),
and memories whose bare names now fit several people, or named what turned out to be a thing, are asked again (names).
Results go to results/<provider>/<set>.jsonl, one line per story and order; a rerun skips what's there.

    python3 run.py <provider> [--set main|astra] [--run N] [--workers N] [--only s01,s02] [--orders natural|all] [--dry]

`--run 2` writes results/<provider>/<set>-run2.jsonl (a second, independent run); `--workers` plays stories in
parallel (each story stays sequential).
"""
import argparse
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from people import State, apply, build_prompt, needs_reconcile, resolve_all, role_phrases, user_text, validate
from providers import PROVIDERS

HERE = Path(__file__).resolve().parent


def load(set_name):
    suffix = "" if set_name == "main" else f"-{set_name}"
    return json.loads((HERE / f"fixtures/stories{suffix}.json").read_text())


def call(provider, state, mem, phrases, calls, mode="full"):
    instructions, prompt, ids = build_prompt(state, mem, phrases)
    r = provider.generate(instructions, prompt, SCHEMA_FOR_CALLS)
    rec = {"memory": mem["id"], "reconcile": mode != "full", "mode": mode, "ok": r.get("ok"), "ms": r.get("ms"),
           "promptTokens": r.get("promptTokens"), "outputTokens": r.get("outputTokens"), "errorKind": r.get("errorKind"), "costUSD": r.get("costUSD")}
    if not r.get("ok"):
        r = provider.generate(instructions, prompt, SCHEMA_FOR_CALLS)   # one retry, as §9.6
        rec.update(retried=True, ok=r.get("ok"), errorKind=r.get("errorKind"))
    if r.get("ok"):
        people, rels, roles, things, dropped = validate(r["content"], mem, ids, phrases, state)
        apply(state, mem, phrases, people, rels, roles, ids, things, mode=mode)
        rec.update(raw=r["content"], dropped=dropped)
    calls.append(rec)


def play(provider, story, order, user_aliases):
    state = State(user_aliases)
    mems = {m["id"]: m for m in story["memories"]}
    calls = []
    for mid in order:
        mem = dict(mems[mid])
        mem["sent"] = user_text(mem["text"], user_aliases)
        state.memories[mid] = mem
        phrases = role_phrases(mem["text"], user_aliases)
        call(provider, state, mem, phrases, calls)
        for rid, mode in needs_reconcile(state):
            if rid == mid:
                continue
            m2 = state.memories[rid]
            call(provider, state, m2, role_phrases(m2["text"], user_aliases), calls, mode=mode)
    return {
        "links": resolve_all(state),
        "people": [{"id": p.id, "name": p.name, "aliases": sorted(p.aliases), "group": p.group, "count": p.count}
                   for p in state.people.values()],
        "relations": [{"person": r.person, "type": r.type, "label": r.label, "cls": r.cls, "status": r.status,
                       "valid_from": r.valid_from, "valid_to": r.valid_to, "deceased": r.deceased, "only": r.only,
                       "negated": r.negated, "trusted": r.trusted, "evidence": [e[0] for e in r.evidence]} for r in state.relations],
        "decisions": [{"memory": k[0], "start": k[1], "person": v[0], "basis": v[1]} for k, v in state.decisions.items()],
        "things": [{"name": n, "kind": k} for n, k in state.things.values()],
        "calls": calls,
    }


SCHEMA_FOR_CALLS = None


def main():
    global SCHEMA_FOR_CALLS
    from people import SCHEMA
    SCHEMA_FOR_CALLS = SCHEMA
    ap = argparse.ArgumentParser()
    ap.add_argument("provider", choices=sorted(PROVIDERS))
    ap.add_argument("--set", default="main")
    ap.add_argument("--only", default="")
    ap.add_argument("--orders", default="all", choices=["natural", "all"])
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--workers", type=int, default=1)
    a = ap.parse_args()
    data = load(a.set)
    ua = data["user"]["aliases"]
    stories = data["stories"]
    if a.only:
        wanted = set(a.only.split(","))
        stories = [s for s in stories if s["id"] in wanted]
    if a.dry:
        s = stories[0]
        state = State(ua)
        mem = dict(s["memories"][0], sent=user_text(s["memories"][0]["text"], ua))
        state.memories[mem["id"]] = mem
        ins, prompt, _ = build_prompt(state, mem, role_phrases(mem["text"], ua))
        print(ins, "\n---\n", prompt)
        return
    out_dir = HERE / "results" / a.provider
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / (f"{a.set}.jsonl" if a.run == 1 else f"{a.set}-run{a.run}.jsonl")
    done = set()
    if path.exists():
        done = {(json.loads(l)["story"], json.loads(l)["orderIndex"]) for l in path.read_text().splitlines() if l.strip()}
    provider = PROVIDERS[a.provider]()
    jobs = []
    for s in stories:
        orders = [[m["id"] for m in s["memories"]]] + (s["orders"] if a.orders == "all" else [])
        jobs += [(s, i, order) for i, order in enumerate(orders) if (s["id"], i) not in done]
    lock = threading.Lock()

    def work(job):
        s, i, order = job
        t0 = time.time()
        res = play(provider, s, order, ua)
        res.update(story=s["id"], orderIndex=i, order=order, provider=a.provider, run=a.run,
                   seconds=round(time.time() - t0, 1))
        with lock, path.open("a") as f:
            f.write(json.dumps(res, ensure_ascii=False) + "\n")
        n, fails = len(res["calls"]), sum(1 for c in res["calls"] if not c["ok"])
        print(f"{a.provider} run {a.run} {s['id']} order {i}: {n} calls, {fails} failed, {res['seconds']} s", flush=True)

    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        list(ex.map(work, jobs))

if __name__ == "__main__":
    main()
