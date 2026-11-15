#!/usr/bin/env python3
"""Spike H, the author's vault: a People backfill on a private copy of the vault (§15), oldest memory first, with one
engine. Everything that holds memory text or names (the copy, the results, the review verdicts) stays in the private
folder given on the command line, never in the repo; this script prints counts only.

    python3 vault_run.py <private dir> [--provider claude-opus] [--limit N]
    python3 vault_run.py <out dir> --vault-json fixtures/search-vault.json --aliases Sam [--tag T]   (invented fixtures)

Reads <dir>/vault-copy.sqlite (a read-only backup of the live vault). Sends only memories within the vault's cloud
limit (read from the app's settings), as the feature would (§13). The user's own names come from About You and are
replaced locally with "the user" (§13). Writes <dir>/backfill[-tag].json and <dir>/backfill[-tag]-log.jsonl.
"""
import argparse
import json
import re
import plistlib
import sqlite3
import subprocess
import time
from pathlib import Path

from people import SCHEMA, State, fold, apply, build_prompt, needs_reconcile, resolve_all, role_phrases, user_text, validate
from providers import PROVIDERS

LEVELS = ["public", "low", "internal", "sensitive", "restricted", "secret"]


def cloud_limit():
    raw = subprocess.run(["defaults", "export", "com.funesvault.mac", "-"], capture_output=True).stdout
    s = plistlib.loads(raw).get("AIModels")
    lim = json.loads(s).get("cloudLimit") if s else None
    if not lim or "never" in lim:
        return -1
    return LEVELS.index(lim["upTo"]["_0"])


def load_json(path, limit, aliases):
    """An invented fixture vault (Spike G's format); the cloud limit is Spike G's default, Internal."""
    mems, skipped = [], []
    for m in sorted(json.loads(Path(path).read_text())["memories"], key=lambda m: (m["createdAt"], m["id"])):
        if LEVELS.index(m["sensitivity"]) > limit:
            skipped.append({"id": m["id"], "text": m["body"], "written": m["createdAt"], "trust": m["trust"],
                            "source": "agent" if m["source"].startswith("agent") else "capture"})
            continue
        agent = m["source"].startswith("agent")
        mems.append({"id": m["id"], "text": m["body"], "written": m["createdAt"], "source": "agent" if agent else "capture",
                     "perspective": "agent" if agent else "capture", "trust": m["trust"], "vault_source": m["source"]})
    return mems, aliases, skipped


