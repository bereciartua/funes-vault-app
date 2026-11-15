#!/usr/bin/env python3
"""Spike H2 (plan v5 §4, §7, §16): the user's work history. A model reads each memory within the cloud limit and
extracts the user's own jobs; code builds stints and a timeline and resolves "before / after X", "in <year>" and
"current" with the plan's rule. Run privately on the author's vault copy (counts only leave that folder) and on the
invented fixture by GPT-6-Astra (fixtures/work-*.json).

    python3 work_history.py extract <vault.json> <out.jsonl> [--aliases Sam] [--limit internal] [--provider claude-haiku]
    python3 work_history.py score   <vault.json> <extract.jsonl> fixtures/work-queries.json     (the fixture: vs truth)

The resolver (plan v5 §7): "before X" = a stated "before" edge, else the stint that ended latest at or before X's
start, else ambiguous; a stint still current or overlapping X is never "before X". Code never invents dates.
"""
import argparse
import json
import re
import sys
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from providers import PROVIDERS

LEVELS = ["public", "low", "internal", "sensitive", "restricted", "secret"]
SUFFIX = re.compile(r"\b(inc|ltd|llc|gmbh|s\.?a|s\.?l|lda|plc|corp|co)\.?$", re.I)

INS = """You read one note from a personal memory vault. Extract only the user's OWN employment that the note states: organizations the user works or worked for (employers, the user's own company or self-employment). Not other people's jobs, not clients, not organizations the user merely mentions or buys from.
For each, give:
- org: the organization's name exactly as written in the note ("Self-employed" for freelancing without a company name);
- role: the user's role or title as written, or null;
- status: "current" (works there now), "former" (no longer), or "unknown";
- start: when the user started, as written (a year, month or date), or null;
- end: when the user stopped, as written, or null;
- before / after: the name of another organization the note says this job came before or after, as written, or null;
- kind: "employee", "self_employed" (freelance or sole trader), or "client" (an organization the user did work FOR while freelancing, not an employer);
- also_called: another name the note gives for the same organization ("Kiteworks Ltd, then called Blue Kite"), or null;
- quote: a short exact quote from the note that states it.
If the note states no employment of the user's, return an empty list. Only what the note states."""

SCHEMA = {"type": "object", "additionalProperties": False, "required": ["jobs"], "properties": {"jobs": {"type": "array", "items": {
    "type": "object", "additionalProperties": False,
    "required": ["org", "role", "status", "start", "end", "before", "after", "kind", "also_called", "quote"],
    "properties": {"org": {"type": "string"}, "role": {"type": ["string", "null"]},
                   "status": {"type": "string", "enum": ["current", "former", "unknown"]},
                   "start": {"type": ["string", "null"]}, "end": {"type": ["string", "null"]},
                   "before": {"type": ["string", "null"]}, "after": {"type": ["string", "null"]},
                   "kind": {"type": "string", "enum": ["employee", "self_employed", "client"]},
                   "also_called": {"type": ["string", "null"]},
                   "quote": {"type": "string"}}}}}}


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s or "") if not unicodedata.combining(c)).lower().strip()


def norm_org(s):
    """Legal suffixes and case normalised ("Acme", "Acme Inc.")."""
    return SUFFIX.sub("", re.sub(r"[,.]+$", "", fold(s))).strip(" ,.")


def year(s):
    m = re.search(r"\b(19|20)\d{2}\b", s or "")
    return int(m.group(0)) if m else None


def user_text(t, aliases):
    for a in sorted(aliases, key=len, reverse=True):
        t = re.sub(r"\b" + re.escape(a) + r"\b", "the user", t)
    return t


