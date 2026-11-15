#!/usr/bin/env python3
"""Spike H3's registry canary: GPT-6-Astra, given only registry.json and REGISTRY.md (never facts.py or any result),
writes (1) a new registry that turns on the partner timeline, as data only, and (2) a blind fixture of relationship
histories with the truth for people links and partner timeline questions. The code is frozen (git tag spike-h3-freeze)
before this runs; the canary passes only if it works with no source change.

    python3 author_astra_canary.py   -> fixtures/raw/astra-canary.json, registry-canary.json, fixtures/stories-canary.json
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


SCHEMA = obj({"registry_json": S(), "registry_changes": L(S()), "user_name": S(), "user_aliases": L(S()), "stories": L(obj({
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
    "timeline": L(obj({"person": S(), "start": S(), "end": S(), "memories": L(S())})),
    "queries": L(obj({"id": S(), "kind": S(enum=["before", "after", "negative"]), "query": S(), "answer_person": S()})),
}))})

BRIEF = """You are testing whether a registry-driven design really needs no code to support a new kind of question. Everything is invented.

CONTEXT. Funes Vault, a private memory app, learns facts about the user from short memories. What each kind of fact means, and how it is used, is defined only in data: the attached registry.json, documented in REGISTRY.md (read both carefully). The code that reads it is frozen and you will not see it. Today the "partner" predicate is linked (role phrases like "my girlfriend" resolve to a person) but has no timeline, so "Who was I dating before Jordan?" can't be answered.

TASK 1: turn on the partner timeline by editing ONLY the registry data. Return the complete new registry as a JSON string in registry_json (same structure; bump "version" to "canary-1"), and list your changes in registry_changes. Decide the uses, succession, slot, gap, query cues (English and Spanish: dating, seeing, going out with, girlfriend, novia…), and anything else the documentation says a timeline predicate needs. Don't change other predicates.

TASK 2: write a blind fixture of 8 to 10 stories (ids c01…c10) about the user's romantic history, 4 to 8 memories each, dated YYYY-MM-DD between 2012-01-01 and 2026-10-31, in arrival order. Cover: successive partners with dates at different precision ("2019", "March 2019"); a breakup stated without a date; getting back together with an earlier partner (a second episode); "my ex" references; a partner named before or after the role phrase; "we started dating in 2021"; an overlap or ambiguity that a careful reader can't order; a gap of several years being single; Spanish and mixed text; an agent's note in the third person; memories about friends' or siblings' partners (not the user's); a denial ("Sam is not my boyfriend").
For each story: people, memories with names / roles / facts / not_linked in the format of the schema (roles: phrases where the user's own relation to a person is referred to by role, starting at the possessive; resolvable: could a careful reader of the whole story tell who it is?), orders (zero or one alternative arrival order where answers must not change), timeline (the user's true partner episodes: person id, start and end as YYYY or YYYY-MM, end "" if current, memory ids), and queries: 2 to 4 per story as the user would type them ("Who was I dating before Jordan?", "¿Con quién salía antes de Lucía?", "Who did I date after breaking up with Max?") with answer_person = the people id a correct answer names, or "" if the story can't decide it; plus 1 "negative" per story that mentions a partner's name with "before"/"after" but doesn't ask about the user's partners ("What did Jordan do before moving to Lisbon?"), answer_person "".

Do not look for or use any other files in the workspace. Return JSON matching the schema."""


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    out = RAW / "astra-canary.json"
    if not out.exists():
        work = Path(tempfile.mkdtemp(prefix="spike-h3-canary-"))
        (work / "schema.json").write_text(json.dumps(SCHEMA))
        (work / "registry.json").write_text((HERE / "registry.json").read_text())
        (work / "REGISTRY.md").write_text((HERE / "REGISTRY.md").read_text())
        cmd = ["codex", "exec", "--ignore-user-config", "-m", MODEL, "-c", f"model_reasoning_effort={EFFORT}", "-c", "web_search=disabled",
               "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--output-schema", str(work / "schema.json"),
               "-o", str(out), "-C", str(work), "-"]
        p = subprocess.run(cmd, input=BRIEF, capture_output=True, text=True, timeout=5400)
        if p.returncode != 0 or not out.exists():
            raise SystemExit(f"codex failed: {p.stderr[-500:]}")
    data = json.loads(out.read_text())
    reg = json.loads(data["registry_json"])
    (HERE / "registry-canary.json").write_text(json.dumps(reg, ensure_ascii=False, indent=1))
    stories = []
    for s in data["stories"]:
        people = {p["id"]: ({"names": p["names"]} if p["names"] or not p["group_type"]
                            else {"names": [], "group": [p["group_type"], p["group_label"]]}) for p in s["people"]}
        names_of = {p["id"]: (p["names"][0] if p["names"] else "") for p in s["people"]}
        mems = [{"id": m["id"], "text": m["text"], "written": m["written"], "source": m["source"],
                 "names": [{"surface": n["surface"], "person": n["person"], **({"of": n["of"]} if n["person"] == "?" else {})}
                           for n in m["names"] if n["surface"] in m["text"]],
                 "roles": [r for r in m["roles"] if r["surface"] in m["text"]], "facts": m["facts"], "not_linked": m["not_linked"]}
                for m in s["memories"]]
        ids = [m["id"] for m in mems]
        stories.append({"id": s["id"], "title": s["title"], "people": people, "memories": mems,
                        "orders": [o for o in s["orders"] if sorted(o) == sorted(ids) and o != ids],
                        "timeline": [{"org": names_of.get(t["person"], t["person"]), "kind": "partner", "start": t["start"], "end": t["end"],
                                      "memories": t["memories"]} for t in s["timeline"]],
                        "queries": [{"id": q["id"], "kind": q["kind"], "query": q["query"],
                                     "answer_org": names_of.get(q["answer_person"], "") if q["answer_person"] else ""} for q in s["queries"]]})
    (HERE / "fixtures" / "stories-canary.json").write_text(json.dumps(
        {"user": {"name": data["user_name"], "aliases": data["user_aliases"]}, "author": MODEL, "stories": stories}, ensure_ascii=False, indent=1))
    print(f"registry changes: {len(data['registry_changes'])}; {len(stories)} stories, {sum(len(s['memories']) for s in stories)} memories, "
          f"{sum(len(s['queries']) for s in stories)} queries")


if __name__ == "__main__":
    main()
