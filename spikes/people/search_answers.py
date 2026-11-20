#!/usr/bin/env python3
"""Spike H, search answers, round 2 (ROUND2.md §2, §6): three arms, three samples each, a blind judge.

    python3 search_answers.py run   --set main|astra|busy [--engine haiku] [--reps 3] [--only ids]
    python3 search_answers.py judge --set ...      Opus labels every answer, blind to the arm
    python3 search_answers.py score --set ...      per-arm results and the cases to read by hand

Arms, all with the user's own names replaced by "the user" in titles and text, all sending the top 8 (Spike G's
cloud-limit rule then withholds what's above the limit, the same in every arm):
- A: plain vault search (Spike G's prompt);
- B: people ranking (search.py), the same prompt;
- C: people ranking, plus bridges (a trusted memory within the cloud limit that states the relation a role link used,
  when none is in the input; it replaces the lowest-ranked results) and an about="…" attribute on each memory that
  came through a link (who it's about and how sure Funes is), plus one sentence in the prompt about that attribute.
  An attribute is sent only if a memory stating the relation is within the cloud limit (§13): otherwise nothing is
  said about the person.
A sample is reused only for an identical request (hash of instructions, prompt, schema and model).
"""
import argparse
import hashlib
import os
import importlib.util
import json
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import search
from search import LEVELS, OUT, USER, paths, rank_people

sys.path.insert(0, str(search.G))
from answer import INSTRUCTIONS, SCHEMA, attr, day, TODAY, validate  # Spike G (memory processing §10.3, §10.4)
from providers import PROVIDERS as G_PROVIDERS

_spec = importlib.util.spec_from_file_location("people_providers", search.HERE / "providers.py")
_pp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pp)

ALLOWED = set(LEVELS[:LEVELS.index("internal") + 1])
ABOUT_RULE = ("\n- An about=\"…\" attribute on a memory is Funes's own inference of who the memory is about, not part of "
              "the memory. You may use it to connect a memory to a person; a claim that relies on it says so "
              "(\"probably\", \"Funes infers\").")
FULL = {"named", "stated_unique", "context", "confirmed"}
ARMS = ("A", "B", "C1", "C2", "C3", "W", "M", "P", "F")      # P, F: the 13d Swift gate (plain = 13b, facts)
ANS = os.environ.get("ANS_DIR", "answers3")    # round 3 (round 2's answers stay in answers2/); Spike H4: answers-terra
HEDGE = re.compile(r"\b(probabl\w*|infer\w*|likely|seems?|appears?|apparently|presumably|Funes)\b", re.I)


def user_text(t):
    for u in sorted(USER, key=len, reverse=True):
        t = re.sub(r"\b" + re.escape(u) + r"\b", "the user", t)
    return t


def load(set_name, engine):
    vault, queries, bf_path, plan_path, scores_path = paths(set_name, engine)
    mems = {m["id"]: m for m in json.loads(vault.read_text())["memories"]}
    bf = json.loads(bf_path.read_text())
    qs = {q["id"]: q for q in json.loads(queries.read_text())["queries"]}
    # The judge and the scorer need neither (the 13d gate's records come from Swift); `run` does.
    plan = {p["id"]: p for p in json.loads(plan_path.read_text())} if plan_path.exists() else {}
    scores = json.loads(scores_path.read_text()) if scores_path.exists() else {}
    return mems, bf, qs, plan, scores


def relation_for(bf, pid, type_):
    rs = [r for r in bf["relations"] if r["person"] == pid and not r["negated"] and (type_ is None or r["type"] == type_)]
    rs.sort(key=lambda r: r["status"] != "current")
    return rs[0] if rs else None


def stating_ok(r, mems, trusted=False):
    return [e for e in r.get("stating", []) if e in mems and mems[e]["sensitivity"] in ALLOWED
            and (not trusted or mems[e]["trust"] == "trusted")] if r else []


