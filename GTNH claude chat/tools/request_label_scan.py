#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- queues an item-LABEL
scan (a full ME-network sweep that captures every item's display name,
used to build/refresh item_labels.json for resolve_item.py lookups).

This is the QUEUED equivalent of the "scan_labels" command a player can
type directly at the crafting OC computer's terminal -- it exists because
that command originally could ONLY be triggered by a human typing at that
one terminal; Claude (running server-side, with no access to the live
game world) had no way to trigger it at all. This tool queues a request
that the crafting computer's own background poll picks up and runs the
same underlying scan for.

Usage: python tools/request_label_scan.py

Does NOT run instantly -- the crafting OC computer (the one with the `me`
proxy) picks this up on its own background poll (same ~10s cadence as its
craft-job poll), not this same turn. Completion (or failure) is reported
back separately, as its own chat message, once that computer finishes.

Prints the server's /request_label_scan response verbatim (JSON) to
stdout -- {"queued": true, "scan_id": "..."}. Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/request_label_scan",
        data=b"",
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
