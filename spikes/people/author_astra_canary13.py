#!/usr/bin/env python3
"""Phase 13a.2's registry canary (ADR-0032's canary row): after the Swift code freeze, GPT-6-Astra, given only the shipped
registry (`Resources/facts-registry.json`) and its documentation (memory processing §11.2, and the spike's REGISTRY.md for
the field meanings), writes (1) a registry that turns on the partner timeline as data only, and (2) a blind fixture of
relationship histories with each memory's facts and dates as written, with negatives, concurrency, untrusted text, a
restricted memory (privacy) and the user's corrections, and questions reported as distinct. It never sees the code, a
prompt, another set or a result. The code must work with no source change (`scripts/facts_freeze.sh --check`).

    python3 author_astra_canary13.py                -> fixtures/raw/astra-canary13.json (after the freeze only),
                                                       fixtures/canary-13a2/registry.json and stories.json
    python3 author_astra_canary13.py --fix <notes>  a fresh Astra instance corrects the raw output from the checks' problems
    python3 author_astra_canary13.py --convert      converts the raw file only
The conversion fails if the registry changes anything but the partner predicate, or on structural or label problems
(`fixture_counts.py --check canary13`). The Swift test FactsCannedPlayTests plays it on its own labels.
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
REPO = HERE.parent.parent
RAW = HERE / "fixtures" / "raw"
OUT_RAW = RAW / "astra-canary13.json"
LOG = RAW / "astra-canary13-provenance"
DEST = HERE / "fixtures" / "canary-13a2"
REGISTRY = REPO / "Packages/FunesCore/Sources/FunesCore/Resources/facts-registry.json"
MODEL, EFFORT = "gpt-6-astra", "high"
TYPES = ["partner", "parent", "child", "sibling", "other_family", "friend", "manager", "colleague", "care", "other"]
S = lambda **kw: {"type": "string", **kw}
N = lambda t: {"type": [t, "null"]}
B = {"type": "boolean"}
L = lambda item: {"type": "array", "items": item}


def obj(props):
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


SCHEMA = obj({"registry_json": S(), "registry_changes": L(S()), "user_name": S(), "user_aliases": L(S()), "stories": L(obj({
    "id": S(), "title": S(), "traps": L(S(enum=["successive", "precision", "undated_breakup", "second_episode", "ex", "concurrent",
                                                "gap", "spanish", "agent_note", "others_partners", "denial", "restricted", "correction"])),
    "people": L(obj({"id": S(), "names": L(S()), "group_type": N("string"), "group_label": N("string")})),
    "memories": L(obj({
        "id": S(), "text": S(), "written": S(), "source": S(enum=["capture", "agent", "import"]),
        "sensitivity": S(enum=["low", "internal", "sensitive", "restricted"]),
        "names": L(obj({"surface": S(), "person": S(), "of": L(S())})),
        "roles": L(obj({"surface": S(), "person": S(), "resolvable": B})),
        "facts": L(obj({"person": N("string"), "type": S(enum=TYPES), "label": N("string"),
                        "status": S(enum=["current", "former"]), "polarity": S(enum=["positive", "negative"]),
                        "deceased": B, "only": B, "count": N("integer"),
                        "start": N("string"), "end": N("string"), "time": N("string"),
                        "preceded_by": N("string"), "followed_by": N("string")})),
        "not_linked": L(S())})),
    "orders": L(L(S())),
    "corrections": L(obj({"after": S(), "op": S(enum=["reject", "start", "end"]), "person": S(), "memory": N("string"),
                          "surface": N("string"), "value": N("string")})),
    "timeline": L(obj({"person": S(), "start": S(), "end": S(), "memories": L(S())})),
    "queries": L(obj({"id": S(), "kind": S(enum=["before", "after", "year", "current", "previous", "negative"]), "query": S(),
                      "answer_person": S()})),
}))})

BRIEF = """You are testing whether a registry-driven design really needs no code to support a new kind of question. Everything is invented.

