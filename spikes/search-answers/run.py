#!/usr/bin/env python3
"""Spike G runner: for each question, the prompt of memory processing §10.3 over the search results in
fixtures/search.json (answer-input's output), one call to the provider, §10.4's validation. Results go to
results/<provider>/<set>.jsonl, one line per question; a rerun skips questions already there.

    python3 run.py <provider> [--set main|astra] [--only q01,q02] [--dry]

Providers: claude-haiku, codex-terra, codex-luna, apple. `--dry` prints the first prompt and makes no call.
"""
import argparse
import json
import sys
from pathlib import Path

from answer import build, validate
from providers import PROVIDERS

HERE = Path(__file__).resolve().parent


def load(set_name):
    suffix = "" if set_name == "main" else f"-{set_name}"
    questions = json.loads((HERE / f"fixtures/questions{suffix}.json").read_text())["questions"]
    search = {e["id"]: e for e in json.loads((HERE / f"fixtures/search{suffix}.json").read_text())}
    return questions, search


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("provider", choices=sorted(PROVIDERS))
    ap.add_argument("--set", default="main")
    ap.add_argument("--only", default="")
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    questions, search = load(a.set)
    if a.only:
        wanted = set(a.only.split(","))
        questions = [q for q in questions if q["id"] in wanted]
    kind = "apple" if a.provider == "apple" else "cloud"
    if a.dry:
        b = build(questions[0], search[questions[0]["id"]], kind)
        print(b["instructions"], "\n---\n", b["prompt"], f"\n--- {len(b['prompt'])} characters, {len(b['sent'])} memories sent, "
              f"{b['withheld']} withheld")
        return
    out_dir = HERE / "results" / a.provider
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{a.set}.jsonl"
    done = set()
    if path.exists():
        done = {json.loads(line)["id"] for line in path.read_text().splitlines() if line.strip()}
    provider = PROVIDERS[a.provider]()
    with path.open("a") as f:
        for q in questions:
            if q["id"] in done:
                continue
            b = build(q, search[q["id"]], kind)
            record = {"id": q["id"], "provider": a.provider, "read": len(b["sent"]), "withheld": b["withheld"],
                      "droppedForWindow": b["droppedForWindow"], "totalHits": b["totalHits"],
                      "sent": [m["fixtureId"] for m in b["sent"]], "promptChars": len(b["prompt"])}
            if not b["sent"]:
                # §10.3: nothing left to send; no call, no cap.
                record.update(called=False, ok=True, ms=0, outcome="no_answer", claims=[], dropped=[])
            else:
                r = provider.generate(b["instructions"], b["prompt"], b["schema"])
                record.update(called=True, **{k: r.get(k) for k in ("ok", "errorKind", "error", "ms", "promptTokens",
                                                                    "outputTokens", "reasoningTokens", "modelId")})
                if r.get("ok"):
                    record["raw"] = r["content"]
                    record.update(validate(r["content"], b["sent"]))
                else:
                    record.update(outcome="failed", claims=[], dropped=[])
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
            f.flush()
            print(f"{q['id']} {record['outcome']} {len(record['claims'])} claims, {len(record['dropped'])} dropped, "
                  f"{record['ms']} ms", file=sys.stderr)


if __name__ == "__main__":
    main()
