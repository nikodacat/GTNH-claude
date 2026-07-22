#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- deletes a bad/
mislearned gt_machine recipe without touching the machine's label (use
tools/unlabel_machine.py instead if the LABEL itself was wrong, not just
one recipe reading).

Usage:
  python tools/remove_recipe.py "<machine name>" <item_id>   -- remove just this item's recipe(s) for that machine
  python tools/remove_recipe.py "<machine name>"             -- remove EVERY recipe ever learned for that machine

machine name must match exactly what was used when the machine was
labeled (see label_machine.py) -- check earlier chat messages if unsure
rather than guessing. item_id, if given, must be an exact recipe_db.json
key (e.g. "minecraft:stick", "gregtech:gt.metaitem.01:17809").

Prints the server's /remove_recipe response verbatim (JSON) to stdout.
Stdlib only.
"""
import sys
import json
import urllib.request
import urllib.error

PORT = 11434


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: remove_recipe.py <machine name> [item_id]"}))
        sys.exit(1)

    machine = sys.argv[1]
    item = sys.argv[2] if len(sys.argv) > 2 else None

    payload = {"machine": machine}
    if item:
        payload["item"] = item
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/remove_recipe",
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