CONTEXT. Funes Vault, a private memory app, learns facts about the user from short memories. What each kind of fact means, and how it is used, is defined only in data: the attached registry.json, documented in registry-spec.md (the app's own specification of it) and registry-prototype.md (the field meanings, written for the registry's prototype; where they differ, registry.json and registry-spec.md win). Read all three carefully. The code that reads the registry is frozen and you will not see it. Today the "partner" predicate is linked (role phrases like "my girlfriend" resolve to a person) but has no timeline, so "Who was I dating before Jordan?" can't be answered.

TASK 1: turn on the partner timeline by editing ONLY the partner predicate in the registry data. Return the complete new registry as a JSON string in registry_json (same structure; set "version" to "canary-13a2"), and list your changes in registry_changes. Decide the uses, succession, slot, gap, query cues (English and Spanish: dating, seeing, going out with, girlfriend, novia…), and anything else the documentation says a timeline predicate needs. Don't change other predicates, the language data or the uses rules.

TASK 2: write a blind fixture of 8 to 10 stories (ids c01…c10) about the user's romantic history, 4 to 8 memories each, dated YYYY-MM-DD between 2012-01-01 and 2026-10-31, in arrival order, and tag each story with what it covers (traps). Cover: successive partners with dates at different precision ("2019", "March 2019"); a breakup stated without a date; getting back together with an earlier partner (a second episode); "my ex" references; a partner named before or after the role phrase; "we started dating in 2021"; an overlap or ambiguity that a careful reader can't order (concurrent); a gap of several years being single; Spanish and mixed text; an agent's note in the third person (Funes trusts it less: it must never end or reorder what the user's own notes state); memories about friends' or siblings' partners (not the user's); a denial ("Sam is not my boyfriend"); a restricted memory (the user's most private note: Funes never sends it to a cloud model, but the user's own answers use it); and the user's corrections: "reject" (the user says a role phrase in a memory isn't that person: memory, surface = the exact phrase), "start" or "end" (the user gives a partner's start or end date: value, as YYYY or YYYY-MM), each applied after the memory "after".
For each story: people; memories with names / roles / facts / not_linked (roles: phrases where the user's own relation to a person is referred to by role, starting at the possessive; resolvable: could a careful reader of the whole story tell who it is?; facts: what this memory states, with start, end, time, preceded_by and followed_by EXACTLY as the memory writes them, a substring of its text, or null); sensitivity; orders (zero or one alternative arrival order where answers must not change); corrections; timeline (the user's true partner episodes: person id, start and end as YYYY or YYYY-MM, end "" if current, memory ids); and queries: 3 to 5 per story as the user would type them, worded naturally and variously as different people would phrase them (kinds before, after, year, current, previous; English and Spanish), with answer_person = the people id a correct answer names, or "" if the story can't decide it; plus 1 "negative" per story that mentions a partner's name with "before"/"after" but doesn't ask about the user's partners, answer_person "". Each query is a distinct question: don't repeat one with another wording in the same story.

Do not look for or use any other files in the workspace. Return JSON matching the schema."""

FIX = """You wrote the attached output (output.json in the working directory) for this brief:

<brief>
{brief}
</brief>

A script checked it and found the problems listed in notes.md in the working directory. Fix exactly those. Keep everything the problems don't touch. Return the WHOLE corrected output as JSON matching the schema. Read only output.json, notes.md, registry.json, registry-spec.md and registry-prototype.md."""


def spec_11_2():
    text = (REPO / "spec/domain/memory-processing.md").read_text()
    a = text.index("### 11.2 The predicate registry")
    return text[a:text.index("### 11.3", a)]


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
    work = Path(tempfile.mkdtemp(prefix="facts-canary13-astra-"))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    (work / "registry.json").write_text(REGISTRY.read_text())
    (work / "registry-spec.md").write_text(spec_11_2())               # distinct names: macOS file names ignore case
    (work / "registry-prototype.md").write_text((HERE / "REGISTRY.md").read_text())
    for name, path in files:
        shutil.copy(path, work / name)
    (LOG / f"{stamp}-prompt.txt").write_text(prompt)
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--json", "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=7200)
    (LOG / f"{stamp}-codex.log").write_text(f"exit {p.returncode}\n")
    audit(p.stdout, work, stamp)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-800:]}")


