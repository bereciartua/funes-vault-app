#!/usr/bin/env python3
"""Spike H3 runner: plays memories through facts.py (one implementation over registry.json) with a call-group setup.

    python3 run_facts.py stories <provider> --set main|astra|mixed [--groups people|separate|merged] [--run N] [--workers N] [--tag T]
    python3 run_facts.py work    <provider> <vault.json> <out-state.json> [--groups work|separate|merged] [--aliases Sam] [--limit internal]

`--groups people` (or work) calls only that registry call group; `separate` calls every group, one call each;
`merged` makes one call with every recorded predicate. Story results go to results-h3/<provider>-<groups><tag>/<set>.jsonl in
run.py's format (person entities, person facts as relations, person links), so score.py scores them unchanged.
`work` writes the final state (entities, facts with assertions) for timeline scoring (score_facts.py).
"""
import argparse
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import facts as F
from providers import PROVIDERS

HERE = Path(__file__).resolve().parent
LEVELS = ["public", "low", "internal", "sensitive", "restricted", "secret"]


def groups_for(mode):
    if mode in ("separate", "merged"):
        return F.R.group_names(mode)
    return [mode]


def call(provider, state, mem, group, calls, mode="full"):
    preds = F.R.group_preds(group)
    phrases = F.role_phrases(mem["text"], state.user_aliases, preds=set(preds))
    ins, prompt, ids = F.build_prompt(state, mem, phrases, group)
    sch = F.schema(group)
    r = provider.generate(ins, prompt, sch)
    rec = {"memory": mem["id"], "group": group, "mode": mode, "reconcile": mode != "full", "ok": r.get("ok"), "ms": r.get("ms"),
           "promptTokens": r.get("promptTokens"), "outputTokens": r.get("outputTokens"), "costUSD": r.get("costUSD")}
    if not r.get("ok"):
        r = provider.generate(ins, prompt, sch)
        rec.update(retried=True, ok=r.get("ok"))
    if r.get("ok"):
        people, rels, roles, things, dropped = F.validate(r["content"], mem, ids, phrases, state, preds)
        F.apply(state, mem, phrases, people, rels, roles, ids, things, mode=mode)
        rec.update(raw=r["content"], dropped=dropped)
    calls.append(rec)


def play(provider, mems_in_order, user_aliases, groups):
    state = F.State(user_aliases)
    calls = []
    for mem0 in mems_in_order:
        mem = dict(mem0)
        mem["sent"] = F.user_text(mem["text"], user_aliases)
        state.memories[mem["id"]] = mem
        for g in groups:
            call(provider, state, mem, g, calls)
        for rid, mode in F.needs_reconcile(state):
            if rid == mem["id"]:
                continue
            m2 = state.memories[rid]
            for g in groups:
                preds = set(F.R.group_preds(g))
                has_people = any(F.R.kind_of(p) == "person" for p in preds)
                phr = F.role_phrases(m2["text"], user_aliases, preds=preds)
                if (mode == "names" and has_people) or (mode == "roles" and phr):
                    call(provider, state, m2, g, calls, mode=mode)
    return state, calls


def span(f):
    """A fact's latest episode, for the dumps (nothing reads these back)."""
    from datetime import date
    eps = F.fact_episodes(f)
    e = eps[-1] if eps else None
    iso = lambda d: date.fromordinal(d).isoformat() if d and d not in (F.MIN_DAY, F.MAX_DAY) else None
    return {"valid_from": iso(e.start.lo) if e and e.start else None, "valid_to": iso(e.end.hi) if e and e.end else None}


def dump_people(state, calls):
    person = {k for k, e in state.entities.items() if e.kind == "person"}
    return {
        "links": [l for l in F.resolve_all(state, kinds={"person"})],
        "people": [{"id": p.id, "name": p.name, "aliases": sorted(p.aliases), "group": p.group, "count": p.count}
                   for p in state.entities.values() if p.kind == "person"],
        "relations": [{"person": r.entity, "type": r.type, "label": r.label, "cls": r.cls, "status": r.status,
                       **span(r), "deceased": state.entities[r.entity].deceased,
                       "only": r.only, "negated": r.negated, "trusted": r.trusted, "evidence": [e[0] for e in r.evidence]}
                      for r in state.facts if r.entity in person],
        "decisions": [{"memory": k[0], "start": k[1], "person": v[0], "basis": v[1]} for k, v in state.decisions.items()],
        "things": [{"name": n, "kind": k} for n, k in state.things.values()],
        "calls": calls,
    }


def dump_state(state, calls):
    return {
        "registry": F.R.version,
        "entities": [{"id": e.id, "kind": e.kind, "name": e.name, "aliases": sorted(e.aliases), "group": e.group,
                      "count": e.count, "deceased": e.deceased} for e in state.entities.values()],
        "facts": [{"entity": f.entity, "type": f.type, "label": f.label, "cls": f.cls, "status": f.status,
                   **span(f), "only": f.only, "negated": f.negated,
                   "evidence": f.evidence, "stating": f.stating, "assertions": f.assertions}
                  for f in state.facts],
        "names": [[k[0], k[1], v[0], v[1], v[2]] for k, v in state.names.items()],
        "decisions": [[k[0], k[1], v[0], v[1]] for k, v in state.decisions.items()],
        "things": list(state.things.values()),
        "user_aliases": list(state.user_aliases),
        "memories": {k: {"id": v["id"], "text": v["text"], "written": v["written"], "source": v["source"],
                         **({"trust": v["trust"]} if "trust" in v else {})} for k, v in state.memories.items()},
        "calls": [{k: c.get(k) for k in ("memory", "group", "mode", "ok", "ms", "promptTokens", "outputTokens", "costUSD", "dropped")} for c in calls],
    }


