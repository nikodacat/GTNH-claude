#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- undoes a mislabeled
machine: resets the interface back to unlabeled (so the "Found an
unidentified machine..." prompt fires again next scan) and deletes every
recipe that was learned under the wrong machine name.

Usage: python tools/unlabel_machine.py <interface_address>

The interface_address must already be on record (i.e. it showed up in a
pattern scan and was previously labeled) -- fails with a 404 otherwise, and
with a 400 if it's on record but was never labeled in the first place
(nothing to undo).

Prints the server's /unlabel_machine response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: unlabel_machine.py <interface_address>"}))
        sys.exit(1)

    interface_address = sys.argv[1]

    body = json.dumps({"interface_address": interface_address}).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/unlabel_machine",
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
