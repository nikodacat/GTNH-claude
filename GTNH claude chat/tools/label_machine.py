#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- labels an unlabeled
machine once the player answers a "what machine is this?" prompt.

Usage: python3 tools/label_machine.py <interface_address> <machine name...>

The interface_address comes from the prompt Claude already saw earlier in
this same conversation (pushed to chat when scan_patterns_oc.lua reports a
minecraft:stick marker pattern on a not-yet-labeled interface) -- the
player never needs to type the raw address themselves, Claude should
supply it from context. This will fail with a 404 if that interface
hasn't actually shown up in a marker scan yet (nothing to label).

Prints the server's /label_machine response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "usage: label_machine.py <interface_address> <machine name>"}))
        sys.exit(1)

    interface_address = sys.argv[1]
    machine = " ".join(sys.argv[2:])

    body = json.dumps({"interface_address": interface_address, "machine": machine}).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/label_machine",
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
