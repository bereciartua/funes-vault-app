#!/usr/bin/env python3
"""13e.2's timeline gate: judging (ADR-0032 decision 9, amended 2026-11-21; plan v2 in the 13e.2 step 4 notes). Frozen with
the gate's code: the prompts, the per-claim labels and the rules for changing a label.

    python3 judge_13e2.py judge --engine haiku|terra --judge opus|astra [--dir results-13e2] [--workers 4]
        Every answer that has claims, one at a time and blind: the judge sees the story's memories (text, date, source,
        trust), its timeline, the question and its label, and the answer's claims as text, without Funes's marks or
        check notes. R answers by both judges; P answers by Opus only. Resumable: a judged answer (same claims) is skipped.
    python3 judge_13e2.py adjudicate --engine haiku|terra
        R answers whose two judgments differ on a gate label (a claim's verdict, temporal or inferred): a fresh GPT-6-Astra
        sees the story, the label, the answer and both judgments; its ruling is final.
    python3 judge_13e2.py relabel
        Questions any judged answer disagrees with (decidable not right, undecidable naming an organization as the
        answer, negative wrong), on either engine: a fresh GPT-6-Astra relabels each from scratch (the story and the
        question only). Writes labels-corrected.json; changes apply to every arm, engine and sample.
    python3 judge_13e2.py facts --read <read dir>
        Disputed facts from the gate read (qualify.timeline_measures' wrong facts and dates, filler facts included): a
        fresh GPT-6-Astra with the memory texts says whether the memories state that job; changes are listed.
"""
import argparse
import ast
import hashlib
import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import providers as P

HERE = Path(__file__).resolve().parent
SET = HERE / "fixtures" / "gate-13e2"
RESULTS = HERE / "results-13e2"
VERDICTS = ["answers_right", "answers_wrong", "not_sure", "true_other", "wrong_other", "someone_else"]
GATE_FIELDS = ("verdict", "temporal", "inferred")

JUDGE_INS = """You check answers that a personal-memory app gave to a question its user typed into a search field, against the truth the test's author wrote. Everything is invented. You never see how an answer was produced.

Today is 2026-10-29. You get the story (the user's memories, each with its date, source and trust: "capture" is the user's own note, "import" the user's old note, "agent" an AI assistant's note about the user, trusted less), the user's true work history, the question with its label (decidable with the right organization, undecidable, or negative, and why), and the answer's claims as the user reads them.

For EACH claim give:
- verdict:
  - answers_right: it answers the question's own ask (which organization the user worked at, relative to the time or job asked) with the right organization, and everything it says is true;
  - answers_wrong: it answers that ask with a wrong organization, or names one where the label says the memories can't decide (on a rehire question, choosing a stint the question doesn't name is answers_wrong; naming both stints as alternatives is not_sure);
  - not_sure: it says the memories can't tell, or gives alternatives without choosing;
  - true_other: a true statement that isn't an answer to the ask (context, a title, a date, someone else's true fact as theirs);
  - wrong_other: any other false statement, including a right organization with a false date, title or order;
  - someone_else: it states another person's job or fact as the user's.
  A claim with any false statement is never answers_right or true_other. "It's inferred" never excuses a falsehood.
- temporal: true if the claim picks which of the user's organizations held at a time or in an order: at a date or in a year, before or after another job or event, now, previously, first or last ("Before Cedar you were at Birch", "In 2019 you worked at Birch", "You're now at Cedar", "Your previous job was Birch"). A claim that only says when a job started or ended, a title, how long, or quotes a note, without picking which job held relative to something, is not temporal.
- inferred: true if the claim rests on something no memory states outright (an order worked out from dates, an end inferred from the next job's start, a "current" job no recent memory confirms).
- why: one short line.
Judge only by the story and the label. Return JSON matching the schema."""

JUDGE_SCHEMA = {"type": "object", "properties": {"claims": {"type": "array", "items": {"type": "object", "properties": {
    "n": {"type": "integer"}, "verdict": {"type": "string", "enum": VERDICTS}, "temporal": {"type": "boolean"},
    "inferred": {"type": "boolean"}, "why": {"type": "string"}},
    "required": ["n", "verdict", "temporal", "inferred", "why"], "additionalProperties": False}}},
    "required": ["claims"], "additionalProperties": False}

