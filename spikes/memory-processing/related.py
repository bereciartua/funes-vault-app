#!/usr/bin/env python3
"""Question 8: the "related" threshold for bge-small (memory processing §5.5).

Every required expected piece with labelled related memories is embedded as a memory (its claim as title and
body, its first expected category) and compared with the 200 vault memories. Positives: the labelled targets
and related memories; everything else is noise. Prints recall and noise per threshold, and the finder's
top-5 recall (cosine or keyword hit, hybrid-ranked) per threshold. Optionally also for a provider's real
extracted pieces (matched to expected ones): python3 related.py codex
"""
import json
import sys
from pathlib import Path

from finder import Embeddings, Finder
from score import INPUTS, load, matches

HERE = Path(__file__).resolve().parent


def cases_expected():
    out = []
    for inp in INPUTS.values():
        for e in inp["expected"]:
            if e.get("optional") or not e["related"]:
                continue
            out.append((e["claim"], e.get("categories", [])[:1], set(e["related"]), set(e["link"]["target"])))
    return out


def cases_provider(provider):
    recs = load(provider, "extract") or {}
    out = []
    for iid, r in recs.items():
        inp = INPUTS[iid]
        for p in r.get("pieces") or []:
            for e in inp["expected"]:
                if not e.get("optional") and e["related"] and matches(e, p):
                    out.append(((p.get("title", ""), p["body"]), p.get("categoryKeys", []), set(e["related"]),
                                set(e["link"]["target"])))
                    break
    return out


def main():
    vault = json.loads((HERE / "fixtures/vault.json").read_text())["memories"]
    f = Finder(vault, Embeddings())
    source = sys.argv[1] if len(sys.argv) > 1 else None
    cases = cases_provider(source) if source else cases_expected()
    rows = []
    for text, cats, related, targets in cases:
        title, body = text if isinstance(text, tuple) else (text, text)
        cos = f.cosines(title, "fact", cats, body)
        kw = f.keyword_scores(title + " " + body)
        rows.append((cos, kw, related, targets, title, body, cats))
    pos_cos = sorted(c[r] for c, _, rel, _, *_ in rows for r in rel)
    neg_max = sorted(max(v for k, v in c.items() if k not in rel) for c, _, rel, _, *_ in rows)
    print(f"{len(rows)} pieces ({source or 'expected claims'}), {len(pos_cos)} related pairs")
    q = lambda xs, p: xs[int(p * (len(xs) - 1))]
    print(f"related-pair cosine: min {pos_cos[0]:.3f}, p10 {q(pos_cos, .1):.3f}, median {q(pos_cos, .5):.3f}")
    print(f"best unrelated cosine per piece: median {q(neg_max, .5):.3f}, p90 {q(neg_max, .9):.3f}, max {neg_max[-1]:.3f}")
    print()
    print("| Threshold | Related pairs ≥ t | Unrelated ≥ t per piece (mean) | Finder top-5: related found | Finder: target found |")
    print("|---|---|---|---|---|")
    for t in (0.60, 0.65, 0.70, 0.72, 0.75, 0.78, 0.80, 0.85):
        hit = sum(1 for c, _, rel, _, *_ in rows for r in rel if c[r] >= t)
        noise = sum(sum(1 for k, v in c.items() if k not in rel and v >= t) for c, _, rel, _, *_ in rows) / len(rows)
        f_rel = f_tgt = n_tgt = 0
        for c, kw, rel, tgt, title, body, cats in rows:
            ids, _, _ = f.find(title, "fact", cats, body, threshold=t)
            f_rel += len(rel & set(ids))
            if tgt:
                n_tgt += 1
                f_tgt += bool(tgt & set(ids))
        print(f"| {t:.2f} | {100 * hit / len(pos_cos):.0f}% | {noise:.1f} | {100 * f_rel / len(pos_cos):.0f}% | "
              f"{100 * f_tgt / n_tgt:.0f}% of {n_tgt} |")


if __name__ == "__main__":
    main()
