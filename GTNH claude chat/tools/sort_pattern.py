#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- resolves a pending
"which machine is this for?" prompt from the wildcard importer interface
(see tools/mark_importer.py), learning that specific pattern as a recipe
for the machine the player named.

Usage:
  python tools/sort_pattern.py <sort_id> "<machine name>"
  python tools/sort_pattern.py <sort_id> "<machine name>" --confirm

sort_id comes from the exact prompt Claude saw earlier in this same
conversation ("New pattern on the importer interface ...: in: X -> out: Y.
Which machine is this for? (sort_id: <id>)") -- never invent or guess one.

The importer is meant to route patterns to machines that ALREADY exist
elsewhere, not create near-duplicate machine buckets from typos/phrasing/
translation differences. The first call (no --confirm) checks the given
name against every already-known machine: an exact match learns it right
away; anything else comes back as {"status": "needs_confirmation",
"did_you_mean": ..., "known_machines": [...]} WITHOUT learning anything --
ask the player to confirm, then re-run with --confirm and whichever name
was actually agreed on (the suggested one, or the player's own if it's
genuinely a new machine) to finalize.

Fails with a 404 if the sort_id is unknown or was already resolved.

Prints the server's /sort_pattern response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    args = sys.argv[1:]
    confirm = "--confirm" in args
    if confirm:
        args = [a for a in args if a != "--confirm"]

    if len(args) < 2:
        print(json.dumps({"error": "usage: sort_pattern.py <sort_id> <machine name> [--confirm]"}))
        sys.exit(1)

    sort_id = args[0]
    machine = " ".join(args[1:])

    payload = {"sort_id": sort_id, "machine": machine}
    if confirm:
        payload["confirm"] = True
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/sort_pattern",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            print(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(e.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
