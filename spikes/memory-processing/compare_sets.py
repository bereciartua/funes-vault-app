#!/usr/bin/env python3
"""Author-bias check: each cloud model on the first set (written by Claude Opus 5.5) and on Astra's (GPT-6-Astra).
Prints extraction, linking, tidy-up and auto-apply numbers side by side. Run from this directory."""
import importlib
import os
import sys

MODELS = ["codex", "codex-terra", "claude-haiku", "claude-opus"]


def numbers(set_name):
    os.environ["SPIKE_SET"] = set_name
    for m in ("score",):
        sys.modules.pop(m, None)
    score = importlib.import_module("score")
    out = {}
    for prov in MODELS:
        ext, dec, tidy = score.load(prov, "extract"), score.load(prov, "decide"), score.load(prov, "tidy-v2")
        if not ext:
            continue
        res = score.score_extraction(ext, decisions=dec)
        s, lk = res["s"], res["link"]
        typed = {"capture_typed", "capture_dictated", "seed_answer"}
        rows = [r for r in res["rows"] if score.INPUTS[r["input"]]["type"] != "agent"]
        for r in rows:
            r["ok"] = r["correct"] and (r["link_ok"] if "link_ok" in r else r.get("action") == "create")
        dups = [r for r in rows if r.get("action") == "duplicate"]
        applied = [r for r in rows if r.get("atomic") is not False and not r["support"].get("notInInput")
                   and not (r.get("action") in ("update", "retract") and r["type"] not in typed)]
        t = score.score_tidy(tidy) if tidy else None
        acts = t["acts"] if t else []
        out[prov] = {
            "recall": (s["req_hit"] + s["req_split"], s["req"]), "whole": s["req_hit"], "split": s["req_split"],
            "single_over": (s["single_oversplit"], s["single_inputs"]), "wrong": s["wrong_claims"],
            "link": (lk["ok"], lk["checked"]),
            "new_dup": (sum(r["ok"] for r in dups), len(dups)), "new_all": (sum(r["ok"] for r in applied), len(applied)),
            "tidy_right": (sum(a["correct"] for a in acts), len(acts)),
            "tidy_resolved": (t["s"]["action_clusters_resolved"], t["s"]["action_clusters"]) if t else None,
            "tidy_noaction_fp": (t["s"]["noaction_fp"], t["s"]["noaction_clusters"]) if t else None,
            "tidy_inj": (t["s"]["injection_followed"], t["s"]["injection_clusters"]) if t else None,
            "tidy_dup": score.autoapply(acts, "duplicates", 0)[::-1], "tidy_all": score.autoapply(acts, "everything", 0)[::-1],
        }
    return out


def f(p):
    if not p:
        return "–"
    n, d = p
    return f"{n}/{d} ({100 * n / d:.0f}%)" if d else f"{n}/{d}"


if __name__ == "__main__":
    a, b = numbers(""), numbers("astra")
    keys = ["recall", "single_over", "wrong", "link", "new_dup", "new_all", "tidy_right", "tidy_resolved",
            "tidy_noaction_fp", "tidy_inj", "tidy_dup", "tidy_all"]
    for prov in MODELS:
        print(f"== {prov}")
        for k in keys:
            va, vb = a.get(prov, {}).get(k), b.get(prov, {}).get(k)
            fa = va if isinstance(va, int) else f(va)
            fb = vb if isinstance(vb, int) else f(vb)
            print(f"  {k:18} first: {fa!s:22} astra: {fb}")
        if prov in b:
            print(f"  astra recall: {b[prov]['whole']} whole + {b[prov]['split']} split")
