#!/usr/bin/env python3
"""Spike T (drafts/facts-llm-first §5): does a model reading the question beat the grammar, on the same stores, without
more wrong answers?

Arms, on identical questions and stores (a store is a story played through the Swift pipeline from replayed calls:
work13 and workt from their own labels (gold), mixed from Spike H3b's recorded Haiku calls):
  1  plain:  the answer model reads the story's memories and the question; no facts.
  2  grammar: today's TimelineIntent grammar and time model (the Swift harness); with "+1", a question the grammar
             doesn't read falls back to arm 1's answer, as the app falls back to a plain answer.
  3  intent: a model reads the question into a typed intent; code turns it into the canonical question the grammar
             reads ("Where did I work before X?") and the same time model answers. "+1" as above.
  4  rows:   the answer model reads the memories plus the store's work rows (episodes with dates, kinds, trust,
             renames) and reasons itself; no time model.
Arm 5 of the draft (arm 3 on a gold store against a live one) needs a recorded live read; the live gate reads didn't
record their calls. The mixed store is a real model read (H3b), work13 and workt are gold.

    python3 spike_t.py freeze                     records the prompts' sha256 (before reading any held-out label)
    python3 spike_t.py stores                     plays every store once with its own questions (arm 2, and the rows)
    python3 spike_t.py run --engine haiku|terra [--arms 1,3,4] [--samples 2] [--limit N] [--dry]
    python3 spike_t.py swift --engine ...         arm 3's canonical questions through the time model
    python3 spike_t.py refuse --engine ...        arm 3's intent step on 13e.1's should-refuse questions
    python3 spike_t.py score                      every arm, per split, family and engine -> results-spike-t/report.md
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import unicodedata
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

import providers as P

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ST = Path(os.environ.get("SPIKE_T_DIR", REPO / "build" / "spike-t"))
RES = HERE / "results-spike-t"
TODAY = "2026-11-21"
TIMELINE_KINDS = ("before", "after", "year", "current", "previous", "no_answer")
SETS = {"work13": "gold", "mixed": "recorded", "workt": "gold"}
JUDGE = lambda: P.ClaudeCLI("claude-opus-5-5", "low")
ENGINES = {"haiku": lambda: P.ClaudeCLI("claude-haiku-5-5", "low"), "terra": lambda: P.Codex("gpt-5.6-terra", "low")}

# MARK: prompts (frozen before any held-out label is read: `freeze`) ------------------------------------------------

ANSWER_INSTRUCTIONS = """You answer the user's question from their own memories, for Funes, a private memory vault.

The input gives today's date, the question, and the user's memories (each with an id, the date it was written, and who wrote it: the user, an AI agent's note about the user, or an old note the user imported). The user's own name is replaced by "the user".

Rules:
- Use only the memories (and the work history rows, when given). Never use outside knowledge.
- Every claim quotes the memory or memories it rests on, word for word.
- An agent's note is less trustworthy than the user's own notes: it never overrides them. If only an agent's note supports an answer, say so in the answer.
- Dates are as precise as written: "2019" is any time that year. If the memories can't decide (two jobs that may overlap, an order that could go either way, two candidates), set status "not_sure" and say why. Never guess.
- If the memories don't contain the answer, set status "no_answer".
- answer_org: when the question asks which organization (employer, company, business) the user worked at or ran, the name of that organization exactly as the memories write it; otherwise "". Empty unless status is "answer"."""

ROWS_RULE = """
- The work history rows are Funes's own structured reading of the memories (organization, kind, dates at the precision written, whether it rests only on an agent's note, renames). Use them to reason about order and dates; quote the memories they cite."""

ANSWER_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["status", "answer_org", "answer", "claims"],
                 "properties": {"status": {"type": "string", "enum": ["answer", "not_sure", "no_answer"]},
                                "answer_org": {"type": "string"}, "answer": {"type": "string"},
                                "claims": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                                           "required": ["text", "quotes"], "properties": {
                                               "text": {"type": "string"},
                                               "quotes": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                                                          "required": ["memory", "quote"], "properties": {
                                                              "memory": {"type": "string"}, "quote": {"type": "string"}}}}}}}}}

INTENT_INSTRUCTIONS = """You read one question typed into the search field of Funes, a private memory vault, into a structured intent. You don't answer it.

