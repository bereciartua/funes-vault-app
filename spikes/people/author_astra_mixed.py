#!/usr/bin/env python3
"""Spike H3: a blind mixed-predicate fixture by GPT-6-Astra. Stories whose memories mix people (family, colleagues,
managers) with the user's own jobs, clients and vendors in the same memories, with the truth for both: who each name and
role phrase refers to (Spike H's story format) and the user's job timeline with timeline queries (Spike H2's format).
Astra never sees facts.py, the registry or any result. The script only checks and converts the format.

    python3 author_astra_mixed.py   -> fixtures/raw/astra-mixed.json, fixtures/stories-mixed.json
"""
import json
import re
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


SCHEMA = obj({"user_name": S(), "user_aliases": L(S()), "stories": L(obj({
    "id": S(), "title": S(),
    "people": L(obj({"id": S(), "names": L(S()), "group_type": N("string"), "group_label": N("string")})),
    "memories": L(obj({
        "id": S(), "text": S(), "written": S(), "source": S(enum=["capture", "agent", "import"]),
        "names": L(obj({"surface": S(), "person": S(), "of": L(S())})),
        "roles": L(obj({"surface": S(), "person": S(), "resolvable": B})),
        "facts": L(obj({"person": N("string"), "type": S(enum=TYPES), "label": N("string"),
                        "status": S(enum=["current", "former"]), "polarity": S(enum=["positive", "negative"]),
                        "deceased": B, "only": B, "count": N("integer")})),
        "organizations": L(obj({"surface": S(), "org": S(), "relation": S(enum=["employer", "self_employed", "client", "vendor", "other"])})),
        "not_linked": L(S())})),
    "orders": L(L(S())),
    "timeline": L(obj({"org": S(), "role": S(), "start": S(), "end": S(), "kind": S(enum=["employee", "self_employed", "client", "vendor"]),
                       "memories": L(S())})),
    "queries": L(obj({"id": S(), "kind": S(enum=["before", "after", "negative"]), "query": S(), "answer_org": S()})),
}))})

