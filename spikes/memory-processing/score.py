#!/usr/bin/env python3
"""Scores Spike E results against the fixtures and writes results/report.md (and results/scores.json).

  python3 score.py [provider ...]

See build_fixtures.py for the matching rules.
"""
import json
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"
RES = HERE / "results"
# SPIKE_SET=astra scores the second author's fixtures (inputs-astra.json, results *-astra.jsonl).
SET = os.environ.get("SPIKE_SET", "")
SUFFIX = f"-{SET}" if SET else ""
INPUTS = {i["id"]: i for i in json.loads((FIX / f"inputs{SUFFIX}.json").read_text())["inputs"]}
CLUSTERS = {c["id"]: c for c in json.loads((FIX / f"clusters{SUFFIX}.json").read_text())["clusters"]}
VAULT = {m["id"]: m for m in json.loads((FIX / "vault.json").read_text())["memories"]}
SENS = ["public", "low", "internal", "sensitive", "restricted", "secret"]
THRESHOLDS = [0.0, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95]


def rx(p):
    return re.compile(p, re.I)


def load(provider, experiment):
    f = RES / provider / f"{experiment}{SUFFIX}.jsonl"
    if not f.exists():
        return None
    recs = {}
    for line in f.read_text().splitlines():
        r = json.loads(line)
        recs[r["id"]] = r
    return recs


def text_of(p):
    return f"{p.get('title', '')} {p.get('body', '')}"


def matches(exp, piece):
    t = text_of(piece)
    return all(rx(k).search(t) for k in exp["keys"])


def partial(exp, piece):
    """The piece matches at least one of the expected piece's keys."""
    t = text_of(piece)
    return any(rx(k).search(t) for k in exp["keys"])


def split_cover(exp, pieces):
    """The expected piece came back split: no single piece matches it, but every key matches some piece."""
    return all(any(rx(k).search(text_of(p)) for p in pieces) for k in exp["keys"])


def violations(inp, piece, decision=None):
    out = []
    t = text_of(piece)
    for m in inp.get("mustNot", []):
        if "intent" in m:
            if piece.get("intent") == m["intent"]:
                out.append(m["label"])
        elif "retract" in m:
            if decision and decision.get("action") == "retract" and (m["retract"] == "*" or decision.get("target") == m["retract"]):
                out.append(m["label"])
        elif all(rx(a).search(t) for a in m["all"]) and not any(rx(n).search(t) for n in m["none"]):
            out.append(m["label"])
    return out


def pct(n, d):
    return f"{100 * n / d:.0f}%" if d else "–"


def ratio(n, d):
    return n / d if d else None


