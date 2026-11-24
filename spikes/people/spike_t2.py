#!/usr/bin/env python3
"""Spike T, round 2 (drafts/facts-llm-first §10): the model answers, the time model checks.

Fresh held-out stories by GPT-6-Astra (`workr`, 12 stories, about half everyday notes), each searched together with 40
shared filler memories (fixtures/spike-t/distractors.json), top 10 by keyword (BM25), so retrieval matters. Stores: one
recorded live Haiku read of workr (run_facts.py, both call groups, replayed by the Swift harness), and its gold store.

Arms (Haiku and Terra answer; one sample each):
  A  plain: the top 10 search results only (today's app with Facts off).
  B  facts: the store's trusted work rows (episodes, dates, kinds, renames) + the top 10 + the memories the rows cite
     (at most 16 memories); the model answers and states the comparison it made, if any.
  Bc B checked: the comparison, as the canonical question the grammar reads (with round 1's three fixes: a stint field,
     normalised dates, and a second check on the store without agents' notes), goes through the time model:
       agrees -> the answer stands; can't tell -> "not sure", unless the store without agents' notes agrees (the answer
       stands, marked "an agent's note says otherwise"); disagrees -> dropped ("not sure"); no comparison -> unchecked.
  C  today: the grammar and time model on the live store, else arm A's answer.
  Bc on the gold store too (no calls), to separate extraction from the check.

    python3 spike_t2.py freeze | stores | run --engine haiku|terra [--dry] | check --engine ... | judge | score
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

os.environ.setdefault("SPIKE_T_DIR", str(Path(__file__).resolve().parents[2] / "build" / "spike-t2"))
import spike_t as T

HERE = T.HERE
ST = Path(os.environ["SPIKE_T_DIR"])
T.ST = ST
RES = HERE / "results-spike-t2"
SET = "workr"
TODAY = T.TODAY
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

# MARK: prompts (frozen: `freeze`) -----------------------------------------------------------------------------------

COMPARISON_RULE = """
- comparison: when your answer names which organization the user worked at or ran by comparing the user's jobs in time (the one before or after another, the one held at a date or between two dates, the current one, the previous one), fill it in: made true; operator (before, after, in, between, current, previous); anchor_org (for before/after an organization, its name as the work history rows write it); stint (first or second when the question means one stint of a job the user held twice, else any); anchor_date and end_date (for a date anchor, "in" or "between": normalised as YYYY, YYYY-MM or YYYY-MM-DD; a season or a vague span as "between" its months); kind (employee when the question asks about an employer or salaried job only, self_employed for the user's own business or freelance work only, else any); answer_org (the organization you answer). Otherwise made false and the other fields empty."""

COMPARISON = {"type": "object", "additionalProperties": False,
              "required": ["made", "operator", "anchor_org", "stint", "anchor_date", "end_date", "kind", "answer_org"],
              "properties": {"made": {"type": "boolean"},
                             "operator": {"type": "string", "enum": ["before", "after", "in", "between", "current", "previous", ""]},
                             "anchor_org": {"type": "string"}, "stint": {"type": "string", "enum": ["first", "second", "any", ""]},
                             "anchor_date": {"type": "string"}, "end_date": {"type": "string"},
                             "kind": {"type": "string", "enum": ["employee", "self_employed", "any", ""]}, "answer_org": {"type": "string"}}}
B_SCHEMA = json.loads(json.dumps(T.ANSWER_SCHEMA))
B_SCHEMA["properties"]["comparison"] = COMPARISON
B_SCHEMA["required"] = B_SCHEMA["required"] + ["comparison"]
A_INSTRUCTIONS = T.ANSWER_INSTRUCTIONS.replace("and the user's memories", "and the memories a search of the vault found for it")
B_INSTRUCTIONS = A_INSTRUCTIONS + T.ROWS_RULE + COMPARISON_RULE


def prompt_hash():
    return hashlib.sha256(json.dumps([A_INSTRUCTIONS, B_INSTRUCTIONS, T.ANSWER_SCHEMA, B_SCHEMA], sort_keys=True).encode()).hexdigest()


def date_words(d):
    m = re.fullmatch(r"(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", (d or "").strip())
    if not m:
        return d
    y, mo, da = m.groups()
    if da:
        return f"{int(da)} {MONTHS[int(mo) - 1]} {y}"
    return f"{MONTHS[int(mo) - 1]} {y}" if mo else y


def canonical(c):
    """The comparison as one wording the grammar reads (checked on work13's w01 and w07 before the freeze)."""
    if not c or not c.get("made") or not c.get("operator"):
        return ""
    op, k, stint, org = c["operator"], c.get("kind") or "any", c.get("stint") or "any", c.get("anchor_org", "")
    head = {"employee": ("Which employer did I work for", "Which employer do I work for now?", "What was my previous employer?"),
            "self_employed": ("Which freelance business did I run", "Which freelance business do I run now?",
                              "What was my previous freelance business?"),
            "any": ("Where did I work", "Where do I work now?", "What was my previous job?")}[k if k in ("employee", "self_employed") else "any"]
    if op == "current":
        return head[1]
    if op == "previous":
        return head[2]
    if op in ("before", "after") and org:
        if stint == "second":
            return f"{head[0]} {op} my second stint at {org}?"
        if stint == "first":
            return f"{head[0]} after leaving {org} the first time?" if op == "after" else f"{head[0]} before my first stint at {org}?"
        return f"{head[0]} {op} {org}?"
    if op in ("before", "after") and c.get("anchor_date"):
        return f"{head[0]} {op} {date_words(c['anchor_date'])}?"
    if op == "in" and c.get("anchor_date"):
        return f"{head[0]} in {date_words(c['anchor_date'])}?"
    if op == "between" and c.get("anchor_date") and c.get("end_date"):
        return f"{head[0]} between {date_words(c['anchor_date'])} and {date_words(c['end_date'])}?"
    return ""


# MARK: search -------------------------------------------------------------------------------------------------------

STOP = set("a an the of to in on at for and or is was were be i my me did do does what which who where when how it this that "
           "with from by as have had has am are el la los las de del en y o que mi me yo un una por para con es fue era".split())


def tokens(t):
    return [w for w in re.findall(r"[a-z0-9]+", T.fold(t)) if w not in STOP]


def vault(st):
    fx = T.fixture(SET)
    dis = json.loads((HERE / "fixtures" / "spike-t" / "distractors.json").read_text())["memories"]
    return [dict(m) for m in st["memories"]] + [{**m, "source": "capture", "filler": True} for m in dis]


def search(q, mems, k=10):
    docs = [tokens(m["text"]) for m in mems]
    n, avg = len(docs), sum(map(len, docs)) / max(1, len(docs))
    df = Counter(w for d in docs for w in set(d))
    qt = tokens(q)
    def score(d):
        tf = Counter(d)
        return sum(math.log(1 + (n - df[w] + 0.5) / (df[w] + 0.5)) * tf[w] * 2.2 / (tf[w] + 1.2 * (0.25 + 0.75 * len(d) / avg))
                   for w in qt if w in tf)
    ranked = sorted(range(n), key=lambda i: (-score(docs[i]), i))
    return [mems[i] for i in ranked[:k] if score(docs[i]) > 0] or [mems[i] for i in ranked[:k]]


def block(mems, aliases):
    who = {"capture": "the user", "agent": "an AI agent's note", "import": "a note the user imported"}
    return "\n".join(f'<memory id="{m["id"]}" written="{m["written"]}" by="{who.get(m.get("source"), "the user")}">\n'
                     f'{T.replace_user(m["text"], aliases)}\n</memory>' for m in mems)


# MARK: stores -------------------------------------------------------------------------------------------------------

def swift(store, tag, qfile, trusted_only=False):
    ex = ST / f"export-{store}-{SET}.jsonl"
    opts = [f"set={SET}", f"replay={ex}", *(["reader=1"] if store == "gold" else []), "orders=natural", f"queries={qfile}",
            f"out={ST / 'out'}", f"tag={tag}", *(["trusted_only=1"] if trusted_only else [])]
    subprocess.run(["rm", "-rf", str(ST / "out" / f"swift-replay-{tag}")])
    p = subprocess.run(["swift", "test", "--package-path", str(T.REPO / "Packages/FunesCore"), "--filter", "FactsHarnessTests/fullRun"],
                       env=dict(os.environ, FUNES_FACTS_HARNESS=";".join(opts)), capture_output=True, text=True)
    if p.returncode != 0 or "facts harness:" not in p.stdout:
        raise SystemExit(f"swift failed ({tag}): {p.stdout[-1500:]}{p.stderr[-400:]}")
    out, lines = {}, {}
    for line in (ST / "out" / f"swift-replay-{tag}" / f"{SET}.jsonl").read_text().splitlines():
        r = json.loads(line)
        if r["orderIndex"] == 0:
            lines[r["story"]] = r
            for qid, o in r["swift_judged"].items():
                out[(r["story"], qid)] = (o, r["swift_answers"].get(qid))
    return out, lines


def questions():
    return [(st["id"], q["id"], q) for st in T.fixture(SET)["stories"] for q in st.get("queries", [])]


def cmd_stores(a):
    """The live read (run_facts.py, Haiku, both groups) and the gold store, exported for the Swift replay; then the
    grammar (arm C) on the live store and the rows each arm B prompt reads."""
    live = HERE / "results-h3" / "claude-haiku-separate-r2" / f"{SET}.jsonl"
    if not live.exists():
        if not a.live:
            raise SystemExit("spike_t2: no live read yet (stores --live makes it: about 2 calls a memory, Haiku)")
        subprocess.run(["python3", "run_facts.py", "stories", "claude-haiku", "--set", SET, "--groups", "separate", "--orders", "natural",
                        "--tag=-r2", "--workers", "4"], cwd=HERE, check=True)
    subprocess.run(["python3", "export_replay.py", str(live), f"fixtures/stories-{SET}.json", str(ST / f"export-live-{SET}.jsonl")], cwd=HERE, check=True)
    subprocess.run(["python3", "gold_answers.py", "--set", SET, str(ST / f"gold-{SET}.jsonl")], cwd=HERE, check=True)
    subprocess.run(["python3", "export_replay.py", str(ST / f"gold-{SET}.jsonl"), f"fixtures/stories-{SET}.json", str(ST / f"export-gold-{SET}.jsonl")],
                   cwd=HERE, check=True)
    per = defaultdict(list)
    for sid, qid, q in questions():
        per[sid].append(q)
    qf = ST / "queries-original.json"
    qf.write_text(json.dumps(per, ensure_ascii=False))
    for store in ("live", "gold"):
        res, _ = swift(store, f"r2-{store}-grammar", qf)
        (ST / f"grammar-{store}.json").write_text(json.dumps({"|".join(k): v for k, v in res.items()}, ensure_ascii=False))
        print(f"{store} grammar: {dict(Counter(o for o, _ in res.values()))}")


def store_line(store, sid):
    for line in (ST / "out" / f"swift-replay-r2-{store}-grammar" / f"{SET}.jsonl").read_text().splitlines():
        r = json.loads(line)
        if r["story"] == sid and r["orderIndex"] == 0:
            return r


# MARK: model calls --------------------------------------------------------------------------------------------------

def requests():
    fx = T.fixture(SET)
    aliases = fx["user"]["aliases"]
    out = []
    for st in fx["stories"]:
        mems = vault(st)
        line = store_line("live", st["id"])
        rows = T.rows_block(line, aliases) if line else "(none)"
        cited = {m for e in (line or {}).get("state", {}).get("episodes", []) if e["predicate"] in ("works_at", "client") and e.get("trusted", True)
                 for m in e["memories"]}
        for q in st.get("queries", []):
            top = search(q["query"], mems)
            base = f"Today: {TODAY}\nQuestion: {q['query']}\n\n"
            out.append(((st["id"], q["id"], "A"), A_INSTRUCTIONS, base + block(top, aliases), T.ANSWER_SCHEMA))
            extra = [m for m in st["memories"] if m["id"] in cited and m["id"] not in {x["id"] for x in top}]
            given = (top + extra)[:16]
            out.append(((st["id"], q["id"], "B"), B_INSTRUCTIONS,
                        base + "<work_history>\n" + rows + "\n</work_history>\n\n" + block(given, aliases), B_SCHEMA))
    return out


def cmd_run(a):
    f = RES / "prompts.sha256"
    if not f.exists() or f.read_text().strip() != prompt_hash():
        raise SystemExit("spike_t2: prompts changed since `freeze`")
    reqs = requests()
    if a.dry:
        print(f"{a.engine}: {len(reqs)} requests, {sum(T.cached(a.engine, 'answer', i, p, s, 0, dry=True) is None for _, i, p, s in reqs)} not cached")
        return
    def one(r):
        key, ins, prompt, schema = r
        res = T.cached(a.engine, "answer", ins, prompt, schema, 0)
        return {"key": list(key), "ok": res.get("ok"), "content": res.get("content"), "ms": res.get("ms"), "error": res.get("error"), "prompt": prompt}
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex, (ST / f"records-{a.engine}.jsonl").open("a") as out:
        for rec in ex.map(one, reqs):
            out.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"{a.engine}: {len(reqs)} records")


