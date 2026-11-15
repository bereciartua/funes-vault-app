#!/usr/bin/env python3
"""Spike H, search and answers round 2 (ROUND2.md §3): the busy vault, written blind by GPT-6-Astra. Spike G's vault plus
about 150 memories with two heavy people, so plain search has to compete, and queries in families, with per-memory
truth (who each memory is about). It's a challenge set, reported apart from ordinary queries. Frozen once written: no
query is rewritten after a baseline run. The script only checks the format.

    python3 author_astra_busy.py   -> fixtures/raw/astra-busy.json, fixtures/search-vault-busy.json,
                                      fixtures/search-queries-busy.json
"""
import json
import re
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
G = HERE.parent / "search-answers" / "fixtures"
RAW = HERE / "fixtures" / "raw"
MODEL, EFFORT = "gpt-6-astra", "high"

S = lambda **kw: {"type": "string", **kw}
B = {"type": "boolean"}
L = lambda item: {"type": "array", "items": item}


def obj(props):
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


SCHEMA = obj({
    "memories": L(obj({"id": S(), "title": S(), "body": S(), "kind": S(enum=["fact", "preference", "instruction",
                                                                             "relationship", "constraint", "event"]),
                       "categories": L(S()), "sensitivity": S(enum=["low", "internal", "sensitive"]),
                       "createdAt": S(), "source": S(enum=["manual", "agent_write"]),
                       "about": L(S())})),
    "queries": L(obj({
        "id": S(), "family": S(), "kind": S(enum=["ordinary", "challenge", "collision", "privacy", "no_answer", "name_only"]),
        "query": S(), "answerable": B, "targets": L(S()), "decoys": L(S()), "about": L(S()),
        "facts": L(obj({"text": S(), "keys": L(S()), "required": B, "memory": S()})),
        "must_not": L(obj({"label": S(), "all": L(S()), "none": L(S())})),
    })),
})