def extract(a):
    mems = json.loads(Path(a.vault).read_text())["memories"]
    limit = LEVELS.index(a.limit)
    aliases = [x for x in a.aliases.split(",") if x]
    todo = [m for m in mems if LEVELS.index(m["sensitivity"]) <= limit]
    out = Path(a.out)
    done = {json.loads(l)["id"] for l in out.read_text().splitlines()} if out.exists() else set()
    prov = PROVIDERS[a.provider]()

    def one(m):
        text = user_text(m["title"] + "\n" + m["body"], aliases)
        r = prov.generate(INS, f"<note written=\"{m['createdAt']}\">\n{text}\n</note>", SCHEMA)
        jobs, dropped = [], 0
        n = lambda s: re.sub(r"\s+", " ", fold(s))
        for j in (r.get("content") or {}).get("jobs", []) if r.get("ok") else []:
            if n(j["quote"]) in n(text) and (n(j["org"]) in n(text) or j["org"] == "Self-employed"):
                for k in ("start", "end", "before", "after", "role", "also_called"):
                    if j[k] and n(j[k]) not in n(text):
                        j[k] = None
                jobs.append(j)
            else:
                dropped += 1
        return {"id": m["id"], "ok": bool(r.get("ok")), "jobs": jobs, "dropped": dropped, "cost": r.get("costUSD") or 0,
                "written": m["createdAt"], "trust": m.get("trust", "trusted")}
    rows = [m for m in todo if m["id"] not in done]
    with ThreadPoolExecutor(4) as ex, out.open("a") as f:
        for rec in ex.map(one, rows):
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            f.flush()
    recs = [json.loads(l) for l in out.read_text().splitlines()]
    print(f"read {len(recs)}; failed {sum(not r['ok'] for r in recs)}; memories with a job {sum(bool(r['jobs']) for r in recs)}; "
          f"facts {sum(len(r['jobs']) for r in recs)}; dropped {sum(r['dropped'] for r in recs)}; cost ${sum(r['cost'] for r in recs):.2f}")