def records(engine):
    out = {}
    p = ST / f"records-{engine}.jsonl"
    if p.exists():
        for line in p.read_text().splitlines():
            r = json.loads(line)
            out[tuple(r["key"])] = r
    return out


def cmd_check(a):
    """Arm B's comparisons through the time model, on the live and gold stores, with and without agents' notes."""
    recs = records(a.engine)
    per = defaultdict(list)
    canon = {}
    for sid, qid, q in questions():
        r = recs.get((sid, qid, "B"))
        if not r or not r["ok"]:
            continue
        text = canonical(r["content"].get("comparison"))
        canon[f"{sid}|{qid}"] = text
        per[sid].append({"id": qid, "kind": q["kind"], "answer_org": q.get("answer_org", ""), "query": text})
    qf = ST / f"queries-check-{a.engine}.json"
    qf.write_text(json.dumps(per, ensure_ascii=False))
    out = {"canonical": canon}
    for store in ("live", "gold"):
        for trusted in (False, True):
            res, lines = swift(store, f"r2-check-{a.engine}-{store}-{'trusted' if trusted else 'full'}", qf, trusted)
            out[f"{store}-{'trusted' if trusted else 'full'}"] = {"|".join(k): v for k, v in res.items()}
            print(f"{a.engine} {store} {'trusted' if trusted else 'full'}: {dict(Counter(o for o, _ in res.values()))}")
    (ST / f"check-{a.engine}.json").write_text(json.dumps(out, ensure_ascii=False))


