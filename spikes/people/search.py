#!/usr/bin/env python3
"""Spike H, search and answers (§10, §15): people in vault search, on top of FunesCore's real search scores.

    python3 search.py plan    --set main|astra [--engine haiku]   query → people, admitted memories, the rest of the query
    swift/.build/release/search-scores <vault> results-search/plan-<set>-<engine>.json results-search/scores-<set>-<engine>.json <model dir>
    python3 search.py rank    --set main|astra [--engine haiku]   ranks both arms, writes the report
    python3 search.py answers --set main|astra [--engine haiku] [--provider claude-haiku]   the answer call, both arms

The ranking (§10), all code, no model:
- **Matching:** a person's names and aliases in the query (whole words, accents ignored; a name two people share matches
  both), and role phrases ("my sister", "mi hermana", the same finder as memories) resolved from the relations: one
  holder → that person; several → all of them as candidates; none named → the role group.
- **Admission:** every memory linked to a matched person is a result, whatever its search score.
- **Ranking:** an admitted memory scores max(its score for the query, its score for the rest of the query, with the
  people taken out) + a boost by how sure the link is (BOOST); a memory linked only to people the query doesn't name
  loses OTHERS (someone else's drink, when the query names Lucía); other memories keep their score. A query with no
  person is unchanged.
- **Answers:** when an admitted memory in the top 8 came through a role link, the memory that establishes that
  relation (the bridge) is added to the answer's input, within the cloud limit, if it isn't there already.
"""
import argparse
import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

from people import PERSON_NOUNS, PLURAL_ROLES, SINGULAR, SINGULAR_LABEL, STOP_NAMES, fold, label_class, role_phrases

HERE = Path(__file__).resolve().parent
OUT = HERE / "results-search"
G = HERE.parent / "search-answers"
USER = ["Sam"]
BOOST = {"full": 0.0, "weak": 0.0, "cand": 0.0}   # round 2: locked in results-search/locked.json (no boost)
OTHERS = 0.10     # subtracted from a memory linked only to people the query doesn't name
CAP = None        # boost only the CAP admitted memories that best match the query (None: all)
RANK = {"cand": 0, "weak": 1, "full": 2}
FULL_BASES = {"named", "stated_unique", "context", "confirmed", "group"}
WEAK_BASES = {"sole_known", "untrusted"}
STOP = {"a", "an", "and", "the", "of", "to", "for", "is", "are", "was", "what", "whats", "what's", "who", "when", "where",
        "how", "does", "do", "did", "should", "i", "my", "me", "now", "que", "qué", "le", "lo", "la", "el", "a", "de",
        "mi", "cuál", "es", "s"}
LEVELS = ["public", "low", "internal", "sensitive", "restricted", "secret"]
# Spanish function words, dropped from the rest of a query (FunesCore's keyword stop words are English).
ES_STOP = {"que", "qué", "le", "lo", "la", "las", "los", "el", "un", "una", "a", "de", "del", "en", "y", "o", "mi", "mis",
           "su", "sus", "es", "son", "por", "para", "con", "cuál", "cuáles", "cuándo", "dónde", "cómo", "quién", "me", "se",
           "al", "tu", "tus"}


def paths(set_name, engine):
    sfx = "" if set_name == "main" else f"-{set_name}"
    bf = OUT / (f"backfill-{engine}.json" if set_name == "main" else f"backfill-{set_name}-{engine}.json")
    return (HERE / f"fixtures/search-vault{sfx}.json", HERE / f"fixtures/search-queries{sfx}.json", bf,
            OUT / f"plan-{set_name}-{engine}.json", OUT / f"scores-{set_name}-{engine}.json")


def folded_with_map(text):
    """Accent-folded lowercase text and, for each folded character, its index in the original."""
    out, idx = [], []
    for i, ch in enumerate(text):
        for c in unicodedata.normalize("NFKD", ch):
            if not unicodedata.combining(c):
                out.append(c.lower())
                idx.append(i)
    return "".join(out), idx


