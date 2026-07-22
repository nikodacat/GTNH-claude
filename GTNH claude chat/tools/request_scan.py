#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- QUEUES a full
ME-interface pattern scan. Does NOT run it instantly.

Usage: python3 tools/request_scan.py

Takes no arguments -- a scan request is just "go scan everything", no
item/qty involved. This is a SEPARATE queue from tools/request_craft.py's
crafting job queue, and is picked up by a SEPARATE, dedicated OC computer
(the one wired to the Database Upgrade + me_interfaces needed to read
pattern contents -- see scan_patterns_oc.lua) on its own background poll,
not instantly. Tell the player the scan is QUEUED, never that it's done --
completion (or failure, e.g. missing hardware on that computer) is
reported separately later as its own chat message.

This is unrelated to the "scan_labels" OC terminal command (item-label
scanning) -- that's a different feature, not reachable via a tool.

Prints the server's /request_scan response verbatim (JSON) to stdout.
Stdlib only.
"""
import json
import urllib.request

PORT = 11434


def main():
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/request_scan",
        data=b"",
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            print(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
