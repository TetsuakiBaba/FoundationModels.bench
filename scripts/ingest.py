#!/usr/bin/env python3
"""Merge a benchmark entry posted in a GitHub Issue into benchmarks.json.

usage: ingest.py <issue-body-file> [benchmarks.json]
Reads the first ```json fenced block from the issue body. Accepts a single entry object, an array of
entries, or a whole benchmarks file ({"entries": [...]}). Entries with the same "key" are replaced.
Prints a one-line summary per entry (used for the PR body). Exit 2 = nothing to ingest, 1 = invalid, 3 = already up to date.
"""
import json, re, sys
from datetime import datetime, timezone

REQUIRED_ENV = ["machine", "chip", "osVersion"]

def extract_json(body: str):
    m = re.search(r"```json\s*\n(.*?)\n\s*```", body, re.S)
    if not m:
        return None
    return m.group(1).strip()

def normalize(obj):
    if isinstance(obj, dict) and "entries" in obj and isinstance(obj["entries"], list):
        return obj["entries"]
    if isinstance(obj, dict):
        return [obj]
    if isinstance(obj, list):
        return obj
    raise ValueError("payload must be an entry object, an array of entries, or {\"entries\": [...]}")

def validate(e):
    if not isinstance(e, dict):
        raise ValueError("entry is not an object")
    env, bench, key = e.get("environment"), e.get("benchmarks"), e.get("key")
    if not isinstance(key, str) or not key.strip():
        raise ValueError("entry.key missing")
    if not isinstance(env, dict) or any(k not in env for k in REQUIRED_ENV):
        raise ValueError(f"entry.environment must contain {REQUIRED_ENV}")
    if not isinstance(bench, dict) or not bench:
        raise ValueError("entry.benchmarks is empty")
    for kind, b in bench.items():
        if not isinstance(b, dict) or "result" not in b:
            raise ValueError(f"benchmarks.{kind} has no result")
    # Only keep the fields fmbench writes; drop anything else a hand-edited issue might add.
    return {k: e[k] for k in ("key", "createdAt", "updatedAt", "environment", "benchmarks") if k in e}

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    body = open(sys.argv[1], encoding="utf-8").read()
    path = sys.argv[2] if len(sys.argv) > 2 else "benchmarks.json"
    raw = extract_json(body)
    if raw is None:
        print("no ```json block found in issue body", file=sys.stderr); sys.exit(2)
    try:
        entries = [validate(e) for e in normalize(json.loads(raw))]
    except (ValueError, json.JSONDecodeError) as ex:
        print(f"invalid payload: {ex}", file=sys.stderr); sys.exit(1)

    try:
        root = json.load(open(path, encoding="utf-8"))
    except FileNotFoundError:
        root = {"version": 1, "entries": []}
    before = json.dumps(root, sort_keys=True)
    existing = root.setdefault("entries", [])
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for e in entries:
        e.setdefault("createdAt", now)
        e.setdefault("updatedAt", now)
        idx = next((i for i, x in enumerate(existing) if x.get("key") == e["key"]), None)
        action = "updated" if idx is not None else "added"
        if idx is not None:
            e["createdAt"] = existing[idx].get("createdAt", e["createdAt"])
            existing[idx] = e
        else:
            existing.append(e)
        env = e["environment"]
        kinds = ", ".join(sorted(e["benchmarks"]))
        print(f"- {action}: {env.get('chip')} / {env.get('machine')} / {env.get('memoryGB', '?')} GB / "
              f"macOS {env.get('osVersion')} ({env.get('osBuild', '?')}) — {kinds}")
    root["version"] = 1
    root.setdefault("generatedBy", "FoundationModels.bench")
    if json.dumps(root, sort_keys=True) == before:
        print("benchmarks.json already contains exactly these results", file=sys.stderr); sys.exit(3)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(root, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")

if __name__ == "__main__":
    main()