def load_state(d):
    s = F.State(d["user_aliases"])
    for e in d["entities"]:
        s.entities[e["id"]] = F.Entity(e["id"], e["kind"], e["name"], set(e["aliases"]), tuple(e["group"]) if e["group"] else None,
                                       e["count"], e["deceased"])
        if e["group"]:
            s.groups[tuple(e["group"])] = s.entities[e["id"]]
    for f in d["facts"]:
        s.facts.append(F.Fact(f["entity"], f["type"], f["label"], f["cls"], f["only"], [tuple(x) for x in f["evidence"]],
                              f["negated"], f["stating"], f["assertions"]))
    for mid, surface, pid, basis, c in d["names"]:
        s.names[(mid, surface)] = (pid, basis, c)
    for mid, st, pid, basis in d["decisions"]:
        s.decisions[(mid, st)] = (pid, basis)
    s.things = {F.fold(n): (n, k) for n, k in d["things"]}
    s.memories = d["memories"]
    s.n = max([int(e["id"][1:]) for e in d["entities"]] or [0])
    return s


def cmd_stories(a):
    suffix = "" if a.set == "main" else f"-{a.set}"
    data = json.loads((HERE / f"fixtures/stories{suffix}.json").read_text())
    ua = data["user"]["aliases"]
    groups = groups_for(a.groups)
    out_dir = HERE / "results-h3" / f"{a.provider}-{a.groups}{a.tag}"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / (f"{a.set}.jsonl" if a.run == 1 else f"{a.set}-run{a.run}.jsonl")
    done = {(json.loads(l)["story"], json.loads(l)["orderIndex"]) for l in path.read_text().splitlines() if l.strip()} if path.exists() else set()
    provider = PROVIDERS[a.provider]()
    jobs = []
    for s in data["stories"]:
        if a.only and s["id"] not in a.only.split(","):
            continue
        orders = [[m["id"] for m in s["memories"]]] + (s.get("orders", []) if a.orders == "all" else [])
        jobs += [(s, i, o) for i, o in enumerate(orders) if (s["id"], i) not in done]
    lock = threading.Lock()

    def work(job):
        s, i, order = job
        t0 = time.time()
        mems = {m["id"]: m for m in s["memories"]}
        state, calls = play(provider, [mems[m] for m in order], ua, groups)
        res = dump_people(state, calls)
        res.update(story=s["id"], orderIndex=i, order=order, provider=a.provider, run=a.run, groups=a.groups,
                   registry=F.R.version, seconds=round(time.time() - t0, 1))
        if a.keep_state:
            res["state"] = dump_state(state, [])
        with lock, path.open("a") as f:
            f.write(json.dumps(res, ensure_ascii=False) + "\n")
        print(f"{a.provider} {a.groups} run {a.run} {s['id']} order {i}: {len(calls)} calls, "
              f"{sum(1 for c in calls if not c['ok'])} failed, {res['seconds']} s", flush=True)

    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        list(ex.map(work, jobs))


def vault_memories(path, limit):
    mems = json.loads(Path(path).read_text())["memories"]
    lim = LEVELS.index(limit)
    out = []
    for m in sorted(mems, key=lambda m: (m["createdAt"], m["id"])):
        if LEVELS.index(m.get("sensitivity", "low")) > lim:
            continue
        src = {"manual": "capture", "agent": "agent", "import": "import"}.get(m.get("source"), "capture")
        out.append({"id": m["id"], "text": m["title"] + "\n" + m["body"], "written": m["createdAt"][:10], "source": src,
                    "trust": m.get("trust", "trusted")})
    return out


def cmd_work(a):
    groups = groups_for(a.groups)
    ua = [x for x in a.aliases.split(",") if x]
    mems = vault_memories(a.vault, a.limit)
    provider = PROVIDERS[a.provider]()
    t0 = time.time()
    state, calls = play(provider, mems, ua, groups)
    out = dump_state(state, calls)
    out.update(groups=a.groups, provider=a.provider, seconds=round(time.time() - t0, 1))
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False))
    print(f"memories {len(mems)}; calls {len(calls)} ({sum(not c['ok'] for c in calls)} failed); entities {len(state.entities)}; "
          f"facts {len(state.facts)}; cost ${sum(c.get('costUSD') or 0 for c in calls):.2f}; {out['seconds']} s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["stories", "work"])
    ap.add_argument("provider", choices=sorted(PROVIDERS))
    ap.add_argument("vault", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--set", default="main")
    ap.add_argument("--groups", default="people")
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--orders", default="all", choices=["natural", "all"])
    ap.add_argument("--only", default="")
    ap.add_argument("--tag", default="")
    ap.add_argument("--keep-state", action="store_true")
    ap.add_argument("--aliases", default="")
    ap.add_argument("--limit", default="internal")
    a = ap.parse_args()
    {"stories": cmd_stories, "work": cmd_work}[a.cmd](a)


if __name__ == "__main__":
    main()
