#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- gets the static
craft-tree plan for item+qty (phase 1: recipe_db.json + ore_dict.json
only, no live AE2 stock check).

Usage: python3 tools/craft_plan.py <modid:name:meta> [qty]

IMPORTANT: if the response's "needs_player_input" list is non-empty, the
plan hit a real dependency loop or an ambiguity it can't resolve on its
own -- relay that to the player and ask them to pick, do NOT call
request_craft.py for this item anyway (it will refuse the same way).

Prints the server's /craft_plan response verbatim (JSON) to stdout. Thin
wrapper only -- the real planner lives in claude_test.py. Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.parse

PORT = 11434


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: craft_plan.py <item_id> [qty]"}))
        sys.exit(1)

    item = sys.argv[1]
    qty = sys.argv[2] if len(sys.argv) > 2 else "1"
    q = urllib.parse.quote(item)
    url = f"http://127.0.0.1:{PORT}/craft_plan?item={q}&qty={qty}"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            print(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