# MARK: judging and scoring ------------------------------------------------------------------------------------------

def cmd_judge(a):
    fx = T.fixture(SET)
    jobs = []
    for engine in T.ENGINES:
        recs = records(engine)
        for st in fx["stories"]:
            for q in st.get("queries", []):
                if q["kind"] not in ("negative", "role_in_stint"):
                    continue
                for arm in ("A", "B"):
                    r = recs.get((st["id"], q["id"], arm))
                    if not r or not r["ok"] or r["content"]["status"] != "answer":
                        continue
                    sent = r["prompt"].split("\n\n", 1)[1]
                    prompt = sent + f"\n\nQuestion: {q['query']}\n\nAnswer: {r['content']['answer']}\n\nClaims: " + json.dumps(r["content"].get("claims", []), ensure_ascii=False)
                    jobs.append(("|".join([engine, st["id"], q["id"], arm]), prompt))
    out = {}
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for key, res in ex.map(lambda j: (j[0], T.cached("opus-judge", "judge", T.JUDGE_INSTRUCTIONS, j[1], T.JUDGE_SCHEMA, 0)), jobs):
            if res and res.get("ok"):
                out[key] = res["content"]
    (ST / "judge.json").write_text(json.dumps(out, ensure_ascii=False, indent=0))
    print(f"judge: {len(out)} of {len(jobs)}: {dict(Counter(v['verdict'] for v in out.values()))}")


