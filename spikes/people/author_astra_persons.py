#!/usr/bin/env python3
"""Phase 13a.2's person fixture: GPT-6-Astra (through the Codex CLI, on the author's ChatGPT plan) writes stories blind,
with their ground truth, in Spike H's story format. The qualification gate pools the person predicates and needs at least
20 role references per predicate (memory processing §11.10); main, astra and mixed have child 3, other 1, parent 15,
care 17 and other family 17, every order counted (`fixture_counts.py`). This set brings each to 20 with margin and covers
the other person predicates too. Astra gets the feature's rules, the registry's relation words, the format and the traps
to cover; never another set's stories, the extractor's prompts or any model's output. Its judgments are kept as written;
this script only converts the format and checks that every surface appears in its memory.

    python3 author_astra_persons.py                 -> fixtures/raw/astra-persons.json, fixtures/stories-persons.json
    python3 author_astra_persons.py --fix <notes>   a fresh Astra instance corrects the raw stories from reviewers' notes
                                                    (it may disagree), then converts again
    python3 author_astra_persons.py --extend <notes> a fresh Astra instance returns only new stories, and rewrites of the
                                                    ones the notes name; merged into the raw file by id
    python3 author_astra_persons.py --convert       converts the raw file only
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "fixtures" / "raw"
OUT_RAW = RAW / "astra-persons.json"
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


def words():
    """The registry's relation words per type (the words Funes recognises in a role phrase)."""
    reg = json.loads((HERE / "registry.json").read_text())
    return {p["id"]: [w for e in p["lexicon"] for w in e["words"]] for p in reg["predicates"] if p["object_kind"] == "person"}


BRIEF = """You are writing a frozen, blind test set for a feature of Funes Vault, a private personal-memory app on the Mac. Everything is invented.

THE FEATURE ("People"). The vault holds short memories about the user, Ari Castell (gender never stated; agents' notes may call them "Ari", "Ari Castell" or "the user"). Memories arrive over time: captures the user writes ("My neighbour waters my plants"), notes an AI agent saved about the user (third person, source "agent"), and old notes the user imports (source "import"). For each memory, Funes records which people it mentions and how they relate to the user, and resolves role phrases ("my daughter", "mi abuela", "Ari's landlord", "the user's dentist") to a person. It must work without asking the user, and stay honest: if the user has two neighbours and a memory just says "my neighbour", it must not guess. It must never infer a gender or a relation word from a name. People only: pets, companies, apps and places are not people.

RELATION TYPES AND THEIR WORDS. Funes recognises a role phrase by these words only (with an owner: "my", "mi", "mis", "the user's", "Ari's", "Ari Castell's", optionally a modifier such as only, other, old, new, late, former, current, younger, older, little, big, best, elder, eldest, youngest, previous, first):
{words}
When the user refers to their own relation by role, use one of these words, exactly (no "landlady", "GP", "physio", "stepmum", "supervisor", "granddad"). "ex" means a former partner. Note that coach, lawyer and accountant are "care", and step-children, step-siblings and in-laws are "other_family", while stepmom/stepdad are "parent".

THE POINT OF THIS SET: enough role references for every relation type, especially the ones other sets have few of. Count a role reference as one listed role (below), in the natural order. In the natural order alone, the set must have AT LEAST:
- child 26, other 26, parent 22, care 22, other_family 22;
- partner, sibling, friend, manager and colleague: 8 to 12 each.
In every type, at least three quarters of the role references must be resolvable, and some (about one in six overall) genuinely undecidable from the whole story's text. Spread them over many stories and people; don't pad with one person repeated. Give about half the stories one extra arrival order (below), which also exercises order independence.

WRITE about 32 stories (ids p01…p32), each 4 to 7 memories in the order they arrive, dated YYYY-MM-DD between 2023-01-01 and 2026-10-31 (an import's text may talk about earlier years). Mix easy and hard stories. Cover, across the set, each SEVERAL times:
- several people sharing a role (two children, two neighbours, a doctor and a dentist, two cousins, a landlord who changes), with later memories that settle or don't settle earlier references;
- a person referred to by role before their name is known, and a person never named (a group);
- a count ("I have three kids", "two neighbours on our floor") and "my only …";
- a role that changes hands over time (a new landlord after a move, a new therapist, a new boss) where earlier memories keep pointing to whoever held it then; "my old landlord", "my former therapist";
- former and deceased people: "my late grandmother", "my late father", an ex, a former doctor;
- an old note imported recently about the past;
- quoted speech of someone else containing a role phrase ("My neighbour Jun said 'my landlord raised the rent'", "Mi vecina dice que su hija…" with a quote) — never a reference to the user's own relation;
- other people's relatives: possessive chains ("my son's teacher", "my aunt's neighbour", "my landlord's daughter", "my friend's mom", "my dentist's son"). A chain whose second part is a person is not a role reference at all: list neither part as a role, and put the user's own relation that could be confused in not_linked (for "my landlord's daughter", the user's daughter). A possessive that isn't a chain ("my daughter's school play", "my mom's lasagna") is an ordinary role reference to the first part;
- shared names: two different people with the same first name in one story (the user's son and a neighbour both called Leo), including a bare mention that can't be told apart;
- role phrases that shouldn't link: a plural ("my kids", "my parents", "our neighbours"), a hypothetical or wish ("if I ever have a daughter"), a denial ("Ines is not my aunt, she's my mom's friend"), a generic statement ("every doctor says…"), a role word without an owner ("the landlord", "a neighbour"). These are not listed as roles; use not_linked where a wrong link is tempting;
- Spanish and mixed Spanish-English text; an agent's note naming the user in the third person; a name that is also an ordinary word or a role word; a pet or a company with a person-like name; an agent note containing an instruction that tries to plant a false relation.

FORMAT, per story:
- people: every person in the story (not the user): id (short, e.g. "olga"), names (every way the story writes their name; empty if never named), and for a person never named, group_type and group_label (the relation type and the word used, e.g. "care" and "dentist"); otherwise null.
- memories: id (m1, m2…), text, written, source (capture, agent or import), and:
  - names: every name in the text that refers to a person: surface (exactly as written, a substring of text), person (a people id; "user" for the user's own name; "?" when it can't be told which of several people with that name is meant, with their ids in "of"; otherwise "of" is empty).
  - roles: every phrase where the user's own relation is referred to by role: surface (exactly as written, starting at the owner and ending at the relation word: "My daughter", "mi abuela", "Ari's landlord", "The user's dentist", "My older son", "my late grandmother"), person (who it really is in the story; a people id), resolvable (true if a careful reader of the WHOLE story could tell who it is; false if not). If the same surface occurs twice in one memory, list it twice, in order. Do not list quoted speech by someone else, possessive chains, plurals, hypotheticals, denials or owner-less role words as roles.
  - facts: the user's relations this memory states: person (a people id, or null for "I don't have kids" or a bare count), type, label (the word the text uses, exactly as written, or null), status (current, or former for an ex, a past landlord or a past doctor), polarity (positive, or negative for a denial), deceased, only, count (a stated number, or null).
  - not_linked: people this memory must NOT be linked to.
- orders: zero or one other arrival order worth testing (a list of all memory ids), only where the order should not change the final answer.

Do not look for or use any other files in the workspace. Return JSON matching the schema."""