def about(mid, p, bf, mems):
    """The why line for a memory that came through a link, or None (no link, a group, or the relation's only stating
    memories are above the cloud limit)."""
    v = p["via"].get(mid)
    if not v:
        return None
    people = {x["id"]: x for x in bf["people"]}
    person = people.get(v["person"])
    if not person or not person["name"]:
        return None
    r = relation_for(bf, v["person"], v.get("type"))
    if not stating_ok(r, mems):
        return None
    label = r["label"] or r["type"]
    former = " (former)" if r["status"] == "former" else ""
    if v["basis"] in ("ambiguous", "candidates"):
        names = [people[c]["name"] for c in v["candidates"] if c in people and people[c]["name"]]
        return f"your {label}: one of {', '.join(names)}" if v["kind"] == "role" else f"one of {', '.join(names)}"
    if v["basis"] == "sole_known":
        return f"probably {person['name']}, your {label}{former} (the only one Funes knows)"
    if v["basis"] == "untrusted":
        return f"{person['name']}, your {label}{former} (from a memory you didn't write)"
    return f"{person['name']}, your {label}{former}"


def bridges(p, top, bf, mems):
    out = []
    for mid in top:
        v = p["via"].get(mid)
        if not v or v["kind"] != "role":
            continue
        r = relation_for(bf, v["person"], v.get("type"))
        ok = stating_ok(r, mems, trusted=True)
        if not ok or any(e in top or e in out for e in ok):
            continue
        out.append(ok[-1])
    return out[:2]


def entry(mid, mems, passages, cats, about_text=None):
    m = mems[mid]
    src = "you" if m["trust"] != "untrusted" else {"agent_write": "an agent", "agent_suggestion": "an agent",
                                                    "import": "an import"}.get(m["source"], "shared text")
    return {"fixtureId": mid, "title": user_text(m["title"]), "kind": m["kind"], "created": m["createdAt"],
            "updated": m["updatedAt"], "source": src, "sensitivity": m["sensitivity"],
            "text": user_text(passages.get(mid, m["body"][:1500])),
            "categories": [cats.get(c, c) for c in m["categories"]], "about": about_text}


def build(q, results, with_rule):
    results = [r for r in results if r["sensitivity"] in ALLOWED]      # Spike G's cloud-limit rule
    parts = [f"Today is {TODAY.strftime('%A, %-d %B %Y')}.", f"<search>{q['query']}</search>"]
    for i, r in enumerate(results, 1):
        ab = f' about="{attr(r["about"])}"' if r.get("about") else ""
        parts.append(f'<memory ref="m{i}" kind="{attr(r["kind"])}" categories="{attr(", ".join(r["categories"]))}" '
                     f'created="{day(r["created"])}" updated="{day(r["updated"])}" source="{attr(r["source"])}"{ab}>\n'
                     f"<title>{r['title']}</title>\n<text>{r['text']}</text>\n</memory>")
    sent = [{"ref": f"m{i}", **r} for i, r in enumerate(results, 1)]
    return INSTRUCTIONS + (ABOUT_RULE if with_rule else ""), "\n".join(parts), sent


def wrong_hint(q, p, bf, mems):
    """For round 3's wrong-hint arm: the queried person and a hint naming them, put on a trap memory. The same privacy
    gate as every hint: only a relation stated by a memory within the cloud limit."""
    people = {x["id"]: x for x in bf["people"]}
    for pid in p.get("matched_ids", []):
        person = people.get(pid)
        r = relation_for(bf, pid, None)
        if person and person["name"] and r and stating_ok(r, mems):
            return pid, f"{person['name']}, your {r['label'] or r['type']}"
    return None, None


def arms_for(q, p, e, bf, mems, cats):
    """Round 3's arms (module docstring): A, B, C1 hint, C2 hint + sentence, C3 + bridges, W wrong hint, M missing hint."""
    base, ppl, _ = rank_people(e, p)
    pas = e["full"]["passages"]
    top8 = ppl[:8]
    hints = {m: a for m in top8 if (a := about(m, p, bf, mems))}
    br = bridges(p, top8, bf, mems)
    top_br = ppl[:8 - len(br)] + br
    hints_br = {m: a for m in top_br if (a := about(m, p, bf, mems))}
    out = {"A": (base[:8], [], {}, False), "B": (top8, [], {}, False), "C1": (top8, [], hints, False),
           "C2": (top8, [], hints, True), "C3": (top_br, br, hints_br, True)}
    pid, wrong = wrong_hint(q, p, bf, mems)
    decoys = [d for d in q.get("decoys", []) if d in mems and mems[d]["sensitivity"] in ALLOWED]
    if wrong and decoys:
        d = decoys[0]
        ids = top8 if d in top8 else top8[:7] + [d]
        out["W"] = (ids, [], {**{m: a for m, a in hints.items() if m in ids}, d: wrong}, True)
    targets = set(q.get("targets", []))
    if targets & set(hints):
        out["M"] = (top8, [], {m: a for m, a in hints.items() if m not in targets}, True)
    people = {x["id"]: x for x in bf["people"]}
    built = {}
    for arm, (ids, br_, ab, rule) in out.items():
        results = [entry(m, mems, pas if m not in br_ else {}, cats, ab.get(m)) for m in ids]
        names = {}
        for m in ab:
            v = p["via"].get(m)
            per = people.get(v["person"]) if v else (people.get(pid) if arm == "W" else None)
            if arm == "W" and m == decoys[0]:
                per = people.get(pid)
            if per and per["name"]:
                names[m] = sorted(set(per["aliases"]) | {per["name"]})
        built[arm] = build(q, results, rule) + (br_, ab, names)
    return built