def entity_matches(name, st, truth):
    return T.matches(name or "", T.org_aliases(st, truth))


def outcome(st, q, status, org, kind_neg_verdict=None):
    if q["kind"] in ("negative", "role_in_stint"):
        if status != "answer":
            return "quiet"
        return {"correct": "neg_right", "wrong": "neg_wrong", "declined": "quiet"}.get(kind_neg_verdict, "neg_unjudged")
    decidable = bool(q.get("answer_org"))
    if status != "answer" or not org:
        return "told_decidable" if decidable else "told"
    if not decidable:
        return "wrong"
    return "right" if entity_matches(org, st, q["answer_org"]) else "wrong"


def checked(st, q, c, chk, store, sid, qid):
    """Arm B's answer after the time model's check: (status, org, how)."""
    status = c["status"]
    org = c.get("answer_org", "") if status == "answer" else ""
    comp = c.get("comparison") or {}
    if status != "answer" or not comp.get("made") or not chk["canonical"].get(f"{sid}|{qid}"):
        return status, org, "unchecked" if status == "answer" and org else "no_answer"
    full = chk[f"{store}-full"].get(f"{sid}|{qid}")
    trusted = chk[f"{store}-trusted"].get(f"{sid}|{qid}")
    def names(v):
        return (v[1] or {}).get("entities", []) if v else []
    def agrees(v):
        return any(T.matches(org, {T.fold(n)}) or T.matches(n, {T.fold(org)}) for n in names(v))
    if full is None or full[0] in ("miss", "told_no_intent", "quiet", "triggered"):
        return status, org, "unparsed"
    if agrees(full):
        return status, org, "agrees"
    if not names(full):
        if agrees(trusted):
            return status, org, "agrees_without_agent"
        return "not_sure", "", "cant_tell"
    return "not_sure", "", "disagrees"


