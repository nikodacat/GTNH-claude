#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- marks an interface as
the shared wildcard importer: a single physical ME interface the player
can drop ANY freshly-encoded pattern onto (for whichever machine, doesn't
matter which), where every new/changed pattern gets its own "which
machine is this for?" prompt instead of the interface being permanently
tied to one machine. See tools/sort_pattern.py for resolving those
prompts.

Usage: python tools/mark_importer.py <interface_address>

The interface must already be on record (i.e. it showed up in a pattern
scan) -- fails with a 404 otherwise, and with a 400 if it's already
marked as the importer.

Prints the server's /mark_importer response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: mark_importer.py <interface_address>"}))
        sys.exit(1)

    interface_address = sys.argv[1]

    body = json.dumps({"interface_address": interface_address}).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/mark_importer",
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