ADJ_INS = JUDGE_INS.replace("You check answers", "Two independent checkers judged an answer differently; you settle it. You check answers") + \
    "\n\nThe two judgments are given; they may both be wrong. Give your own labels for every claim."

RELABEL_INS = """You label a test question for a personal-memory app, from scratch. Everything is invented.

You get the story: the user's memories, each with its date, source and trust ("capture" is the user's own note, "import" the user's old note, "agent" an AI assistant's note about the user: it never decides the user's jobs against or beyond the user's own notes), and the question the user typed. Today is 2026-10-29.

Label it as a careful human reader would:
- class: decidable (it asks which organization the user worked at or ran, relative to a time or another job, and the user's OWN memories decide it), undecidable (the same kind of question, but the user's own memories can't decide it: a rehire question whose stints give different answers is undecidable unless it names which one), or negative (it doesn't ask which organization the user held relative to a time: a first job, how long, a yes/no about order, a list, a title, someone else's job, a vendor, an event);
- answer_org: for decidable, the organization a correct answer names (as the memories write it; for a renamed employer, either name); else "";
- why: one short line.
Return JSON matching the schema."""

RELABEL_SCHEMA = {"type": "object", "properties": {"class": {"type": "string", "enum": ["decidable", "undecidable", "negative"]},
                                                   "answer_org": {"type": "string"}, "why": {"type": "string"}},
                  "required": ["class", "answer_org", "why"], "additionalProperties": False}

FACT_INS = """You check whether a personal-memory app's work history for its user is right. Everything is invented. You get the user's memories (date, source: "capture" and "import" are the user's own notes, "agent" an AI assistant's note, trusted less) and one item the app recorded: that the user worked at (or ran) an organization. Say whether the user's own memories state it (true) or not (false), and why in one line. Return JSON matching the schema."""

FACT_SCHEMA = {"type": "object", "properties": {"stated": {"type": "boolean"}, "why": {"type": "string"}},
               "required": ["stated", "why"], "additionalProperties": False}

lock = threading.Lock()


def load_set():
    d = json.loads((SET / "stories.json").read_text())
    return {s["id"]: s for s in d["stories"]}, d["user"]


def labels():
    """The questions' labels, with any correction relabel wrote."""
    stories, _ = load_set()
    out = {(s["id"], q["id"]): {"class": q["class"], "answer_org": q["answer_org"], "why": q["why"]}
           for s in stories.values() for q in s["queries"]}
    corr = Path(RESULTS) / "labels-corrected.json"
    if corr.exists():
        for k, v in json.loads(corr.read_text())["changed"].items():
            sid, qid = k.split("/")
            out[(sid, qid)] = v
    return out


def trusted(m):
    return (m.get("trust") or ("untrusted" if m["source"] == "agent" else "trusted")) == "trusted"


def story_text(s):
    lines = ["MEMORIES"]
    for m in sorted(s["memories"], key=lambda m: m["written"]):
        lines.append(f"- {m['id']} ({m['written']}, {m['source']}, {'trusted' if trusted(m) else 'untrusted'}): {m['text']}")
    lines.append("\nTRUE WORK HISTORY")
    for t in s["timeline"]:
        lines.append(f"- {t['org']} ({t['kind']}): {t['start'] or '?'} to {t['end'] or 'now'}; {t['role']}")
    return "\n".join(lines)


def question_text(q, label):
    cls = label["class"]
    ans = (f"decidable: a right answer names {label['answer_org']}" if cls == "decidable"
           else "undecidable: the user's own memories can't decide it" if cls == "undecidable"
           else "negative: it doesn't ask which organization the user held relative to a time" +
                (f" (a right answer names {label['answer_org']})" if label["answer_org"] else ""))
    return f"QUESTION: {q['query']}\nLABEL: {ans}. Why: {label['why']}"


def answer_text(r):
    return "\n".join(f"claim {i}: {c['text']}" for i, c in enumerate(r["claims"], 1))


def fillers():
    p = SET / "fillers.json"
    return {m["id"]: m for m in json.loads(p.read_text())["memories"]} if p.exists() else {}


def cited_fillers(r):
    """The shared fillers the answer cites (not in the story's memories), as evidence for the judge."""
    f = fillers()
    ids = sorted({c["memory"] for cl in r["claims"] for c in cl["citations"] if c["memory"] in f})
    if not ids:
        return ""
    return "\n\nOTHER MEMORIES THE ANSWER CITES (the user's everyday notes)\n" + "\n".join(
        f"- {i} ({f[i]['written']}, {f[i]['source']}): {f[i]['text']}" for i in ids)


