#!/usr/bin/env python3
"""Scores Spike G's results (results/<provider>/<set>.jsonl) into results/report.md, against Phase 9.2's gates.

- Correct claims: surviving claims that match a fact of the question and no `must_not` (build_fixtures.py's rules),
  over all surviving claims. Claims matching neither are "unmatched": incorrect until labelled by hand in
  labels.json ({"<provider>/<set>/<question>/<claim>": {"correct": true|false, "note": "..."}}, the claim's index
  after validation). A label overrides the keys and `must_not` rules.
- Answerable as sent: the question has an answer and a memory holding it was sent (search found it and, for a cloud
  provider, it's within the cloud limit). The right "no answer" is scored on the others.
- Gates: correct claims ≥ 95%, right "no answer" ≥ 90%, answered ≥ 80% of answerable, p95 ≤ 15 s.
"""
import json
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATES = {"correct": 0.95, "no_answer": 0.90, "answered": 0.80, "p95_ms": 15_000}


def plain(text):
    """Curly apostrophes and quotes as straight ones, so "don’t" meets the keys' "n't"."""
    return text.translate(str.maketrans({"\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"'}))


def matches(keys, text):
    return all(re.search(k, plain(text), re.I) for k in keys)


def wrong(rule, text):
    return matches(rule["all"], text) and not any(re.search(n, plain(text), re.I) for n in rule["none"])


def answerable_as_sent(q, rec, provider):
    if not q["answerable"] or (q["aboveLimit"] and provider != "apple"):
        return False
    sent = set(rec.get("sent") or [])
    required = [f for f in q["facts"] if f["required"]]
    return any(f.get("memory") is None or f["memory"] in sent for f in required)


def pct(a, b):
    return f"{a}/{b} ({100 * a / b:.0f}%)" if b else "–"


def score(provider, set_name, records, questions, labels):
    qs = {q["id"]: q for q in questions}
    claims = correct = wrong_n = unmatched_n = 0
    unmatched, wrongs = [], []
    ans_n = ans_ok = noans_n = noans_ok = 0
    recall_hit = recall_n = 0
    conflict_n = conflict_ok = 0
    dropped = Counter()
    failed = 0
    latencies = [r["ms"] for r in records if r.get("called") and r.get("ok")]
    tokens = [(r.get("promptTokens") or 0, r.get("outputTokens") or 0) for r in records if r.get("called") and r.get("ok")]
    for r in records:
        q = qs[r["id"]]
        if r["outcome"] == "failed":
            failed += 1
        for d in r.get("dropped") or []:
            dropped[d["reason"]] += 1
        matched_facts = set()
        for i, c in enumerate(r.get("claims") or []):
            claims += 1
            text = c["text"]
            hits = [j for j, f in enumerate(q["facts"]) if matches(f["keys"], text)]
            bad = [m["label"] for m in q["must_not"] if wrong(m, text)]
            key = f"{provider}/{set_name}/{r['id']}/{i}"
            label = labels.get(key)
            if isinstance(label, dict):
                label = label.get("correct")
            if label is False:
                wrong_n += 1
                wrongs.append((r["id"], text, ["labelled wrong"]))
            elif label is True:
                correct += 1
                matched_facts.update(hits)
            elif bad:
                wrong_n += 1
                wrongs.append((r["id"], text, bad))
            elif hits:
                correct += 1
                matched_facts.update(hits)
            else:
                unmatched_n += 1
                if key not in labels:
                    unmatched.append((key, q["query"], text))
        if answerable_as_sent(q, r, provider):
            ans_n += 1
            ans_ok += r["outcome"] == "answered"
            req = [j for j, f in enumerate(q["facts"]) if f["required"] and (f.get("memory") is None or f["memory"] in r["sent"])]
            recall_n += len(req)
            recall_hit += len(set(req) & matched_facts)
            if q["conflict"] and len(req) >= 2:
                conflict_n += 1
                conflict_ok += set(req) <= matched_facts
        else:
            noans_n += 1
            noans_ok += r["outcome"] == "no_answer"
    lat = sorted(latencies)
    p50 = statistics.median(lat) if lat else None
    p95 = lat[min(len(lat) - 1, int(round(0.95 * (len(lat) - 1))))] if lat else None
    result = {
        "provider": provider, "set": set_name, "questions": len(records), "calls": len(latencies), "failed": failed,
        "claims": claims, "correct": correct, "wrong": wrong_n, "unmatched": unmatched_n,
        "answerable": ans_n, "answered": ans_ok, "noAnswerable": noans_n, "rightNoAnswer": noans_ok,
        "recall": (recall_hit, recall_n), "conflicts": (conflict_ok, conflict_n), "dropped": dict(dropped),
        "p50": p50, "p95": p95,
        "tokens": (round(statistics.mean(t[0] for t in tokens)) if tokens else None,
                   round(statistics.mean(t[1] for t in tokens)) if tokens else None),
    }
    result["gates"] = {
        "correct": claims > 0 and correct / claims >= GATES["correct"],
        "no_answer": noans_n > 0 and noans_ok / noans_n >= GATES["no_answer"],
        "answered": ans_n > 0 and ans_ok / ans_n >= GATES["answered"],
        "p95": p95 is not None and p95 <= GATES["p95_ms"],
    }
    return result, unmatched, wrongs


def main():
    labels_path = HERE / "labels.json"
    labels = json.loads(labels_path.read_text()) if labels_path.exists() else {}
    lines = ["# Spike G results", "",
             "| Provider | Set | Correct claims | Right \"no answer\" | Answered (answerable) | Recall | Conflicts both | "
             "Dropped | Failed | p50 / p95 | Tokens in / out | Gates |", "|" + "---|" * 12]
    review = []
    pooled = {}
    for d in sorted((HERE / "results").glob("*/*.jsonl")):
        provider, set_name = d.parent.name, d.stem
        suffix = "" if set_name == "main" else f"-{set_name}"
        questions = json.loads((HERE / f"fixtures/questions{suffix}.json").read_text())["questions"]
        records = [json.loads(line) for line in d.read_text().splitlines() if line.strip()]
        r, unmatched, wrongs = score(provider, set_name, records, questions, labels)
        pooled.setdefault(provider, []).append((set_name, records, questions))
        gates = "pass" if all(r["gates"].values()) else "fail: " + ", ".join(k for k, v in r["gates"].items() if not v)
        lat = f"{r['p50'] / 1000:.1f} / {r['p95'] / 1000:.1f} s" if r["p50"] is not None else "–"
        lines.append(f"| {provider} | {set_name} | {pct(r['correct'], r['claims'])} ({r['wrong']} wrong, {r['unmatched']} unmatched) "
                     f"| {pct(r['rightNoAnswer'], r['noAnswerable'])} | {pct(r['answered'], r['answerable'])} "
                     f"| {pct(*r['recall'])} | {pct(*r['conflicts'])} | {sum(r['dropped'].values())} {r['dropped'] or ''} "
                     f"| {r['failed']} | {lat} | {r['tokens'][0]} / {r['tokens'][1]} | {gates} |")
        for qid, text, bad in wrongs:
            review.append(f"- WRONG {provider}/{set_name}/{qid}: {text} ({', '.join(bad)})")
        for key, query, text in unmatched:
            review.append(f"- UNMATCHED `{key}` ({query}): {text}")
    # The gates are judged on both sets together (main and the held-out set).
    lines += ["", "## Both sets", "", lines[2], lines[3]]
    for provider, sets in sorted(pooled.items()):
        if len(sets) < 2:
            continue
        parts = [score(provider, name, recs, qs, labels)[0] for name, recs, qs in sets]
        recs = [x for _, rs, _ in sets for x in rs]
        lat = sorted(x["ms"] for x in recs if x.get("called") and x.get("ok"))
        p50 = statistics.median(lat)
        p95 = lat[min(len(lat) - 1, int(round(0.95 * (len(lat) - 1))))]
        tot = lambda k: sum(p[k] for p in parts)
        pair = lambda k: (sum(p[k][0] for p in parts), sum(p[k][1] for p in parts))
        dropped = sum(sum(p["dropped"].values()) for p in parts)
        g = {"correct": tot("correct") / tot("claims") >= GATES["correct"],
             "no_answer": tot("rightNoAnswer") / tot("noAnswerable") >= GATES["no_answer"],
             "answered": tot("answered") / tot("answerable") >= GATES["answered"], "p95": p95 <= GATES["p95_ms"]}
        gates = "pass" if all(g.values()) else "fail: " + ", ".join(k for k, v in g.items() if not v)
        lines.append(f"| {provider} | both | {pct(tot('correct'), tot('claims'))} ({tot('wrong')} wrong, {tot('unmatched')} unmatched) "
                     f"| {pct(tot('rightNoAnswer'), tot('noAnswerable'))} | {pct(tot('answered'), tot('answerable'))} "
                     f"| {pct(*pair('recall'))} | {pct(*pair('conflicts'))} | {dropped} | {tot('failed')} "
                     f"| {p50 / 1000:.1f} / {p95 / 1000:.1f} s | | {gates} |")
    if review:
        lines += ["", "## To review", ""] + review
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main())
