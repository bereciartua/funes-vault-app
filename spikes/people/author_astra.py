#!/usr/bin/env python3
"""Spike H's held-out set: GPT-6-Astra (through the Codex CLI, on the author's ChatGPT plan) writes about 20 stories
blind, with their ground truth. It gets the feature's rules, the format and the kinds of cases to cover; never the
first set's stories or any model's output. Its judgments are kept as written; this script only converts the format
and checks that every surface appears in its memory.

    python3 author_astra.py      -> fixtures/raw/astra.json, fixtures/stories-astra.json
"""
import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "fixtures" / "raw"
MODEL, EFFORT = "gpt-6-astra", "high"
TYPES = ["partner", "parent", "child", "sibling", "other_family", "friend", "manager", "colleague", "care", "other"]

S = lambda **kw: {"type": "string", **kw}
N = lambda t: {"type": [t, "null"]}
B = {"type": "boolean"}
L = lambda item: {"type": "array", "items": item}


def obj(props):
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


SCHEMA = obj({"stories": L(obj({
    "id": S(), "title": S(),
    "people": L(obj({"id": S(), "names": L(S()), "group_type": N("string"), "group_label": N("string")})),
    "memories": L(obj({
        "id": S(), "text": S(), "written": S(), "source": S(enum=["capture", "agent", "import"]),
        "names": L(obj({"surface": S(), "person": S(), "of": L(S())})),
        "roles": L(obj({"surface": S(), "person": S(), "resolvable": B})),
        "facts": L(obj({"person": N("string"), "type": S(enum=TYPES), "label": N("string"),
                        "status": S(enum=["current", "former"]), "polarity": S(enum=["positive", "negative"]),
                        "deceased": B, "only": B, "count": N("integer")})),
        "not_linked": L(S())})),
    "orders": L(L(S())),
}))})

BRIEF = """You are writing a held-out test set for a feature of Funes Vault, a private personal-memory app on the Mac.

THE FEATURE ("People"). The vault holds short memories about the user, Noa Bergman (gender never stated; agents' notes may call them "Noa" or "the user"). Memories arrive over time: captures the user writes ("My sister likes coffee"), notes an AI agent saved about the user (third person), and old notes the user imports. For each memory, Funes records which people it mentions and how they relate to the user, and resolves role phrases ("my sister", "mi hermana", "Noa's boss", "the user's wife") to a person. It must work without asking the user, but stay honest: if the user has two sisters and a memory just says "my sister", it must not guess. It must never infer a gender or a relation word from a name. Relation types: partner, parent, child, sibling, other_family (grandparents, aunts, uncles, cousins, in-laws), friend, manager, colleague, care (doctor, dentist, therapist, vet, lawyer), other (neighbour, landlord, coach). People only: pets, companies, apps and places are not people.

WRITE about 20 short stories (ids a01…a20), each 3 to 6 memories in the order they arrive, with dates (YYYY-MM-DD, between 2024-01-01 and 2026-10-31). Everything is invented. Mix easy and hard stories; about a quarter of all role references should be genuinely undecidable from the story's text. Cover, across the set: several people sharing a role (siblings, friends, colleagues, doctors), with later memories that settle or don't settle earlier references; a person referred to by role before their name is known; a count ("I have three brothers"); "my only …"; a role that changes hands over time (a new boss, a breakup and a new partner) where earlier memories must keep pointing to whoever held it then; an old note imported recently about the past; a deceased relative; in-laws and step-family that must not be confused with parents or siblings; a denial ("X is not my …"); quoted speech of someone else ("my dad said 'my brother is visiting'") and possessive chains ("my sister's husband", "my friend's son") that are not references to the user's own relation; two different people with the same first name; Spanish and mixed Spanish-English text; an agent's note that names the user in the third person; a name that is also an ordinary word; a pet or a company with a person-like name; an agent note containing an instruction that tries to plant a false relation.

FORMAT, per story:
- people: every person in the story (not the user): id (short, e.g. "olga"), names (every way the story writes their name; empty if never named), and for a person never named, group_type and group_label (the relation type and the word used, e.g. "sibling" and "brother"); otherwise null.
- memories: id (m1, m2…), text, written, source (capture, agent or import), and:
  - names: every name in the text that refers to a person: surface (exactly as written, a substring of text), person (a people id; "user" for the user's own name; "?" when it can't be told which of several people with that name is meant, with their ids in "of"; otherwise "of" is empty).
  - roles: every phrase where the user's own relation is referred to by role: surface (exactly as written, starting at the possessive: "My sister", "mi abuela", "Noa's partner", "The user's brother", "My older brother"), person (who it really is in the story; a people id), resolvable (true if a careful reader of the WHOLE story could tell who it is; false if not). Do not list quoted speech by someone else or possessive chains as roles.
  - facts: the user's relations this memory states: person (a people id, or null for "I don't have kids" or a bare count), type, label (the word the text uses, or null), status (current, or former for an ex or a past boss), polarity (positive, or negative for a denial), deceased, only, count (a stated number, or null).
  - not_linked: people this memory must NOT be linked to (e.g. the user's sister for a memory with quoted speech mentioning "my sister", or a parent for a memory about a mother-in-law).
- orders: zero or one other arrival order worth testing (a list of all memory ids), only where the order should not change the final answer.

Do not look for or use any other files in the workspace. Return JSON matching the schema."""


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="spike-h-astra-"))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    out = RAW / "astra.json"
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    if not out.exists():
        p = subprocess.run(cmd, input=BRIEF, capture_output=True, text=True, timeout=3600)
        if p.returncode != 0 or not out.exists():
            raise SystemExit(f"codex failed: {p.stderr[-500:]}")
    convert(json.loads(out.read_text()))


def convert(data):
    stories, problems = [], []
    for s in data["stories"]:
        people = {p["id"]: ({"names": p["names"]} if p["names"] or not p["group_type"]
                            else {"names": [], "group": [p["group_type"], p["group_label"]]}) for p in s["people"]}
        mems = []
        for m in s["memories"]:
            for x in m["names"] + m["roles"]:
                if x["surface"] not in m["text"]:
                    problems.append(f"{s['id']} {m['id']}: '{x['surface']}' not in text")
            mems.append({"id": m["id"], "text": m["text"], "written": m["written"], "source": m["source"],
                         "names": [{"surface": n["surface"], "person": n["person"], **({"of": n["of"]} if n["person"] == "?" else {})}
                                   for n in m["names"] if n["surface"] in m["text"]],
                         "roles": [r for r in m["roles"] if r["surface"] in m["text"]],
                         "facts": m["facts"], "not_linked": m["not_linked"]})
        ids = [m["id"] for m in mems]
        orders = [o for o in s["orders"] if sorted(o) == sorted(ids) and o != ids]
        stories.append({"id": s["id"], "title": s["title"], "people": people, "memories": mems, "orders": orders})
    out = {"user": {"name": "Noa Bergman", "aliases": ["Noa Bergman", "Noa"]}, "stories": stories}
    (HERE / "fixtures" / "stories-astra.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    n_roles = sum(len(m["roles"]) for s in stories for m in s["memories"])
    undec = sum(1 for s in stories for m in s["memories"] for r in m["roles"] if not r["resolvable"])
    print(f"{len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, {n_roles} role references "
          f"({undec} undecidable), {sum(len(s['orders']) for s in stories)} extra orders")
    for p in problems:
        print("dropped:", p)


if __name__ == "__main__":
    main()