# --- matching ------------------------------------------------------------------------------------------------------
def match_names(query, people):
    """[(start, end, [person ids])] for names in the query, longest first, no overlaps."""
    fq, idx = folded_with_map(query)
    users = {fold(u) for u in USER}
    by_alias = {}
    for p in people:
        if not p["name"]:
            continue
        for a in set(p["aliases"]) | {p["name"]}:
            fa = fold(a)
            if len(fa) < 3 or fa in users or fa in STOP:
                continue
            by_alias.setdefault(fa, set()).add(p["id"])
    # A first name alone matches everyone who has it as their first name.
    for p in people:
        if p["name"] and len(fold(p["name"]).split()) > 1:
            first = fold(p["name"]).split()[0]
            if len(first) >= 3 and first not in STOP and first not in users:
                by_alias.setdefault(first, set()).add(p["id"])
    found, taken = [], set()
    for fa in sorted(by_alias, key=len, reverse=True):
        for mt in re.finditer(r"(?<![\w])" + re.escape(fa) + r"(?:['’]s)?(?![\w])", fq):
            span = set(range(mt.start(), mt.end()))
            if span & taken:
                continue
            o = idx[mt.start()]
            if fa in STOP_NAMES:
                start = not query[:o].strip() or query[:o].rstrip()[-1:] in ".!?¿¡"
                after = query[idx[mt.end() - 1] + 1:].strip()
                owned = bool(re.match(r"['’]s\b", query[o + len(fa):]))
                if not query[o].isupper() or (start and not owned and after.strip("?!. ")):
                    continue    # "in may", "Will you…", "Mark the task": a common word unless capitalized mid-sentence,
                                # or at the start as "May's …" or the whole query ("May")
            taken |= span
            found.append((idx[mt.start()], idx[mt.end() - 1] + 1, sorted(by_alias[fa])))
    return found


def match_roles(query, people, relations):
    """[(start, end, [(person id, weight)])] for role phrases, resolved from the relations (code, §10)."""
    named = {p["id"] for p in people if p["name"]}
    out = []
    # "my sister's kids", "my partner's sister": about someone else, as in memories. Same length, so offsets hold.
    chained = {m.start() for m in re.finditer(r"['’]s\s+(\w[\w-]*)", query) if m.group(1).lower() in PERSON_NOUNS}
    query = re.sub(r"['’]s\b", "  ", query)
    for ph in role_phrases(query, USER):
        if ph.end in chained:
            continue     # "my partner's sister" is someone else: no person matched (Astra's review)
        if ph.word in PLURAL_ROLES:      # "my parents": the group, never one holder (as in memories)
            groups = [p["id"] for p in people if p["group"] and p["group"][0] == ph.type and p["group"][1] is None]
            out.append((ph.start, ph.end, [(g, "cand") for g in groups], ph))
            continue
        former = ph.cls == "ex" or any(m in ("old", "former", "late") for m in ph.mods)
        hold = {}
        for r in relations:
            if r["negated"] or r["type"] != ph.type or r["person"] not in named:
                continue
            if (r["status"] == "former") != former:
                continue
            cls = label_class(r["type"], r["label"])
            if not (ph.generic or cls is None or cls == ph.cls):
                continue
            hold.setdefault(r["person"], []).append(r)
        if len(hold) == 1:
            pid, rs = next(iter(hold.items()))
            sure = any(r["only"] for r in rs) or ph.type in SINGULAR or (ph.type, ph.cls) in SINGULAR_LABEL
            out.append((ph.start, ph.end, [(pid, "full" if sure else "weak")], ph))
        elif hold:
            out.append((ph.start, ph.end, [(pid, "cand") for pid in hold], ph))
        else:
            groups = [p["id"] for p in people if p["group"] and p["group"][0] == ph.type
                      and (ph.generic or p["group"][1] in (None, ph.cls))]
            # §10: a role group adds its memories without naming anyone, at the candidates weight
            out.append((ph.start, ph.end, [(g, "cand") for g in groups], ph))
    return out


