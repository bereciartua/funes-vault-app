#!/usr/bin/env python3
"""Phase 13a.2's fresh blind work fixture (`work13`), for the works-at timeline gate (memory processing §11.10). GPT-6-Astra
(through the Codex CLI, on the author's ChatGPT plan) writes it after the code freeze, in the mixed set's story format with
each memory's jobs as written, so the harness plays it with both call groups and its own labels drive the scripted plays.
Astra gets the feature's rules, the format and what to cover; never another set, the code, a prompt or any result. Its
judgments are kept as written: this script converts the format and fails on structural or label problems
(`fixture_counts.py --check work13`); fixes are Astra's (`--fix`), for those problems only.

    python3 author_astra_work13.py                  -> fixtures/raw/astra-work13.json, fixtures/stories-work13.json
    python3 author_astra_work13.py --fix <notes>    a fresh Astra instance corrects the raw set from the checks' problems
    python3 author_astra_work13.py --convert        converts the raw file only
The prompt and Codex's output for every round are kept beside the raw file (provenance).
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "fixtures" / "raw"
OUT_RAW = RAW / "astra-work13.json"
LOG = RAW / "astra-work13-provenance"
OUT_FIXTURE = HERE / "fixtures" / "stories-work13.json"
MODEL, EFFORT = "gpt-6-astra", "high"
TYPES = ["partner", "parent", "child", "sibling", "other_family", "friend", "manager", "colleague", "care", "other"]
TRAPS = ["untrusted_end", "concurrent_slots", "rehire", "promotion", "freelance_clients", "vendor", "gap", "renamed", "import",
         "spanish", "negative_wording", "undated_order", "precision"]
S = lambda **kw: {"type": "string", **kw}
N = lambda t: {"type": [t, "null"]}
B = {"type": "boolean"}
L = lambda item: {"type": "array", "items": item}


def obj(props):
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


SCHEMA = obj({"user_name": S(), "user_aliases": L(S()), "stories": L(obj({
    "id": S(), "title": S(), "traps": L(S(enum=TRAPS)),
    "people": L(obj({"id": S(), "names": L(S()), "group_type": N("string"), "group_label": N("string")})),
    "memories": L(obj({
        "id": S(), "text": S(), "written": S(), "source": S(enum=["capture", "agent", "import"]),
        "sensitivity": S(enum=["low", "internal", "sensitive", "restricted"]),
        "names": L(obj({"surface": S(), "person": S(), "of": L(S())})),
        "roles": L(obj({"surface": S(), "person": S(), "resolvable": B})),
        "facts": L(obj({"person": N("string"), "type": S(enum=TYPES), "label": N("string"),
                        "status": S(enum=["current", "former"]), "polarity": S(enum=["positive", "negative"]),
                        "deceased": B, "only": B, "count": N("integer")})),
        "organizations": L(obj({"surface": S(), "org": S(), "relation": S(enum=["employer", "self_employed", "client", "vendor", "other"])})),
        "jobs": L(obj({"org": S(), "kind": S(enum=["employee", "self_employed", "client"]), "title": N("string"),
                       "status": S(enum=["current", "former", "unknown"]), "polarity": S(enum=["positive", "negative"]),
                       "start": N("string"), "end": N("string"), "time": N("string"),
                       "preceded_by": N("string"), "followed_by": N("string"), "also_called": N("string")})),
        "not_linked": L(S())})),
    "orders": L(L(S())),
    "timeline": L(obj({"org": S(), "role": S(), "start": S(), "end": S(), "kind": S(enum=["employee", "self_employed", "client", "vendor", "study"]),
                       "memories": L(S())})),
    "queries": L(obj({"id": S(), "kind": S(enum=["before", "after", "year", "current", "previous", "role_in_stint", "negative", "no_answer"]),
                      "query": S(), "answer_org": S()})),
}))})

BRIEF = """You are writing a frozen, blind test set for a feature of Funes Vault, a private personal-memory app on the Mac. Everything is invented.

THE FEATURE (work history). The vault holds short memories about the user (choose an invented name; gender never stated; agents' notes may use the name or "the user"). Memories arrive over time: captures the user writes, notes an AI agent saved about the user (third person; Funes trusts them less: they must never end or reorder a job the user's own notes state), and old notes the user imports. A language model reads each memory and records the user's own jobs: the organization (an employer, or the user's own freelance business), the user's title, and start and end dates, "before X" and "after leaving X", exactly as the memory writes them; and the organizations the user did freelance work for (clients). Code then builds the user's timeline of jobs and answers the user's questions about it, typed into a search field. It must never guess: when the memories can't decide, it says so. Concurrent jobs (a day job and a side business) are separate tracks; one doesn't end the other.

