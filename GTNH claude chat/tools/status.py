#!/usr/bin/env python3
"""
Tool script for Claude (invoked via a scoped Bash permission, see
ask_claude()'s --allowedTools in claude_test.py) -- fetches aggregate
dashboard numbers: total recipes, total known machines, interface/queue
backlog sizes, and which interfaces the scanner can currently see. Built
2026-07-24 after a real back-and-forth where two brand-new, genuinely
connected ME Interfaces looked completely invisible -- this tool's
"scanner_visibility" section exists specifically to answer "is my new
machine actually visible to the scanner at all, or does it just not have
a pattern in it yet" without guessing.

Usage: python tools/status.py

Prints the server's /status response verbatim (JSON) to stdout:
{
  "recipes": {total_items_indexed, total_recipes, crafting_table_recipes, gt_machine_recipes},
  "machines": {total_known_machines, known_machine_names, labeled_interfaces,
               importer_interfaces, interfaces_awaiting_label, machines_with_description},
  "scanner_visibility": {total_interfaces_seen_by_scanner,
                          seen_but_never_had_a_pattern_reported: [{interface_address, interface_label, last_seen}, ...]},
  "patterns": {total_known_pattern_slots},
  "queues": {scan_requests_by_status, craft_jobs_by_status, importer_sorts_awaiting_answer},
  "last_scan": {time, event, scan_id, details} or null
}
Stdlib only.
"""
import sys
import json
import urllib.request

PORT = 11434


def main():
    url = f"http://127.0.0.1:{PORT}/status"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            print(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