Funes can answer one kind of question from the user's work history: which organization the USER worked at (as an employee) or ran (their own business or freelance practice) at some point in time. The input gives today's date, the question, and the organizations Funes knows from the user's memories.

Set about_user_work true only when the question asks which organization the user themself worked at or ran, relative to a time: before or after an organization or a date, in a year or month, between two dates, now (current), or the one before now (previous). Set it false for anything else: someone else's job ("where did my sister work before Acme?"), clients, vendors, events, things the user did at work, the user's title, yes/no questions, and questions that only mention a company.

Fields:
- operator: before, after, in (a year or month), between, current, previous; none when about_user_work is false.
- anchor_org: for before/after an organization, its name from the known organizations (the closest match to what the question writes), else "".
- anchor_date: for before/after a date or "in", the date as written (e.g. "2019", "March 2019"), else "". For between: the start.
- end_date: for between, the end; else "".
- kind: employee when the question asks about an employer or salaried job only, self_employed when it asks about the user's own business or freelance work only, any otherwise."""

INTENT_SCHEMA = {"type": "object", "additionalProperties": False,
                 "required": ["about_user_work", "operator", "anchor_org", "anchor_date", "end_date", "kind"],
                 "properties": {"about_user_work": {"type": "boolean"},
                                "operator": {"type": "string", "enum": ["before", "after", "in", "between", "current", "previous", "none"]},
                                "anchor_org": {"type": "string"}, "anchor_date": {"type": "string"}, "end_date": {"type": "string"},
                                "kind": {"type": "string", "enum": ["employee", "self_employed", "any"]}}}


def prompt_hash():
    return hashlib.sha256(json.dumps([ANSWER_INSTRUCTIONS, ROWS_RULE, ANSWER_SCHEMA, INTENT_INSTRUCTIONS, INTENT_SCHEMA],
                                     sort_keys=True).encode()).hexdigest()


def canonical(it):
    """The intent as the one wording the grammar is known to read (checked on w01 before the freeze); "" = no intent."""
    if not it or not it.get("about_user_work") or it.get("operator") == "none":
        return ""
    op, k = it["operator"], it.get("kind", "any")
    anchor = it.get("anchor_org") or it.get("anchor_date") or ""
    head = {"employee": ("Which employer did I work for", "Which employer do I work for now?", "What was my previous employer?"),
            "self_employed": ("Which freelance business did I run", "Which freelance business do I run now?",
                              "What was my previous freelance business?"),
            "any": ("Where did I work", "Where do I work now?", "What was my previous job?")}[k if k in ("employee", "self_employed") else "any"]
    if op == "current":
        return head[1]
    if op == "previous":
        return head[2]
    if op in ("before", "after") and anchor:
        return f"{head[0]} {op} {anchor}?"
    if op == "in" and it.get("anchor_date"):
        return f"{head[0]} in {it['anchor_date']}?"
    if op == "between" and it.get("anchor_date") and it.get("end_date"):
        return f"{head[0]} between {it['anchor_date']} and {it['end_date']}?"
    return ""


# MARK: data ---------------------------------------------------------------------------------------------------------

def fixture(s):
    return json.loads((HERE / "fixtures" / f"stories-{s}.json").read_text())


def questions():
    """Every question: (set, story, qid, split, query dict). Dev: the sets' own questions (work13, mixed); held out: the
    new wordings over those stories and every workt question."""
    out = []
    wf = HERE / "fixtures" / "spike-t" / "wordings.json"
    wordings = json.loads(wf.read_text()) if wf.exists() else {}
    for s in SETS:
        p = HERE / "fixtures" / f"stories-{s}.json"
        if not p.exists():
            continue
        for st in fixture(s)["stories"]:
            if not st.get("timeline"):
                continue
            split = "held" if s == "workt" else "dev"
            for q in st.get("queries", []):
                out.append((s, st["id"], q["id"], split, q))
            for q in wordings.get(s, {}).get(st["id"], []):
                out.append((s, st["id"], q["id"], "held", q))
    # A fresh GPT-6-Astra adjudicated every question some arm got wrong (fixtures/spike-t/adjudication.json); where it
    # found the label wrong, its answer replaces the label's.
    adj = HERE / "fixtures" / "spike-t" / "adjudication.json"
    fixes = {c["id"]: c for c in json.loads(adj.read_text())["cases"] if not c["label_right"]} if adj.exists() else {}
    for i, (s, sid, qid, split, q) in enumerate(out):
        c = fixes.get(f"{s}/{sid}/{qid}")
        if c:
            out[i] = (s, sid, qid, split, {**q, "answer_org": c["answer"] if c["decidable"] else "", "adjudicated": True})
    return out


