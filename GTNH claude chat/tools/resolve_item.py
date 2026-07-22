#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- resolves an item
name/label to candidate concrete item ids.

Usage: python3 tools/resolve_item.py <name or partial name>

Tries the scanned display-name index first (/resolve_name, built from the
"scan_labels" OC command -- see item_labels.json), then falls back to the
raw id-substring search (/search) since not every item has been label-
scanned yet. Prints one JSON object to stdout; nothing else.

This is a thin wrapper only -- all real logic lives server-side in
claude_test.py so there is exactly one implementation of each lookup,
whether it's called from this tool, the web viewer, or an OC script.
Stdlib only (urllib), matching the rest of this project's "no extra
pip installs required on the player's PC" convention.
"""
import sys
import json
import urllib.request
import urllib.parse

PORT = 11434


def get(path):
    url = f"http://127.0.0.1:{PORT}{path}"
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: resolve_item.py <name>"}))
        sys.exit(1)

    query = " ".join(sys.argv[1:])
    q = urllib.parse.quote(query)

    try:
        by_label = get(f"/resolve_name?q={q}&limit=5")
    except Exception as e:
        by_label = {"results": [], "error": str(e)}

    try:
        by_id = get(f"/search?q={q}&limit=5")
    except Exception as e:
        by_id = {"results": [], "error": str(e)}

    print(json.dumps({
        "query": query,
        "label_matches": by_label.get("results", []),   # [{"id_meta","label"}, ...] -- from a real display-name scan
        "id_matches": by_id.get("results", []),         # [id, ...] -- raw id-substring match, no display name attached
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
