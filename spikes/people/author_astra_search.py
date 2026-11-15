#!/usr/bin/env python3
"""Spike H, search and answers: the held-out set. GPT-6-Astra (Codex CLI, the author's ChatGPT plan) writes, blind,
memories about the people in the persona's life and queries over them, on Spike G's vault. It never sees
build_search.py's memories or queries, the ranking rule's weights or any result. The script only checks the format.

    python3 author_astra_search.py   -> fixtures/raw/astra-search.json, fixtures/search-vault-astra.json,
                                        fixtures/search-queries-astra.json
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
                       "createdAt": S(), "source": S(enum=["manual", "agent_write"])})),
    "queries": L(obj({
        "id": S(), "query": S(), "tags": L(S()), "answerable": B, "targets": L(S()), "about": L(S()),
        "facts": L(obj({"keys": L(S()), "required": B, "memory": S()})),
        "must_not": L(obj({"label": S(), "all": L(S()), "none": L(S())})),
    })),
})

BRIEF = """You are writing a held-out test set for a feature of Funes Vault, a personal memory vault on the Mac.

THE FEATURE (People in search). In the background, a language model reads each memory and records the people it mentions and how they relate to the user ("Jordan is my partner", "Lucía is my sister"). A memory that mentions someone only through a role ("my sister drinks mate") is linked by code to the person that role resolves to, from what the vault says. In search, names and role phrases ("my sister", "my partner", "mi hermana") in the query are matched to people by code; the memories linked to that person are admitted to the results and ranked by the rest of the query. So "What does Lucía drink?" should find "My sister drinks mate" even though it never says Lucía. Then the top 8 results go to a language model that answers the search in at most 3 short claims, each citing memories with exact quotes. When a result came through a role link, the memory that establishes the link ("My sister Lucía lives in Montevideo") is added to the answer's input so it can cite it. The risks: the wrong person's memory ranked first or quoted (another person's drink as Lucía's), a role resolved to the wrong person, a query that mentions no person getting worse results, invented answers.

THE VAULT is in the attached file vault.json (the persona is Sam, a freelance developer in Lisbon). Everything in it is invented. Read who is in Sam's life before writing. ADD 12 to 16 memories of your own (ids h01…h16) about the people in Sam's life, consistent with the vault and invented, written as Sam would note them (first person, short) or, for one or two, as an agent's summary in the third person about Sam (source agent_write). Include: facts said only through a role ("my partner …", "my sister …", "my mum …", "my manager …"); the same kind of fact about a different person, so a wrong link would be visible; one new person who shares a first name with someone already in the vault; one person whose role changed (a former and a current holder); one memory in Spanish; one that mentions a role in a way that refers to nobody in particular or to someone else's relative ("my friend's sister", a quote, a negation). Dates are YYYY-MM-DD, between 2025-06-01 and 2026-10-28. Categories are keys used in the vault (copy them from vault.json). Sensitivity low, internal or sensitive (sensitive memories are never sent to the cloud answer model; use it for at most one).

WRITE 14 to 18 queries (ids a01…a18), the way Sam would type them into a search field: questions or a few words, two in Spanish. Most mention a person by name or by role. Cover: a name query whose answer is in a role-only memory; a role query whose answer is in a memory that uses the name; a query where another person's similar fact is a trap; the shared first name; the changed role (who is it now?); one or two queries that are just a person's name; one query about a person whose answer isn't in the vault (the model must not invent it); one query that mentions no person at all, near the topic of your memories.

FOR EACH QUERY give:
- targets: the ids of the memories that answer it (any vault id or yours); a good search has one of them in the top 3. Empty for a query with no answer or a name-only query.
- about: only for a name-only query, the ids of every memory about that person (vault and yours); otherwise empty.
- facts: what a correct answer says, each with keys (a list of case-insensitive Python regexes that must ALL match a claim's text; short and robust to rephrasing and to Spanish answers for Spanish queries), required (true for what an answer must say), and memory (the id holding it). Empty for a name-only query.
- must_not: claims that would be wrong, especially another person's fact stated as this person's, as {label, all: [regexes that must all match], none: [regexes that excuse it]}. For a query with no answer, include {"label": "an invented answer", "all": ["."], "none": []}.
- answerable (false for no answer and for name-only queries), tags.

Do not look for or use any other test files in the workspace. Return JSON matching the schema."""


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    vault = json.loads((G / "vault.json").read_text())
    work = Path(tempfile.mkdtemp(prefix="spike-h-astra-"))
    (work / "vault.json").write_text(json.dumps(vault["memories"], indent=1, ensure_ascii=False))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    out = RAW / "astra-search.json"
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=BRIEF, capture_output=True, text=True, timeout=3600)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-500:]}")
    data = json.loads(out.read_text())
    known = {m["id"] for m in vault["memories"]}
    added = []
    for m in data["memories"]:
        assert re.fullmatch(r"h\d\d", m["id"]) and m["id"] not in known, m["id"]
        added.append({**m, "updatedAt": m["createdAt"], "trust": "trusted" if m["source"] == "manual" else "untrusted"})
    known |= {m["id"] for m in added}
    qs = []
    for x in data["queries"]:
        for f in x["facts"]:
            for k in f["keys"]:
                re.compile(k)
            if f["memory"] and f["memory"] not in known:
                print(f"{x['id']}: unknown memory {f['memory']}")
        for m in x["must_not"]:
            for k in m["all"] + m["none"]:
                re.compile(k)
        for t in x["targets"] + x["about"]:
            if t not in known:
                print(f"{x['id']}: unknown target {t}")
        qs.append({**x, "set": "people", "aboveLimit": False, "conflict": False,
                   **({"noAnswerCall": True} if x["about"] else {})})
    (HERE / "fixtures/search-vault-astra.json").write_text(json.dumps(
        {**vault, "note": "Spike G's vault plus GPT-6-Astra's people memories (h01…); all invented.",
         "memories": vault["memories"] + added}, indent=1, ensure_ascii=False) + "\n")
    (HERE / "fixtures/search-queries-astra.json").write_text(json.dumps(
        {"format": "funes.spike-h.search.v1", "author": MODEL, "queries": qs}, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(added)} memories, {len(qs)} queries")


if __name__ == "__main__":
    main()