def replace_user(text, aliases):
    for a in sorted(aliases, key=len, reverse=True):
        text = re.sub(rf"(?<!\w){re.escape(a)}(?!\w)", "the user", text)
    return text


def memories_block(st, aliases):
    who = {"capture": "the user", "agent": "an AI agent's note", "import": "a note the user imported"}
    lines = []
    for m in st["memories"]:
        lines.append(f'<memory id="{m["id"]}" written="{m["written"]}" by="{who.get(m.get("source"), "the user")}">\n'
                     f'{replace_user(m["text"], aliases)}\n</memory>')
    return "\n".join(lines)


def store_line(s, story):
    p = ST / "out" / f"swift-replay-arm2-{s}" / f"{s}.jsonl"
    for line in p.read_text().splitlines():
        r = json.loads(line)
        if r["story"] == story and r["orderIndex"] == 0:
            return r
    return None


def fmt_range(r):
    if not r:
        return "unknown"
    lo, _, prec = r
    d = date.fromordinal(lo)
    return {"day": d.isoformat(), "month": d.strftime("%Y-%m"), "year": str(d.year)}.get(prec, d.isoformat())


def rows_block(line, aliases):
    """The store's work rows: trusted episodes only (untrusted-only episodes stay out, draft §3.4), with renames."""
    st = line["state"]
    names = {e["id"]: e["name"] for e in st["entities"]}
    groups = st.get("timeline_groups") or []
    out = []
    for e in st["episodes"]:
        if e["predicate"] not in ("works_at", "client") or not e.get("trusted", True):
            continue
        end = "ongoing" if e["end"] is None and not e.get("former") else fmt_range(e["end"]) if e["end"] else "ended, date unknown"
        bits = [f'org="{replace_user(names.get(e["entity"], "?"), aliases)}"', f'kind="{e["predicate"] if e["predicate"] == "client" else e.get("slot") or "unknown"}"',
                f'start="{fmt_range(e["start"])}"', f'end="{end}"']
        if e.get("inferred_end"):
            bits.append('end_inferred="true"')
        if not e.get("start_trusted", True) or not e.get("end_trusted", True):
            bits.append('dates_from_agent_note="true"')
        bits.append(f'memories="{",".join(e["memories"])}"')
        out.append("<row " + " ".join(bits) + "/>")
    for g in groups:
        ns = [names.get(x, x) for x in (g if isinstance(g, list) else g.get("entities", []))]
        if len(ns) > 1:
            out.append(f'<rename names="{" / ".join(ns)}"/>')
    return "\n".join(out) or "(none)"


def roster(line, aliases):
    st = line["state"]
    return sorted({replace_user(e["name"], aliases) for e in st["entities"] if e["kind"] == "organization"})


# MARK: model calls --------------------------------------------------------------------------------------------------

LOCK = threading.Lock()


def cached(engine, kind, instructions, prompt, schema, sample, dry=False):
    key = hashlib.sha256(json.dumps([engine, kind, instructions, prompt, schema, sample], sort_keys=True).encode()).hexdigest()
    f = ST / "cache" / engine / f"{key}.json"
    if f.exists():
        return json.loads(f.read_text())
    if dry:
        return None
    r = (JUDGE() if engine == "opus-judge" else ENGINES[engine]()).generate(instructions, prompt, schema)
    f.parent.mkdir(parents=True, exist_ok=True)
    if r.get("ok"):
        f.write_text(json.dumps(r, ensure_ascii=False))
    return r