def link_weight(l):
    if l["basis"] in FULL_BASES:
        return "full"
    if l["basis"] in WEAK_BASES:
        return "weak"
    return None


def plan_query(q, bf):
    people, relations = bf["people"], [r for r in bf["relations"]]
    matched = {}                         # person id -> (weight, via)
    spans = []
    for s, e, pids in match_names(q["query"], people):
        spans.append((s, e))
        for pid in pids:     # a shared name admits everyone who has it; the rest of the query decides
            matched[pid] = ("full", "name")
    for s, e, holders, ph in match_roles(q["query"], people, relations):
        if any(a < e and s < b for a, b in spans):
            continue
        spans.append((s, e))
        for pid, w in holders:
            if pid not in matched or RANK[w] > RANK[matched[pid][0]]:
                matched[pid] = (w, "role:" + ph.type)
    if not matched:
        return {"id": q["id"], "query": q["query"], "rest": None, "matched": {}, "admitted": {}, "via": {}}
    rest = q["query"]
    for s, e in sorted(spans, reverse=True):
        rest = rest[:s] + " " + rest[e:]
    rest = re.sub(r"(^|\s)['’]s\b", " ", rest)
    rest = re.sub(r"\s+", " ", re.sub(r"[¿?¡!,.]", " ", rest)).strip()
    rest = " ".join(w for w in rest.split() if w.lower() not in ES_STOP)
    if not [w for w in re.findall(r"[\w'’]+", rest.lower()) if w not in STOP]:
        rest = ""
    admitted, via = {}, {}
    for l in bf["links"]:
        pid = l["person"]
        if pid is None and l["basis"] in ("ambiguous", "candidates"):
            # an unresolved name or role: admitted for each candidate the query names, at the candidates weight
            pid = next((c for c in l.get("candidates") or [] if c in matched), None)
            lw = "cand" if pid else None
        else:
            lw = link_weight(l) if pid in matched else None
        if pid in matched and lw:
            w = min(lw, matched[pid][0], key=lambda x: RANK[x])
            if l["memory"] not in admitted or RANK[w] > RANK[admitted[l["memory"]]]:
                admitted[l["memory"]] = w
                ph = role_phrases(l["surface"], USER) if l["kind"] == "role" else []
                via[l["memory"]] = {"person": pid, "kind": l["kind"], "basis": l["basis"], "surface": l["surface"],
                                    "type": ph[0].type if ph else None, "candidates": l.get("candidates") or []}
    # Linked only to people the query doesn't name: a resolved, full-basis link to a named person (a group, a weak or an
    # unresolved link isn't evidence that the memory is about someone else).
    named = {p["id"] for p in people if p["name"]}
    others = sorted({l["memory"] for l in bf["links"] if l["person"] in named and l["person"] not in matched
                     and link_weight(l) == "full"} - set(admitted))
    names = {p["id"]: p["name"] or f"group:{'/'.join(x or '' for x in p['group'])}" for p in people}
    return {"id": q["id"], "query": q["query"], "rest": rest, "others": others,
            "matched": {names[k]: v for k, v in matched.items()}, "matched_ids": sorted(matched),
            "admitted": admitted, "via": via}


def cmd_plan(a):
    vault, queries, bf_path, plan_path, _ = paths(a.set, a.engine)
    bf = json.loads(bf_path.read_text())
    qs = json.loads(queries.read_text())["queries"]
    plan = [plan_query(q, bf) for q in qs]
    plan_path.write_text(json.dumps(plan, indent=1, ensure_ascii=False))
    n = sum(1 for p in plan if p["matched"])
    print(f"{len(plan)} queries, {n} with people; plan → {plan_path.relative_to(HERE)}")
    for p in plan:
        if p["matched"]:
            print(f"  {p['id']}: {p['query']!r} → {p['matched']} rest={p['rest']!r} admitted={len(p['admitted'])}")


