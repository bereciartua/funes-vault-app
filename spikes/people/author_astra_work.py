#!/usr/bin/env python3
"""Spike H2 (plan v5 §16): a blind work-history fixture by GPT-6-Astra. Spike G's vault (persona Sam) plus memories
about Sam's work history, with the true timeline, and queries about it, including wordings that must not trigger the
timeline. Astra never sees the probe's code, the plan's resolver rule or any result. The script only checks the format.

    python3 author_astra_work.py   -> fixtures/raw/astra-work.json, fixtures/work-vault.json, fixtures/work-queries.json
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
    "memories": L(obj({"id": S(), "title": S(), "body": S(), "kind": S(enum=["fact", "preference", "instruction", "relationship",
                                                                             "event", "project_context"]),
                       "categories": L(S()), "sensitivity": S(enum=["low", "internal", "sensitive"]), "createdAt": S(),
                       "source": S(enum=["manual", "agent_write"])})),
    "timeline": L(obj({"org": S(), "role": S(), "start": S(), "end": S(), "kind": S(enum=["employee", "self_employed", "client", "study"]),
                       "memories": L(S())})),
    "queries": L(obj({
        "id": S(), "family": S(), "kind": S(enum=["before", "after", "year", "current", "previous", "role_in_stint", "negative", "no_answer"]),
        "query": S(), "answerable": B, "answer_org": S(), "targets": L(S()),
        "facts": L(obj({"text": S(), "keys": L(S()), "required": B, "memory": S()})),
        "must_not": L(obj({"label": S(), "all": L(S()), "none": L(S())})),
    })),
})

BRIEF = """You are writing a frozen test set for a feature of Funes Vault, a personal memory vault on the Mac. Everything is invented.

THE FEATURE (work history). A language model reads each memory and records the user's own jobs: organization, role, start, end, and "before / after" another organization, as written. Code builds a timeline of the user's employers. A search like "What was my job before Acme?" is then answered from that timeline: code finds the employer that came before, and gives the answer model the memories about that job. The risks: a wrong order (a confident wrong "before X"), concurrent or undated jobs, freelance periods and gaps, being rehired, promotions within one job, renamed companies ("Acme" / "Acme Inc."), agent-written notes in the third person, and searches that use "before" or a company name without asking about a job.

THE VAULT is the attached vault.json (persona Sam, a freelance developer in Lisbon). Read it first, and stay consistent with it: Sam's current work (Nordwind, the sailing club's Harbor project, Ledgerly…) must fit your history.

ADD 50 to 70 memories (ids j001…j070) that tell Sam's work history over about 12 years, as Sam would note it (first person, short), a few as an agent's summary in the third person (source agent_write), with dates YYYY-MM-DD between 2018-01-01 and 2026-10-28. Include: at least 6 employers or self-employment periods; one employer Sam left and rejoined; one promotion within a job; a period of two jobs at once; one freelance period; one gap (study or a break); one company renamed or written two ways; some memories that give dates, some that only say "before X" or "after leaving X", some that give neither; a few that mention a company without being about Sam's job there (a client, a supplier, a friend's employer); two in Spanish; one sensitive memory (e.g. a salary). Categories: keys used in vault.json.

GIVE the true timeline: each stint with org, role, start and end as you intend them (YYYY or YYYY-MM; end "" if current), kind (employee, self_employed, client, study), and the ids of the memories that state it.

WRITE 25 to 35 queries (ids w01…w35), as Sam would type them into a search field (four in Spanish), each with a "family" (a short id; paraphrases share one). Kinds: "before" and "after" (e.g. "What did I do before Acme?", "Where did I work after leaving Beta?"), "year" ("Where was I working in 2021?"), "current", "previous" ("my previous job"), "role_in_stint" ("What was my title at Acme before the promotion?": a role question inside one job, not a timeline question), "negative" (uses "before"/"after" or a company name but doesn't ask about Sam's job: "What did we use before Acme moved to Slack?", "Who was Acme's CTO?"), and "no_answer" (a job question the vault can't answer). For each: answerable, answer_org (the organization a correct answer names, or ""), targets (memory ids that answer it), facts (text, keys: case-insensitive Python regexes that must all match a claim stating it, required, memory), must_not (wrong claims, especially the wrong employer as the answer; for no_answer include {"label": "an invented answer", "all": ["."], "none": []}).

Do not look for or use any other files in the workspace. Return JSON matching the schema."""


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    vault = json.loads((G / "vault.json").read_text())
    work = Path(tempfile.mkdtemp(prefix="spike-h2-astra-"))
    (work / "vault.json").write_text(json.dumps(vault["memories"], indent=1, ensure_ascii=False))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    out = RAW / "astra-work.json"
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}", "-c", "web_search=disabled",
           "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--output-schema", str(work / "schema.json"),
           "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=BRIEF, capture_output=True, text=True, timeout=5400)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-500:]}")
    data = json.loads(out.read_text())
    known = {m["id"] for m in vault["memories"]}
    added = []
    for m in data["memories"]:
        assert re.fullmatch(r"j\d{3}", m["id"]) and m["id"] not in known, m["id"]
        added.append({**m, "updatedAt": m["createdAt"], "trust": "trusted" if m["source"] == "manual" else "untrusted"})
    known |= {m["id"] for m in added}
    for x in data["queries"]:
        for f in x["facts"]:
            [re.compile(k) for k in f["keys"]]
        for m in x["must_not"]:
            [re.compile(k) for k in m["all"] + m["none"]]
        for t in x["targets"]:
            if t not in known:
                print(f"{x['id']}: unknown target {t}")
    (HERE / "fixtures/work-vault.json").write_text(json.dumps({**vault, "note": "Spike G's vault plus GPT-6-Astra's work history (j001…); invented.",
                                                               "memories": vault["memories"] + added}, indent=1, ensure_ascii=False) + "\n")
    (HERE / "fixtures/work-queries.json").write_text(json.dumps({"format": "funes.spike-h2.work.v1", "author": MODEL,
                                                                 "timeline": data["timeline"], "queries": data["queries"]},
                                                                indent=1, ensure_ascii=False) + "\n")
    print(f"{len(added)} memories, {len(data['timeline'])} stints, {len(data['queries'])} queries")


if __name__ == "__main__":
    main()