MONTHS = {m: i for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
MONTHS.update({"ene": 1, "abr": 4, "ago": 8, "dic": 12, "set": 9})


def ym(s, end=False):
    """A date as written → months since year 0, at the precision written (a bare year: January as a start, December
    as an end), and whether the month was stated. Code never invents a date beyond that."""
    if not s:
        return None, False
    y = year(s)
    if not y:
        return None, False
    t = fold(s)
    m = re.search(r"\b(19|20)\d{2}-(\d{1,2})\b", t)
    mon = int(m.group(2)) if m else next((v for k, v in MONTHS.items() if re.search(r"\b" + k, t)), None)
    if mon:
        return y * 12 + mon - 1, True
    return y * 12 + (11 if end else 0), False


def build(recs):
    """Employers (clients excluded; names joined by normalisation and "also called") and their stints. A stint pairs a
    start with the earliest end after it and before the next start, so a rehire is a second stint."""
    parent = {}

    def root(k):
        while parent.get(k, k) != k:
            k = parent[k]
        return k

    def union(a, b):
        ra, rb = root(a), root(b)
        if ra != rb:
            parent[rb] = ra
    facts = [(r, j) for r in recs for j in r["jobs"] if j.get("kind", "employee") != "client"]
    keys = {}
    for r, j in facts:
        k = norm_org(j["org"])
        hit = next((o for o in keys if o and k and (o in k or k in o)), None)
        keys.setdefault(hit or k, set()).add(j["org"])
        if hit and hit != k:
            union(hit, hit)
        if j.get("also_called"):
            a = norm_org(j["also_called"])
            hit2 = next((o for o in keys if o and a and (o in a or a in o)), a)
            keys.setdefault(hit2, set()).add(j["also_called"])
            union(hit or k, hit2)
    orgs = {}
    for r, j in facts:
        k = norm_org(j["org"])
        key = root(next((o for o in keys if o and k and (o in k or k in o)), k))
        o = orgs.setdefault(key, {"names": set(), "mems": set(), "starts": set(), "ends": set(), "status": set(),
                                  "before": set(), "after": set(), "start": set(), "end": set()})
        o["names"] |= {j["org"]} | ({j["also_called"]} if j.get("also_called") else set())
        o["mems"].add(r["id"]); o["status"].add(j["status"])
        st, _ = ym(j["start"]); en, _ = ym(j["end"], end=True)
        if st is not None:
            o["starts"].add(st); o["start"].add(year(j["start"]))
        if en is not None:
            o["ends"].add(en); o["end"].add(year(j["end"]))
        for f in ("before", "after"):
            if j[f]:
                o[f].add(norm_org(j[f]))
    for k, o in orgs.items():
        starts, ends = sorted(o["starts"]), sorted(o["ends"])
        stints = []
        for i, st in enumerate(starts):
            nxt = starts[i + 1] if i + 1 < len(starts) else None
            en = next((e for e in ends if e >= st and (nxt is None or e < nxt)), None)
            if starts[i - 1:i] and stints and stints[-1][1] is None and en is None:
                continue          # two starts with no end between: the same stint, written twice
            stints.append([st, en])
        if not starts and ends:
            stints.append([None, max(ends)])
        if not stints:
            stints.append([None, None])
        if "current" in o["status"] and stints[-1][1] is None:
            stints[-1][1] = "now"
        o["stints"] = stints
    return orgs


def find(orgs, name):
    if re.search(r"sole trader|self.employed|freelanc|aut[oó]nom", fold(name)):
        name = next((n for o in orgs.values() for n in o["names"] if re.search(r"self.employed|freelanc", fold(n))), name)
    k = norm_org(name)
    return next((o for o, v in orgs.items() if o and (o in k or k in o or any(norm_org(n) and (norm_org(n) in k or k in norm_org(n)) for n in v["names"]))), None)


def pick_stint(o, query):
    """Which stint of X the query means: "first" → earliest, "return/second/again" → latest; one stint → it."""
    q = fold(query)
    st = o["stints"]
    if len(st) == 1:
        return st[0]
    if re.search(r"\b(first|primera|primer)\b", q):
        return st[0]
    if re.search(r"\b(return|returned|rejoin|second|again|volver|volvi|segunda|regres)", q):
        return st[-1]
    return None


GAP = 2   # months between a stint's end and X's start beyond which the answer must say there's a gap


def before(orgs, x, query=""):
    """The plan's rule on stints. Returns (employer key | None, basis): stated, ordered, gap, ambiguous."""
    if x not in orgs:
        return None, "unknown"
    stated = [k for k, o in orgs.items() if k != x and (any(b and (b in x or x in b) for b in o["before"])
                                                        or any(a and (a in k or k in a) for a in orgs[x]["after"]))]
    if len(stated) == 1 and len(orgs[x]["stints"]) == 1:
        return stated[0], "stated"
    sx = pick_stint(orgs[x], query)
    if not sx or sx[0] is None:
        return None, "ambiguous"
    cands = []
    for k, o in orgs.items():
        for st in o["stints"]:
            if (k, st) == (x, sx) or st[1] in (None, "now") or st[1] > sx[0]:
                continue                      # current, undated or overlapping X: never "before X"
            cands.append((st[1], k))
    if not cands:
        return None, "ambiguous"
    best = max(e for e, _ in cands)
    top = {k for e, k in cands if e == best}
    if len(top) > 1:
        return None, "ambiguous"
    k = top.pop()
    return (k, "gap") if sx[0] - best > GAP else (k, "ordered")


def after(orgs, x, query=""):
    if x not in orgs:
        return None, "unknown"
    stated = [k for k, o in orgs.items() if k != x and (any(a and (a in x or x in a) for a in o["after"])
                                                        or any(b and (b in k or k in b) for b in orgs[x]["before"]))]
    if len(stated) == 1 and len(orgs[x]["stints"]) == 1:
        return stated[0], "stated"
    sx = pick_stint(orgs[x], query)
    if not sx or sx[1] in (None, "now"):
        return None, "ambiguous"
    cands = [(st[0], k) for k, o in orgs.items() for st in o["stints"] if (k, st) != (x, sx) and st[0] is not None and st[0] >= sx[1]]
    if not cands:
        return None, "ambiguous"
    best = min(s0 for s0, _ in cands)
    top = {k for s0, k in cands if s0 == best}
    if len(top) > 1:
        return None, "ambiguous"
    k = top.pop()
    return (k, "gap") if best - sx[1] > GAP else (k, "ordered")


INTENT = re.compile(r"\b(job|jobs|work|worked|working|employer|company|employed|role|trabajo|trabajaba|trabaj[eé]|empresa)\b", re.I)


def intent(query):
    """A timeline query needs a job/employer word plus before/after/previous/current/a year (plan v5 §7)."""
    q = fold(query)
    if not INTENT.search(q):
        return None
    if re.search(r"\b(before|antes de)\b", q):
        return "before"
    if re.search(r"\b(after|despues de)\b", q):
        return "after"
    if re.search(r"\b(19|20)\d{2}\b", q):
        return "year"
    if re.search(r"\b(previous|anterior|last)\b", q):
        return "previous"
    if re.search(r"\b(current|now|actual)\b", q):
        return "current"
    return None


def score(a):
    """On the invented fixture: the timeline's employers and answers against Astra's truth."""
    recs = [json.loads(l) for l in Path(a.extract).read_text().splitlines()]
    data = json.loads(Path(a.queries).read_text())
    orgs = build(recs)
    truth = data["timeline"]
    emp = [t for t in truth if t["kind"] in ("employee", "self_employed")]
    found = sum(1 for t in emp if find(orgs, t["org"]))
    print(f"employers in the truth {len({norm_org(t['org']) for t in emp})}; found {len({norm_org(t['org']) for t in emp if find(orgs, t['org'])})}; "
          f"employers made by the extraction {len(orgs)} (clients or wrong ones: "
          f"{sum(1 for k in orgs if not any(norm_org(t['org']) in k or k in norm_org(t['org']) for t in emp))})")
    right = wrong = amb = trig_neg = 0
    rows = []
    for q in data["queries"]:
        kind = intent(q["query"])
        if q["kind"] in ("negative", "role_in_stint"):
            trig_neg += kind is not None
            rows.append((q["id"], q["kind"], q["query"], "triggered" if kind else "not triggered"))
            continue
        if q["kind"] not in ("before", "after"):
            continue
        names = sorted({n for o in orgs.values() for n in o["names"]}, key=len, reverse=True)
        xname = next((n for n in names if norm_org(n) and re.search(r"(?<!\w)" + re.escape(norm_org(n)) + r"(?!\w)", fold(q["query"]))), None)
        x = find(orgs, xname) if xname else None
        got, basis = (before if q["kind"] == "before" else after)(orgs, x, q["query"]) if x else (None, "no X")
        want = find(orgs, q["answer_org"]) if q["answer_org"] else None
        ok = got is not None and got == want and basis != "gap"
        gap = basis == "gap"
        right += ok; wrong += (got is not None and not ok and not gap); amb += got is None or gap
        rows.append((q["id"], q["kind"], q["query"], f"{basis}: {'right' if ok else ('gap told' if gap else ('ambiguous' if got is None else 'WRONG'))}"))
    print(f"before/after queries: right {right}, wrong {wrong}, ambiguous or gap told {amb}; negative or in-stint queries that triggered "
          f"the timeline: {trig_neg}")
    for r in rows:
        print("  ", *r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["extract", "score"])
    ap.add_argument("vault")
    ap.add_argument("out_or_extract")
    ap.add_argument("queries", nargs="?")
    ap.add_argument("--aliases", default="")
    ap.add_argument("--limit", default="internal")
    ap.add_argument("--provider", default="claude-haiku")
    a = ap.parse_args()
    a.out = a.extract = a.out_or_extract
    {"extract": extract, "score": score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