def requests(engine, arms, samples, limit=None):
    """Every call the run makes: (record key, kind, instructions, prompt, schema, sample)."""
    reqs = []
    qs = questions()
    if limit:
        qs = qs[:limit]
    for s, sid, qid, split, q in qs:
        fx = fixture(s)
        st = next(x for x in fx["stories"] if x["id"] == sid)
        aliases = fx["user"]["aliases"]
        line = store_line(s, sid)
        base = f"Today: {TODAY}\nQuestion: {q['query']}\n"
        if "1" in arms:
            reqs.append(((s, sid, qid, "1", 0), "answer", ANSWER_INSTRUCTIONS, base + "\n" + memories_block(st, aliases), ANSWER_SCHEMA, 0))
        if "4" in arms and line:
            reqs.append(((s, sid, qid, "4", 0), "answer", ANSWER_INSTRUCTIONS + ROWS_RULE,
                         base + "\n<work_history>\n" + rows_block(line, aliases) + "\n</work_history>\n\n" + memories_block(st, aliases),
                         ANSWER_SCHEMA, 0))
        if "3" in arms and line:
            for k in range(samples):
                reqs.append(((s, sid, qid, "3", k), "intent", INTENT_INSTRUCTIONS,
                             base + "Known organizations: " + "; ".join(roster(line, aliases)), INTENT_SCHEMA, k))
    return reqs


def cmd_run(a):
    frozen = RES / "prompts.sha256"
    if not frozen.exists() or frozen.read_text().strip() != prompt_hash():
        raise SystemExit("spike_t: the prompts changed since `freeze` (or were never frozen)")
    reqs = requests(a.engine, a.arms.split(","), a.samples, a.limit)
    if a.dry:
        todo = [r for r in reqs if cached(a.engine, r[1], r[2], r[3], r[4], r[5], dry=True) is None]
        print(f"{a.engine}: {len(reqs)} requests, {len(todo)} not cached")
        return
    out = ST / f"records-{a.engine}.jsonl"
    done = 0
    def one(r):
        key, kind, ins, prompt, schema, sample = r
        res = cached(a.engine, kind, ins, prompt, schema, sample)
        return {"key": list(key), "kind": kind, "ok": res.get("ok"), "content": res.get("content"), "ms": res.get("ms"),
                "error": res.get("error"), "model": res.get("modelId"), "prompt": prompt}
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex, out.open("a") as f:
        for rec in ex.map(one, reqs):
            with LOCK:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                done += 1
                if done % 50 == 0:
                    print(f"{a.engine}: {done}/{len(reqs)}", flush=True)
    print(f"{a.engine}: {done} records -> {out}")


def records(engine):
    """The latest record per key."""
    p = ST / f"records-{engine}.jsonl"
    out = {}
    if p.exists():
        for line in p.read_text().splitlines():
            r = json.loads(line)
            out[tuple(r["key"])] = r
    return out


# MARK: arm 3 through the time model ---------------------------------------------------------------------------------

def run_swift(s, tag, qfile):
    env = dict(os.environ, FUNES_FACTS_HARNESS=";".join(
        [f"set={s}", f"replay={ST / ('export-gold-' if SETS[s] == 'gold' else 'export-rec-') }{s}.jsonl".replace(" ", ""),
         *(["reader=1"] if SETS[s] == "gold" else []), "orders=natural", f"queries={qfile}", f"out={ST / 'out'}", f"tag={tag}"]))
    subprocess.run(["rm", "-rf", str(ST / "out" / f"swift-replay-{tag}")])
    p = subprocess.run(["swift", "test", "--package-path", str(REPO / "Packages/FunesCore"), "--filter", "FactsHarnessTests/fullRun"],
                       env=env, capture_output=True, text=True)
    summary = [l for l in p.stdout.splitlines() if l.startswith("facts harness:")]
    if p.returncode != 0 or not summary:
        raise SystemExit(f"swift harness failed for {s} {tag}: {p.stdout[-1500:]}{p.stderr[-500:]}")
    res = {}
    for line in (ST / "out" / f"swift-replay-{tag}" / f"{s}.jsonl").read_text().splitlines():
        r = json.loads(line)
        if r["orderIndex"] == 0:
            for qid, o in r["swift_judged"].items():
                res[(s, r["story"], qid)] = (o, r["swift_answers"].get(qid))
    return res


