#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- QUEUES a craft
request. Does NOT execute it.

Usage: python3 tools/request_craft.py <modid:name:meta> <qty>

Only the physical OC computer in-game can actually touch AE2 (check a
free crafting CPU, submit the request) -- this server has no way to push
a command into the game, it can only wait for OC to ask "anything queued
for me?" (which craft_oc.lua now does on a background timer, not just
when someone is actively typing, since a request can just as easily come
from the web chat). So:

- If "queued" is true: tell the player it's been QUEUED, not that it's
  done. Completion is reported separately (as a new chat message) once
  the OC side actually finishes it -- this call only confirms the job
  was accepted into the queue.
- If "queued" is false: "needs_player_input" explains what's blocking it
  (a real recipe ambiguity or dependency loop the planner can't resolve
  on its own) -- relay that to the player and ask them to pick, rather
  than retrying this call blindly.

Prints the server's /request_craft response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request

PORT = 11434


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "usage: request_craft.py <item_id> <qty>"}))
        sys.exit(1)

    item = sys.argv[1]
    try:
        qty = int(sys.argv[2])
    except ValueError:
        qty = 1

    body = json.dumps({"item": item, "qty": qty}).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/request_craft",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            print(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
