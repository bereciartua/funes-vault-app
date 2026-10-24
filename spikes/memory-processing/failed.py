#!/usr/bin/env python3
"""Prints the ids (comma-separated) whose calls failed with an error kind: failed.py <provider> <experiment> <kind>"""
import json
import sys
from pathlib import Path

f = Path(__file__).resolve().parent / "results" / sys.argv[1] / f"{sys.argv[2]}.jsonl"
ids = [r["id"] for r in map(json.loads, f.read_text().splitlines())
       if any(c.get("errorKind") == sys.argv[3] for c in r.get("calls") or [])] if f.exists() else []
print(",".join(ids))