def cmd_swift(a):
    """Arm 2 on every question (original wording), and arm 3's canonical questions per engine and sample."""
    qs = questions()
    recs = records(a.engine) if a.engine else {}
    jobs = [("2", 0)] if not a.engine else [("3", k) for k in range(a.samples)]
    out = {}
    for arm, k in jobs:
        for s in SETS:
            per = defaultdict(list)
            for (ss, sid, qid, split, q) in qs:
                if ss != s:
                    continue
                text = q["query"]
                if arm == "3":
                    r = recs.get((s, sid, qid, "3", k))
                    if not r or not r["ok"]:
                        continue
                    text = canonical(r["content"])
                per[sid].append({**{x: q[x] for x in ("id", "kind", "answer_org")}, "query": text})
            if not per:
                continue
            qf = ST / f"queries-{s}-{arm}-{a.engine or 'grammar'}-{k}.json"
            qf.write_text(json.dumps(per, ensure_ascii=False))
            if not (ST / "out" / f"swift-replay-arm2-{s}" / f"{s}.jsonl").exists():
                print(f"{s}: no store yet (spike_t.py stores)")
                continue
            res = run_swift(s, f"st-{s}-{arm}-{a.engine or 'grammar'}-{k}", qf)
            for key, v in res.items():
                out["|".join([*key, arm, str(k)])] = v
            print(f"{s} arm {arm} sample {k}: {dict(Counter(o for o, _ in res.values()))}")
    f = ST / f"swift-{a.engine or 'grammar'}.json"
    f.write_text(json.dumps(out, ensure_ascii=False))


def cmd_stores(a):
    for s in SETS:
        if not (HERE / "fixtures" / f"stories-{s}.json").exists():
            continue
        ex = ST / (("export-gold-" if SETS[s] == "gold" else "export-rec-") + f"{s}.jsonl")
        if not ex.exists():
            if SETS[s] == "gold":
                subprocess.run(["python3", "gold_answers.py", "--set", s, str(ST / f"gold-{s}.jsonl")], cwd=HERE, check=True)
                subprocess.run(["python3", "export_replay.py", str(ST / f"gold-{s}.jsonl"), f"fixtures/stories-{s}.json", str(ex)], cwd=HERE, check=True)
            else:
                subprocess.run(["python3", "export_replay.py", "results-h3b/claude-haiku-separate/mixed.jsonl", "fixtures/stories-mixed.json", str(ex)],
                               cwd=HERE, check=True)
        per = defaultdict(list)
        for (ss, sid, qid, split, q) in questions():
            if ss == s:
                per[sid].append(q)
        qf = ST / f"queries-{s}-store.json"
        qf.write_text(json.dumps(per, ensure_ascii=False))
        res = run_swift(s, f"arm2-{s}", qf)
        print(f"{s} store: {dict(Counter(o for o, _ in res.values()))}")


def cmd_refuse(a):
    labels = json.loads((HERE / "fixtures" / "spike-t" / "refuse-labels.json").read_text())["labels"]
    known = "Brindle; Nudo Estudio; Copper Delta; Alder Signal"
    reqs = [(l["question"], f"Today: {TODAY}\nQuestion: {l['question']}\nKnown organizations: {known}") for l in labels]
    def one(r):
        res = cached(a.engine, "intent", INTENT_INSTRUCTIONS, r[1], INTENT_SCHEMA, 0)
        return {"question": r[0], "ok": res.get("ok"), "content": res.get("content"), "ms": res.get("ms")}
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        recs = list(ex.map(one, reqs))
    (ST / f"refuse-{a.engine}.json").write_text(json.dumps(recs, ensure_ascii=False, indent=0))
    print(f"refuse {a.engine}: {len(recs)} intents")


JUDGE_INSTRUCTIONS = """You grade one answer for Funes, a private memory vault. You get the user's memories, the question and the answer (with its quoted claims). The user's own name is replaced by "the user". Judge only against the memories.
verdict: correct (it answers what was asked, and every claim is supported by the memories), wrong (it answers a different question, states something the memories don't support, or contradicts them), or declined (it says it can't tell or doesn't know). why: one short line."""
JUDGE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["verdict", "why"],
                "properties": {"verdict": {"type": "string", "enum": ["correct", "wrong", "declined"]}, "why": {"type": "string"}}}


