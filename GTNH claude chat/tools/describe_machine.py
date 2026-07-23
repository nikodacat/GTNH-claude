#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- writes or updates a
short free-text description for a machine, so future chat has real
context about it instead of just a name. Either Claude or the player can
be the source: Claude can write one itself after learning a few recipes
for a machine ("makes GT circuit boards, LV-MV tier"), or record what the
player says about it ("that one's near spawn, feeds the assembly line").

Usage: python tools/describe_machine.py "<machine name>" "<description>"

BOTH arguments must be quoted as single shell tokens -- unlike
label_machine.py/sort_pattern.py (where only the trailing field is
multi-word, so joining "everything after the first token" is
unambiguous), this tool has TWO multi-word fields with nothing to
separate them by position alone. Passing anything other than exactly 2
arguments is treated as a usage error rather than guessed at.

machine must (case-insensitively) match an existing known machine name --
same enforcement as sort_pattern.py, for the same reason (a description
written under a typo'd variant of a name would never be found again). If
it doesn't match, the response comes back as {"status": "unknown_machine",
"did_you_mean": ..., "known_machines": [...]} and nothing is saved -- fix
the name and call again.

Overwrites any existing description for that machine outright (this is a
living note, not a history log).

Prints the server's /describe_machine response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    if len(sys.argv) != 3:
        print(json.dumps({"error": 'usage: describe_machine.py "<machine name>" "<description>" -- '
                                    "both arguments must be quoted as single tokens"}))
        sys.exit(1)

    machine = sys.argv[1]
    description = sys.argv[2]

    body = json.dumps({"machine": machine, "description": description}).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/describe_machine",
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