def cmd_run(a):
    lock = json.loads((OUT / "locked.json").read_text())
    search.BOOST = {"full": lock["boost"], "weak": round(lock["boost"] * 0.7, 3), "cand": round(lock["boost"] * 0.3, 3)}
    search.OTHERS, search.CAP = lock["others"], lock["cap"]
    mems, bf, qs, plan, scores = load(a.set, a.engine)
    cats = scores["categoryNames"]
    provider = G_PROVIDERS[a.provider]()
    path = OUT / ANS / f"{a.set}-{a.engine}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    cache, done = {}, set()
    if path.exists():
        for line in path.read_text().splitlines():
            r = json.loads(line)
            done.add((r["id"], r["arm"], r["rep"]))
            cache.setdefault((r["hash"], r["rep"]), r)
    with path.open("a") as f:
        for e in scores["queries"]:
            q, p = qs[e["id"]], plan[e["id"]]
            # people queries, and Spike G questions that match a person (the rest are identical in every arm)
            if not (q["set"] == "people" or (q["set"] == "spike-g" and p["admitted"])):
                continue
            if q.get("noAnswerCall") or (a.only and q["id"] not in a.only.split(",")):
                continue
            for arm, (ins, prompt, sent, br, ab, names) in arms_for(q, p, e, bf, mems, cats).items():
                if a.arms and arm not in a.arms.split(","):
                    continue
                h = hashlib.sha256(json.dumps([ins, prompt, SCHEMA, a.provider]).encode()).hexdigest()[:16]
                for rep in range(1, a.reps + 1):
                    if (q["id"], arm, rep) in done:
                        continue
                    rec = {"id": q["id"], "arm": arm, "rep": rep, "hash": h, "sent": [s["fixtureId"] for s in sent],
                           "bridges": br, "about": ab, "about_names": names}
                    prev = cache.get((h, rep))
                    if prev:
                        rec.update({k: prev[k] for k in ("outcome", "claims", "dropped", "found", "ms")}, reused=prev["arm"])
                    elif not sent:
                        rec.update(outcome="no_answer", claims=[], dropped=[], found="no", ms=0)
                    else:
                        r = provider.generate(ins, prompt, SCHEMA)
                        if r.get("ok"):
                            rec.update(validate(r["content"], sent), ms=r.get("ms"))
                        else:
                            rec.update(outcome="failed", claims=[], dropped=[], found=None, ms=r.get("ms"), error=r.get("errorKind"))
                    cache.setdefault((h, rep), rec)
                    done.add((q["id"], arm, rep))
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                    f.flush()
                    print(f"{q['id']} {arm}{rep}: {rec['outcome']}, {len(rec['claims'])} claims"
                          + (f" (same request as {rec['reused']})" if rec.get("reused") else ""), file=sys.stderr)


