#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- fetches a structured
log of recent scan-pipeline activity: new/changed patterns found,
unidentified machines flagged, importer sort prompts raised, recipes
learned, and scan requests queued/completed/failed. Lets Claude answer
"what happened in the last scan?" or "what's going on with scanning
lately?" directly, instead of asking the player to paste raw OC debug
logs or relying on whatever happens to still be in this conversation's
own history.

Usage: python tools/recent_scans.py [limit]
limit defaults to 20. Results are newest first.

Prints the server's /recent_scans response verbatim (JSON) to stdout --
{"count": N, "events": [{"time", "event", ...fields depending on event
type}, ...]}. event is one of: scan_requested, scan_completed,
scan_failed, pattern_new, pattern_changed, unknown_machine,
importer_pending_sort, recipe_learned. Stdlib only.
"""
import sys
import json
import urllib.request

PORT = 11434


def main():
    limit = sys.argv[1] if len(sys.argv) > 1 else "20"
    url = f"http://127.0.0.1:{PORT}/recent_scans?limit={limit}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            print(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
