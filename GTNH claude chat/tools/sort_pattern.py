#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- resolves a pending
"which machine is this for?" prompt from the wildcard importer interface
(see tools/mark_importer.py), learning that specific pattern as a recipe
for the machine the player named.

Usage: python tools/sort_pattern.py <sort_id> "<machine name>"

sort_id comes from the exact prompt Claude saw earlier in this same
conversation ("New pattern on the importer interface ...: in: X -> out: Y.
Which machine is this for? (sort_id: <id>)") -- never invent or guess one.
Fails with a 404 if the sort_id is unknown or was already resolved (each
one can only be answered once).

Prints the server's /sort_pattern response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "usage: sort_pattern.py <sort_id> <machine name>"}))
        sys.exit(1)

    sort_id = sys.argv[1]
    machine = " ".join(sys.argv[2:])

    body = json.dumps({"sort_id": sort_id, "machine": machine}).encode("utf-8")
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