# --- judge ---------------------------------------------------------------------------------------------------------
JUDGE_INS = """You check answers to a search over a personal memory vault, against the truth the test author wrote. You never see how an answer was produced. For each answer, judge:
- covers: true if its claims state every required fact (in any wording or language), false otherwise. For a question with no answer in the vault, null.
- abstains_right: for a question with no answer, true if the answer makes no claim that purports to answer it (saying the vault doesn't say is fine); null otherwise.
- each claim's label:
  - "fact": states a fact from the truth, correctly attributed;
  - "true_other": true and relevant per the truth or its quote, but not a listed fact;
  - "hedged": states a true fact but marks it as probable or inferred; fine;
  - "denies_true": denies, doubts or refuses a fact that the truth says is true, about the right person (for example "this may not be about her" when it is);
  - "wrong_person": attributes a fact to the wrong person, or says a memory is about someone it isn't about;
  - "unsupported": not supported by its quote, or invented;
  - "other": anything else.
The truth includes who each listed memory is really about. A claim is only as good as its quotes: a quote that doesn't contain or imply the claim makes it "unsupported", even if the claim happens to be true.
Code adds two kinds of notes to claims, for every answer alike:
- [the cited memory names X]: the person is named elsewhere in the cited memory, outside the quoted words. The claim is supported if the quote plus that fact support it.
- [Funes marks this as inferred]: the claim connects a quoted memory to a person only through Funes's own link, and the app shows that it's inferred. Don't call it unsupported for that: label it "hedged" if the connection is right per the truth, "wrong_person" if it isn't."""

JUDGE_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["answers"],
    "properties": {"answers": {"type": "array", "items": {
        "type": "object", "additionalProperties": False, "required": ["answer", "covers", "abstains_right", "claims"],
        "properties": {
            "answer": {"type": "integer"},
            "covers": {"type": ["boolean", "null"]},
            "abstains_right": {"type": ["boolean", "null"]},
            "claims": {"type": "array", "items": {
                "type": "object", "additionalProperties": False, "required": ["claim", "label", "why"],
                "properties": {"claim": {"type": "integer"}, "why": {"type": "string"},
                               "label": {"type": "string", "enum": ["fact", "true_other", "hedged", "denies_true",
                                                                    "wrong_person", "unsupported", "other"]}}}}}}}},
}


def inferred(claim, rec):
    """Code's rule (plan §10: the app, not the model, shows "inferred"): the claim names a person that a cited memory's
    hint names, and none of the claim's quotes names them. Records from the Swift answer gate (13d,
    FactsAnswerLiveTests) carry the app's own mark, which wins."""
    if "inferred" in claim:
        return bool(claim["inferred"])
    names = rec.get("about_names") or {}
    quotes = search.fold(" ".join(c["quote"] for c in claim["citations"]))
    text = search.fold(claim["text"])
    for c in claim["citations"]:
        for n in names.get(c["memory"], []):
            f = search.fold(n)
            if re.search(r"(?<!\w)" + re.escape(f) + r"(?!\w)", text) and not re.search(r"(?<!\w)" + re.escape(f) + r"(?!\w)", quotes):
                return True
    return False


def notes(claim, rec, mems, bf):
    """Code's notes on a claim (judge round 3b): people the claim names that its cited memories name outside the quote,
    and whether it relies on a hint (inferred). The same rule for every arm."""
    text = search.fold(claim["text"])
    quotes = search.fold(" ".join(c["quote"] for c in claim["citations"]))
    bodies = search.fold(" ".join(user_text(mems[c["memory"]]["title"] + " " + mems[c["memory"]]["body"])
                                  for c in claim["citations"] if c["memory"] in mems))
    has = lambda f, t: re.search(r"(?<!\w)" + re.escape(f) + r"(?!\w)", t)
    named = []
    for p in bf["people"]:
        if not p["name"]:
            continue
        for n in sorted(set(p["aliases"]) | {p["name"]}, key=len, reverse=True):
            f = search.fold(n)
            if len(f) >= 3 and has(f, text) and not has(f, quotes) and has(f, bodies):
                named.append(p["name"])
                break
    out = "".join(f" [the cited memory names {n}]" for n in dict.fromkeys(named))
    # The app's own mark (13d) is shown whatever else the note says; the spike's rule gave way to a name.
    shown = inferred(claim, rec) and (not named or "inferred" in claim)
    return out + (" [Funes marks this as inferred]" if shown else "")


def answers_hash(rs):
    """What a judge line judged: every answer's arm, sample, outcome and claims (with the app's mark). The 13d scorer
    refuses a verdict whose answers changed since."""
    key = sorted([r["arm"], r["rep"], r.get("outcome"),
                  [[c["text"], [[x["memory"], x["quote"]] for x in c["citations"]], c.get("inferred")] for c in r["claims"]]]
                 for r in rs)
    return hashlib.sha256(json.dumps(key, ensure_ascii=False).encode()).hexdigest()[:16]


