#!/usr/bin/env python3
"""Spike T's held-out questions (drafts/facts-llm-first §5), written by GPT-6-Astra through the Codex CLI before anyone
reads them; the arms' prompts are frozen first (spike_t.py --freeze). Three parts:

    python3 author_astra_spiket.py stories    new stories (set `workt`, fixtures/stories-workt.json), work13's format,
                                              weighted to undecidable questions (overlaps, same-year hand-overs, ties)
    python3 author_astra_spiket.py wordings   new questions over work13's and mixed's existing stories
                                              (fixtures/spike-t/wordings.json, {set: {story: [query]}})
    python3 author_astra_spiket.py refuse     independent labels for 13e.1's should-refuse questions
                                              (fixtures/spike-t/refuse-labels.json)
    python3 author_astra_spiket.py stories --fix <notes>   a correction round from the checks' problems

Astra gets the feature's description and the format, never the code, a prompt or a result; every command Codex runs is
audited to stay in its work directory (author_astra_work13.audit). Provenance beside each raw file.
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import author_astra_work13 as W

HERE = Path(__file__).resolve().parent
OUT = HERE / "fixtures" / "spike-t"
RAW = HERE / "fixtures" / "raw"
S, N, L, obj = W.S, W.N, W.L, W.obj

KINDS = ["before", "after", "year", "current", "previous", "role_in_stint", "negative", "no_answer"]
QUERY = obj({"id": S(), "kind": S(enum=KINDS), "query": S(), "answer_org": S(),
             "why": S()})   # one line: why that answer (or why none), for the reader of the results

STORIES_BRIEF = W.BRIEF.replace("WRITE 12 to 15 stories (ids w01…w15)", "WRITE 10 to 12 stories (ids t01…t12)").replace(
    "with 30 to 45 queries in all.", "with 40 to 55 queries in all.").replace(
    "At least 30 queries must be decidable (answer_org not \"\").",
    "At least 20 queries must be decidable (answer_org not \"\"), and AT LEAST 30 must be UNDECIDABLE timeline questions "
    "(kinds before, after, year, current or previous, answer_org \"\"): the memories genuinely can't tell, for example two "
    "jobs that may overlap and the user says they can't remember, a hand-over within the same year or month where either "
    "order is possible, two jobs both described as current, an anchor that matches two stints of a rehire, an undated job "
    "that could sit anywhere, or only an agent's note says it. Make the undecidable ones look as answerable as the "
    "decidable ones; a careful human reader must agree the story can't decide them. Weight the traps to renamed, rehire, "
    "concurrent_slots, untrusted_end, precision, undated_order and spanish.").replace(
    "QUERIES, 2 to 4 per story,", "QUERIES, 4 to 6 per story,")

WORDINGS_BRIEF = """You are writing held-out test questions for a feature of Funes Vault, a private personal-memory app on the Mac. Everything is invented.