# --- ranking -------------------------------------------------------------------------------------------------------
def rank_people(entry, plan):
    """Both arms, as lists of memory ids."""
    full = {h["id"]: h["score"] for h in entry["full"]["hits"]}
    base = [h["id"] for h in entry["full"]["hits"]]
    if not plan["admitted"]:
        return base, base, {}
    rest = {}
    if entry.get("restScores"):
        rs = entry["restScores"]
        kw = {h["id"]: h["keyword"] for h in rs["hits"]}
        cos = rs["cosines"]
        lo, hi = min(cos.values()), max(cos.values())
        for mid, c in cos.items():
            rest[mid] = 0.30 * kw.get(mid, 0) + 0.70 * ((c - lo) / (hi - lo) if hi > lo else 0)
    order = {mid: i for i, mid in enumerate(base)}
    score = dict(full)
    for mid in plan.get("others", []):
        if mid in score:
            score[mid] -= OTHERS
    pre = {mid: max(full.get(mid, 0), rest.get(mid, 0)) for mid in plan["admitted"]}
    boosted = set(sorted(pre, key=lambda m: -pre[m])[:CAP]) if CAP else set(pre)
    for mid, w in plan["admitted"].items():
        score[mid] = pre[mid] + (BOOST[w] if mid in boosted else 0)
    ranked = sorted(score, key=lambda m: (-score[m], order.get(m, 10_000), m))
    return base, ranked, score


def best_rank(ranked, targets):
    rs = [ranked.index(t) + 1 for t in targets if t in ranked]
    return min(rs) if rs else None


