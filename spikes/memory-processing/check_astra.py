#!/usr/bin/env python3
"""Turns Astra's raw fixtures (fixtures/raw/) into fixtures/inputs-astra.json and clusters-astra.json, and reports
mechanical problems only: bad regexes, a piece whose keys don't match its own claim, unknown ids, secrets that
the scanner doesn't (or wrongly does) catch. Judgments stay Astra's; every fix is listed in FIXES and logged."""
import json
import re
from pathlib import Path

from validate import scan_secrets

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"
VARIANT = {"capture_typed": "first_person", "capture_dictated": "first_person", "capture_shared": "first_person",
           "seed_answer": "first_person", "agent": "about_user", "import_claude": "about_user",
           "import_markdown": "about_user", "import_chatgpt": "about_user"}
# Mechanical fixes, applied by id after review: {(item id, field path): replacement}. Logged in the output notes.
FIXES = {}


def compiles(rx, where, problems):
    try:
        re.compile(rx, re.I)
        return True
    except re.error as e:
        problems.append(f"{where}: bad regex {rx!r} ({e})")
        return False


def convert_inputs(raw, vault_ids, problems):
    out = []
    for i in raw["inputs"]:
        d = {"id": i["id"], "type": i["type"], "variant": VARIANT[i["type"]], "tags": i["tags"], "text": i["text"],
             "expected": [], "mustNot": []}
        if any(i["hint"].values()):
            d["hint"] = i["hint"]
        for k in ("declaredSensitivity", "expectRejected"):
            if i[k]:
                d[k] = i[k]
        if i["singleClaim"]:
            d["singleClaim"] = True
        if i["notes"]:
            d["notes"] = i["notes"]
        found = scan_secrets(i["text"])
        if i["expectRejected"] and not found:
            problems.append(f"{i['id']}: expectRejected {i['expectRejected']} but the scanner finds nothing")
        if found and not i["expectRejected"]:
            problems.append(f"{i['id']}: the scanner finds {found} but expectRejected is empty")
        for n, e in enumerate(i["expected"]):
            where = f"{i['id']}.expected[{n}]"
            keys = FIXES.get((i["id"], f"expected[{n}].keys"), e["keys"])
            if all(compiles(k, where, problems) for k in keys) and not all(re.search(k, e["claim"], re.I) for k in keys):
                problems.append(f"{where}: keys {keys} don't match its own claim {e['claim']!r}")
            for t in e["target"] + e["related"]:
                if t not in vault_ids:
                    problems.append(f"{where}: unknown vault id {t}")
            p = {"claim": e["claim"], "keys": keys, "link": {"decision": e["decision"] or ["create"], "target": e["target"]},
                 "related": list(dict.fromkeys(e["target"] + e["related"])), "intent": e["intent"] or ["assertion"]}
            if e["categories"]:
                p["categories"] = e["categories"]
            if e["minSensitivity"]:
                p["minSensitivity"] = e["minSensitivity"]
            if e["optional"]:
                p["optional"] = True
            if e["group"]:
                p["group"] = e["group"]
            d["expected"].append(p)
        for n, m in enumerate(i["mustNot"]):
            where = f"{i['id']}.mustNot[{n}]"
            if m["intent"]:
                d["mustNot"].append({"label": m["label"], "intent": m["intent"]})
            elif m["retract"]:
                d["mustNot"].append({"label": m["label"], "retract": m["retract"]})
            else:
                for rx in m["all"] + m["none"]:
                    compiles(rx, where, problems)
                d["mustNot"].append({"label": m["label"], "all": m["all"], "none": m["none"]})
        out.append(d)
    return out


def convert_action(a, cl_ids, where, problems):
    d = {"type": a["type"]}
    for k in ("target", "survivor", "reason"):
        if a[k]:
            d[k] = a[k]
    for k in ("sources", "ids", "keys", "notkeys"):
        if a[k]:
            d[k] = a[k]
    for k in ("target", "survivor"):
        for x in d.get(k, "").split("|") if d.get(k) else []:
            if x not in cl_ids:
                problems.append(f"{where}: unknown id {x}")
    for x in d.get("sources", []) + d.get("ids", []):
        if x not in cl_ids:
            problems.append(f"{where}: unknown id {x}")
    for rx in d.get("keys", []) + d.get("notkeys", []):
        compiles(rx, where, problems)
    return d


def convert_clusters(raw, problems):
    out, seen = [], set()
    for c in raw["clusters"]:
        ids = {m["id"] for m in c["memories"]}
        if ids & seen:
            problems.append(f"{c['id']}: memory ids reused {ids & seen}")
        seen |= ids
        mems = [{**m, "updatedAt": m["createdAt"]} for m in c["memories"]]
        d = {"id": c["id"], "tags": c["tags"], "memories": mems}
        for part in ("expected", "acceptable", "forbidden"):
            d[part] = [convert_action(a, ids, f"{c['id']}.{part}", problems) for a in c[part]]
        if c["notes"]:
            d["notes"] = c["notes"]
        out.append(d)
    return out


def main():
    vault_ids = {m["id"] for m in json.loads((FIX / "vault.json").read_text())["memories"]}
    problems = []
    note = ("Second-author fixtures, written blind by GPT-6-Astra (author_astra.py). Synthetic; judgments as Astra "
            "wrote them; mechanical fixes: " + (json.dumps({f"{k[0]} {k[1]}": v for k, v in FIXES.items()}) if FIXES else "none") + ".")
    raw_i = json.loads((FIX / "raw/astra-inputs.json").read_text())
    inputs = convert_inputs(raw_i, vault_ids, problems)
    (FIX / "inputs-astra.json").write_text(json.dumps({"format": "funes.fixture.extraction.v1", "note": note,
                                                       "now": "2026-10-23", "inputs": inputs}, ensure_ascii=False, indent=1) + "\n")
    raw_c_path = FIX / "raw/astra-clusters.json"
    if raw_c_path.exists():
        clusters = convert_clusters(json.loads(raw_c_path.read_text()), problems)
        (FIX / "clusters-astra.json").write_text(json.dumps({"format": "funes.fixture.tidyup.v1", "note": note,
                                                             "clusters": clusters}, ensure_ascii=False, indent=1) + "\n")
    n_req = sum(1 for i in inputs for e in i["expected"] if not e.get("optional"))
    print(f"{len(inputs)} inputs, {n_req} required pieces; problems: {len(problems)}")
    for p in problems:
        print(" -", p)


if __name__ == "__main__":
    main()
