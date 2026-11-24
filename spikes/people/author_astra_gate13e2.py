#!/usr/bin/env python3
"""13e.2's timeline gate set (ADR-0032 decision 9, amended 2026-11-21), written blind by GPT-6-Astra through the Codex CLI
after the gate's code freeze (spikes/people/freeze-13e2.txt). Astra gets the feature's description, the format and what
to cover; never the code, a prompt, another set or a result. Every command Codex runs is audited to stay in its work
directory (author_astra_work13.audit). Its judgments are kept as written: this script converts the format, and
check_gate13e2.py fails on structural or label problems; fixes are Astra's (`--fix`), for those problems only.

    python3 author_astra_gate13e2.py stories        two halves of 12 stories (g01–g12, g13–g24; the second is told the
                                                    first's organization names so none repeats)
    python3 author_astra_gate13e2.py fillers        about 250 shared everyday memories naming no story organization
    python3 author_astra_gate13e2.py convert        fixtures/gate-13e2/stories.json and fillers.json from the raw files
    python3 author_astra_gate13e2.py stories --fix <notes> --half 1|2     a correction round from the checks' problems,
                                                    on only the stories the notes name
    python3 author_astra_gate13e2.py fillers --fix <notes>

The raw files and each round's prompt are kept in fixtures/raw/astra-gate13e2-provenance/.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import author_astra_work13 as W

HERE = Path(__file__).resolve().parent
RAW = HERE / "fixtures" / "raw"
LOG = RAW / "astra-gate13e2-provenance"
OUT = HERE / "fixtures" / "gate-13e2"
MODEL, EFFORT = "gpt-6-astra", "high"
FREEZE = "spikes/people/freeze-13e2.txt"
S, N, B, L, obj = W.S, W.N, W.B, W.L, W.obj

TRAPS = ["rehire", "possible_overlap", "same_year_handover", "agent_competitor", "rename", "exact_day", "concurrent_slots",
         "untrusted_end", "freelance_clients", "vendor", "gap", "precision", "import", "spanish", "undated_order"]
KINDS = ["before", "after", "in_year", "on_day", "between", "current", "previous", "first_job", "how_long", "order_yes_no",
         "list", "title_in_job", "someone_else", "vendor", "other"]

MEMORY = obj({
    "id": S(), "text": S(), "written": S(), "source": S(enum=["capture", "agent", "import"]),
    "filler": B,
    "sensitivity": S(enum=["low", "internal"]),
    "names": L(obj({"surface": S(), "person": S()})),
    "organizations": L(obj({"surface": S(), "org": S(), "relation": S(enum=["employer", "self_employed", "client", "vendor", "other"])})),
    "jobs": L(obj({"org": S(), "kind": S(enum=["employee", "self_employed", "client"]), "title": N("string"),
                   "status": S(enum=["current", "former", "unknown"]), "polarity": S(enum=["positive", "negative"]),
                   "start": N("string"), "end": N("string"), "time": N("string"),
                   "preceded_by": N("string"), "followed_by": N("string"), "also_called": N("string")})),
})
STORY_SCHEMA = obj({"user_name": S(), "user_aliases": L(S()), "stories": L(obj({
    "id": S(), "title": S(), "traps": L(S(enum=TRAPS)),
    "memories": L(MEMORY),
    "timeline": L(obj({"org": S(), "role": S(), "start": S(), "end": S(),
                       "kind": S(enum=["employee", "self_employed", "client", "vendor", "study"]), "memories": L(S())})),
    "questions": L(obj({"id": S(), "class": S(enum=["decidable", "undecidable", "negative"]), "kind": S(enum=KINDS),
                        "query": S(), "answer_org": S(), "traps": L(S(enum=TRAPS)), "why": S()})),
}))})
FILLER_SCHEMA = obj({"memories": L(obj({"id": S(), "text": S(), "written": S(), "source": S(enum=["capture", "import"])}))})

FEATURE = """THE FEATURE (work history in search answers). Funes Vault is a private personal-memory app on the Mac. Everything here is invented. The vault holds short memories about one user: captures the user writes, notes an AI agent saved about the user (third person, "the user" or the user's name; Funes trusts them less: they never end, reorder or add a job against what the user's own notes say), and old notes the user imported (the user's own words, written long ago). A language model reads each memory and records the user's own jobs (employers and the user's own freelance businesses; clients are not employers; concurrent jobs are separate tracks), with dates and "before X" / "after leaving X" exactly as written. When the user types a question into the vault's search field, another model answers from the matching memories and the user's work history, and code checks every answer about which organization the user held relative to a time or another job. It must never guess: when the user's own memories can't decide, the answer must say it can't tell."""

STORIES_BRIEF = FEATURE + """

Today is 2026-10-29. WRITE 12 stories (ids {ids}) about ONE user (invent a name; Spanish or English is fine; gender never stated). Each story is a separate test: the same user, a different life, so each story stands alone. Each story has 6 to 10 memories, dated YYYY-MM-DD between 2012-01-01 and 2026-10-28, including exactly 2 FILLER memories (filler: true): everyday notes that name one of the story's organizations in a role that is NOT the user's job (bought something from it, a friend or relative works there, read news about it, a delivery, a meeting with someone from it), placed by date among the other memories; a filler's jobs list is empty. Organization names must be invented, distinctive, and never reused between stories{avoid}.

Across the 12 stories write 78 to 90 QUESTIONS, 6 to 8 per story, as the user would type them into a search field, worded naturally and variously (terse, casual, long, indirect; some in Spanish; small typos allowed). Each question has a class:
- decidable (at least 28): asks which organization the user worked at (or ran) relative to a time or another job, and the user's OWN memories (captures and imports, never an agent's note) decide it. answer_org: the organization a correct answer names, exactly as the timeline writes it.
- undecidable (at least 28): the same kinds of questions, worded just as naturally, where the user's own memories can't decide it; answer_org "". Make them look as answerable as the decidable ones. A careful human reader must agree the story can't decide them.
- negative (at least 22): questions that look related but don't ask which organization the user held relative to a time: first job, how long a job lasted, "did I work at A before B?" (yes/no), lists ("every company I've worked for"), the user's title inside one job, someone else's job, a vendor, an event. answer_org: the organization a correct answer names if it names one, else "". "why" states the correct answer.
Kinds: before, after, in_year, on_day, between, current, previous, first_job, how_long, order_yes_no, list, title_in_job, someone_else, vendor, other.

TRAPS. Each question lists the traps it tests (or none); across the 12 stories at least 3 UNDECIDABLE questions, and also some decidable ones, for EACH of:
- rehire: the user left an employer and rejoined it later. A question whose stints give different answers is undecidable unless it names which stint ("the first time", "when I came back").
- possible_overlap: two jobs may have overlapped; the user says they don't remember, or the dates allow either order.
- same_year_handover: one job ended and another began in the same year, known only to the year, so their order (or which one held at a date) can't be told.
- agent_competitor: only an agent's note claims another job or an end; the user's own notes don't confirm it. Questions whose answer would rest on the agent's note are undecidable (or decided by the user's notes alone).
- rename: an employer renamed (a trusted note states it); questions may use either name; the answer is the same employer (answer_org: the timeline's name).
- exact_day: a question about a specific day inside a range known only to the year or month.
Also cover, several times: concurrent_slots (a day job and a freelance business), untrusted_end, freelance_clients (clients aren't employers), vendor, gap, precision ("2019", "March 2019", "15 March 2019"), import, spanish, undated_order ("before X", "after leaving X").

FORMAT per story:
- memories: id (m1…; fillers too), text, written, source, filler, sensitivity (low or internal), and:
  - names: every PERSON name in the text: surface (exact substring of text), person ("user" for the user's own name, else a short id like p1).
  - organizations: every organization named: surface (exactly as written), org (one canonical name per organization within the story), relation (employer, self_employed, client, vendor, other).
  - jobs: the user's own jobs and client engagements THIS memory states: org (as written in this memory), kind, title (as written, or null), status (current, former, unknown), polarity (negative for "I never worked at X"), start, end, time, preceded_by, followed_by, also_called EXACTLY as written (substrings of text), or null. Never a date the memory doesn't write.
- timeline: the user's true jobs, client engagements, gaps (kind study) and vendors (kind vendor, start/end ""): org (canonical), role, start and end (YYYY, YYYY-MM or YYYY-MM-DD; end "" if current), kind, the ids of the memories that state it.
- questions: id (q1…), class, kind, query, answer_org, traps, why (one line: why that answer, or why it can't be decided).

Do not look for or use any other files in the workspace. Return JSON matching the schema."""

FILLERS_BRIEF = """You are writing background memories for a test of a private personal-memory app. Everything is invented.

Write 250 short memories a person might keep in a notes app over the years: errands, health, family, friends, hobbies, travel, reading, cooking, money, home repairs, appointments, ideas, quotes. Mix lengths (one line to four sentences), styles (terse notes, full sentences, lists written as a sentence), and languages (about one in five in Spanish). About one in six mentions work in passing WITHOUT ever saying where the writer works, worked, will work, or whom they work for (no employer, no job title tied to an organization, no "I joined", "I left", "my company", "mi empresa"); other people's jobs are fine ("my cousin is a nurse at a hospital in Leeds"). A few are old imported notes, source import; the rest capture (no AI assistant's notes). Organizations may appear as shops, brands, apps, airlines, banks or public services, but NEVER any of these names, or anything close to them: {avoid}. Never use a person name from this list either: {names}.

Dates YYYY-MM-DD between 2012-01-01 and 2026-10-28, spread across the years. ids f001…f250.

Do not look for or use any other files in the workspace. Return JSON matching the schema."""

FIX = """You wrote the attached file (input.json in the working directory) for this brief:

<brief>
{brief}
</brief>

A script checked it and found the problems listed in notes.md in the working directory. Fix exactly those: correct the labels, or reword a memory or question when that is the cleaner fix (keep surfaces exact substrings, and dates in jobs exactly as written). Keep every id and everything the problems don't touch. Return the WHOLE corrected file as JSON matching the schema. Read only input.json and notes.md, and only with cat, head, tail, sed, grep, jq or wc: running python or any other program fails the round. Write the corrected file as your answer, not with a command."""


def frozen():
    env = dict(os.environ, FACTS_FREEZE=FREEZE)
    f = subprocess.run(["sh", str(HERE.parent.parent / "scripts/facts_freeze.sh"), "check"], capture_output=True, text=True, env=env)
    if f.returncode != 0:
        raise SystemExit("author: the gate's code freeze doesn't hold: " + (f.stderr or f.stdout)[-400:])


def run_codex(prompt, schema, out, files=()):
    frozen()
    LOG.mkdir(parents=True, exist_ok=True)
    W.LOG = LOG
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    work = Path(tempfile.mkdtemp(prefix="facts-gate13e2-astra-"))
    (work / "schema.json").write_text(json.dumps(schema))
    for name, path in files:
        shutil.copy(path, work / name)
    (LOG / f"{stamp}-prompt.txt").write_text(prompt)
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--json", "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    pending = out.with_suffix(".pending.json")
    pending.unlink(missing_ok=True)
    cmd[cmd.index(str(out))] = str(pending)
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=7200)
    (LOG / f"{stamp}-codex.log").write_text(f"exit {p.returncode}\n")
    try:
        W.audit(p.stdout, work, stamp)
        strict_audit(p.stdout, stamp)
    except SystemExit:
        pending.unlink(missing_ok=True)            # a round that failed the audit leaves nothing to use
        raise
    if p.returncode != 0 or not pending.exists():
        raise SystemExit(f"codex failed: {p.stderr[-800:]}")
    json.loads(pending.read_text())
    pending.replace(out)


ALLOWED = {"cat", "head", "tail", "wc", "ls", "jq", "sed", "nl", "grep", "rg"}


def strict_audit(events, stamp):
    """Blindness, beyond W.audit's absolute paths: every event is a message, reasoning or a command (no other tool), and
    every command is a reading tool from an allowlist over plain relative names: no path separator but "./", no "..",
    "~", variables, substitutions or pipes into other programs. Codex needs nothing else: its inputs are in the work
    directory."""
    import re
    import shlex
    bad = []
    for line in events.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        item = e.get("item") if isinstance(e.get("item"), dict) else None
        if not item:
            continue
        kind = item.get("type") or item.get("item_type")
        if kind in ("agent_message", "reasoning", "todo_list", None):
            continue
        if kind != "command_execution":
            bad.append(f"tool {kind}")
            continue
        c = item.get("command")
        c = c if isinstance(c, str) else " ".join(map(str, c or []))
        if re.search(r"\.\.|~|\$|`|[\n\r]", c):
            bad.append(c)
            continue

        def tokens(s):
            """Shell words, with every unquoted operator its own token: a quoted "|" is a jq filter's own pipe (13e.2's
            r3 set), not a shell's."""
            lex = shlex.shlex(s, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            lex.commenters = ""                     # the shell reads "x#" as a word, not a comment
            return list(lex)

        def operator(t):
            return bool(t) and set(t) <= set("();<>|&")
        try:
            outer = tokens(c)
            if outer and re.fullmatch(r"(/bin/)?(ba|z)?sh", outer[0]):
                if len(outer) != 3 or outer[1] not in ("-c", "-lc"):
                    bad.append(c)
                    continue
                inner = outer[2]
            else:
                inner = c
            words = tokens(inner)
        except ValueError:
            bad.append(c)
            continue
        if any(map(operator, outer + words)):
            bad.append(c)
            continue
        # Only the forms Codex reads with: jq without file-loading options (modules, -f, --rawfile), sed printing lines.
        flags = [w for w in words[1:] if w.startswith("-")]
        if words and words[0] == "jq" and (
                any(not re.fullmatch(r"-[crSMesnja]+|--(raw-output|compact-output|sort-keys|slurp|tab|monochrome-output)", f)
                    for f in flags) or any(re.search(r"\b(import|include|input_filename)\b", w) for w in words[1:])):
            bad.append(c)
            continue
        script = next((w for w in words[1:] if not w.startswith("-")), "")
        if words and words[0] == "sed" and (any(f not in ("-n", "-E") for f in flags)
                                            or not re.fullmatch(r"\d+(,\d+)?p|/[^/]*/p", script)):
            bad.append(c)
            continue
        # Every program's options from a list: none reads other files or runs a program (grep -f, rg --pre,
        # wc --files0-from); no word zsh expands into a path ("=sh").
        opts = {"grep": r"-[niFwcloEhHvx]+|-[ABCm]\d*|--(line-number|ignore-case|fixed-strings|count|word-regexp)",
                "rg": r"-[niFwcloEhHvx]+|-[ABCm]\d*|--(line-number|ignore-case|fixed-strings|count|word-regexp)",
                "head": r"-[nc]\d*|-\d+", "tail": r"-[nc]\+?\d*|-\d+", "wc": r"-[lcwm]+", "ls": r"-[la1hR]+",
                "nl": r"-ba|-b|a"}
        if words and (any(w.startswith("=") for w in words)
                      or (words[0] in opts and any(not re.fullmatch(opts[words[0]], f) for f in flags))):
            bad.append(c)
            continue
        # A sed, grep or rg script may hold slashes; every other word is a plain relative name.
        args = [w for w in words[1:] if not w.startswith("-")]
        if words and words[0] in ("sed", "grep", "rg") and args:
            args = args[1:]
        if not words or words[0] not in ALLOWED or any("/" in w and not w.startswith("./") for w in args):
            bad.append(c)
    if bad:
        raise SystemExit(f"author: Codex did something outside the reading allowlist: {bad[:5]}")


def raw(name):
    return RAW / f"astra-gate13e2-{name}.json"


def orgs_of(path):
    d = json.loads(path.read_text())
    return sorted({o["org"] for s in d["stories"] for m in s["memories"] for o in m["organizations"]}
                  | {t["org"] for s in d["stories"] for t in s["timeline"]})


def stories_brief(half, avoid, user=None):
    ids = "g01…g12" if half == 1 else "g13…g24"
    av = "" if not avoid else (" (the other half of the set already uses these organizations, never reuse or resemble them: "
                               + ", ".join(avoid) + ")")
    brief = STORIES_BRIEF.replace("{ids}", ids).replace("{avoid}", av)
    if user:
        brief = brief.replace("about ONE user (invent a name; Spanish or English is fine; gender never stated)",
                              f"about ONE user, named {user['user_name']} (also written {', '.join(user['user_aliases'])}; "
                              "gender never stated; return that name and those aliases)")
    return brief


def fix(brief, schema, path, notes):
    tmp = path.with_suffix(".fixed.json")
    tmp.unlink(missing_ok=True)
    run_codex(FIX.replace("{brief}", brief), schema, tmp, [("input.json", path), ("notes.md", notes)])
    shutil.copy(path, LOG / f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-before-fix-{path.name}")
    tmp.replace(path)


def fix_stories(brief, path, notes):
    """A story correction round on only the stories the notes name, merged back by id. A whole half is big enough that
    Astra reaches for python to read it, which the audit refuses (13e.2's second set, the author's decision)."""
    import re
    full = json.loads(path.read_text())
    ids = set(re.findall(r"\bg\d{2}\b", Path(notes).read_text()))
    part = dict(full, stories=[s for s in full["stories"] if s["id"] in ids])
    if not part["stories"]:
        raise SystemExit("author: the notes name no story of this half")
    given = path.with_suffix(".subset.json")
    given.write_text(json.dumps(part, ensure_ascii=False, indent=1))
    tmp = path.with_suffix(".fixed.json")
    tmp.unlink(missing_ok=True)
    run_codex(FIX.replace("{brief}", brief), STORY_SCHEMA, tmp, [("input.json", given), ("notes.md", notes)])
    fixed = {s["id"]: s for s in json.loads(tmp.read_text())["stories"]}
    if set(fixed) != {s["id"] for s in part["stories"]}:
        raise SystemExit("author: the fix returned other stories than it was given")
    shutil.copy(path, LOG / f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-before-fix-{path.name}")
    full["stories"] = [fixed.get(s["id"], s) for s in full["stories"]]
    path.write_text(json.dumps(full, ensure_ascii=False))
    tmp.unlink()
    given.unlink()


def convert():
    """The two halves → stories.json (work13's story format; questions under `queries` with their labels), and fillers."""
    a, b = json.loads(raw("half1").read_text()), json.loads(raw("half2").read_text())
    stories = []
    for half in (a, b):
        for s in half["stories"]:
            mems = [{"id": m["id"], "text": m["text"], "written": m["written"], "source": m["source"],
                     "sensitivity": m["sensitivity"], "filler": m["filler"], "names": m["names"],
                     "organizations": m["organizations"],
                     "jobs": [{k: v for k, v in j.items() if v is not None} for j in m["jobs"]]} for m in s["memories"]]
            stories.append({"id": s["id"], "title": s["title"], "traps": s["traps"], "memories": mems,
                            "timeline": s["timeline"], "queries": s["questions"]})
    aliases = sorted(set(a["user_aliases"]) | {a["user_name"]} | set(b["user_aliases"]) | {b["user_name"]})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "stories.json").write_text(json.dumps({"user": {"name": a["user_name"], "aliases": aliases}, "author": MODEL,
                                                  "stories": stories}, ensure_ascii=False, indent=1) + "\n")
    f = json.loads(raw("fillers").read_text())
    (OUT / "fillers.json").write_text(json.dumps({"author": MODEL, "memories": [
        {"id": m["id"], "text": m["text"], "written": m["written"], "source": m["source"]} for m in f["memories"]]},
        ensure_ascii=False, indent=1) + "\n")
    print(f"{len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, "
          f"{sum(len(s['queries']) for s in stories)} questions, {len(f['memories'])} shared fillers")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["stories", "fillers", "convert"])
    ap.add_argument("--fix")
    ap.add_argument("--half", type=int, choices=[1, 2])
    a = ap.parse_args()
    RAW.mkdir(parents=True, exist_ok=True)
    if a.what == "stories":
        for half in ([a.half] if a.half else [1, 2]):
            first = json.loads(raw("half1").read_text()) if half == 2 and raw("half1").exists() else None
            avoid = orgs_of(raw("half1")) if first else []
            brief = stories_brief(half, avoid, first)
            if a.fix:
                fix_stories(brief, raw(f"half{half}"), a.fix)
            elif not raw(f"half{half}").exists():
                run_codex(brief, STORY_SCHEMA, raw(f"half{half}"))
    elif a.what == "fillers":
        avoid = orgs_of(raw("half1")) + orgs_of(raw("half2"))
        names = sorted({n["surface"] for h in ("half1", "half2") for s in json.loads(raw(h).read_text())["stories"]
                        for m in s["memories"] for n in m["names"]})
        brief = FILLERS_BRIEF.replace("{avoid}", ", ".join(avoid)).replace("{names}", ", ".join(names))
        if a.fix:
            fix(brief, FILLER_SCHEMA, raw("fillers"), a.fix)
        elif not raw("fillers").exists():
            run_codex(brief, FILLER_SCHEMA, raw("fillers"))
    else:
        convert()
    return 0


if __name__ == "__main__":
    sys.exit(main())