THE FEATURE (work history). The vault holds short memories about the user: captures the user writes, notes an AI agent saved (third person; trusted less: they never end or reorder a job the user's own notes state), and old notes the user imported. Funes builds the user's timeline of jobs (employers and the user's own freelance businesses; clients are not employers; concurrent jobs are separate tracks) and answers questions typed into a search field. It must never guess: when the memories can't decide, it says so.

stories.json in the working directory holds existing stories: each has memories (text, date written, source) and the true timeline. For EACH story write 4 NEW questions the user might type, in the story's language(s), worded as different people would (casual, indirect, terse, long, Spanish where the story uses it, typos allowed), NOT copying the story's existing queries' wording. Mix the kinds across the set: before, after, year, current, previous (timeline questions about the user's own jobs), role_in_stint (the user's title inside one job), negative (uses a company name or "before/after" but doesn't ask which job the user held: someone else's job, a vendor, an event), no_answer (a job question the story can't answer). About one in five timeline questions should be undecidable from the memories (answer_org ""). answer_org: the organization a correct answer names, exactly as the story's timeline writes it, or "" when the memories can't decide it, and for role_in_stint, negative and no_answer. why: one short line. ids: n1, n2, ... per story.

Return JSON matching the schema: {"stories": [{"set": ..., "id": ..., "queries": [...]}]}. Read only stories.json."""

REFUSE_BRIEF = """You are labelling test questions for a feature of Funes Vault, a private personal-memory app. Everything is invented.

The user's vault holds exactly these four memories (all written by the user):
- m1 (2023-02-01): "From 2012 to 2015 I worked at Brindle."
- m2 (2023-02-02): "Since 2016 I run my own business Nudo Estudio."
- m3 (2023-02-03): "From 2016 to 2019 I worked at Copper Delta."
- m4 (2023-02-04): "I joined Alder Signal in January 2020."

questions.json in the working directory lists questions typed into the vault's search field. For EACH question, label independently, as a careful human reader would:
- work_timeline: true only if the question asks which organization the USER worked at or ran (as an employee or their own business) at some point in time relative to something (before/after an organization or date, in a year or range, now, previously). false for questions about other people's jobs, clients, vendors, events, things the user did at work, yes/no questions, titles, and anything else.
- operator: before, after, year, range, current, previous, or none (none when work_timeline is false).
- anchor: the organization or date the question is relative to, or "".
- answer: the organization a correct answer names from the four memories, or "" when work_timeline is false or the memories can't decide it.
- why: one short line.
Return JSON matching the schema: {"labels": [{"question": <exactly as given>, ...}]} in the same order."""


def run(prompt, schema, out, files, tag):
    RAW.mkdir(parents=True, exist_ok=True)
    W.LOG = RAW / f"astra-spiket-{tag}-provenance"
    W.LOG.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    work = Path(tempfile.mkdtemp(prefix=f"spiket-{tag}-astra-"))
    (work / "schema.json").write_text(json.dumps(schema))
    for name, path in files:
        shutil.copy(path, work / name)
    (W.LOG / f"{stamp}-prompt.txt").write_text(prompt)
    cmd = ["codex", "exec", "--ignore-user-config", "-m", W.MODEL, "-c", f"model_reasoning_effort={W.EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--json", "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=7200)
    (W.LOG / f"{stamp}-codex.log").write_text(f"exit {p.returncode}\n")
    W.audit(p.stdout, work, stamp)
    if p.returncode != 0 or not Path(out).exists():
        raise SystemExit(f"codex failed: {p.stderr[-800:]}")


def stories(a):
    W.OUT_RAW = RAW / "astra-workt.json"
    schema = json.loads(json.dumps(W.SCHEMA))
    if a.fix:
        tmp = W.OUT_RAW.with_suffix(".fixed.json")
        tmp.unlink(missing_ok=True)
        run(W.FIX.replace("{brief}", STORIES_BRIEF), schema, tmp, [("stories.json", W.OUT_RAW), ("notes.md", a.fix)], "workt")
        shutil.copy(W.OUT_RAW, W.LOG / f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-before-fix.json")
        tmp.replace(W.OUT_RAW)
    elif not W.OUT_RAW.exists():
        run(STORIES_BRIEF, schema, W.OUT_RAW, [], "workt")
    W.OUT_FIXTURE = HERE / "fixtures" / "stories-workt.json"
    return W.convert(json.loads(W.OUT_RAW.read_text()))


def wordings(a):
    src = OUT / "wordings-input.json"
    ss = []
    for set_name, f in (("work13", "stories-work13.json"), ("mixed", "stories-mixed.json")):
        for s in json.loads((HERE / "fixtures" / f).read_text())["stories"]:
            if not s.get("timeline"):
                continue
            ss.append({"set": set_name, "id": s["id"], "memories": [{k: m[k] for k in ("id", "text", "written", "source")} for m in s["memories"]],
                       "timeline": s["timeline"], "existing_queries": [q["query"] for q in s.get("queries", [])]})
    src.write_text(json.dumps({"stories": ss}, ensure_ascii=False, indent=1))
    schema = obj({"stories": L(obj({"set": S(), "id": S(), "queries": L(QUERY)}))})
    raw = RAW / "astra-spiket-wordings.json"
    if not raw.exists():
        run(WORDINGS_BRIEF, schema, raw, [("stories.json", src)], "wordings")
    d = json.loads(raw.read_text())
    out = {}
    for s in d["stories"]:
        out.setdefault(s["set"], {})[s["id"]] = s["queries"]
    (OUT / "wordings.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(f"wordings: {sum(len(v) for st in out.values() for v in st.values())} questions over {sum(len(st) for st in out.values())} stories")
    return []


def refuse(a):
    schema = obj({"labels": L(obj({"question": S(), "work_timeline": W.B, "operator": S(enum=["before", "after", "year", "range", "current", "previous", "none"]),
                                   "anchor": S(), "answer": S(), "why": S()}))})
    raw = RAW / "astra-spiket-refuse.json"
    if not raw.exists():
        run(REFUSE_BRIEF, schema, raw, [("questions.json", OUT / "refuse-questions.json")], "refuse")
    d = json.loads(raw.read_text())
    qs = json.loads((OUT / "refuse-questions.json").read_text())
    got = [l["question"] for l in d["labels"]]
    probs = [] if got == qs else [f"labels don't match the questions ({len(got)} vs {len(qs)})"]
    (OUT / "refuse-labels.json").write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n")
    print(f"refuse: {len(d['labels'])} labels, {sum(l['work_timeline'] for l in d['labels'])} read as work-timeline questions")
    return probs

ROUND2_BRIEF = W.BRIEF.replace(
    "WRITE 12 to 15 stories (ids w01…w15), each 5 to 9 memories in arrival order",
    "WRITE 12 stories (ids r01…r12), each 12 to 16 memories in arrival order").replace(
    "with 30 to 45 queries in all.",
    "with 72 to 84 queries in all. Every memory text is at most 170 characters. user_aliases lists EVERY name the stories use "
    "for the user. Role phrases use common relation words (manager, boss, colleague, coworker, sister, partner, friend, jefe, "
    "jefa, colega, hermana, pareja, amiga).\n\nABOUT HALF of each story's memories are everyday notes a real vault holds beside "
    "the job facts: meetings, deadlines, colleagues, commutes, lunches, payslips, trips, tools, hobbies, family. Many mention "
    "the employer or work words (\"work\", \"job\", \"office\", \"trabajo\") without stating anything new about the user's jobs, "
    "so a search for the question's words finds them too. They must not change the timeline.").replace(
    "QUERIES, 2 to 4 per story,", "QUERIES, 6 or 7 per story,").replace(
    "At least 30 queries must be decidable (answer_org not \"\").",
    "At least 25 queries must be decidable (answer_org not \"\"); AT LEAST 25 must be UNDECIDABLE timeline questions (kinds "
    "before, after, year, current or previous, answer_org \"\"): the memories genuinely can't tell, e.g. two jobs that may "
    "overlap, a hand-over within the same year or month where either order is possible, an anchor matching two stints of a "
    "rehire, an undated job that could sit anywhere, or only an agent's note says it; a careful human reader must agree. "
    "AT LEAST 15 must be negative: questions that use work words, a company name or before/after but don't ask which "
    "organization the user worked at (what the user got, kept or did after leaving a job, who they worked with, someone "
    "else's job, a client, a vendor, a yes/no question, the company's location).")

DISTRACTOR_BRIEF = """You are writing filler memories for a test of Funes Vault, a private personal-memory app. Everything is invented.

Write 40 short everyday memories a person might keep (at most 170 characters each), about half in English and half in Spanish or mixed: errands, family, friends, health appointments, hobbies, trips, recipes, books, home repairs, money, and work routines in general terms ("long day at work", "team lunch on Friday", "my job's new laptop policy", "reunión de trabajo a las 10"). They must NOT name any company, employer, business, school or brand, must not say when the person started, left or changed a job, and must not use a person's own name for the writer. Each has a date written (YYYY-MM-DD, 2014-01-01 to 2026-10-31) and an id d01…d40.
Return JSON matching the schema."""


def round2(a):
    W.OUT_RAW = RAW / "astra-workr.json"
    W.OUT_FIXTURE = HERE / "fixtures" / "stories-workr.json"
    if a.fix:
        tmp = W.OUT_RAW.with_suffix(".fixed.json")
        tmp.unlink(missing_ok=True)
        run(W.FIX.replace("{brief}", ROUND2_BRIEF), W.SCHEMA, tmp, [("stories.json", W.OUT_RAW), ("notes.md", a.fix)], "workr")
        shutil.copy(W.OUT_RAW, W.LOG / f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-before-fix.json")
        tmp.replace(W.OUT_RAW)
    elif not W.OUT_RAW.exists():
        run(ROUND2_BRIEF, W.SCHEMA, W.OUT_RAW, [], "workr")
    return W.convert(json.loads(W.OUT_RAW.read_text()))


def distractors(a):
    schema = obj({"memories": L(obj({"id": S(), "text": S(), "written": S()}))})
    raw = RAW / "astra-spiket-distractors.json"
    if not raw.exists():
        run(DISTRACTOR_BRIEF, schema, raw, [], "distractors")
    d = json.loads(raw.read_text())
    (OUT / "distractors.json").write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n")
    print(f"distractors: {len(d['memories'])}, longest {max(len(m['text']) for m in d['memories'])}")
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("part", choices=["stories", "wordings", "refuse", "round2", "distractors"])
    ap.add_argument("--fix")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    probs = {"stories": stories, "wordings": wordings, "refuse": refuse, "round2": round2, "distractors": distractors}[a.part](a)
    for p in probs:
        print("problem:", p)
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main())