def truth_text(q, mems, bf_truth=None):
    lines = [f"Search: {q['query']}", f"Has an answer in the vault: {'yes' if q.get('answerable') else 'no'}"]
    for f in q.get("facts", []):
        m = mems.get(f.get("memory") or "")
        desc = f.get("text") or f"a claim matching /{'/ and /'.join(f['keys'])}/"
        lines.append(f"- {'Required' if f['required'] else 'Optional'} fact: {desc}"
                     + (f"\n  from memory: \"{user_text(m['body'])}\"" if m else "")
                     + (f" (about: {', '.join(m['about'])})" if m and m.get("about") else ""))
    for t in q.get("targets", []):
        m = mems.get(t)
        if m and m.get("about"):
            lines.append(f"- Memory \"{user_text(m['body'][:300])}\" is about: {', '.join(m['about'])}")
    for d in q.get("decoys", []):
        m = mems.get(d)
        if m:
            lines.append(f"- A trap: \"{user_text(m['body'][:300])}\" is about "
                         f"{', '.join(m.get('about') or ['someone else'])}, not the person searched for")
    for mn in q.get("must_not", []):
        lines.append(f"- Wrong: {mn['label']}")
    return "\n".join(lines)


def cmd_judge(a):
    mems, bf, qs, plan, scores = load(a.set, a.engine)
    recs = [json.loads(l) for l in (OUT / ANS / f"{a.set}-{a.engine}.jsonl").read_text().splitlines()]
    path = OUT / ANS / f"{a.set}-{a.engine}-judge{a.judge_tag}.jsonl"
    # The last line per question; it's judged again if it failed, or (13d records) if its answers changed since.
    done = {}
    for l in (path.read_text().splitlines() if path.exists() else []):
        j = json.loads(l)
        done[j["id"]] = j
    judge = _pp.PROVIDERS["claude-opus"]()
    by_q = defaultdict(list)
    for r in recs:
        by_q[r["id"]].append(r)
    with path.open("a") as f:
        for qid, rs in by_q.items():
            h = answers_hash(rs)
            prev = done.get(qid)
            if (prev and prev.get("ok") and prev.get("answers_hash", h) == h) or (a.only and qid not in a.only.split(",")):
                continue
            rnd = random.Random(f"{qid}-judge")
            order = rs[:]
            rnd.shuffle(order)
            blocks = []
            for i, r in enumerate(order, 1):
                cl = "\n".join(f"  claim {j}: {c['text']}" + notes(c, r, mems, bf)
                               + "\n    quotes: " + " | ".join(f'"{x["quote"]}"' for x in c["citations"])
                               for j, c in enumerate(r["claims"], 1)) or "  (no claims)"
                blocks.append(f"Answer {i}:\n{cl}")
            prompt = "TRUTH\n" + truth_text(qs[qid], mems) + "\n\nANSWERS\n" + "\n\n".join(blocks)
            out = judge.generate(JUDGE_INS, prompt, JUDGE_SCHEMA)
            rec = {"id": qid, "ok": out.get("ok"), "map": [(r["arm"], r["rep"]) for r in order], "answers_hash": h,
                   "verdicts": out.get("content", {}).get("answers") if out.get("ok") else None, "costUSD": out.get("costUSD")}
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            f.flush()
            print(f"{qid}: judged {len(order)} answers" if rec["ok"] else f"{qid}: judge failed", file=sys.stderr)