BRIEF = """You are writing a frozen challenge set for a feature of Funes Vault, a personal memory vault on the Mac. Everything is invented.

THE FEATURE (People in search). A language model reads each memory in the background and records the people it mentions and the user's relations to them ("Lucía is my sister"). A memory that mentions someone only through a role ("my sister drinks mate") is linked by code to the person the role resolves to. In search, names and role phrases in the query ("Lucía", "my sister", "mi hermana") are matched to people; that person's memories are admitted to the results and ranked by the rest of the query. The top 8 results go to a model that answers in short claims with exact quotes. Memories above the cloud limit (sensitivity "sensitive" or higher) are never sent to the cloud, and no fact that only such a memory states may be sent either.

THE VAULT is the attached vault.json (persona Sam, a freelance developer in Lisbon; partner Jordan; sister Lucía in Montevideo; parents in Buenos Aires; Erik Halvorsen at Nordwind; Marta Silva at the sailing club). Read who is in Sam's life first.

ADD about 150 memories (ids w001…w160), consistent with the vault, short, written as Sam would note them (first person), a few as an agent's summary in the third person about Sam (source agent_write). Dates YYYY-MM-DD between 2024-11-01 and 2026-10-28. Categories: keys used in vault.json. Requirements:
- Two heavy people: Lucía (about 55 memories) and Jordan (about 45), over many topics that also apply to other people: food and drink, gifts, health and allergies, travel, work, hobbies, schedules, money, family plans. About a quarter of each person's memories mention them only through a role ("my sister …", "my partner …", "mi hermana …"), never by name. The rest use the name.
- Decoys: at least 25 memories with the same kinds of fact about other people (friends, colleagues, parents, new people you invent), so a wrong link or plain topic search would pick the wrong person.
- People named May, Will and Mark (new friends or colleagues), each with 2–4 memories, so that queries with the words "may", "will" or "mark" in their ordinary sense could falsely match them.
- Two different people who share a first name, both with memories at low or internal sensitivity.
- Privacy cases: at least two people whose relation to Sam is stated ONLY in a sensitive memory (for example "My half-brother Tomás…" marked sensitive), while other memories at internal sensitivity mention them by name without the relation.
- Spanish in some memories. A few memories that mention a role that refers to nobody in particular or to someone else's relative ("my friend's sister", a quote, a negation).
- For each memory, "about": the names of the people it is about (use full names as you introduce them; for role-only memories, the person the role means, e.g. ["Lucía"]; [] if nobody).

WRITE about 44 queries (ids q01…q44), as Sam would type them into a search field (questions or a few words; four in Spanish). Each belongs to a "family": a short id for the fact or story it tests; paraphrases of the same question share a family. Give at least 18 families. Kinds:
- "challenge" (about 14): a person named or role-referred in the query, where you expect plain topic search to rank the answer outside the top 3 because many memories compete (e.g. "What does Lucía drink?" answered only by a role-only memory, while other people's drink memories and many Lucía memories compete).
- "ordinary" (about 12): person queries where plain search should already do fine.
- "collision" (about 6): half use may/will/mark as ordinary words and must match nobody; half are real queries about May, Will or Mark.
- "privacy" (2–3): about a person from the privacy cases; the answer must not state the relation that only the sensitive memory gives.
- "no_answer" (3): about a person, with no answer in the vault.
- "name_only" (3): just a person's name.

FOR EACH QUERY give:
- targets: ids of memories that answer it (any vault id or yours); empty for no_answer and name_only.
- decoys: ids of memories with the same kind of fact about someone else (the traps); may be empty.
- about: for name_only, every memory id about that person; otherwise empty.
- facts: what a correct answer says: text (one plain sentence a reviewer can check), keys (case-insensitive Python regexes that must all match a claim stating it; robust to rephrasing and to Spanish), required, memory.
- must_not: wrong claims (another person's fact as this person's, the sensitive relation for privacy queries, an invented answer), as {label, all: [regexes], none: [regexes that excuse it]}. For no_answer include {"label": "an invented answer", "all": ["."], "none": []}.
- answerable (false for no_answer and name_only).

Do not look for or use any other files in the workspace. Return JSON matching the schema."""


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    vault = json.loads((G / "vault.json").read_text())
    work = Path(tempfile.mkdtemp(prefix="spike-h-busy-"))
    (work / "vault.json").write_text(json.dumps(vault["memories"], indent=1, ensure_ascii=False))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    out = RAW / "astra-busy.json"
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=BRIEF, capture_output=True, text=True, timeout=5400)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-500:]}")
    data = json.loads(out.read_text())
    known = {m["id"] for m in vault["memories"]}
    added = []
    for m in data["memories"]:
        assert re.fullmatch(r"w\d{3}", m["id"]) and m["id"] not in known, m["id"]
        added.append({**m, "updatedAt": m["createdAt"], "trust": "trusted" if m["source"] == "manual" else "untrusted"})
    known |= {m["id"] for m in added}
    qs = []
    for x in data["queries"]:
        for f in x["facts"]:
            for k in f["keys"]:
                re.compile(k)
        for m in x["must_not"]:
            for k in m["all"] + m["none"]:
                re.compile(k)
        for t in x["targets"] + x["decoys"] + x["about"] + [f["memory"] for f in x["facts"] if f["memory"]]:
            if t not in known:
                print(f"{x['id']}: unknown memory {t}")
        qs.append({**x, "id": "w" + x["id"], "set": "people", "tags": [x["kind"]], "aboveLimit": False, "conflict": False,
                   **({"noAnswerCall": True} if x["kind"] == "name_only" else {})})
    (HERE / "fixtures/search-vault-busy.json").write_text(json.dumps(
        {**vault, "note": "Spike G's vault plus GPT-6-Astra's busy people memories (w001…); all invented.",
         "memories": vault["memories"] + added}, indent=1, ensure_ascii=False) + "\n")
    (HERE / "fixtures/search-queries-busy.json").write_text(json.dumps(
        {"format": "funes.spike-h.search.v2", "author": MODEL, "queries": qs}, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(added)} memories, {len(qs)} queries, {len({q['family'] for q in qs})} families")


if __name__ == "__main__":
    main()