def registry_problems(new):
    """The canary may change the partner predicate only (and the version)."""
    old = json.loads(REGISTRY.read_text())
    out = []
    if {k for k in new if k != "version"} != {k for k in old if k != "version"}:
        out.append("registry: top-level keys changed")
    for k in old:
        if k not in ("version", "predicates") and new.get(k) != old[k]:
            out.append(f"registry: {k} changed")
    op, np_ = {p["id"]: p for p in old["predicates"]}, {p["id"]: p for p in new.get("predicates", [])}
    if set(op) != set(np_):
        out.append(f"registry: predicates {sorted(set(op) ^ set(np_))} added or removed")
    out += [f"registry: {pid} changed" for pid in op if pid != "partner" and np_.get(pid) != op[pid]]
    if "timeline" not in np_.get("partner", {}).get("uses", []):
        out.append("registry: partner doesn't declare the timeline")
    return out


def convert(data):
    problems = []
    reg = json.loads(data["registry_json"])
    problems += registry_problems(reg)
    stories = []
    for s in data["stories"]:
        people = {p["id"]: ({"names": p["names"]} if p["names"] or not p["group_type"]
                            else {"names": [], "group": [p["group_type"], p["group_label"]]}) for p in s["people"]}
        first = {p["id"]: (p["names"][0] if p["names"] else "") for p in s["people"]}
        mems = []
        for m in s["memories"]:
            for x in m["names"] + m["roles"]:
                if x["surface"] not in m["text"]:
                    problems.append(f"{s['id']} {m['id']}: '{x['surface']}' not in text")
            mems.append({"id": m["id"], "text": m["text"], "written": m["written"], "source": m["source"],
                         "sensitivity": m["sensitivity"],
                         "names": [{"surface": n["surface"], "person": n["person"], **({"of": n["of"]} if n["person"] == "?" else {})}
                                   for n in m["names"]],
                         "roles": m["roles"], "facts": [{k: v for k, v in f.items() if v is not None or k in ("person", "label", "count")}
                                                         for f in m["facts"]],
                         "not_linked": m["not_linked"]})
        ids = [m["id"] for m in mems]
        for o in s["orders"]:
            if sorted(o) != sorted(ids) or o == ids:
                problems.append(f"{s['id']}: order {o} isn't another permutation of the memories")
        for t in s["timeline"]:
            if not first.get(t["person"]):
                problems.append(f"{s['id']}: timeline person {t['person']} has no name")
        stories.append({"id": s["id"], "title": s["title"], "traps": s["traps"], "people": people, "memories": mems,
                        "orders": [o for o in s["orders"] if sorted(o) == sorted(ids) and o != ids],
                        "corrections": [{k: v for k, v in c.items() if v is not None} for c in s["corrections"]],
                        "timeline": [{"org": first.get(t["person"], t["person"]), "kind": "partner", "start": t["start"], "end": t["end"],
                                      "memories": t["memories"]} for t in s["timeline"]],
                        "queries": [{"id": q["id"], "kind": q["kind"], "query": q["query"],
                                     "answer_org": first.get(q["answer_person"], "") if q["answer_person"] else ""} for q in s["queries"]]})
    DEST.mkdir(parents=True, exist_ok=True)
    (DEST / "registry.json").write_text(json.dumps(reg, ensure_ascii=False, indent=1) + "\n")
    out = {"user": {"name": data["user_name"], "aliases": data["user_aliases"]}, "author": MODEL,
           "registry_changes": data["registry_changes"], "stories": stories}
    (DEST / "stories.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(f"registry changes: {len(data['registry_changes'])}; {len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, "
          f"{sum(len(s['queries']) for s in stories)} queries, {sum(len(s['corrections']) for s in stories)} corrections")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix")
    ap.add_argument("--convert", action="store_true")
    a = ap.parse_args()
    RAW.mkdir(parents=True, exist_ok=True)
    if a.fix:
        tmp = OUT_RAW.with_suffix(".fixed.json")
        tmp.unlink(missing_ok=True)
        run_codex(FIX.replace("{brief}", BRIEF), tmp, [("output.json", OUT_RAW), ("notes.md", a.fix)])
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