FIX = """You wrote the attached test set (stories.json in the working directory) for this brief:

<brief>
{brief}
</brief>

Two reviewers checked its ground truth against the brief. Their notes are in notes.md in the working directory. For each note, decide whether it is right. Where it is, fix the story: correct the labels (roles, resolvable, facts, names, not_linked), or reword a memory's text when that is the cleaner fix (keep surfaces exact substrings). Where a note is wrong, leave the story as it is. Keep every story and memory id, and keep everything the notes don't touch unchanged. Keep the brief's minimum counts per type.

Return the WHOLE corrected set as JSON matching the schema, with nothing omitted. Read only stories.json and notes.md."""


EXTEND = """You wrote the attached test set (stories.json in the working directory) for this brief:

<brief>
{brief}
</brief>

notes.md in the working directory asks for new stories, and may ask for a few existing stories to be rewritten. Return
ONLY the new stories and the rewritten ones (whole, with their ids), as JSON matching the schema. A story you return
with an existing id replaces it; one with a new id is added. Don't return stories the notes don't ask about. Read only
stories.json and notes.md."""


def run_codex(prompt, out, files=()):
    work = Path(tempfile.mkdtemp(prefix="facts-persons-astra-"))
    (work / "schema.json").write_text(json.dumps(SCHEMA))
    for name, path in files:
        shutil.copy(path, work / name)
    cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}",
           "-c", "web_search=disabled", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
           "--output-schema", str(work / "schema.json"), "-o", str(out), "-C", str(work), "-"]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=7200)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"codex failed: {p.stderr[-800:]}")


def brief():
    return BRIEF.replace("{words}", "\n".join(f"- {t}: {', '.join(ws)}" for t, ws in words().items()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", help="reviewers' notes (markdown) for a correction round")
    ap.add_argument("--extend", help="notes asking for new or rewritten stories")
    ap.add_argument("--convert", action="store_true")
    a = ap.parse_args()
    RAW.mkdir(parents=True, exist_ok=True)
    if a.fix:
        tmp = OUT_RAW.with_suffix(".fixed.json")
        tmp.unlink(missing_ok=True)
        run_codex(FIX.replace("{brief}", brief()), tmp, [("stories.json", OUT_RAW), ("notes.md", a.fix)])
        json.loads(tmp.read_text())
        tmp.replace(OUT_RAW)
    elif a.extend:
        tmp = OUT_RAW.with_suffix(".extra.json")
        tmp.unlink(missing_ok=True)
        run_codex(EXTEND.replace("{brief}", brief()), tmp, [("stories.json", OUT_RAW), ("notes.md", a.extend)])
        data, extra = json.loads(OUT_RAW.read_text()), json.loads(tmp.read_text())["stories"]
        by_id = {s["id"]: s for s in extra}
        data["stories"] = [by_id.pop(s["id"], s) for s in data["stories"]] + list(by_id.values())
        print(f"extend: {len(extra) - len(by_id)} rewritten, {len(by_id)} added")
        OUT_RAW.write_text(json.dumps(data, ensure_ascii=False, indent=1))
        tmp.unlink()
    elif not a.convert and not OUT_RAW.exists():
        run_codex(brief(), OUT_RAW)
    convert(json.loads(OUT_RAW.read_text()))


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
    out = {"user": {"name": "Ari Castell", "aliases": ["Ari Castell", "Ari"]}, "author": MODEL, "stories": stories}
    (HERE / "fixtures" / "stories-persons.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    n_roles = sum(len(m["roles"]) for s in stories for m in s["memories"])
    undec = sum(1 for s in stories for m in s["memories"] for r in m["roles"] if not r["resolvable"])
    print(f"{len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, {n_roles} role references "
          f"({undec} undecidable), {sum(len(s['orders']) for s in stories)} extra orders")
    for p in problems:
        print("dropped:", p)


if __name__ == "__main__":
    main()