BRIEF = """You are writing a frozen, blind test set for a feature of Funes Vault, a private personal-memory app on the Mac. Everything is invented.

THE FEATURE. The vault holds short memories about the user (choose an invented name; gender never stated; agents' notes may use the name or "the user"). Memories arrive over time: captures the user writes, notes an AI agent saved about the user (third person), and old notes the user imports. A language model reads each memory and records facts about the user: the people it mentions and how they relate to the user (partner, parent, child, sibling, other_family, friend, manager, colleague, care, other), and the organizations the user works or worked for (employers, or the user's own freelance business), with start and end dates as written, and organizations the user did work for as a freelancer (clients). Role phrases ("my sister", "my boss", "my previous job") are resolved to people or jobs. Code then answers questions like "What was my job before Acme?" from a timeline of the user's jobs. It must never guess: undecidable references stay undecided.

THE POINT OF THIS SET: people and jobs appear in the SAME memories, so a system that reads both at once can confuse them. Cover, across the set: a manager or colleague named together with the employer ("My boss Priya at Lumen Labs…"); a family member's employer that is NOT the user's ("my sister works at Orbit Bank"); a client named with the client's contact person; a company the user only buys from or uses (a vendor: an accountant's firm, a coworking space, an airline); a company with a person-like name; a job change announced together with a new manager; a promotion inside one job; rejoining an earlier employer; two jobs at once (a day job and a side business); a freelance period with clients; a gap; dates given at different precision ("2019", "March 2019"); memories that say "before X" or "after leaving X" without dates; an agent note in the third person; Spanish and mixed Spanish-English text; a denial ("Sasha is not my manager"); possessive chains ("my boss's husband") that aren't the user's own relation.

WRITE 10 to 12 stories (ids x01…x12), each 5 to 9 memories in arrival order, dated YYYY-MM-DD between 2016-01-01 and 2026-10-31.

FORMAT, per story:
- people: every person (not the user): id, names (every way the story writes their name; empty if never named), and for a person never named, group_type and group_label (relation type and the word used); otherwise null.
- memories: id (m1…), text, written, source (capture, agent or import), and:
  - names: every name in the text that refers to a PERSON: surface (exactly as written, a substring of text), person (a people id; "user" for the user's own name; "?" when it can't be told which of several same-named people is meant, with their ids in "of"; otherwise "of" is empty). Company names are not person names.
  - roles: every phrase where the user's own relation to a PERSON is referred to by role: surface (exactly as written, starting at the possessive: "My sister", "mi jefa", "The user's manager"), person (a people id), resolvable (could a careful reader of the WHOLE story tell who it is?). Not quoted speech by someone else, not possessive chains, not job phrases like "my job".
  - facts: the user's relations to people this memory states: person (id or null), type, label (the word used, or null), status (current or former), polarity, deceased, only, count.
  - organizations: every organization named in the text: surface (as written), org (one canonical name per organization across the story), relation (employer, self_employed, client, vendor, or other: e.g. a relative's employer, a client's competitor).
  - not_linked: people this memory must NOT be linked to.
- orders: zero or one other arrival order worth testing (all memory ids), only where the order must not change the final answers.
- timeline: the user's true jobs and client engagements in this story: org (canonical), role, start and end as you intend them (YYYY or YYYY-MM; end "" if current), kind (employee, self_employed, client), and memory ids that state it. List vendors too, with kind "vendor" (start/end "").
- queries: 2 to 4 per story as the user would type them into a search field (some in Spanish): "before" or "after" questions about the user's jobs naming an organization ("Where did I work before Lumen Labs?", "What did I do after leaving Orbit?") with answer_org = the organization a correct answer names (canonical), or "" if the story can't decide it; plus 1 "negative" per story that uses "before"/"after" or a company name but does not ask about the user's own job ("What did Priya do before joining Lumen Labs?", "When does my sister start at Orbit Bank?"), answer_org "".

Do not look for or use any other files in the workspace. Return JSON matching the schema."""


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    out = RAW / "astra-mixed.json"
    if not out.exists():
        work = Path(tempfile.mkdtemp(prefix="spike-h3-astra-"))
        (work / "schema.json").write_text(json.dumps(SCHEMA))
        cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}", "-c", "web_search=disabled",
               "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--output-schema", str(work / "schema.json"),
               "-o", str(out), "-C", str(work), "-"]
        p = subprocess.run(cmd, input=BRIEF, capture_output=True, text=True, timeout=5400)
        if p.returncode != 0 or not out.exists():
            raise SystemExit(f"codex failed: {p.stderr[-500:]}")
    data = json.loads(out.read_text())
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
                         "names": [{"surface": n["surface"], "person": n["person"], **({"of": n["of"]} if n["person"] == "?" else {})}
                                   for n in m["names"] if n["surface"] in m["text"]],
                         "roles": [r for r in m["roles"] if r["surface"] in m["text"]],
                         "facts": m["facts"], "not_linked": m["not_linked"], "organizations": m["organizations"]})
        ids = [m["id"] for m in mems]
        orders = [o for o in s["orders"] if sorted(o) == sorted(ids) and o != ids]
        stories.append({"id": s["id"], "title": s["title"], "people": people, "memories": mems, "orders": orders,
                        "timeline": s["timeline"], "queries": s["queries"]})
    out2 = {"user": {"name": data["user_name"], "aliases": data["user_aliases"]}, "author": MODEL, "stories": stories}
    (HERE / "fixtures" / "stories-mixed.json").write_text(json.dumps(out2, ensure_ascii=False, indent=1))
    print(f"{len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, "
          f"{sum(len(m['roles']) for s in stories for m in s['memories'])} role references, "
          f"{sum(len(s['queries']) for s in stories)} queries, {sum(len(s['orders']) for s in stories)} extra orders")
    for p in problems:
        print("dropped:", p)


if __name__ == "__main__":
    main()
