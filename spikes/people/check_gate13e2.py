#!/usr/bin/env python3
"""13e.2's timeline gate set, checked before anything runs (no model unless --astra): counts and trap minimums (ADR-0032
decision 9), ids, labels against texts and timelines, organization names unique across stories, and fillers that never
state the user's own employment. Prints only counts and problems (the set stays unread by the gate's builder).

    python3 check_gate13e2.py [--dir fixtures/gate-13e2] [--astra]

--astra: a fresh GPT-6-Astra lists every filler (shared or a story's own) that states or implies where the user works or
worked; any it lists is a problem.
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
MIN = {"decidable": 50, "undecidable": 50, "negative": 40}
UNDECIDABLE_TRAPS = ["rehire", "possible_overlap", "same_year_handover", "agent_competitor", "rename", "exact_day"]
TRAP_MIN = 4
EMPLOYMENT = [
    r"\b(i|i'm|i've|i'd|i was|we)\b[^.!?]{0,40}\b(work|works|worked|working)\s+(at|for|with)\b",
    r"\b(i|i've|i'd)\b[^.!?]{0,20}\b(joined|left|quit|was hired|got hired|started at|resigned)\b",
    r"\bmy\s+(job|company|employer|boss|manager|workplace|office at)\b",
    r"\b(trabajo|trabajé|trabajaba|trabajaré|he trabajado)\s+(en|para|con)\b",
    r"\b(entré|empecé|dejé|renuncié)\s+(en|a|de)\b",
    r"\bmi\s+(empresa|trabajo|empleo|jefe|jefa|empleador|oficina)\b",
]


def fold(s):
    import unicodedata
    return unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()


def check(d, fillers):
    probs = []
    stories = d["stories"]
    ids = [s["id"] for s in stories]
    if len(stories) != 24 or len(set(ids)) != 24:
        probs.append(f"{len(stories)} stories ({len(set(ids))} distinct ids), want 24")
    users = [fold(a) for a in d["user"]["aliases"] + [d["user"]["name"]]]
    classes, traps, owner = Counter(), Counter(), {}
    for s in stories:
        sid = s["id"]
        mids = [m["id"] for m in s["memories"]]
        if len(set(mids)) != len(mids):
            probs.append(f"{sid}: duplicate memory ids")
        story_fillers = [m for m in s["memories"] if m.get("filler")]
        if len(story_fillers) != 2:
            probs.append(f"{sid}: {len(story_fillers)} fillers, want 2")
        tl_orgs = {t["org"] for t in s["timeline"]}
        jobs_orgs = {t["org"] for t in s["timeline"] if t["kind"] in ("employee", "self_employed")}
        for t in s["timeline"]:
            for mid in t["memories"]:
                if mid not in mids:
                    probs.append(f"{sid}: timeline {t['org']} cites {mid}, not a memory")
            for k in ("start", "end"):
                if t[k] and not re.fullmatch(r"\d{4}(-\d{2}(-\d{2})?)?", t[k]):
                    probs.append(f"{sid}: timeline {t['org']} {k} {t[k]!r}")
        canon = set()
        for m in s["memories"]:
            at = f"{sid} {m['id']}"
            if not re.fullmatch(r"20(1[2-9]|2[0-6])-\d{2}-\d{2}", m["written"]) or m["written"] > "2026-10-28":
                probs.append(f"{at}: written {m['written']}")
            for x in m["names"] + m["organizations"]:
                if x["surface"] not in m["text"]:
                    probs.append(f"{at}: {x['surface']!r} not in its text")
            for o in m["organizations"]:
                canon.add(o["org"])
            for j in m["jobs"]:
                for k in ("org", "start", "end", "time", "preceded_by", "followed_by", "also_called"):
                    if j.get(k) and j[k] not in m["text"]:
                        probs.append(f"{at}: job {k} {j[k]!r} not in its text")
            if m.get("filler"):
                if m["source"] == "agent":
                    probs.append(f"{at}: a filler from an agent (fillers are all trusted)")
                if m["jobs"]:
                    probs.append(f"{at}: a filler with jobs")
                if not any(o["org"] in tl_orgs for o in m["organizations"]):
                    probs.append(f"{at}: a filler naming none of the story's organizations")
                if any(re.search(p, fold(m["text"])) for p in EMPLOYMENT):
                    probs.append(f"{at}: a filler that may state the user's employment")
        for o in canon | tl_orgs:
            k = fold(o)
            if k in owner and owner[k] != sid:
                probs.append(f"{sid}: organization {o!r} also in {owner[k]}")
            owner.setdefault(k, sid)
        qids = [q["id"] for q in s["queries"]]
        if len(set(qids)) != len(qids):
            probs.append(f"{sid}: duplicate question ids")
        for q in s["queries"]:
            at = f"{sid} {q['id']}"
            classes[q["class"]] += 1
            if q["class"] == "undecidable":
                for t in q["traps"]:
                    traps[t] += 1
                if q["answer_org"]:
                    probs.append(f"{at}: undecidable with answer_org {q['answer_org']!r}")
            if q["class"] == "decidable" and q["answer_org"] not in jobs_orgs:
                probs.append(f"{at}: decidable answer_org {q['answer_org']!r} isn't a job on the timeline")
        try:
            import qualify
            qualify.check_labels(s, "works_at")
        except SystemExit as e:
            probs.append(str(e))
    for c, n in MIN.items():
        if classes[c] < n:
            probs.append(f"{classes[c]} {c} questions, want ≥ {n}")
    for t in UNDECIDABLE_TRAPS:
        if traps[t] < TRAP_MIN:
            probs.append(f"{traps[t]} undecidable {t} questions, want ≥ {TRAP_MIN}")
    fids = [m["id"] for m in fillers]
    story_ids = {m["id"] for st in stories for m in st["memories"]}
    if story_ids & set(fids):
        probs.append(f"shared filler ids also used by story memories: {sorted(story_ids & set(fids))[:5]}")
    if any(m["source"] == "agent" for m in fillers):
        probs.append("a shared filler from an agent (fillers are all trusted)")
    if not 230 <= len(fillers) <= 270 or len(set(fids)) != len(fids):
        probs.append(f"{len(fillers)} shared fillers ({len(set(fids))} distinct ids), want about 250")
    names = {fold(o) for o in owner} | set(users)
    for m in fillers:
        t = fold(m["text"])
        if any(re.search(r"(?<!\w)" + re.escape(n) + r"(?!\w)", t) for n in names if len(n) >= 3):
            probs.append(f"filler {m['id']}: names a story organization or the user")
        if any(re.search(p, t) for p in EMPLOYMENT):
            probs.append(f"filler {m['id']}: may state the user's employment")
    return probs, classes, traps


ASTRA = """You are checking background memories for a test. Everything is invented. fillers.json in the working directory lists short memories (id, text). The writer is the user of a notes app; notes with source "agent" are an AI assistant's notes about the user.