def cmd_judge(a):
    """Opus grades the model arms' answers to the non-timeline questions (negative, role_in_stint), which the org match
    can't judge. Blind to the arm and engine."""
    jobs = []
    for engine in ENGINES:
        recs = records(engine)
        for (s, sid, qid, split, q) in questions():
            if q["kind"] not in ("negative", "role_in_stint"):
                continue
            fx = fixture(s)
            st = next(x for x in fx["stories"] if x["id"] == sid)
            for arm in ("1", "4"):
                r = recs.get((s, sid, qid, arm, 0))
                if not r or not r["ok"]:
                    continue
                c = r["content"]
                prompt = (memories_block(st, fx["user"]["aliases"]) + f"\n\nQuestion: {q['query']}\n\nAnswer: {c['answer']}\n\nClaims: "
                          + json.dumps(c.get("claims", []), ensure_ascii=False))
                jobs.append(((engine, s, sid, qid, arm), prompt))
    def one(j):
        res = cached("opus-judge", "judge", JUDGE_INSTRUCTIONS, j[1], JUDGE_SCHEMA, 0, dry=a.dry)
        return j[0], res
    out = {}
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for key, res in ex.map(one, jobs):
            if res and res.get("ok"):
                out["|".join(key)] = res["content"]
    if a.dry:
        print(f"judge: {len(jobs)} answers, {len(out)} cached")
        return
    (ST / "judge.json").write_text(json.dumps(out, ensure_ascii=False, indent=0))
    print(f"judge: {len(out)} of {len(jobs)} graded: {dict(Counter(v['verdict'] for v in out.values()))}")


# MARK: scoring ------------------------------------------------------------------------------------------------------