def cmd_score(a):
    fx = T.fixture(SET)
    verdicts = json.loads((ST / "judge.json").read_text()) if (ST / "judge.json").exists() else {}
    table, hows, wrongs, lat = defaultdict(Counter), defaultdict(Counter), defaultdict(list), defaultdict(list)
    grammar = json.loads((ST / "grammar-live.json").read_text())
    rows = []
    for engine in T.ENGINES:
        recs = records(engine)
        chk = json.loads((ST / f"check-{engine}.json").read_text()) if (ST / f"check-{engine}.json").exists() else None
        for r in recs.values():
            if r.get("ms"):
                lat[(engine, r["key"][2])].append(r["ms"])
        for st in fx["stories"]:
            for q in st.get("queries", []):
                sid, qid = st["id"], q["id"]
                cls = "neg" if q["kind"] in ("negative", "role_in_stint") else ("dec" if q.get("answer_org") else "und")
                o = {}
                for arm in ("A", "B"):
                    r = recs.get((sid, qid, arm))
                    if not r or not r["ok"]:
                        continue
                    c = r["content"]
                    v = verdicts.get("|".join([engine, sid, qid, arm]), {}).get("verdict")
                    o[arm] = outcome(st, q, c["status"], c.get("answer_org", ""), v)
                    if arm == "B" and chk:
                        for store in ("live", "gold"):
                            s2, org2, how = checked(st, q, c, chk, store, sid, qid)
                            o[f"Bc-{store}"] = outcome(st, q, s2, org2, v)
                            hows[(engine, store, cls)][how] += 1
                g = grammar.get(f"{sid}|{qid}")
                if g and "A" in o:
                    o["C"] = o["A"] if g[0] in ("miss", "told_no_intent", "quiet") or cls == "neg" else g[0]
                for arm, v in o.items():
                    table[(engine, arm)][f"{cls}:{v}"] += 1
                    if v in ("wrong", "neg_wrong"):
                        wrongs[(engine, arm)].append(f"{sid} {qid} ({q['kind']}): {q['query']}")
                rows.append({"engine": engine, "story": sid, "qid": qid, "kind": q["kind"], **o})
    RES.mkdir(exist_ok=True)
    (RES / "outcomes.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows))
    L = ["# Spike T round 2", "", f"Prompts {prompt_hash()[:12]}; set {SET}; top 10 of each story's memories plus 40 fillers (BM25).", "",
         "| engine | arm | decidable right / n | decidable wrong | undecidable not sure / n | undecidable wrong | negatives right / wrong / n |",
         "|---|---|---|---|---|---|---|"]
    for (engine, arm), c in sorted(table.items()):
        n = lambda k: sum(v for x, v in c.items() if x.startswith(k + ":"))
        L.append(f"| {engine} | {arm} | {c['dec:right']} / {n('dec')} | {c['dec:wrong']} | {c['und:told']} / {n('und')} | {c['und:wrong']} | "
                 f"{c['neg:neg_right']} / {c['neg:neg_wrong']} / {n('neg')} |")
    L += ["", "## How the check decided (arm B's answers)", ""]
    for (engine, store, cls), c in sorted(hows.items()):
        L.append(f"- {engine} {store} {cls}: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items())))
    L += ["", "## Latency (ms, p50 / p95)", ""]
    for (engine, arm), v in sorted(lat.items()):
        v = sorted(v)
        L.append(f"- {engine} {arm}: {v[len(v) // 2]} / {v[max(0, int(len(v) * 0.95) - 1)]} ({len(v)})")
    L += ["", "## Wrong answers", ""]
    for (engine, arm), v in sorted(wrongs.items()):
        L += [f"### {engine} {arm} ({len(v)})"] + [f"- {x}" for x in v]
    (RES / "report.md").write_text("\n".join(L) + "\n")
    print("\n".join(L[:40]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["freeze", "stores", "run", "check", "judge", "score"])
    ap.add_argument("--engine", choices=list(T.ENGINES))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--live", action="store_true")
    a = ap.parse_args()
    ST.mkdir(parents=True, exist_ok=True)
    if a.cmd == "freeze":
        RES.mkdir(exist_ok=True)
        (RES / "prompts.sha256").write_text(prompt_hash() + "\n")
        print("frozen", prompt_hash()[:12])
    else:
        {"stores": cmd_stores, "run": cmd_run, "check": cmd_check, "judge": cmd_judge, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