def cmd_score(a):
    mems, bf, qs, plan, scores = load(a.set, a.engine)
    recs = {(r["id"], r["arm"], r["rep"]): r for r in
            (json.loads(l) for l in (OUT / ANS / f"{a.set}-{a.engine}.jsonl").read_text().splitlines())}
    judged = [json.loads(l) for l in (OUT / ANS / f"{a.set}-{a.engine}-judge{a.judge_tag}.jsonl").read_text().splitlines()]
    per = defaultdict(lambda: defaultdict(list))        # qid -> arm -> [verdict]
    for j in judged:
        if not j["ok"]:
            continue
        for v in j["verdicts"]:
            arm, rep = j["map"][v["answer"] - 1]
            per[j["id"]][arm].append((rep, v))
    lines = [f"# Spike H answers, round 2 ({a.set} set, links from {a.engine})", "",
             "Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, "
             "C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.", ""]
    import rank_eval
    kind_of = lambda q: (f"{qs[q].get('tags', ['?'])[0]} {rank_eval.half(qs[q])}" if a.set.startswith("busy")
                         else qs[q]["set"])
    for kind in sorted({kind_of(q) for q in per}):
        sub = [q for q in per if kind_of(q) == kind]
        c = Counter()
        for q in sub:
            for arm in ARMS:
                for rep, v in per[q][arm]:
                    if qs[q].get("answerable"):
                        c[(arm, "ans")] += 1
                        c[(arm, "covers")] += bool(v["covers"])
                    else:
                        c[(arm, "noans")] += 1
                        c[(arm, "abst")] += bool(v["abstains_right"])
                    rec = recs.get((q, arm, rep))
                    for cl in v["claims"]:
                        c[(arm, cl["label"])] += 1
                        c[(arm, "claims")] += 1
                        if rec and 0 < cl["claim"] <= len(rec["claims"]):
                            claim = rec["claims"][cl["claim"] - 1]
                            if inferred(claim, rec):
                                c[(arm, "inferred")] += 1
                                c[(arm, "inferred_hedged")] += bool(HEDGE.search(claim["text"]))
        lines += [f"## {kind} ({len(sub)} queries)", "", "| Measure | " + " | ".join(ARMS) + " |", "|---|" + "---|" * len(ARMS)]
        lines.append("| Required facts covered (answers) | " + " | ".join(f"{c[(x, 'covers')]}/{c[(x, 'ans')]}" for x in ARMS) + " |")
        if any(c[(x, "noans")] for x in ARMS):
            lines.append("| No-answer queries abstained right | " + " | ".join(f"{c[(x, 'abst')]}/{c[(x, 'noans')]}" for x in ARMS) + " |")
        for lab in ("fact", "true_other", "hedged", "denies_true", "wrong_person", "unsupported", "other"):
            lines.append(f"| Claims: {lab} | " + " | ".join(str(c[(x, lab)]) for x in ARMS) + " |")
        lines.append("| Claims code marks inferred (of which the model hedged) | " + " | ".join(
            f"{c[(x, 'inferred')]} ({c[(x, 'inferred_hedged')]})" for x in ARMS) + " |")
        lines.append("")
    # cases to read by hand: every query whose coverage differs between arms, and every bad label
    review = []
    for q in per:
        cov = {arm: sum(bool(v["covers"]) for _, v in per[q][arm]) for arm in ARMS if per[q][arm]}
        bad = [(arm, rep, cl) for arm in ARMS for rep, v in per[q][arm] for cl in v["claims"]
               if cl["label"] in ("denies_true", "wrong_person", "unsupported")]
        if len({cov[x] for x in ("A", "B", "C1", "C2", "C3", "P", "F") if x in cov}) > 1 or bad:
            review.append((q, cov, bad))
    lines += ["## To read by hand", ""]
    for q, cov, bad in review:
        lines.append(f"- **{q}** {qs[q]['query']}: covers " + ", ".join(f"{x} {n}/3" for x, n in cov.items()))
        for arm, rep, cl in bad:
            r = recs[(q, arm, rep)]
            t = r["claims"][cl["claim"] - 1]["text"] if 0 < cl["claim"] <= len(r["claims"]) else "?"
            lines.append(f"  - {arm}{rep} {cl['label']}: {t} — judge: {cl['why']}")
    report = OUT / (f"report-answers2-{a.set}-{a.engine}{a.judge_tag}.md" if ANS == "answers3" else f"{ANS}/report-{a.set}-{a.engine}{a.judge_tag}.md")
    report.write_text("\n".join(lines))
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["run", "judge", "score"])
    ap.add_argument("--set", default="main")
    ap.add_argument("--engine", default="haiku")
    ap.add_argument("--provider", default="claude-haiku")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--only", default="")
    ap.add_argument("--arms", default="", help="only these arms (Spike H4: A,B,C1,W,M)")
    ap.add_argument("--judge-tag", default="", help="suffix for a re-judged file (round 3b: -b)")
    a = ap.parse_args()
    {"run": cmd_run, "judge": cmd_judge, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