WRITE 12 to 15 stories (ids w01…w15), each 5 to 9 memories in arrival order, dated YYYY-MM-DD between 2014-01-01 and 2026-10-31, with 30 to 45 queries in all. Across the set cover, each SEVERAL times, and tag each story with what it covers (traps):
- untrusted_end: an agent's note that claims the user left a job, or started a new one, that the user's own notes contradict or never mention;
- concurrent_slots: two jobs at once (a day job and a freelance business), where a question about one must not be answered from the other;
- rehire: leaving an employer and rejoining it later; promotion: a new title within one job; renamed: a company renamed or written two ways ("Acme" / "Acme Inc.", "also called");
- freelance_clients: a freelance period with clients (clients are not employers); vendor: companies the user only buys from or uses (an airline, a coworking space, an accountant's firm), named in work contexts;
- gap: a gap (study, a sabbatical, looking for work); undated_order: memories that only say "before X" or "after leaving X"; precision: dates at different precision ("2019", "March 2019", "15 March 2019");
- import: an old note imported recently, about the past; spanish: Spanish or mixed Spanish-English memories and questions;
- negative_wording: questions that use "before" / "after" or a company name without asking about the user's job.
Some memories also mention people (a manager, colleagues, family) with their relation to the user, as people do. Mark one or two memories "restricted" (very private, e.g. a salary negotiation); the rest "low" or "internal".

QUERIES, 2 to 4 per story, as the user would type them, worded naturally and variously, as different people would phrase them (paraphrases welcome): kinds before (the job before an organization), after (the job after one), year (where the user worked at a date), current, previous (the user's previous job), role_in_stint (a question about the user's title inside one job, not a timeline question), negative (as above), no_answer (a job question the story can't answer). answer_org: the organization a correct answer names (the timeline's org, exactly), or "" when the story can't decide it, or for negative, role_in_stint and no_answer. At least 30 queries must be decidable (answer_org not "").

FORMAT, per story:
- people: every person (not the user): id, names (every way the story writes their name; empty if never named), and for a person never named, group_type and group_label (relation type and the word used); otherwise null.
- memories: id (m1…), text, written, source, sensitivity, and:
  - names: every name in the text that refers to a PERSON: surface (exactly as written, a substring of text), person (a people id; "user" for the user's own name; "?" when it can't be told which of several same-named people is meant, with their ids in "of"; otherwise "of" is empty). Company names are not person names.
  - roles: every phrase where the user's own relation to a PERSON is referred to by role ("My manager", "mi jefa", "the user's colleague"): surface (exact, starting at the owner), person, resolvable (could a careful reader of the WHOLE story tell who it is?). Not job phrases like "my job".
  - facts: the user's relations to people this memory states: person (id or null), type, label (the word used, or null), status, polarity, deceased, only, count.
  - organizations: every organization named in the text: surface (as written), org (one canonical name per organization across the story), relation (employer, self_employed, client, vendor, or other: e.g. a relative's employer).
  - jobs: the user's own jobs and client engagements THIS memory states, each with org (as written in this memory), kind, title (as written, or null), status (current, former, or unknown), polarity (negative for "I never worked at X"), and start, end, time, preceded_by, followed_by, also_called EXACTLY as the memory writes them (a substring of text: "March 2019", "2019", "Acme"), or null when the memory doesn't say. Never a date the memory doesn't write.
  - not_linked: people this memory must NOT be linked to.
- orders: zero or one other arrival order worth testing (all memory ids), only where the order must not change the answers.
- timeline: the user's true jobs, client engagements, gaps (kind study for a study or break) and vendors (kind vendor, start/end ""): org (canonical), role, start and end as you intend them (YYYY, YYYY-MM or YYYY-MM-DD; end "" if current), kind, and the ids of the memories that state it.
- queries: as above.

Do not look for or use any other files in the workspace. Return JSON matching the schema."""

FIX = """You wrote the attached test set (stories.json in the working directory) for this brief:

<brief>
{brief}
</brief>

A script checked its structure and labels and found the problems listed in notes.md in the working directory. Fix exactly those: correct the labels, or reword a memory's text when that is the cleaner fix (keep surfaces exact substrings, and dates in jobs exactly as written). Keep every story and memory id, and everything the problems don't touch. Return the WHOLE corrected set as JSON matching the schema. Read only stories.json and notes.md."""


def frozen():
    """The blind sets are written only after the code freeze, and only while it holds."""
    f = subprocess.run(["sh", str(HERE.parent.parent / "scripts/facts_freeze.sh"), "check"], capture_output=True, text=True)
    if f.returncode != 0:
        raise SystemExit("author: the code freeze doesn't hold (scripts/facts_freeze.sh check): " + (f.stderr or f.stdout)[-400:])


def audit(events, work, stamp):
    """Blindness, checked: every command Codex ran stays inside its work directory. Only the commands are kept (their
    output can quote the set); a command naming any other absolute path fails the round."""
    cmds = []
    for line in events.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        item = e.get("item") or e.get("msg") or {}
        c = item.get("command") if isinstance(item, dict) else None
        if c:
            cmds.append(c if isinstance(c, str) else " ".join(map(str, c)))
    (LOG / f"{stamp}-commands.json").write_text(json.dumps(cmds, indent=1, ensure_ascii=False) + "\n")
    w = str(work.resolve())
    def reaches_data(path):          # the user's files, the repo, temp folders and volumes (not /bin or /usr tools)
        r = str(Path(path).expanduser().resolve())
        return not r.startswith(w) and r.startswith(("/Users", "/private", "/var", "/tmp", "/Volumes", "/home"))
    outside = [c for c in cmds for path in __import__("re").findall(r"(?<![\w.])(/[^\s'\";|&]+|~[^\s'\";|&]*)", c)
               if reaches_data(path)]
    if outside:
        raise SystemExit(f"author: Codex ran commands outside its work directory: {outside[:5]}")


def run_codex(prompt, out, files=()):
    frozen()
    LOG.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    work = Path(tempfile.mkdtemp(prefix="facts-work13-astra-"))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    for name, path in files:
        shutil.copy(path, work / name)
    (LOG / f"{stamp}-prompt.txt").write_text(prompt)
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--json", "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=7200)
    (LOG / f"{stamp}-codex.log").write_text(f"exit {p.returncode}\n")
    audit(p.stdout, work, stamp)      # no transcript: it can quote the set
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-800:]}")


def convert(data):
    stories, problems = [], []
    for s in data["stories"]:
        people = {p["id"]: ({"names": p["names"]} if p["names"] or not p["group_type"]
                            else {"names": [], "group": [p["group_type"], p["group_label"]]}) for p in s["people"]}
        mems = []
        for m in s["memories"]:
            for x in m["names"] + m["roles"] + m["organizations"]:
                if x["surface"] not in m["text"]:
                    problems.append(f"{s['id']} {m['id']}: '{x['surface']}' not in text")
            mems.append({"id": m["id"], "text": m["text"], "written": m["written"], "source": m["source"],
                         "sensitivity": m["sensitivity"],
                         "names": [{"surface": n["surface"], "person": n["person"], **({"of": n["of"]} if n["person"] == "?" else {})}
                                   for n in m["names"]],
                         "roles": m["roles"], "facts": m["facts"], "organizations": m["organizations"],
                         "jobs": [{k: v for k, v in j.items() if v is not None} for j in m["jobs"]], "not_linked": m["not_linked"]})
        ids = [m["id"] for m in mems]
        for o in s["orders"]:
            if sorted(o) != sorted(ids) or o == ids:
                problems.append(f"{s['id']}: order {o} isn't another permutation of the memories")
        stories.append({"id": s["id"], "title": s["title"], "traps": s["traps"], "people": people, "memories": mems,
                        "orders": [o for o in s["orders"] if sorted(o) == sorted(ids) and o != ids],
                        "timeline": s["timeline"], "queries": s["queries"]})
    out = {"user": {"name": data["user_name"], "aliases": data["user_aliases"]}, "author": MODEL, "stories": stories}
    OUT_FIXTURE.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, "
          f"{sum(len(s['queries']) for s in stories)} queries, {sum(len(s['orders']) for s in stories)} extra orders")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", help="the checks' problems (notes), for a correction round")
    ap.add_argument("--convert", action="store_true")
    a = ap.parse_args()
    RAW.mkdir(parents=True, exist_ok=True)
    if a.fix:
        tmp = OUT_RAW.with_suffix(".fixed.json")
        tmp.unlink(missing_ok=True)
        run_codex(FIX.replace("{brief}", BRIEF), tmp, [("stories.json", OUT_RAW), ("notes.md", a.fix)])
        json.loads(tmp.read_text())
        shutil.copy(OUT_RAW, LOG / f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-before-fix.json")   # every round kept
        tmp.replace(OUT_RAW)
    elif not a.convert and not OUT_RAW.exists():
        run_codex(BRIEF, OUT_RAW)
    problems = convert(json.loads(OUT_RAW.read_text()))
    for p in problems:
        print("problem:", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