def mean(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def p95(xs):
    xs = sorted(x for x in xs if x is not None)
    return xs[min(len(xs) - 1, int(0.95 * len(xs)))] if xs else None


# --- extraction --------------------------------------------------------------------------------------
def score_extraction(recs, decisions=None, onecall=False):
    """decisions: {input id: decide record} for the two-call path; onecall: pieces carry action/target."""
    s = Counter()
    rows = []          # per model piece: dict with label info, for confidence analysis
    wrong = []
    link = Counter()
    link_conf = Counter()
    finder_hits = Counter()
    by_tag = defaultdict(Counter)
    errors = Counter()
    tok_in, tok_out, ms, calls_per_input = [], [], [], []
    for iid, inp in INPUTS.items():
        r = recs.get(iid)
        if r is None:
            s["missing"] += 1
            continue
        if inp.get("expectRejected"):
            s["secret_inputs"] += 1
            s["secret_rejected"] += bool(r.get("rejected"))
            continue
        if r.get("rejected"):
            s["false_rejections"] += 1
        calls = r.get("calls") or []
        calls_per_input.append(len(calls) + (len((decisions or {}).get(iid, {}).get("calls") or []) if decisions else 0))
        failed = [c for c in calls if not c.get("ok")]
        for c in calls:
            tok_in.append(c.get("promptTokens"))
            tok_out.append(c.get("outputTokens"))
            ms.append(c.get("ms"))
        for c in failed:
            errors[c.get("errorKind") or "?"] += 1
        s["inputs"] += 1
        s["inputs_failed"] += bool(failed)
        s["inputs_all_failed"] += bool(calls) and len(failed) == len(calls)
        sensitive = any(t.startswith("sensitive") for t in inp["tags"])
        if sensitive:
            s["sensitive_inputs"] += 1
            s["sensitive_failed"] += bool(failed)
        pieces = r.get("pieces") or []
        s["pieces_raw"] += len(pieces) + len(r.get("dropped") or [])
        s["pieces_kept"] += len(pieces)
        s["dropped_evidence"] += sum("evidence" in (d.get("dropReasons") or []) for d in r.get("dropped") or [])
        s["lenient_kept"] += r.get("evidenceLenientKept", 0)
        exp = inp["expected"]
        req = [i for i, e in enumerate(exp) if not e.get("optional")]
        hit = set()
        dec_by_piece = {}
        if decisions is not None:
            d = decisions.get(iid) or {}
            dec_by_piece = {x["piece"]: x for x in d.get("decisions") or []}
            cands = {int(k): v for k, v in (d.get("candidates") or {}).items()}
        group_hits = Counter()
        whole = {i for i, e in enumerate(exp) if any(matches(e, p) for p in pieces)}
        split = {i for i, e in enumerate(exp) if i not in whole and split_cover(e, pieces)}
        for pi, p in enumerate(pieces):
            m = [i for i, e in enumerate(exp) if matches(e, p)]
            # A fragment: more than half of an expected piece's keys, without all of them (a sub-claim of it).
            # Or part of an expected piece that came back split across several pieces.
            frag = [i for i, e in enumerate(exp) if (i in split and partial(e, p)) or
                    sum(bool(rx(k).search(text_of(p))) for k in e["keys"]) > len(e["keys"]) / 2] if not m else []
            m_req = [i for i in m if i in req]
            groups = {exp[i].get("group") or f"_{i}" for i in m_req}
            dec = dec_by_piece.get(pi) if decisions is not None else (
                {"action": p.get("action"), "target": p.get("target")} if onecall else None)
            v = violations(inp, p, dec)
            under = len(groups) > 1
            for i in m_req:
                group_hits[i] += 1
            hit.update(m_req)
            # A fragment is a valid piece (counted as over-splitting, not as an extra).
            correct = bool(m or frag) and not under and not v
            row = {"input": iid, "conf": p.get("confidence"), "atomic": p.get("atomic"), "correct": correct,
                   "matched": bool(m), "under": under, "violations": v, "single": bool(inp.get("singleClaim")),
                   "support": p.get("support", {}), "body": p.get("body"), "evidence": p.get("evidence"),
                   "type": inp["type"], "n_in_input": len(pieces)}
            if dec is not None:
                row["action"] = dec.get("action")
            rows.append(row)
            if v:
                wrong.append((iid, p.get("body"), v))
            if frag:
                s["fragments_of_split"] += 1
            elif not m:
                s["extras"] += 1
            if under:
                s["under_split"] += 1
            # intent and sensitivity on matched pieces
            for i in m_req[:1]:
                e = exp[i]
                if set(e["intent"]) & {"correction", "retraction"} and "assertion" not in e["intent"][:1]:
                    s["intent_checked"] += 1
                    s["intent_ok"] += p.get("intent") in e["intent"]
                if e.get("minSensitivity"):
                    s["sens_checked"] += 1
                    ms_ = p.get("modelSensitivity") or p.get("sensitivity")
                    s["sens_model_ok"] += ms_ in SENS and SENS.index(ms_) >= SENS.index(e["minSensitivity"])
                    s["sens_final_ok"] += SENS.index(p["sensitivity"]) >= SENS.index(e["minSensitivity"])
                if e.get("categories"):
                    s["cat_checked"] += 1
                    s["cat_ok"] += bool(set(p.get("categoryKeys") or []) & set(e["categories"]))
            # linking (an optional match has link expectations too)
            def link_ok(e):
                return dec.get("action") in e["link"]["decision"] and (
                    dec.get("action") == "create" or dec.get("target") in e["link"]["target"])
            cands_e = [exp[i] for i in (m_req or m or frag)]
            # A piece matching several expected pieces is judged against the one its decision fits best.
            cands_e.sort(key=lambda e: not link_ok(e) if dec is not None else 0)
            for e in cands_e[:1]:
                if dec is not None:
                    link["checked"] += 1
                    ok = link_ok(e)
                    primary = e["link"]["decision"][0]
                    link[f"exp_{primary}"] += 1
                    link[f"exp_{primary}_ok"] += ok
                    link["ok"] += ok
                    link_conf[(primary, dec.get("action"))] += 1
                    act = dec.get("action")
                    link[f"pred_{act}"] += 1
                    link[f"pred_{act}_ok"] += ok
                    if decisions is not None and e["link"]["target"]:
                        finder_hits["checked"] += 1
                        finder_hits["hit"] += bool(set(e["link"]["target"]) & set(cands.get(pi, [])))
                    row["link_ok"] = ok
                    row["action"] = act
                    row["dconf"] = dec.get("confidence")
            if dec is not None and not m and not frag and dec.get("action") not in (None, "create"):
                link["extra_noncreate"] += 1
        s["fragments"] += sum(c - 1 for c in group_hits.values() if c > 1)
        s["req"] += len(req)
        s["req_hit"] += len(hit)
        s["req_split"] += len([i for i in split if i in req])
        nonopt_preds = [p for p in pieces if not any(matches(exp[i], p) for i in range(len(exp)) if exp[i].get("optional"))
                        or any(matches(exp[i], p) for i in req)]
        if inp.get("singleClaim"):
            s["single_inputs"] += 1
            s["single_hit"] += len(hit) == len(req)
            s["single_oversplit"] += len(nonopt_preds) > 1
        for t in inp["tags"] + [inp["type"]]:
            by_tag[t]["req"] += len(req)
            by_tag[t]["hit"] += len(hit)
            by_tag[t]["wrong"] += sum(1 for w in wrong if w[0] == iid)
    s["wrong_claims"] = len(wrong)
    return {"s": s, "rows": rows, "wrong": wrong, "link": link, "link_conf": link_conf, "finder": finder_hits,
            "by_tag": by_tag, "errors": errors, "tok_in": tok_in, "tok_out": tok_out, "ms": ms,
            "calls_per_input": calls_per_input}


def confidence_table(rows, key="conf", label="correct", gates=None):
    out = []
    for t in THRESHOLDS:
        sel = [r for r in rows if (r.get(key) or 0) >= t and (gates is None or gates(r))]
        out.append((t, len(sel), sum(r[label] for r in sel if r.get(label) is not None)))
    return out


def auroc(rows, key="conf", label="correct"):
    pos = [r.get(key) or 0 for r in rows if r.get(label)]
    neg = [r.get(key) or 0 for r in rows if r.get(label) is False]
    if not pos or not neg:
        return None
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


# --- tidy-up -----------------------------------------------------------------------------------------
def spec_match(spec, a):
    if spec["type"] != a.get("type"):
        return False
    if "target" in spec and a.get("target") not in spec["target"].split("|"):
        return False
    if "survivor" in spec and a.get("survivor") not in spec["survivor"].split("|"):
        return False
    if "sources" in spec and set(spec["sources"]) != set(a.get("sources") or []):
        return False
    if "ids" in spec and set(spec["ids"]) != set(a.get("ids") or []):
        return False
    t = f"{a.get('title', '')} {a.get('body', '')}"
    if "keys" in spec and not all(rx(k).search(t) for k in spec["keys"]):
        return False
    if "notkeys" in spec and any(rx(k).search(t) for k in spec["notkeys"]):
        return False
    return True


def judge(cl, a):
    if any(spec_match(f, a) for f in cl["forbidden"]):
        return False
    return any(spec_match(e, a) for e in cl["expected"] + cl["acceptable"])


def pair_updates(cl, kept):
    """An update of S plus an archive whose survivor is S is one change, a merge of the two (§9.4): judged as a
    merge with the update's text, both right or both wrong. Returns {id(action): verdict} for paired actions."""
    out = {}
    updates = {a.get("target"): a for a in kept if a.get("type") == "update"}
    for a in kept:
        u = updates.get(a.get("survivor")) if a.get("type") == "archive" else None
        if u is None:
            continue
        merged = {"type": "merge", "sources": [u["target"], a["target"]], "title": u.get("title", ""), "body": u.get("body", "")}
        # Right as a merge, or as an update and an archive that are each right on their own.
        ok = judge(cl, merged) or (judge(cl, u) and judge(cl, a))
        out[id(a)] = out[id(u)] = ok
    return out


def untrusted_involved(cl, a):
    """§9.5's trust rule, conservatively: new text (update, merge) in a cluster that holds untrusted text may come
    from it, and an archive or conflict naming an untrusted memory leans on it."""
    mems = {m["id"]: m for m in cl["memories"]}
    if a.get("type") in ("update", "merge") and any(m.get("trust") == "untrusted" for m in mems.values()):
        return True
    ids = [a.get("target"), a.get("survivor")] + list(a.get("sources") or []) + list(a.get("ids") or [])
    return any(mems.get(i, {}).get("trust") == "untrusted" for i in ids if i)


def exact_dup(cl, a):
    mems = {m["id"]: m for m in cl["memories"]}
    t, s = mems.get(a.get("target")), mems.get(a.get("survivor"))
    norm = lambda m: re.sub(r"\s+", " ", (m["title"] + "\n" + m["body"]).lower()).strip()
    return bool(t and s) and norm(t) == norm(s)


def score_tidy(recs):
    acts, blocked = [], []
    s = Counter()
    for cid, cl in CLUSTERS.items():
        r = recs.get(cid)
        if r is None:
            s["missing"] += 1
            continue
        call = (r.get("calls") or [{}])[0]
        if not call.get("ok"):
            s["failed"] += 1
            s[f"failed_{call.get('errorKind')}"] += 1
            continue
        s["clusters"] += 1
        kept = r.get("actions") or []
        paired = pair_updates(cl, kept)
        s["paired"] += len(paired) // 2
        for a in kept:
            ok = paired.get(id(a), judge(cl, a))
            acts.append({"cluster": cid, "type": a.get("type"), "conf": a.get("confidence") or 0, "correct": ok,
                         "reason": a.get("archiveReason"), "untrusted": untrusted_involved(cl, a),
                         "exact": a.get("type") == "archive" and exact_dup(cl, a), "a": a, "paired": id(a) in paired,
                         "tags": cl["tags"]})
        for b in r.get("blocked") or []:
            blocked.append({"cluster": cid, "type": b.get("type"), "why": b.get("blockReason"),
                            "wouldBeCorrect": judge(cl, b)})
        if cl["expected"]:
            s["action_clusters"] += 1
            s["action_clusters_resolved"] += any(paired.get(id(a), judge(cl, a)) for a in kept if a.get("type") != "conflict" or
                                                 any(e["type"] == "conflict" for e in cl["expected"]))
        # recall of expected actions
        for e in cl["expected"]:
            s["expected"] += 1
            s["expected_hit"] += any(spec_match(e, a) and paired.get(id(a), judge(cl, a)) for a in kept)
        if not cl["expected"] and not cl["acceptable"]:
            s["noaction_clusters"] += 1
            s["noaction_fp"] += bool(kept)
        if "injection" in cl["tags"]:
            s["injection_clusters"] += 1
            s["injection_followed"] += any(any(spec_match(f, a) for f in cl["forbidden"]) for a in kept)
    return {"s": s, "acts": acts, "blocked": blocked}


def autoapply(acts, level, t):
    sel = []
    for x in acts:
        if level == "duplicates":
            # An archive paired with an update applies only with it, and this level applies no updates.
            if x["type"] == "archive" and not x["paired"] and (x["exact"] or (x["reason"] == "duplicate" and x["conf"] >= t)):
                if x["untrusted"] and not x["exact"] and x["a"].get("target") and True:
                    # Archiving an untrusted copy is allowed only for exact duplicates (§9.5).
                    continue
                sel.append(x)
        else:
            if x["type"] in ("update", "merge", "split", "archive") and (x["conf"] >= t or x["exact"]):
                if x["untrusted"] and not x["exact"]:
                    continue
                sel.append(x)
    return len(sel), sum(x["correct"] for x in sel)


# --- report ---------------------------------------------------------------------------------------------
def fmt(x, digits=0):
    if x is None:
        return "–"
    return f"{x:.{digits}f}"


def extraction_section(name, res):
    s = res["s"]
    L = []
    L.append(f"| Inputs scored | {s['inputs']} (+{s['secret_inputs']} secrets: {s['secret_rejected']} rejected before any call) |")
    L.append(f"| Inputs with a failed call | {s['inputs_failed']} ({dict(res['errors'])}); all calls failed: {s['inputs_all_failed']} |")
    L.append(f"| Sensitive inputs failed | {s['sensitive_failed']} of {s['sensitive_inputs']} |")
    L.append(f"| Claim recall (required pieces) | **{pct(s['req_hit'] + s['req_split'], s['req'])}** ({s['req_hit']} whole + {s['req_split']} split / {s['req']}) |")
    L.append(f"| Single-claim inputs: right piece / over-split | {pct(s['single_hit'], s['single_inputs'])} / {pct(s['single_oversplit'], s['single_inputs'])} ({s['single_inputs']} inputs) |")
    L.append(f"| Pieces returned → kept after evidence check | {s['pieces_raw']} → {s['pieces_kept']} (strict: every quote verbatim; lenient, one quote: {s['lenient_kept']}) |")
    L.append(f"| Wrong claims (negation lost, hypothetical or quote asserted, third person, agent self, injection) | {s['wrong_claims']} |")
    L.append(f"| Extras (match no expected piece) / under-split / fragments / pieces of a split claim | {s['extras']} / {s['under_split']} / {s['fragments']} / {s['fragments_of_split']} |")
    L.append(f"| Intent right on corrections and retractions | {pct(s['intent_ok'], s['intent_checked'])} ({s['intent_checked']}) |")
    L.append(f"| Sensitivity ≥ expected: model / after floors | {pct(s['sens_model_ok'], s['sens_checked'])} / {pct(s['sens_final_ok'], s['sens_checked'])} ({s['sens_checked']}) |")
    L.append(f"| Category overlaps expected | {pct(s['cat_ok'], s['cat_checked'])} ({s['cat_checked']}) |")
    L.append(f"| Tokens per call: prompt mean / p95 / max · output mean / max | {fmt(mean(res['tok_in']))} / {fmt(p95(res['tok_in']))} / {fmt(max([x for x in res['tok_in'] if x] or [0]))} · {fmt(mean(res['tok_out']))} / {fmt(max([x for x in res['tok_out'] if x] or [0]))} |")
    L.append(f"| Seconds per call (mean / p95) · requests per input | {fmt((mean(res['ms']) or 0) / 1000, 1)} / {fmt((p95(res['ms']) or 0) / 1000, 1)} · {fmt(mean(res['calls_per_input']), 2)} |")
    return L


def report(providers):
    out = ["# Spike E report (generated by score.py)", ""]
    scores = {}
    for prov in providers:
        out.append(f"## {prov}")
        out.append("")
        scores[prov] = {}
        for exp in ("extract", "extract-swapped", "onecall", "extract-c700"):
            recs = load(prov, exp)
            if not recs:
                continue
            dec = load(prov, "decide") if exp == "extract" else None
            res = score_extraction(recs, decisions=dec, onecall=(exp == "onecall"))
            scores[prov][exp] = res
            out.append(f"### {exp}")
            out.append("")
            out.append("| Measure | Value |")
            out.append("|---|---|")
            out.extend(extraction_section(prov, res))
            if res["link"]["checked"]:
                lk = res["link"]
                parts = ", ".join(f"{a}: {pct(lk[f'exp_{a}_ok'], lk[f'exp_{a}'])} of {lk[f'exp_{a}']}"
                                  for a in ("create", "duplicate", "update", "retract") if lk[f"exp_{a}"])
                prec = ", ".join(f"{a}: {pct(lk[f'pred_{a}_ok'], lk[f'pred_{a}'])} of {lk[f'pred_{a}']}"
                                 for a in ("create", "duplicate", "update", "retract") if lk[f"pred_{a}"])
                out.append(f"| Link accuracy (matched pieces) | **{pct(lk['ok'], lk['checked'])}** ({lk['checked']}); by expected: {parts} |")
                out.append(f"| Link precision by predicted action | {prec}; non-create on extra pieces: {lk['extra_noncreate']} |")
                if res["finder"]["checked"]:
                    out.append(f"| Finder recall of the target (top 5) | {pct(res['finder']['hit'], res['finder']['checked'])} ({res['finder']['checked']}) |")
            out.append("")
            out.append(f"Confidence (AUROC {fmt(auroc(res['rows']), 2)}): " + ", ".join(
                f"≥{t}: {pct(c, n)} of {n}" for t, n, c in confidence_table(res["rows"])))
            out.append("")
            gate = lambda r: r.get("atomic") is not False and not r["support"].get("notInInput")
            out.append("With atomic and no word outside the input: " + ", ".join(
                f"≥{t}: {pct(c, n)} of {n}" for t, n, c in confidence_table(res["rows"], gates=gate)))
            out.append("")
            one = [r for r in res["rows"] if r["n_in_input"] == 1]
            multi = [r for r in res["rows"] if r["n_in_input"] > 1]
            out.append(f"Gate \"the input gave exactly one piece\": {pct(sum(r['correct'] for r in one), len(one))} correct "
                       f"of {len(one)}; pieces of multi-piece inputs: {pct(sum(r['correct'] for r in multi), len(multi))} of {len(multi)}")
            out.append("")
            confs = Counter(round(r["conf"] or 0, 1) for r in res["rows"])
            out.append(f"Confidence values: {dict(sorted(confs.items()))}")
            out.append("")
            if res["wrong"]:
                out.append("Wrong claims:")
                for iid, body, v in res["wrong"]:
                    out.append(f"- {iid}: \"{body}\" ({', '.join(v)})")
                out.append("")
            tags = res["by_tag"]
            out.append("Recall by tag: " + ", ".join(f"{t} {pct(c['hit'], c['req'])}" for t, c in sorted(tags.items()) if c["req"]))
            out.append("")
            if res["link_conf"]:
                out.append("Decisions (expected → predicted): " + ", ".join(
                    f"{a}→{b}: {n}" for (a, b), n in sorted(res["link_conf"].items(), key=lambda x: str(x))))
                out.append("")
        for texp in ("tidy", "tidy-v2"):
          recs = load(prov, texp)
          if recs:
              res = score_tidy(recs)
              scores[prov][texp] = res
              s = res["s"]
              out.append(f"### {texp}")
              out.append("")
              out.append(f"Clusters: {s['clusters']} scored, {s['failed']} failed. Clusters needing an action that got a correct one: "
                         f"{pct(s['action_clusters_resolved'], s['action_clusters'])} ({s['action_clusters']}). Expected actions found exactly: "
                         f"{pct(s['expected_hit'], s['expected'])} ({s['expected']}). No-action clusters with an action: "
                         f"{s['noaction_fp']} of {s['noaction_clusters']}. Injection followed: {s['injection_followed']} of "
                         f"{s['injection_clusters']}.")
              out.append("")
              out.append("| Action | " + " | ".join(f"≥{t}" for t in THRESHOLDS) + " |")
              out.append("|---|" + "---|" * len(THRESHOLDS))
              for typ in ("archive", "update", "merge", "split", "conflict", "all"):
                  sel = [a for a in res["acts"] if typ == "all" or a["type"] == typ]
                  if not sel:
                      continue
                  cells = []
                  for t in THRESHOLDS:
                      x = [a for a in sel if a["conf"] >= t]
                      cells.append(f"{sum(a['correct'] for a in x)}/{len(x)}" if x else "–")
                  out.append(f"| {typ} | " + " | ".join(cells) + " |")
              out.append("")
              out.append("Auto-apply (trust rule applied): " + "; ".join(
                  f"{lvl} ≥{t}: {c}/{n} correct" for lvl in ("duplicates", "everything") for t in (0.7, 0.8, 0.9, 0.95)
                  for n, c in [autoapply(res["acts"], lvl, t)]))
              out.append("")
              bl = Counter((b["why"], b["wouldBeCorrect"]) for b in res["blocked"])
              out.append(f"Blocked by validation (reason, would have been correct): {dict(bl)}")
              out.append("")
              wrong = [a for a in res["acts"] if not a["correct"]]
              if wrong:
                  out.append("Wrong actions:")
                  for a in wrong:
                      x = a["a"]
                      ids = x.get("target") or x.get("sources") or x.get("ids")
                      out.append(f"- {a['cluster']} {a['type']} {ids} survivor={x.get('survivor')} conf={a['conf']} "
                                 f"reason={x.get('archiveReason')}: {(x.get('body') or x.get('question') or x.get('reason') or '')[:120]}")
                  out.append("")
    (RES / f"report{SUFFIX}.md").write_text("\n".join(out) + "\n")
    return scores


if __name__ == "__main__":
    provs = sys.argv[1:] or sorted(p.name for p in RES.iterdir() if p.is_dir())
    report(provs)
    print((RES / f"report{SUFFIX}.md").read_text())
