#!/usr/bin/env python3
"""Spike H, search and answers (§10, §15): the fixtures. Spike G's vault (208 invented memories, the persona Sam, a
freelance developer in Lisbon, partner Jordan, sister Lucía) plus memories about the people in Sam's life that only
the People feature can connect to a query: facts said through a role ("my sister drinks her mate bitter"), the same
kind of fact about someone else (Ana drinks matcha), two people called Ana, a contact who changed, Spanish, an agent's
memory in the third person. Everything is invented; the repo is public.

    python3 build_search.py   -> fixtures/search-vault.json, fixtures/search-queries.json

Queries (`set: people`) give:
- targets: memories that answer it; the search measure is the best target's rank (top 3 is the target, §15);
- for a person-only query ("Jordan"), `about`: every memory about that person; measured as how many of the top 5 are;
- decoys: the same kind of fact about someone else (Ana's matcha for Lucía's drink); measured as decoys ranked above the
  best target, and decoys in the top 3;
- facts and must_not in Spike G's format (search-answers/build_fixtures.py), for the answer call.
Spike G's 42 questions and Spike 2's 30 benchmark tasks are added unchanged (`set: spike-g`, `set: bench`): the
regression sets.
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
G = HERE.parent / "search-answers" / "fixtures"
BENCH = HERE.parent.parent / "Packages/FunesCore/Tests/FunesCoreTests/fixtures/queries-30.json"

REL, PREF, HEALTH, PROJ, COMM = "personal_preferences", "personal_preferences", "health", "project_context", "communication_style"


def mem(id_, title, body, created, kind="fact", cats=(REL,), sens="internal", source="manual"):
    return {"id": id_, "title": title, "body": body, "kind": kind, "categories": list(cats), "sensitivity": sens,
            "createdAt": created, "updatedAt": created, "source": source,
            "trust": "trusted" if source == "manual" else "untrusted"}


ADDED = [
    mem("p01", "Sister's mate", "My sister drinks her mate bitter, never with sugar, and always from the same gourd.", "2026-06-10", "preference"),
    mem("p02", "Ana and matcha", "Ana, my climbing friend, only drinks matcha now; she gave up coffee last year.", "2026-07-02"),
    mem("p03", "Partner's allergy", "My partner is allergic to shellfish, so no prawns, mussels or clams when we cook at home.", "2026-03-20",
        "constraint", (HEALTH,)),
    mem("p04", "Erik and cats", "Erik is allergic to cats; don't suggest the cat café for the Nordwind offsite.", "2026-05-02", "constraint", (PROJ,)),
    mem("p05", "Mum's favourites", "My mum loves orchids and dark chocolate with orange peel.", "2026-08-14", "preference"),
    mem("p06", "Video calls with my dad", "My dad is learning to use WhatsApp video calls; keep any instructions for him to one step at a time.",
        "2026-08-15"),
    mem("p07", "Lucía's kids and dinosaurs", "Lucía's kids are obsessed with dinosaurs; the older one wants a T-rex model for his birthday.",
        "2026-09-03"),
    mem("p08", "Status updates", "My manager wants the weekly status update in Slack before Friday noon, as three bullet points.",
        "2026-04-11", "instruction", (PROJ,)),
    mem("p09", "New Nordwind contact", "Since October my Nordwind contact is Priya Raman, who took over from Erik as engineering lead.",
        "2026-10-01", "relationship", (PROJ,)),
    mem("p10", "Boulder park tip", "Ana from the climbing gym recommended the Arco boulder park near Sintra for a Saturday session.", "2026-07-19"),
    mem("p11", "Encargo de mi hermana", "Mi hermana me pidió dulce de leche y alfajores de maicena cuando viaje a Montevideo.", "2026-09-20"),
    mem("p12", "Jordan's March rota", "Jordan's rota for March: nights for the first two weeks, then days. No dinner plans on weeknights before the 15th.",
        "2026-02-22"),
    mem("p13", "Anniversary dinner", "Sam mentioned that their partner wants a quiet anniversary dinner this year, no surprises and no big group.",
        "2026-06-30", "preference", source="agent_write"),
    mem("p14", "Marta and invoices", "Marta wants invoices as a PDF with the club's tax number on the first line, sent to the treasurer's address.",
        "2026-05-15", "instruction", (PROJ,)),
    mem("p15", "Tomás the sommelier", "My friend Tomás is a sommelier; ask him before buying wine for a dinner party.", "2026-08-01", "relationship"),
    mem("p16", "Wine for Jordan's birthday", "Tomás recommended a Douro red, Quinta do Crasto Reserva, for Jordan's birthday dinner.", "2026-08-29"),
    mem("p17", "Blood test", "Dr. Ferreira said to repeat the cholesterol blood test in six months, fasting.", "2026-04-25", "fact", (HEALTH,),
        "sensitive"),
    mem("p19", "Sister's December visit", "My sister is visiting Lisbon from 18 to 26 December with the kids; they'll stay in our spare room.",
        "2026-10-05", "event"),
    mem("p20", "Where to buy matcha", "Good matcha: ceremonial grade from the tea shop on Rua da Prata, about €30 a tin.", "2026-03-03", "preference"),
    mem("p21", "Restaurants with Jordan", "My partner hates loud restaurants; pick somewhere quiet and book a table in advance.", "2026-07-25", "preference"),
    mem("p22", "Erik's coffee", "Erik takes his coffee as a double espresso, no milk; bring him one to the Nordwind workshop.", "2026-02-10"),
    mem("p23", "Priya and updates", "Priya prefers async updates: send a written summary instead of booking a call.", "2026-10-08", "instruction", (PROJ,)),
]

INVENTED = {"label": "an invented answer", "all": ["."], "none": []}


def q(id_, query, targets, facts, must_not=(), tags=(), about=(), answerable=True, above=False, decoys=()):
    return {"id": id_, "set": "people", "query": query, "targets": list(targets), "about": list(about), "decoys": list(decoys),
            "facts": [{"keys": k, "required": r, "memory": m} for k, r, m in facts], "must_not": list(must_not),
            "answerable": answerable, "aboveLimit": above, "conflict": False, "tags": list(tags)}


def wrong(label, *all_, none=()):
    return {"label": label, "all": list(all_), "none": list(none)}


JORDAN = ["m040", "m041", "m044", "m129", "m191", "p03", "p12", "p13", "p16", "p21"]
LUCIA = ["m006", "m042", "m044", "m198", "p01", "p07", "p11", "p19"]
QUERIES = [
    q("s01", "What does Lucía drink?", ["p01"], [(["mate"], True, "p01"), (["bitter|sugar"], False, "p01")],
      [wrong("Ana's drink as Lucía's", "matcha"), wrong("Erik's coffee as Lucía's", "espresso"),
       wrong("the user's coffee as Lucía's", "oat|americano")], ["role_memory", "distractor"], decoys=["p02", "p22"]),
    q("s02", "What is Jordan allergic to?", ["p03"], [(["shellfish|prawn|mussel|clam"], True, "p03")],
      [wrong("Erik's allergy as Jordan's", "cat")], ["role_memory", "distractor"], decoys=["p04"]),
    q("s03", "What should I get my mum?", ["p05"], [(["orchid|chocolate"], True, "p05")],
      [wrong("a gift for someone else", "ceramic|tea|hiking|dinosaur|T-rex")], ["role_query", "group"], decoys=["m040"]),
    q("s04", "When is my sister coming to Lisbon?", ["p19"], [(["18"], True, "p19"), (["26"], False, "p19")], (), ["role_query"]),
    q("s05", "When is Lucía visiting?", ["p19"], [(["18"], True, "p19"), (["26"], False, "p19")], (), ["role_memory"]),
    q("s06", "¿Qué le llevo a Lucía?", ["p11"], [(["dulce de leche|alfajor"], True, "p11")],
      [wrong("a gift for Jordan as Lucía's", "ceramic|tea|hiking|vino|wine")], ["role_memory", "spanish"], decoys=["m040", "p16"]),
    q("s07", "Where should I take Jordan for dinner?", ["p21", "p13"], [(["quiet|tranquil"], True, "p21")], (), ["role_memory"]),
    q("s08", "Who is my Nordwind contact now?", ["p09"], [(["Priya"], True, "p09")],
      [wrong("Erik as the current contact", "Erik", none=["Priya", "took over", "former|before|until|previous"])], ["name_change"]),
    q("s09", "How does Priya like updates?", ["p23"], [(["async|written|summary"], True, "p23")], (), ["control"]),
    q("s10", "What does Ana drink?", ["p02"], [(["matcha"], True, "p02")],
      [wrong("Lucía's drink as Ana's", "mate"), wrong("Erik's coffee as Ana's", "espresso")], ["two_names", "distractor"], decoys=["p01", "p22"]),
    q("s11", "How does Marta want invoices?", ["p14"], [(["PDF|tax number"], True, "p14")], (), ["first_name"]),
    q("s12", "What wine did Tomás recommend?", ["p16"], [(["Douro|Crasto"], True, "p16")], (), ["control"]),
    q("s13", "What does my partner want for our anniversary?", ["p13"], [(["quiet|no surprise"], True, "p13")], (),
      ["role_query", "untrusted"]),
    q("s14", "What gift ideas do I have for my sister's kids?", ["p07"], [(["dinosaur|T-rex"], True, "p07")], (), ["role_query"]),
    q("s15", "Jordan", [], [], (), ["person_only"], about=JORDAN, answerable=False),
    q("s16", "Lucía", [], [], (), ["person_only", "role_memory"], about=LUCIA, answerable=False),
    q("s17", "How does my manager want status updates?", ["p08"], [(["Slack|Friday|bullet"], True, "p08")], (), ["role_query"]),
    q("s18", "What's Erik's coffee order?", ["p22"], [(["espresso"], True, "p22")],
      [wrong("the user's coffee as Erik's", "oat|americano")], ["distractor"], decoys=["m024"]),
    q("s19", "How should I explain video calls to my dad?", ["p06"], [(["one step|step at a time"], True, "p06")], (),
      ["role_query", "group"]),
    q("s20", "What's Lucía's favourite colour?", [], [], [INVENTED], ["no_answer"], answerable=False),
]
# Person-only queries aren't questions an answer can be scored on.
for x in QUERIES:
    if "person_only" in x["tags"]:
        x["noAnswerCall"] = True


def main():
    vault = json.loads((G / "vault.json").read_text())
    ids = {m["id"] for m in vault["memories"]}
    assert not ids & {m["id"] for m in ADDED}
    out_vault = {**vault, "note": "Spike G's vault plus Spike H's people memories (p01…); all invented.",
                 "memories": vault["memories"] + ADDED}
    all_ids = ids | {m["id"] for m in ADDED}
    for x in QUERIES:
        assert all(t in all_ids for t in x["targets"] + x["about"]), x["id"]
    g = json.loads((G / "questions.json").read_text())["questions"]
    bench = json.loads(BENCH.read_text())["queries"]
    qs = QUERIES + [{**x, "set": "spike-g", "targets": [f["memory"] for f in x["facts"] if f.get("memory") and f["required"]]}
                    for x in g]
    qs += [{"id": f"b{x['id']}", "set": "bench", "query": x["query"], "targets": x["relevant"], "noAnswerCall": True,
            "facts": [], "must_not": []} for x in bench]
    (HERE / "fixtures/search-vault.json").write_text(json.dumps(out_vault, indent=1, ensure_ascii=False) + "\n")
    (HERE / "fixtures/search-queries.json").write_text(json.dumps({"format": "funes.spike-h.search.v1", "queries": qs},
                                                                  indent=1, ensure_ascii=False) + "\n")
    print(f"{len(out_vault['memories'])} memories ({len(ADDED)} added); {len(QUERIES)} people queries, {len(g)} Spike G, "
          f"{len(bench)} benchmark")


if __name__ == "__main__":
    main()