def fold(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\b(inc|llc|ltd|s\.?l|s\.?a|gmbh|co|corp|the)\b\.?", " ", s)
    return " ".join(re.findall(r"[a-z0-9]+", s))


def org_aliases(st, org):
    """Every way the story writes an organization (its labels' surfaces, also_called), for the loose name match."""
    names = {org}
    for m in st["memories"]:
        for o in m.get("organizations", []):
            if fold(o.get("org")) == fold(org):
                names.add(o["surface"])
        for j in m.get("jobs", []):
            if fold(j.get("org")) == fold(org) and j.get("also_called"):
                names.add(j["also_called"])
            if j.get("also_called") and fold(j["also_called"]) == fold(org):
                names.add(j["org"])
    return {fold(n) for n in names if n}


def matches(got, names):
    g = fold(got)
    return bool(g) and any(g == n or (len(n) > 3 and n in g) or (len(g) > 3 and g in n) for n in names)


def judge_model(st, q, content, sent):
    """An arm 1 / arm 4 answer -> the harness's outcomes. A claim whose quotes aren't in the text sent is dropped (as
    Search answers drops it); an answer with no claim left is no answer."""
    if content is None:
        return "error"
    valid = [c for c in content.get("claims", []) if c.get("quotes") and all(x["quote"].strip() and x["quote"].strip() in sent for x in c["quotes"])]
    status = content.get("status")
    org = content.get("answer_org", "") if status == "answer" and valid else ""
    timeline = st.get("timeline", [])
    if q["kind"] in ("negative", "role_in_stint"):
        # A model arm answers these questions themselves (a title, someone else's start date); naming the organization
        # the question is about isn't a misread. Whether the answer is right needs a judge: `answered` is neutral.
        return "answered" if status == "answer" and valid else "quiet"
    decidable = bool(q.get("answer_org"))
    if not org:
        return "told_decidable" if decidable else ("told" if status in ("not_sure", "no_answer") else "told_no_intent")
    if not decidable:
        return "wrong"
    return "right" if matches(org, org_aliases(st, q["answer_org"])) else "wrong"


def family(st, q):
    t = set(st.get("traps", []))
    fam = [x for x in ("renamed", "rehire", "concurrent_slots", "untrusted_end", "undated_order", "precision", "spanish", "gap", "import")
           if x in t]
    return fam or ["other"]


GOOD = {"right", "right_gap", "quiet", "told", "told_gap", "told_no_intent"}


def cmd_score(a):
    qs = questions()
    out = []
    table = defaultdict(Counter)       # (engine, arm, split) -> outcomes
    fam = defaultdict(Counter)
    lat = defaultdict(list)
    wrongs = defaultdict(list)
    verdicts = json.loads((ST / "judge.json").read_text()) if (ST / "judge.json").exists() else {}
    grammar = json.loads((ST / "swift-grammar.json").read_text()) if (ST / "swift-grammar.json").exists() else {}
    for engine in ENGINES:
        recs = records(engine)
        if not recs:
            continue
        sw = json.loads((ST / f"swift-{engine}.json").read_text()) if (ST / f"swift-{engine}.json").exists() else {}
        for r in recs.values():
            if r.get("ms"):
                lat[(engine, r["key"][3])].append(r["ms"])
        for (s, sid, qid, split, q) in qs:
            fx = fixture(s)
            st = next(x for x in fx["stories"] if x["id"] == sid)
            sent = memories_block(st, fx["user"]["aliases"])
            o = {}
            r1 = recs.get((s, sid, qid, "1", 0))
            o["1"] = judge_model(st, q, r1["content"] if r1 and r1["ok"] else None, sent) if r1 else None
            r4 = recs.get((s, sid, qid, "4", 0))
            o["4"] = judge_model(st, q, r4["content"] if r4 and r4["ok"] else None, sent) if r4 else None
            for arm in ("1", "4"):
                v = verdicts.get("|".join([engine, s, sid, qid, arm]))
                if o[arm] == "answered" and v:
                    o[arm] = {"correct": "answered_right", "wrong": "triggered", "declined": "quiet"}[v["verdict"]]
            g = grammar.get("|".join([s, sid, qid, "2", "0"]))
            o["2"] = g[0] if g else None
            for k in range(2):
                v = sw.get("|".join([s, sid, qid, "3", str(k)]))
                o[f"3.{k}"] = v[0] if v else None
            def fb(x):      # "+1": no intent -> arm 1's answer
                return o["1"] if x in ("miss", "told_no_intent", "quiet") and q["kind"] not in ("negative", "role_in_stint") else x
            o["2+1"] = fb(o["2"]) if o["2"] else None
            for k in range(2):
                o[f"3.{k}+1"] = fb(o[f"3.{k}"]) if o.get(f"3.{k}") else None
            cls = "neg" if q["kind"] in ("negative", "role_in_stint") else ("dec" if q.get("answer_org") else "und")
            for arm, v in o.items():
                if v is None:
                    continue
                table[(engine, arm, split)][f"{cls}:{v}"] += 1
                for f in family(st, q):
                    fam[(engine, arm, f)][v] += 1
                if v in ("wrong", "triggered"):
                    wrongs[(engine, arm)].append(f"{s} {sid} {qid} ({split}, {q['kind']}): {q['query']}")
            out.append({"set": s, "story": sid, "qid": qid, "split": split, "kind": q["kind"], "engine": engine, **o})
    RES.mkdir(exist_ok=True)
    (RES / "outcomes.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in out))
    lines = ["# Spike T results", "", f"Prompts sha256 {prompt_hash()[:12]}; stores: work13 and workt gold, mixed recorded (H3b).", ""]
    lines.append("| engine | arm | split | decidable: right / n | decidable: wrong | undecidable: not sure / n | undecidable: wrong | negatives: triggered / n |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for (engine, arm, split), c in sorted(table.items()):
        n = lambda cls: sum(v for k, v in c.items() if k.startswith(cls + ":"))
        lines.append(f"| {engine} | {arm} | {split} | {c['dec:right'] + c['dec:right_gap']} / {n('dec')} | {c['dec:wrong']} | "
                     f"{c['und:told'] + c['und:told_gap'] + c['und:told_no_intent']} / {n('und')} | {c['und:wrong']} | {c['neg:triggered']} (answered {c['neg:answered']}) / {n('neg')} |")
    lines += ["", "## Latency (ms, p50 / p95)", ""]
    for (engine, arm), v in sorted(lat.items()):
        v = sorted(v)
        lines.append(f"- {engine} arm {arm}: {v[len(v) // 2]} / {v[int(len(v) * 0.95) - 1]} ({len(v)} calls)")
    lines += ["", "## Wrong answers and triggered negatives", ""]
    for (engine, arm), v in sorted(wrongs.items()):
        lines.append(f"### {engine} arm {arm} ({len(v)})")
        lines += [f"- {x}" for x in v]
    lines += ["", "## By family (all splits)", ""]
    for (engine, arm, f), c in sorted(fam.items()):
        lines.append(f"- {engine} arm {arm} {f}: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items())))
    (RES / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:60]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["freeze", "stores", "run", "swift", "refuse", "judge", "score"])
    ap.add_argument("--engine", choices=list(ENGINES))
    ap.add_argument("--arms", default="1,3,4")
    ap.add_argument("--samples", type=int, default=2)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    ST.mkdir(parents=True, exist_ok=True)
    if a.cmd == "freeze":
        RES.mkdir(exist_ok=True)
        (RES / "prompts.sha256").write_text(prompt_hash() + "\n")
        print("frozen", prompt_hash()[:12])
    else:
        {"stores": cmd_stores, "run": cmd_run, "swift": cmd_swift, "refuse": cmd_refuse, "judge": cmd_judge, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
