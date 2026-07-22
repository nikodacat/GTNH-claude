#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- looks up every known
recipe_db.json recipe for one exact item id.

Usage: python3 tools/get_recipe.py <modid:name:meta>

Prints the server's /recipe response verbatim (JSON) to stdout. This is a
thin wrapper only -- the real lookup lives in claude_test.py's /recipe
handler. Stdlib only (urllib).
"""
import sys
import json
import urllib.request
import urllib.parse

PORT = 11434


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: get_recipe.py <item_id>"}))
        sys.exit(1)

    item = sys.argv[1]
    q = urllib.parse.quote(item)
    url = f"http://127.0.0.1:{PORT}/recipe?item={q}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            print(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