def load(db, limit):
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True).cursor()
    prof = c.execute("select given_name, family_name, preferred_name from profile").fetchone() or (None, None, None)
    given, family, preferred = prof
    first = preferred or given
    aliases = [a for a in {first, family, f"{first} {family}" if first and family else None} if a]
    rows = c.execute("select id, body, created_at, source, trust, sensitivity from memory where status='active' "
                     "order by created_at").fetchall()
    mems, skipped = [], []
    for mid, body, created, source, trust, sens in rows:
        if sens > limit:
            skipped.append({"id": mid, "text": body, "written": created[:10], "trust": trust,
                            "source": "agent" if source.startswith("agent") else "capture"})
            continue
        mems.append({"id": mid, "text": body, "written": created[:10],
                     "source": "agent" if source.startswith("agent") else "capture",
                     "perspective": "agent" if source.startswith("agent") else ("rewritten" if source == "tidy_up" else "capture"),
                     "trust": trust, "vault_source": source})
    return mems, aliases, skipped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--provider", default="claude-opus")
    ap.add_argument("--limit", type=int, default=0, help="only the first N memories (a trial)")
    ap.add_argument("--tag", default="", help="suffix for the output files (backfill-<tag>.json)")
    ap.add_argument("--vault-json", default="", help="an invented fixture vault instead of <dir>/vault-copy.sqlite")
    ap.add_argument("--aliases", default="", help="with --vault-json: the user's names, comma-separated")
    ap.add_argument("--people-limit", default="internal", help="with --vault-json: the People call's cloud limit (round 3's "
                    "privacy case reads up to sensitive while answers stay at internal)")
    a = ap.parse_args()
    d = Path(a.dir)
    d.mkdir(parents=True, exist_ok=True)
    if a.vault_json:
        limit = LEVELS.index(a.people_limit)
        mems, aliases, skipped = load_json(a.vault_json, limit, [x for x in a.aliases.split(",") if x])
    else:
        limit = cloud_limit()
        mems, aliases, skipped = load(d / "vault-copy.sqlite", limit)
    if a.limit:
        mems = mems[:a.limit]
    print(f"cloud limit: {LEVELS[limit] if limit >= 0 else 'never'}; memories to read: {len(mems)}; above the limit: {len(skipped)}; "
          f"user aliases: {len(aliases)}", flush=True)
    provider = PROVIDERS[a.provider]()
    state = State(aliases)
    state.filter_roster = True
    sfx = f"-{a.tag}" if a.tag else ""
    log = (d / f"backfill{sfx}-log.jsonl").open("w")
    t0, n_calls, fails, cost = time.time(), 0, 0, 0.0

    def call(mem, mode):
        nonlocal n_calls, fails, cost
        phrases = role_phrases(mem["text"], aliases)
        ins, prompt, ids = build_prompt(state, mem, phrases)
        r = provider.generate(ins, prompt, SCHEMA)
        if not r.get("ok"):
            r = provider.generate(ins, prompt, SCHEMA)
        n_calls += 1
        cost += r.get("costUSD") or 0
        rec = {"memory": mem["id"], "mode": mode, "ok": r.get("ok"), "ms": r.get("ms"), "promptTokens": r.get("promptTokens"),
               "outputTokens": r.get("outputTokens"), "costUSD": r.get("costUSD"), "errorKind": r.get("errorKind")}
        if r.get("ok"):
            people, rels, roles, things, dropped = validate(r["content"], mem, ids, phrases, state)
            apply(state, mem, phrases, people, rels, roles, ids, things, mode=mode)
            rec["dropped"] = [x[0] for x in dropped]
        else:
            fails += 1
        log.write(json.dumps(rec) + "\n")
        log.flush()

    for i, m in enumerate(mems):
        mem = dict(m, sent=user_text(m["text"], aliases))
        state.memories[mem["id"]] = mem
        call(mem, "full")
        for rid, mode in needs_reconcile(state):
            if rid != mem["id"]:
                call(state.memories[rid], mode)
        if (i + 1) % 25 == 0:
            print(f"{i + 1}/{len(mems)} memories, {n_calls} calls, {fails} failed, ${cost:.2f}, {time.time() - t0:.0f} s", flush=True)
    # Memories above the cloud limit: never sent, never in a roster. Code links them after every model call (§6): role
    # phrases through known relations (resolve_all), and names only for aliases of at least two words.
    for m in skipped:
        state.memories[m["id"]] = dict(m, sent=None, unread=True, perspective="capture")
        low = fold(m["text"])
        for p in state.people.values():
            for al in p.aliases:
                if len(al.split()) >= 2 and re.search(r"(?<!\w)" + re.escape(fold(al)) + r"(?!\w)", low):
                    state.names[(m["id"], al)] = (p.id, "named" if m["trust"] == "trusted" else "untrusted", [])
    out = {
        "provider": a.provider, "unread": len(skipped), "memories": len(mems), "calls": n_calls, "failed": fails, "costUSD": cost,
        "seconds": round(time.time() - t0), "links": resolve_all(state),
        "people": [{"id": p.id, "name": p.name, "aliases": sorted(p.aliases), "group": p.group, "count": p.count}
                   for p in state.people.values()],
        "relations": [{"person": r.person, "type": r.type, "label": r.label, "cls": r.cls, "status": r.status,
                       "valid_from": r.valid_from, "valid_to": r.valid_to, "deceased": r.deceased, "only": r.only,
                       "negated": r.negated, "trusted": r.trusted, "evidence": [e[0] for e in r.evidence],
                       "stating": r.stating, "start_stated": r.start_stated}
                      for r in state.relations],
        "things": [{"name": n, "kind": k} for n, k in state.things.values()],
    }
    (d / f"backfill{sfx}.json").write_text(json.dumps(out, ensure_ascii=False))
    (d / f"backfill{sfx}.json").chmod(0o600)
    links = out["links"]
    from collections import Counter
    print("done:", {"memories": len(mems), "calls": n_calls, "failed": fails, "cost": round(cost, 2), "seconds": out["seconds"],
                    "people": sum(1 for p in out["people"] if p["name"]), "role groups": sum(1 for p in out["people"] if not p["name"]),
                    "relations": sum(1 for r in out["relations"] if not r["negated"]), "things": len(out["things"]),
                    "role links": dict(Counter(l["basis"] for l in links if l["kind"] == "role")),
                    "name links": dict(Counter(l["basis"] for l in links if l["kind"] == "name"))}, flush=True)


if __name__ == "__main__":
    main()