def cmd_rank(a):
    vault, queries, bf_path, plan_path, scores_path = paths(a.set, a.engine)
    qs = {q["id"]: q for q in json.loads(queries.read_text())["queries"]}
    plan = {p["id"]: p for p in json.loads(plan_path.read_text())}
    scores = json.loads(scores_path.read_text())
    rows, lines = [], []
    agg = Counter()
    for e in scores["queries"]:
        q, p = qs[e["id"]], plan[e["id"]]
        base, ppl, _ = rank_people(e, p)
        r = {"id": q["id"], "set": q["set"], "query": q["query"], "people": bool(p["admitted"]), "tags": q.get("tags", [])}
        if q.get("about"):
            k = min(5, len(q["about"]))
            r["about_base"] = sum(1 for m in base[:5] if m in q["about"])
            r["about_people"] = sum(1 for m in ppl[:5] if m in q["about"])
            r["about_of"] = k
        elif q["targets"]:
            r["base"], r["ppl"] = best_rank(base, q["targets"]), best_rank(ppl, q["targets"])
        if q.get("decoys"):
            for arm, lst, t in (("base", base, r.get("base")), ("ppl", ppl, r.get("ppl"))):
                ranks = [lst.index(d) + 1 for d in q["decoys"] if d in lst]
                r[f"decoy_above_{arm}"] = sum(1 for x in ranks if t is None or x < t)
                r[f"decoy_top3_{arm}"] = sum(1 for x in ranks if x <= 3)
        r["top_base"], r["top_ppl"] = base[:5], ppl[:5]
        rows.append(r)
    (OUT / f"rank-{a.set}-{a.engine}.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False))

    def top3(x):
        return x is not None and x <= 3

    def fmt(x):
        return "–" if x is None else str(x)
    lines += [f"# Spike H search ranks ({a.set} set, links from {a.engine})", "", f"Boost: {BOOST}; others: −{OTHERS}", ""]
    for s in ("people", "spike-g", "bench"):
        sub = [r for r in rows if r["set"] == s]
        if not sub:
            continue
        ranked = [r for r in sub if "base" in r]
        about = [r for r in sub if "about_base" in r]
        lines += [f"## {s} ({len(sub)} queries, {sum(r['people'] for r in sub)} with a person matched)", ""]
        if ranked:
            lines += [f"- Best target in the top 3: without people {sum(top3(r['base']) for r in ranked)}/{len(ranked)}, "
                      f"with people {sum(top3(r['ppl']) for r in ranked)}/{len(ranked)}",
                      f"- Best target in the top 8 (what the answer reads): without {sum(r['base'] is not None and r['base'] <= 8 for r in ranked)}/{len(ranked)}, "
                      f"with {sum(r['ppl'] is not None and r['ppl'] <= 8 for r in ranked)}/{len(ranked)}",
                      f"- Better with people: {sum(1 for r in ranked if (r['ppl'] or 999) < (r['base'] or 999))}, "
                      f"worse: {sum(1 for r in ranked if (r['ppl'] or 999) > (r['base'] or 999))}"]
        dec = [r for r in sub if "decoy_above_base" in r]
        if dec:
            lines += [f"- Decoys (someone else's similar fact, {sum(len(qs[r['id']]['decoys']) for r in dec)} in {len(dec)} queries) "
                      f"ranked above the best target: without {sum(r['decoy_above_base'] for r in dec)}, with "
                      f"{sum(r['decoy_above_ppl'] for r in dec)}; in the top 3: without {sum(r['decoy_top3_base'] for r in dec)}, "
                      f"with {sum(r['decoy_top3_ppl'] for r in dec)}"]
        if about:
            lines += [f"- Person-only queries, memories about the person in the top 5: without "
                      f"{sum(r['about_base'] for r in about)}/{sum(r['about_of'] for r in about)}, with "
                      f"{sum(r['about_people'] for r in about)}/{sum(r['about_of'] for r in about)}"]
        lines += ["", "| Query | Person matched | Best target rank: without → with |", "|---|---|---|"]
        for r in sub:
            if not r["people"] and s != "people":
                continue
            m = plan[r["id"]]["matched"]
            ms = ", ".join(f"{k} ({v[0]}, {v[1]})" for k, v in m.items()) or "none"
            val = (f"{r['about_base']}/{r['about_of']} → {r['about_people']}/{r['about_of']} about them in the top 5"
                   if "about_base" in r else f"{fmt(r.get('base'))} → {fmt(r.get('ppl'))}")
            lines.append(f"| {r['id']} {r['query']} | {ms} | {val} |")
        lines.append("")
    report = OUT / f"report-search-{a.set}-{a.engine}.md"
    report.write_text("\n".join(lines))
    print("\n".join(lines))


# --- answers -------------------------------------------------------------------------------------------------------
def cmd_answers(a):
    sys.path.insert(0, str(G))
    from answer import build, validate  # Spike G's prompt and validation (memory processing §10.3, §10.4)
    from providers import PROVIDERS
    vault, queries, bf_path, plan_path, scores_path = paths(a.set, a.engine)
    mems = {m["id"]: m for m in json.loads(vault.read_text())["memories"]}
    bf = json.loads(bf_path.read_text())
    qs = {q["id"]: q for q in json.loads(queries.read_text())["queries"]}
    plan = {p["id"]: p for p in json.loads(plan_path.read_text())}
    scores = json.loads(scores_path.read_text())
    cats = scores["categoryNames"]
    rels = [r for r in bf["relations"] if not r["negated"]]

    def label(m):
        if m["trust"] != "untrusted":
            return "you"
        return {"agent_write": "an agent", "agent_suggestion": "an agent", "import": "an import"}.get(m["source"], "shared text")

    def entry(mid, passages):
        m = mems[mid]
        return {"fixtureId": mid, "title": m["title"], "kind": m["kind"], "created": m["createdAt"], "updated": m["updatedAt"],
                "source": label(m), "sensitivity": m["sensitivity"], "text": passages.get(mid, m["body"][:1500]),
                "categories": [cats.get(c, c) for c in m["categories"]]}

    def bridges(p, top):
        """The memory establishing each role link's relation, for admitted memories in the top 8 (§10)."""
        out = []
        allowed = set(LEVELS[:LEVELS.index("internal") + 1])
        for mid in top:
            v = p["via"].get(mid)
            if not v or v["kind"] != "role":
                continue
            ev = [e for r in rels if r["person"] == v["person"] for e in r["evidence"]]
            for e in ev:
                if e in mems and e not in top and e not in out and mems[e]["sensitivity"] in allowed:
                    out.append(e)
                    break
        return out

    out_dir = OUT / "answers" / a.provider
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{a.set}-{a.engine}.jsonl"
    done = {}
    if path.exists():
        for line in path.read_text().splitlines():
            r = json.loads(line)
            done[(r["id"], r["arm"])] = r
    provider = PROVIDERS[a.provider]()
    with path.open("a") as f:
        for e in scores["queries"]:
            q, p = qs[e["id"]], plan[e["id"]]
            if q["set"] == "bench" or q.get("noAnswerCall"):
                continue
            if a.only and q["id"] not in a.only.split(","):
                continue
            base, ppl, _ = rank_people(e, p)
            arms = {"base": (base[:8], []), "people": (ppl[:8], bridges(p, ppl[:8]))}
            for arm, (top, br) in arms.items():
                if (q["id"], arm) in done:
                    continue
                passages = e["full"]["passages"]
                results = [entry(m, passages) for m in top] + [entry(m, {}) for m in br]
                b = build(q, {"cloud": {"results": results}, "totalHits": len(e["full"]["hits"])}, "cloud")
                rec = {"id": q["id"], "arm": arm, "set": q["set"], "sent": [m["fixtureId"] for m in b["sent"]], "bridges": br}
                same = arm == "people" and (q["id"], "base") in done and done[(q["id"], "base")]["sent"] == rec["sent"]
                if same:
                    prev = done[(q["id"], "base")]
                    rec.update({k: prev[k] for k in ("outcome", "claims", "dropped", "found", "ms")}, reused=True)
                elif not b["sent"]:
                    rec.update(outcome="no_answer", claims=[], dropped=[], found="no", ms=0)
                else:
                    r = provider.generate(b["instructions"], b["prompt"], b["schema"])
                    if r.get("ok"):
                        rec.update(validate(r["content"], b["sent"]), ms=r.get("ms"))
                    else:
                        rec.update(outcome="failed", claims=[], dropped=[], found=None, ms=r.get("ms"), error=r.get("errorKind"))
                done[(q["id"], arm)] = rec
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                f.flush()
                print(f"{q['id']} {arm}: {rec['outcome']}, {len(rec['claims'])} claims{' (same input)' if rec.get('reused') else ''}",
                      file=sys.stderr)
    score_answers(qs, done, a)


def plain(t):
    return t.translate(str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"'}))


def score_answers(qs, done, a):
    def hits(keys, text):
        return all(re.search(k, plain(text), re.I) for k in keys)
    lines = [f"# Spike H answers ({a.set} set, links from {a.engine}, answers by {a.provider})", ""]
    rows = []
    for s in ("people", "spike-g"):
        c = Counter()
        detail = []
        for (qid, arm), r in sorted(done.items()):
            q = qs[qid]
            if q["set"] != s:
                continue
            for cl in r["claims"]:
                t = cl["text"]
                bad = [m["label"] for m in q["must_not"] if hits(m["all"], t) and not any(re.search(n, plain(t), re.I) for n in m["none"])]
                ok = any(hits(fct["keys"], t) for fct in q["facts"])
                c[(arm, "claims")] += 1
                if bad:
                    c[(arm, "wrong")] += 1
                    detail.append(f"- {qid} {arm} WRONG ({'; '.join(bad)}): {t}")
                elif ok:
                    c[(arm, "correct")] += 1
                else:
                    c[(arm, "unmatched")] += 1
                    detail.append(f"- {qid} {arm} unmatched: {t}")
            req = [fct for fct in q["facts"] if fct["required"]]
            if q.get("answerable") and req:
                c[(arm, "answerable")] += 1
                if any(all(any(hits(fct["keys"], cl["text"]) for cl in r["claims"]) for fct in [rq]) for rq in req):
                    c[(arm, "required_found")] += 1
            if not q.get("answerable"):
                c[(arm, "no_answer_q")] += 1
                c[(arm, "no_answer_right")] += r["outcome"] == "no_answer"
        lines += [f"## {s}", "", "| Measure | Without people | With people |", "|---|---|---|"]
        for k, name in (("claims", "Claims"), ("correct", "Correct (match a fact)"), ("wrong", "Wrong (match a must-not)"),
                        ("unmatched", "Unmatched (check by hand)")):
            lines.append(f"| {name} | {c[('base', k)]} | {c[('people', k)]} |")
        lines.append(f"| Answerable questions where the answer states a required fact | {c[('base', 'required_found')]}/{c[('base', 'answerable')]} | "
                     f"{c[('people', 'required_found')]}/{c[('people', 'answerable')]} |")
        lines.append(f"| No-answer questions answered with no claims | {c[('base', 'no_answer_right')]}/{c[('base', 'no_answer_q')]} | "
                     f"{c[('people', 'no_answer_right')]}/{c[('people', 'no_answer_q')]} |")
        lines += ["", *detail, ""]
    report = OUT / f"report-answers-{a.set}-{a.engine}.md"
    report.write_text("\n".join(lines))
    print("\n".join(lines))


def cmd_grid(a):
    """Tuning on the main set only: each (boost, others) pair over every engine run given; the held-out set is never
    used here."""
    global BOOST, OTHERS
    runs = []
    for eng in a.engine.split(","):
        _, queries, _, plan_path, scores_path = paths("main", eng)
        qs = {q["id"]: q for q in json.loads(queries.read_text())["queries"]}
        runs.append((eng, qs, {p["id"]: p for p in json.loads(plan_path.read_text())}, json.loads(scores_path.read_text())["queries"]))
    print("boost others | top3 people (without) | worse people | decoys in top 3 (without) | person-only top5 | spike-g/bench worse")
    for full in (0.5, 0.3, 0.2, 0.1):
        for oth in (0.0, 0.1, 0.2, 0.3):
            BOOST, OTHERS = {"full": full, "weak": round(full * 0.7, 3), "cand": round(full * 0.3, 3)}, oth
            c = Counter()
            for eng, qs, plan, sc in runs:
                for e in sc:
                    q = qs[e["id"]]
                    b, p, _ = rank_people(e, plan[e["id"]])
                    if q.get("about"):
                        c["about"] += sum(m in q["about"] for m in p[:5]); c["about_n"] += min(5, len(q["about"]))
                        continue
                    if not q["targets"]:
                        continue
                    rb, rp = best_rank(b, q["targets"]) or 99, best_rank(p, q["targets"]) or 99
                    k = "p" if q["set"] == "people" else "r"
                    c[k + "top3"] += rp <= 3; c[k + "top3_b"] += rb <= 3; c[k + "n"] += 1; c[k + "worse"] += rp > rb
                    for d in q.get("decoys", []):
                        c["d3"] += d in p[:3]; c["d3_b"] += d in b[:3]
            print(f"{full:5} {oth:6} | {c['ptop3']}/{c['pn']} ({c['ptop3_b']}) | {c['pworse']} | {c['d3']} ({c['d3_b']}) | "
                  f"{c['about']}/{c['about_n']} | {c['rworse']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "rank", "answers", "grid"])
    ap.add_argument("--set", default="main")
    ap.add_argument("--engine", default="haiku")
    ap.add_argument("--provider", default="claude-haiku")
    ap.add_argument("--only", default="")
    ap.add_argument("--boost", type=float, default=None, help="the full-basis boost (weak 0.7×, candidates 0.3×)")
    ap.add_argument("--others", type=float, default=None)
    a = ap.parse_args()
    global BOOST, OTHERS
    if a.boost is not None:
        BOOST = {"full": a.boost, "weak": round(a.boost * 0.7, 3), "cand": round(a.boost * 0.3, 3)}
    if a.others is not None:
        OTHERS = a.others
    {"plan": cmd_plan, "rank": cmd_rank, "answers": cmd_answers, "grid": cmd_grid}[a.cmd](a)


if __name__ == "__main__":
    main()