List the id of EVERY memory that states or implies where the user (the writer, or "the user" in an agent's note) works, worked, will work, runs a business, or whom the user works for: an employer, a job title tied to an organization, joining or leaving a job, "my company", "mi empresa". Other people's jobs don't count. Return JSON {"ids": [...]} (empty if none). Read only fillers.json."""


def astra(d, fillers):
    rows = [{"id": m["id"], "source": m["source"], "text": m["text"]} for m in fillers]
    rows += [{"id": f"{s['id']}/{m['id']}", "source": m["source"], "text": m["text"]} for s in d["stories"] for m in s["memories"]
             if m.get("filler")]
    work = Path(tempfile.mkdtemp(prefix="gate13e2-fillers-"))
    (work / "fillers.json").write_text(json.dumps(rows, ensure_ascii=False))
    (work / "schema.json").write_text(json.dumps({"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}}},
                                                  "required": ["ids"], "additionalProperties": False}))
    out = work / "out.json"
    p = subprocess.run(["codex", "exec", "--ignore-user-config", "-m", "gpt-6-astra", "-c", "model_reasoning_effort=high",
                        "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                        "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"],
                       input=ASTRA, capture_output=True, text=True, timeout=3600)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-600:]}")
    return json.loads(out.read_text())["ids"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(HERE / "fixtures" / "gate-13e2"))
    ap.add_argument("--astra", action="store_true")
    a = ap.parse_args()
    d = json.loads((Path(a.dir) / "stories.json").read_text())
    fillers = json.loads((Path(a.dir) / "fillers.json").read_text())["memories"]
    probs, classes, traps = check(d, fillers)
    if a.astra:
        probs += [f"filler {i}: Astra reads it as stating the user's employment" for i in astra(d, fillers)]
    print(f"{len(d['stories'])} stories, {sum(len(s['memories']) for s in d['stories'])} memories, {len(fillers)} shared fillers; "
          f"questions {dict(classes)}; undecidable traps " + ", ".join(f"{t} {traps[t]}" for t in UNDECIDABLE_TRAPS))
    for p in probs:
        print("problem:", p)
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main())