def akey(r):
    return f"{r['story']}|{r['id']}|{r['arm']}|{r['rep']}"


def ahash(r, label):
    """What a judgment was made on: the answer's claims and the question's label (a changed label is judged again)."""
    return hashlib.sha256(json.dumps([[c["text"] for c in r["claims"]], label], ensure_ascii=False, sort_keys=True)
                          .encode()).hexdigest()[:16]


def done(path):
    """The latest successful line per key."""
    out = {}
    for l in (path.read_text().splitlines() if path.exists() else []):
        j = json.loads(l)
        if j.get("ok"):
            out[j["key"]] = j
    return out


def done_by_hash(path):
    """Every successful judgment, by key and by what it was made on (claims and label): original labels' judgments stay
    readable after a relabel."""
    out = {}
    for l in (path.read_text().splitlines() if path.exists() else []):
        j = json.loads(l)
        if j.get("ok"):
            out.setdefault(j["key"], {})[j["hash"]] = j
    return out


def write(path, rec):
    with lock, path.open("a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def provider(name):
    return P.ClaudeCLI("opus", effort="high") if name == "opus" else P.Codex("gpt-6-astra", effort="high")


def valid(out, r):
    cl = (out.get("content") or {}).get("claims") or []
    return out.get("ok") and sorted(c["n"] for c in cl) == list(range(1, len(r["claims"]) + 1))


def cmd_judge(a):
    stories, _ = load_set()
    lab = labels()
    d = Path(a.dir) / f"answers-{a.engine}"
    recs = [json.loads(l) for l in (d / "answers.jsonl").read_text().splitlines()]
    path = d / f"judge-{a.judge}.jsonl"
    prev = done(path)
    todo = [r for r in recs if r["claims"] and (a.judge == "opus" or r["arm"] == "R")
            and not (akey(r) in prev and prev[akey(r)]["hash"] == ahash(r, lab[(r["story"], r["id"])]))]
    if a.limit:
        todo = todo[:a.limit]                      # development only
    j = provider(a.judge)

    def one(r):
        s = stories[r["story"]]
        q = next(x for x in s["queries"] if x["id"] == r["id"])
        prompt = (story_text(s) + cited_fillers(r) + "\n\n" + question_text(q, lab[(r["story"], r["id"])]) + "\n\nANSWER\n"
                  + answer_text(r))
        for _ in range(2):
            out = j.generate(JUDGE_INS, prompt, JUDGE_SCHEMA)
            if valid(out, r):
                break
        rec = {"key": akey(r), "hash": ahash(r, lab[(r["story"], r["id"])]), "ok": bool(valid(out, r)), "judge": a.judge,
               "claims": sorted(out["content"]["claims"], key=lambda c: c["n"]) if valid(out, r) else None,
               "model": out.get("modelId"), "error": None if valid(out, r) else out.get("error")}
        write(path, rec)
        print(f"{akey(r)}: {'ok' if rec['ok'] else 'failed'}", file=sys.stderr)

    with ThreadPoolExecutor(a.workers) as ex:
        list(ex.map(one, todo))
    left = [r for r in recs if r["claims"] and (a.judge == "opus" or r["arm"] == "R") and akey(r) not in done(path)]
    print(f"judge {a.judge} ({a.engine}): {len(todo)} judged now, {len(left)} still without a verdict")


def differs(x, y):
    return any(cx[f] != cy[f] for cx, cy in zip(x["claims"], y["claims"]) for f in GATE_FIELDS)


def cmd_adjudicate(a):
    stories, _ = load_set()
    lab = labels()
    d = Path(a.dir) / f"answers-{a.engine}"
    recs = {akey(r): r for r in map(json.loads, (d / "answers.jsonl").read_text().splitlines())}
    o, s_ = done(d / "judge-opus.jsonl"), done(d / "judge-astra.jsonl")
    path = d / "adjudicated.jsonl"
    prev = done(path)
    todo = [k for k, r in recs.items() if r["arm"] == "R" and r["claims"] and k in o and k in s_ and differs(o[k], s_[k])
            and o[k]["hash"] == s_[k]["hash"] == ahash(r, lab[(r["story"], r["id"])])
            and not (k in prev and prev[k]["hash"] == ahash(r, lab[(r["story"], r["id"])]))]
    j = provider("astra")

    def one(k):
        r = recs[k]
        s = stories[r["story"]]
        q = next(x for x in s["queries"] if x["id"] == r["id"])
        both = json.dumps({"first": o[k]["claims"], "second": s_[k]["claims"]}, ensure_ascii=False)
        prompt = (story_text(s) + cited_fillers(r) + "\n\n" + question_text(q, lab[(r["story"], r["id"])]) + "\n\nANSWER\n"
                  + answer_text(r) + "\n\nTHE TWO JUDGMENTS\n" + both)
        for _ in range(2):
            out = j.generate(ADJ_INS, prompt, JUDGE_SCHEMA)
            if valid(out, r):
                break
        write(path, {"key": k, "hash": ahash(r, lab[(r["story"], r["id"])]), "ok": bool(valid(out, r)),
                     "claims": sorted(out["content"]["claims"], key=lambda c: c["n"]) if valid(out, r) else None})
        print(f"{k}: adjudicated", file=sys.stderr)

    with ThreadPoolExecutor(a.workers) as ex:
        list(ex.map(one, todo))
    print(f"adjudicate ({a.engine}): {len(todo)} answers the judges differed on")


def original_labels():
    stories, _ = load_set()
    return {(s["id"], q["id"]): {"class": q["class"], "answer_org": q["answer_org"], "why": q["why"]}
            for s in stories.values() for q in s["queries"]}


def final_claims(dirpath, engine, lab=None):
    """Each answer's claim labels as the scorer reads them, under the label set `lab` (default: the corrected labels):
    R: the adjudicator's where the judges differed, else the agreed labels; P: Opus's. None where an answer with claims
    has no complete judgment under those labels (blocks qualification)."""
    d = Path(dirpath) / f"answers-{engine}"
    recs = [json.loads(l) for l in (d / "answers.jsonl").read_text().splitlines()]
    o, s_, adj = (done_by_hash(d / "judge-opus.jsonl"), done_by_hash(d / "judge-astra.jsonl"),
                  done_by_hash(d / "adjudicated.jsonl"))
    lab = lab or labels()
    out = {}
    for r in recs:
        k, h = akey(r), ahash(r, lab[(r["story"], r["id"])])
        if not r["claims"]:
            out[k] = []
            continue
        a, b = o.get(k, {}).get(h), s_.get(k, {}).get(h)
        if r["arm"] == "P":
            out[k] = a["claims"] if a else None
        elif not a or not b:
            out[k] = None
        elif differs(a, b):
            c = adj.get(k, {}).get(h)
            out[k] = c["claims"] if c else None
        else:
            out[k] = a["claims"]
    return recs, out


def disagrees(label, claims):
    vs = [c["verdict"] for c in claims or []]
    if label["class"] == "decidable":
        return "answers_right" not in vs or any(v in ("answers_wrong", "wrong_other", "someone_else") for v in vs)
    if label["class"] == "undecidable":
        return any(v in ("answers_right", "answers_wrong") for v in vs)
    return any(v in ("answers_wrong", "wrong_other", "someone_else") for v in vs)


def cmd_relabel(a):
    """Once, after both engines are judged under the original labels: the disputes are fixed then, and a second run
    refuses (a re-judge under corrected labels can't move them)."""
    stories, _ = load_set()
    orig = original_labels()
    if (Path(a.dir) / "labels-corrected.json").exists():
        raise SystemExit("relabel: labels-corrected.json exists; the label rule runs once")
    disputed = set()
    for engine in ("haiku", "terra"):
        if not (Path(a.dir) / f"answers-{engine}" / "answers.jsonl").exists():
            raise SystemExit(f"relabel: {engine} isn't answered yet; the label rule runs on both engines' judgments")
        recs, claims = final_claims(a.dir, engine, orig)
        import score_13e2
        keys = {(r["story"], r["id"], r["arm"], r["rep"]) for r in recs}
        want = {(s["id"], q["id"], arm, rep) for s in stories.values() for q in s["queries"]
                for arm, n in (("P", 1), ("R", score_13e2.GATE_REPS)) for rep in range(1, n + 1)}
        if keys != want or len(recs) != len(want):
            raise SystemExit(f"relabel: {engine}'s answers aren't the full matrix yet")
        if any(v is None for v in claims.values()):
            raise SystemExit(f"relabel: {engine} isn't fully judged under the original labels")
        for r in recs:
            c = claims.get(akey(r))
            if c is not None and r["outcome"] != "failed" and disagrees(orig[(r["story"], r["id"])], c):
                disputed.add((r["story"], r["id"]))
    path = Path(a.dir) / "relabels.jsonl"
    prev = done(path)
    j = provider("astra")

    def one(k):
        s = stories[k[0]]
        q = next(x for x in s["queries"] if x["id"] == k[1])
        prompt = story_text_without_truth(s) + f"\n\nQUESTION: {q['query']}"
        for _ in range(3):
            out = j.generate(RELABEL_INS, prompt, RELABEL_SCHEMA)
            if out.get("ok"):
                break
        write(path, {"key": "/".join(k), "ok": bool(out.get("ok")), "label": out.get("content")})

    with ThreadPoolExecutor(a.workers) as ex:
        list(ex.map(one, [k for k in sorted(disputed) if "/".join(k) not in prev]))
    got = done(path)
    changed, failed = {}, []
    for k in sorted(disputed):
        new = (got.get("/".join(k)) or {}).get("label")
        if not new:
            failed.append("/".join(k))
            continue
        o = orig[k]
        same_org = fold(new["answer_org"]) in names_for(stories[k[0]], o["answer_org"]) if o["answer_org"] else not new["answer_org"]
        if new["class"] != o["class"] or (o["class"] == "decidable" and not same_org):
            changed["/".join(k)] = {**new, "was": o}
    (Path(a.dir) / "labels-corrected.json").write_text(json.dumps(
        {"disputed": ["/".join(k) for k in sorted(disputed)], "changed": changed, "failed": failed}, ensure_ascii=False, indent=1) + "\n")
    print(f"relabel: {len(disputed)} disputed questions, {len(changed)} labels changed, {len(failed)} without a ruling")


def story_text_without_truth(s):
    return "\n".join(["MEMORIES"] + [f"- {m['id']} ({m['written']}, {m['source']}): {m['text']}"
                                     for m in sorted(s["memories"], key=lambda m: m["written"])])


def fold(x):
    import unicodedata
    return " ".join(unicodedata.normalize("NFKD", x or "").encode("ascii", "ignore").decode().lower().split())


def names_for(s, org):
    import qualify
    return {fold(n) for n in qualify.labelled_names(s, org)}


def cmd_facts(a):
    import qualify
    stories, _ = load_set()
    fillers = json.loads((SET / "fillers.json").read_text())["memories"]
    lines = [json.loads(l) for l in (Path(a.read) / "stories.jsonl").read_text().splitlines()]
    reg = qualify.registry()
    t = qualify.timeline_measures(lines, stories, reg)
    # Only a plain "the user worked at X" fact can be disputed: a date, a slot, a merge or a duplicate episode is never
    # waived (the adjudicator couldn't see the value recorded).
    items = [x for x in t["details"]["wrong_facts"] if len(ast.literal_eval(x)) == 2]
    path = Path(a.dir) / "fact-disputes.jsonl"
    prev = done(path)
    j = provider("astra")
    for item in items:
        if item in prev:
            continue
        sid = item.split("'")[1]
        s = stories[sid]
        mems = story_text_without_truth({"memories": s["memories"] + fillers})
        sid_, org = ast.literal_eval(item)
        out = j.generate(FACT_INS, mems + f"\n\nITEM: the user worked at (or ran) {org}", FACT_SCHEMA)
        write(path, {"key": item, "read": "gate", "ok": bool(out.get("ok")), "ruling": out.get("content")})
    print(f"facts: {len(items)} disputed items")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["judge", "adjudicate", "relabel", "facts"])
    ap.add_argument("--engine", choices=["haiku", "terra"])
    ap.add_argument("--judge", choices=["opus", "astra"])
    ap.add_argument("--dir", default=str(HERE / "results-13e2"))
    ap.add_argument("--read")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--set", default="gate-13e2", help="the set under fixtures/ (development: gate-13e2-dev)")
    ap.add_argument("--limit", type=int, help="development only: judge at most this many answers")
    a = ap.parse_args()
    global SET, RESULTS
    SET = HERE / "fixtures" / a.set
    RESULTS = Path(a.dir)
    {"judge": cmd_judge, "adjudicate": cmd_adjudicate, "relabel": cmd_relabel, "facts": cmd_facts}[a.cmd](a)


if __name__ == "__main__":
    main()
