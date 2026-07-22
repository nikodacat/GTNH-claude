# =============================================
#  claude_server.py  (v2 - with web UI)
#  Runs on your PC. Bridges OC HTTP requests
#  to Claude Code CLI (claude -p).
#  Requires: Claude Code installed + signed in
#  pip install nothing -- uses stdlib only
#
#  Endpoints:
#    POST /ping                 -- health check (OC)
#    POST /chat                 -- send message  (OC)
#    GET  /                     -- web chat viewer (browser)
#    GET  /history              -- poll for new messages (browser)
#    POST /upload_recipe_image  -- extract a recipe from a screenshot (browser)
#    POST /confirm_recipe       -- save a pending extracted recipe (browser)
#    POST /discard_recipe       -- drop a pending extracted recipe (browser)
#    POST /report_pattern       -- report one scanned ME interface pattern (OC)
#    GET  /oredict              -- resolve an ore:xxx tag to concrete items
#    GET  /craft_plan           -- static recipe-tree plan for item+qty (phase 1, no live AE2)
# =============================================

import http.server
import json
import subprocess
import sys
import os
import threading
import time
import base64
import uuid
import re
import math

PORT       = 11434
CLAUDE_PATH = os.environ.get("CLAUDE_CLI_PATH", "claude")

# ── shared conversation log ───────────────────────────────────
# Each entry: { "role": "player"|"claude"|"error", "text": str, "time": str }
# Persisted to CHAT_LOG_PATH (JSONL -- one JSON object per line, append-
# only) so restarting the server doesn't lose history: previous messages
# AND diag/error log entries (the dedicated /logs viewer reads from this
# same chat_log, just filtered client-side) are both reloaded on startup.
CHAT_LOG_PATH = "chat_log.jsonl"
log_lock   = threading.Lock()
chat_log   = []

def load_chat_log():
    global chat_log
    if not os.path.exists(CHAT_LOG_PATH):
        print(f"[~] {CHAT_LOG_PATH} not found -- starting with an empty chat log.")
        return
    print(f"[~] Loading chat log...", end=" ", flush=True)
    loaded = []
    with open(CHAT_LOG_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                loaded.append(json.loads(line))
            except Exception:
                # tolerate a corrupted trailing line (e.g. a hard crash
                # mid-write) rather than losing the whole log over one bad line
                pass
    with log_lock:
        chat_log[:] = loaded
    print(f"done. {len(chat_log):,} entries loaded.")

def append_log(role, text):
    ts = time.strftime("%H:%M:%S")
    entry = {"role": role, "text": text, "time": ts}
    with log_lock:
        chat_log.append(entry)
        try:
            with open(CHAT_LOG_PATH, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except Exception as e:
            print(f"[warn] failed to persist chat log entry to {CHAT_LOG_PATH}: {e}")

# ── CJK detection ─────────────────────────────────────────────
def contains_cjk(text):
    """Return True if text contains any CJK (Chinese/Japanese/Korean) characters."""
    for ch in text:
        cp = ord(ch)
        if (0x4E00 <= cp <= 0x9FFF   or   # CJK Unified Ideographs
            0x3400 <= cp <= 0x4DBF   or   # CJK Extension A
            0xF900 <= cp <= 0xFAFF   or   # CJK Compatibility
            0x3000 <= cp <= 0x303F   or   # CJK Symbols & Punctuation
            0xFF00 <= cp <= 0xFFEF):      # Halfwidth/Fullwidth Forms
            return True
    return False

def make_oc_notice(reply):
    """
    Given a reply that contains CJK, produce a short ASCII-safe notice
    for the OC terminal telling the player to check the web viewer.
    """
    # strip to first sentence or 80 chars of ASCII for a preview hint
    ascii_only = ''.join(c if ord(c) < 128 else '?' for c in reply)
    preview = ascii_only.strip()[:60].rsplit(' ', 1)[0]  # trim at word boundary
    return (
        "[!] Reply contains Chinese/non-ASCII text.\n"
        "    Check the web viewer for the full response.\n"
        + (("    Preview: " + preview + "...") if preview else "")
    )



# ── recipe database ───────────────────────────────────────────
RECIPE_DB_PATH = "recipe_db.json"
recipe_db = {}
recipe_db_lock = threading.Lock()  # guards recipe_db + the on-disk file during confirm_recipe writes

def load_recipe_db():
    global recipe_db
    if not os.path.exists(RECIPE_DB_PATH):
        print(f"[warn] {RECIPE_DB_PATH} not found — recipe lookups disabled.")
        print(f"       Run parse_recipes.py to generate it.")
        return
    print(f"[~] Loading recipe DB...", end=" ", flush=True)
    with open(RECIPE_DB_PATH, "r", encoding="utf-8") as f:
        recipe_db = json.load(f)
    print(f"done. {len(recipe_db):,} items indexed.")

def save_recipe_db():
    """Write recipe_db back to disk. Caller must hold recipe_db_lock."""
    tmp_path = RECIPE_DB_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(recipe_db, f, ensure_ascii=False)
    os.replace(tmp_path, RECIPE_DB_PATH)  # atomic on both POSIX and Windows

def search_items(query, limit=10):
    """Fuzzy search item names containing query string."""
    q = query.lower()
    results = []
    for name in recipe_db:
        if q in name.lower():
            results.append(name)
        if len(results) >= limit:
            break
    return results


# ── ore dictionary (authoritative ore:xxx tag -> concrete item table) ─────
# Built from a real /mt oredicts MineTweaker dump (see ore_dict.json's own
# generation history) -- lets OC scripts resolve an OreDictionary tag like
# "ore:dustRedstone" to its exact concrete item(s) via a static, authoritative
# table instead of fuzzy-matching item labels in the live ME network (which
# can pick a same-word-but-wrong item -- e.g. matching "dust" against
# unrelated items that happen to share that word in their label).
ORE_DICT_PATH = "ore_dict.json"
ore_dict = {}  # "ore:tagName" -> [[itemId, meta_or_None], ...]  (meta=None = OreDictionary wildcard, matches any damage)

def load_ore_dict():
    global ore_dict
    if not os.path.exists(ORE_DICT_PATH):
        print(f"[warn] {ORE_DICT_PATH} not found -- oredict lookups disabled.")
        return
    print(f"[~] Loading ore dictionary...", end=" ", flush=True)
    with open(ORE_DICT_PATH, "r", encoding="utf-8") as f:
        ore_dict = json.load(f)
    print(f"done. {len(ore_dict):,} tags indexed.")


# ── ME interface pattern scanner (live network recipes) ────────────────────
# scan_patterns_oc.lua walks every me_interface component on the network,
# finds occupied pattern slots, and reports the exact input/output items for
# each (already-valid, player-encoded patterns -- no write-validity mystery
# here, we're only ever reading). We remember them keyed by
# "<interface address>#<pattern index>" so we know exactly where a given
# recipe physically lives (needed to ever replicate/re-trigger it later),
# and only surface genuinely new-or-changed ones instead of re-logging the
# same pattern every scan.
KNOWN_PATTERNS_PATH = "known_patterns.json"
known_patterns = {}
known_patterns_lock = threading.Lock()

def load_known_patterns():
    global known_patterns
    if not os.path.exists(KNOWN_PATTERNS_PATH):
        print(f"[~] {KNOWN_PATTERNS_PATH} not found -- starting with an empty pattern catalog.")
        return
    with open(KNOWN_PATTERNS_PATH, "r", encoding="utf-8") as f:
        known_patterns = json.load(f)
    print(f"[~] Loaded known_patterns.json: {len(known_patterns):,} previously-scanned pattern slots.")

def save_known_patterns():
    """Write known_patterns back to disk. Caller must hold known_patterns_lock."""
    tmp_path = KNOWN_PATTERNS_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(known_patterns, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, KNOWN_PATTERNS_PATH)

def item_sig(entry):
    """Stable string for one item slot entry, used to build a pattern signature."""
    return f'{entry.get("index")}:{entry.get("id")}:{entry.get("damage",0)}:{entry.get("count",1)}'

def pattern_signature(inputs, outputs):
    """A content signature for a pattern's inputs+outputs, independent of dict
    key order -- used to detect whether a slot's recipe actually changed
    since the last scan, not just whether we've seen that slot before."""
    in_sig  = "|".join(sorted(item_sig(e) for e in inputs))
    out_sig = "|".join(sorted(item_sig(e) for e in outputs))
    return in_sig + "=>" + out_sig

def describe_item(entry):
    label = entry.get("label") or entry.get("id", "?")
    count = entry.get("count", 1)
    return f"{count}x {label}"


# ── craft tree planner -- PHASE 1: static, recipe_db.json + ore_dict.json
# only, no live AE2 interaction ─────────────────────────────────────────
# Given a target item + quantity, recursively resolves the full ingredient
# tree and how many craft operations each step needs, using only the
# static data already on disk. Deliberately does NOT check live ME
# network stock or write/request anything -- that's phase 2 (a stateful
# server-driven instruction loop with a new OC executor script, not yet
# built). Phase 1's job is just: "if I had none of anything in stock,
# what's the full shopping list and craft sequence for N of this item."
#
# KNOWN LIMITATION (accepted, not a bug to fix here): if the same
# intermediate item is needed by multiple branches of the tree (e.g. two
# different sub-assemblies both need screws), this flattens to separate
# craft steps per branch rather than merging into one consolidated step --
# it does not deduplicate/merge shared nodes across the whole tree. This
# is intentionally left for phase 2 to correct for naturally: phase 2
# checks REAL stock immediately before each step executes, so by the time
# a later branch's "craft screws" step runs, it'll see the screws an
# earlier branch already made and request less (or none) -- the static
# plan just needs to be correct-enough as a starting point, not optimal.
MAX_CRAFT_TREE_DEPTH = 50  # defensive guard against pathological/circular recipe_db data

def split_item_id(s):
    """'modid:name:meta' -> (id, meta)   'modid:name' -> (id, 0)
    Mirrors the Lua-side splitItemId() used throughout this project's OC
    scripts -- kept behaviorally identical so an item id resolves the same
    way whether it happens server-side (here) or OC-side."""
    parts = s.split(":")
    if len(parts) >= 3:
        try:
            meta = int(parts[-1])
        except ValueError:
            meta = 0  # tolerate a non-numeric trailing segment (e.g. stray "*")
        return ":".join(parts[:-1]), meta
    return s, 0

def resolve_ore_tag_v1(tag):
    """Phase 1 has no live stock data yet, so this just returns
    ore_dict.json's first candidate for the tag -- NOT stock-aware. Phase
    2 should override this using live ME network stock, mirroring the
    Lua-side resolveOreTag()'s "prefer whichever candidate you actually
    have" logic (test_pattern_write_oc.lua / test_pattern_write_direct_oc.lua)."""
    candidates = ore_dict.get(tag)
    if not candidates:
        return None, None
    item_id, meta = candidates[0]
    return item_id, (0 if meta is None else meta)

def resolve_ingredient_id(entry):
    if entry.startswith("ore:"):
        return resolve_ore_tag_v1(entry)
    return split_item_id(entry)

def get_ingredient_counts(recipe):
    """Normalize a recipe object into [(entry_string, count), ...] -- how
    many of each DISTINCT ingredient entry (before ore:-tag resolution) one
    execution of this recipe needs. Aggregates duplicate entries (e.g. a
    shapeless recipe listing "ore:plankWood" twice) into one (entry, 2)
    pair -- this is a planning-quantity concern, deliberately separate from
    how many individual AE2 pattern GRID SLOTS an ingredient occupies
    (that's the pattern-writer's concern, which does NOT aggregate -- see
    the shapeless count-vs-slots bug fixed in test_pattern_write_oc.lua;
    aggregating there was the actual bug, aggregating HERE is correct)."""
    rtype = recipe.get("type")
    counts = {}
    order = []
    def bump(entry, n=1):
        if entry not in counts:
            counts[entry] = 0
            order.append(entry)
        counts[entry] += n

    if rtype == "crafting_shaped":
        for entry in (recipe.get("grid") or []):
            if entry:
                bump(entry)
    elif rtype == "crafting_shapeless":
        for entry in (recipe.get("ingredients") or []):
            if entry:
                bump(entry)
    elif rtype == "gt_machine":
        for ing in (recipe.get("item_inputs") or []):
            entry = ing.get("item")
            if entry:
                bump(entry, ing.get("count", 1) or 1)
        # fluid_inputs intentionally NOT handled yet -- no fluid transport/
        # matching exists anywhere in this project so far. A gt_machine
        # recipe needing fluids will silently plan only its item inputs;
        # flagged in build_craft_tree()'s node as "fluids_ignored".

    return [(e, counts[e]) for e in order]

def get_recipe_output_count(recipe):
    """How many of the target item ONE execution of this recipe yields."""
    rtype = recipe.get("type")
    if rtype in ("crafting_shaped", "crafting_shapeless"):
        return max(1, recipe.get("output_count", 1) or 1)
    if rtype == "gt_machine":
        target = recipe.get("item")
        for out in (recipe.get("item_outputs") or []):
            if out.get("item") == target:
                return max(1, out.get("count", 1) or 1)
        return 1  # target not among its own declared outputs -- shouldn't normally happen
    return 1

def select_recipe(candidates):
    """v1 heuristic: prefer whichever recipe has the fewest distinct
    ingredient lines (simplest/cheapest-looking), tie-broken by whichever
    appears first in recipe_db.json. PLACEHOLDER -- a later phase should
    instead prefer whichever recipe matches an EXISTING scanned pattern in
    known_patterns.json (real, ground-truth, no ambiguity) over guessing
    from recipe_db.json, which can list multiple recipes for the same
    output item with no indication of which one is actually in use --
    this exact ambiguity picked a Saw-based stick recipe over the plain
    one in a real run (see project memory, 2026-07-22)."""
    if not candidates:
        return None
    return min(candidates, key=lambda r: len(get_ingredient_counts(r)))

def build_craft_tree(item, qty, _ancestors=None):
    """Recursively resolve how to make `qty` of `item`. Returns a node
    dict; see the module docstring above for the overall design. A "leaf"
    is a raw material with no recipe_db.json entry, an unresolvable ore:
    tag, a detected circular dependency, or the max-depth guard tripping --
    all treated the same way (nothing more to recurse into), just with a
    different `leaf_reason` for whichever applies."""
    ancestors = _ancestors or []

    # Genuine loops (and the max-depth safety trip, which in practice only
    # ever fires because of a loop the ancestor-chain check somehow missed)
    # are NOT silently resolved by picking a recipe -- there's no algorithmic
    # way to know which of the competing recipes actually breaks the cycle,
    # so this stops here and hands the real candidates back up for a human
    # to pick from (see find_flagged_nodes() below and its use in the
    # /craft_plan handler, which turns this into a plain-language chat
    # message). This is deliberately narrower than flagging every multi-
    # candidate item (nearly everything has >1 recipe_db.json entry) --
    # only a true loop means the planner has NO confident choice at all.
    if item in ancestors:
        return {"item": item, "qty": qty, "is_leaf": True, "needs_player_input": True,
                "leaf_reason": "circular dependency (already an ancestor of itself in this tree)",
                "ancestor_chain": ancestors + [item], "candidate_recipes": recipe_db.get(item) or []}
    if len(ancestors) >= MAX_CRAFT_TREE_DEPTH:
        return {"item": item, "qty": qty, "is_leaf": True, "needs_player_input": True,
                "leaf_reason": f"max tree depth ({MAX_CRAFT_TREE_DEPTH}) reached",
                "ancestor_chain": ancestors + [item], "candidate_recipes": recipe_db.get(item) or []}

    candidates = recipe_db.get(item)
    if not candidates:
        return {"item": item, "qty": qty, "is_leaf": True, "leaf_reason": "no recipe in recipe_db.json"}

    recipe = select_recipe(candidates)
    output_count = get_recipe_output_count(recipe)
    crafts_needed = math.ceil(qty / output_count)

    ingredients = []
    for entry, per_craft_count in get_ingredient_counts(recipe):
        resolved_id, resolved_damage = resolve_ingredient_id(entry)
        total_needed = per_craft_count * crafts_needed
        if resolved_id is None:
            ingredients.append({
                "entry": entry, "resolved_id": None, "resolved_damage": None, "qty_needed": total_needed,
                "node": {"item": entry, "qty": total_needed, "is_leaf": True,
                         "leaf_reason": "could not resolve ore: tag (not in ore_dict.json)"},
            })
            continue
        child = build_craft_tree(resolved_id, total_needed, ancestors + [item])
        ingredients.append({
            "entry": entry, "resolved_id": resolved_id, "resolved_damage": resolved_damage,
            "qty_needed": total_needed, "node": child,
        })

    node = {
        "item": item, "qty": qty, "is_leaf": False,
        "recipe_type": recipe.get("type"), "output_count": output_count,
        "crafts_needed": crafts_needed, "ingredients": ingredients,
    }
    if recipe.get("type") == "gt_machine" and recipe.get("fluid_inputs"):
        node["fluids_ignored"] = recipe["fluid_inputs"]
    return node

def flatten_craft_tree(node, leaves=None, steps=None):
    """Post-order flatten of a build_craft_tree() result into:
      leaves: {item: total_raw_qty}    -- aggregated across every branch
      steps:  [craft step, ...]        -- children before parents (so
              executing in this order guarantees every ingredient a step
              needs was already produced by an earlier step). See the
              module-level KNOWN LIMITATION note above: this does NOT
              merge/dedupe the same intermediate item across branches."""
    if leaves is None: leaves = {}
    if steps is None: steps = []

    if node.get("is_leaf"):
        leaves[node["item"]] = leaves.get(node["item"], 0) + node["qty"]
        return leaves, steps

    for ing in node["ingredients"]:
        flatten_craft_tree(ing["node"], leaves, steps)

    steps.append({
        "item": node["item"], "qty": node["qty"], "recipe_type": node["recipe_type"],
        "output_count": node["output_count"], "crafts_needed": node["crafts_needed"],
    })
    return leaves, steps

def find_flagged_nodes(node, out=None):
    """Walk a build_craft_tree() result collecting every node that needs
    player attention -- currently just genuine loops and the max-depth
    safety trip (see build_craft_tree()'s comment on why those two, and
    only those two, stop the planner cold instead of picking a recipe)."""
    if out is None:
        out = []
    if node.get("is_leaf"):
        if node.get("needs_player_input"):
            out.append(node)
        return out
    for ing in node["ingredients"]:
        find_flagged_nodes(ing["node"], out)
    return out

def describe_flagged_nodes_for_chat(item, qty, flagged):
    """Turn find_flagged_nodes() output into a plain-language chat message
    -- literally the "AI just calls it out and tells the player to choose"
    behavior. Lists each stuck item's real candidate recipes (ingredient
    summary only, not the full JSON) so there's actually something to
    choose between, not just an error."""
    lines = [f"Craft plan for {qty}x {item} hit {len(flagged)} spot(s) that need your input "
             f"(a real dependency loop, or several recipes chained too deep to resolve automatically):"]
    for node in flagged:
        chain = " -> ".join(node.get("ancestor_chain") or [node["item"]])
        lines.append(f"- {node['item']}: {node['leaf_reason']}")
        lines.append(f"    chain: {chain}")
        candidates = node.get("candidate_recipes") or []
        if not candidates:
            lines.append("    (no recipe_db.json entries at all for this item)")
            continue
        shown = candidates[:10]
        for i, r in enumerate(shown, 1):
            ings = r.get("grid") or r.get("ingredients") or []
            ings_str = ", ".join(e for e in ings if e) or "(no ingredients listed)"
            lines.append(f"    {i}. [{r.get('type','?')}] {ings_str}")
        if len(candidates) > 10:
            lines.append(f"    ... and {len(candidates) - 10} more recipe(s) not shown")
    lines.append("Pick which recipe should be used for the looping item(s) above, then ask again.")
    return "\n".join(lines)


# ── image-based recipe extraction (staged, needs confirmation) ────────────
# Player uploads a screenshot from the web chat page. We save it to disk,
# hand the file path to `claude -p` (which reads it directly via its Read
# tool -- no separate vision API needed), ask it to return one JSON recipe
# matching one of three schemas, and stage the result in `pending_recipes`
# for the player to review before it's ever written to recipe_db.json.
UPLOAD_DIR = "uploaded_recipes"
os.makedirs(UPLOAD_DIR, exist_ok=True)

pending_lock = threading.Lock()
pending_recipes = {}  # pending_id -> {"item": str, "recipe": dict, "image_path": str, "time": str}

RECIPE_EXTRACT_SYSTEM = """You are extracting a structured GTNH (GregTech: New Horizons) crafting recipe from a screenshot.

Read the image file at the path given below (a screenshot from Minecraft/NEI/JEI showing either a normal 3x3 crafting-table recipe or a GregTech machine recipe such as an Assembler, Mixer, Assembly Line, Circuit Assembler, etc). Then respond with EXACTLY ONE fenced ```json code block and nothing else outside of it -- no other commentary before or after.

If you cannot confidently identify the recipe from the image, respond with only:
```json
{"recognized": false, "reason": "<short explanation of what's unclear>"}
```

Otherwise, use ONE of these three schemas depending on what the image shows:

1) Normal SHAPED crafting-table recipe (ingredient position matters):
```json
{"recognized": true, "type": "crafting_shaped", "item": "<output item id, e.g. gregtech:gt.metaitem.01:810>", "output_count": 1, "grid": ["ore:dustRedstone", null, null, null, null, null, null, null, null]}
```
"grid" is always exactly 9 entries, row-major (top-left to bottom-right), null for empty cells.

2) Normal SHAPELESS crafting-table recipe (position doesn't matter):
```json
{"recognized": true, "type": "crafting_shapeless", "item": "<output item id>", "output_count": 1, "ingredients": ["ore:dustRedstone", "ore:dustSilicon", "ore:dustCoal"]}
```
List one entry per required item -- if 2 of the same ingredient are needed, list it twice.

3) GregTech MACHINE recipe (Assembler, Mixer, Assembly Line, Chemical Reactor, etc):
```json
{"recognized": true, "type": "gt_machine", "item": "<primary output item id>", "machine": "<machine name, e.g. Assembler, Assembly Line, Mixer>", "tier": "<voltage tier shown, e.g. LV/MV/HV, or the EU/t number if no tier name is visible>", "duration_ticks": 100, "eu_per_tick": 30, "item_inputs": [{"item": "<id>", "count": 1}], "item_outputs": [{"item": "<id>", "count": 1}], "fluid_inputs": [{"fluid": "<fluid name>", "amount_mb": 1000}], "fluid_outputs": []}
```
Omit fluid_inputs/fluid_outputs (or use empty arrays) if the recipe has none.

Item id conventions (match how this project's existing recipe database stores items):
- Prefer an OreDictionary tag string like "ore:dustRedstone", "ore:ingotIron", "ore:plateSteel" for generic materials that have one -- that's how the existing database stores common materials.
- Otherwise use "<modid>:<registryname>" (e.g. "minecraft:stick", "OpenComputers:wrench"), or "<modid>:<registryname>:<meta>" if the item has a numeric metadata/subtype (e.g. "gregtech:gt.metaitem.01:810").
- Never invent an item id you aren't reasonably confident about -- if unsure of the exact id, use a plain-English placeholder like "UNKNOWN:redstone_alloy_dust_guess" rather than a fabricated modded id, so a human can fix it during review.

Be precise and only report what the screenshot actually shows."""

def ask_claude_vision(image_abs_path):
    prompt = (RECIPE_EXTRACT_SYSTEM
              + "\n\nImage file path (read this file with your Read tool):\n"
              + image_abs_path)
    try:
        result = subprocess.run(
            [CLAUDE_PATH, "-p", prompt, "--allowedTools", "Read"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120  # vision + tool use is slower than a plain text reply
        )
        if result.returncode != 0:
            err = result.stderr.strip() or "unknown error"
            return None, f"claude exited {result.returncode}: {err}"
        return result.stdout.strip(), None
    except subprocess.TimeoutExpired:
        return None, "claude timed out (>120s) reading the image"
    except Exception as e:
        return None, str(e)

def extract_json_object(text):
    """Pull the JSON object out of a Claude reply that should contain exactly
    one ```json fenced block, tolerating minor deviations (no fence, stray
    text around it) since we're parsing free-form model output.

    Note: this matches on the ``` fence markers only, NOT on brace-balancing
    regex -- gt_machine recipes contain nested objects/arrays (item_inputs,
    fluid_inputs, ...), so a brace-matching regex like `\\{.*?\\}` would stop
    at the first inner "}" instead of the real end of the object. Once we
    have the fenced text, json.loads (or raw_decode as a fallback) parses
    nesting correctly because it understands JSON grammar, not just braces.
    """
    m = re.search(r"```(?:json)?\s*\n?(.*?)```", text, re.DOTALL)
    candidate = m.group(1).strip() if m else text

    try:
        return json.loads(candidate), None
    except Exception:
        pass  # fall through to a more lenient scan below

    start = candidate.find("{")
    if start == -1:
        return None, "no JSON object found in reply"
    try:
        obj, _ = json.JSONDecoder().raw_decode(candidate[start:])
        return obj, None
    except Exception as e:
        return None, f"failed to parse JSON: {e}"


# ── verify claude ─────────────────────────────────────────────
def check_claude():
    try:
        result = subprocess.run(
            [CLAUDE_PATH, "--version"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            print(f"[ok] Claude CLI found: {result.stdout.strip()}")
            return True
    except FileNotFoundError:
        pass
    print("[err] Claude CLI not found.")
    print("      Install: npm install -g @anthropic-ai/claude-code")
    print("      Sign in: claude")
    return False

# ── call claude -p ────────────────────────────────────────────
def ask_claude(messages, system=None):
    parts = []
    if system:
        parts.append(f"[System]\n{system}\n")
    for msg in messages:
        label = "User" if msg.get("role") == "user" else "Assistant"
        parts.append(f"[{label}]\n{msg.get('content','')}")
    parts.append("[Assistant]\n(reply below)")
    prompt = "\n\n".join(parts)

    try:
        result = subprocess.run(
            [CLAUDE_PATH, "-p", prompt],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60
        )
        if result.returncode != 0:
            err = result.stderr.strip() or "unknown error"
            return None, f"claude exited {result.returncode}: {err}"
        return result.stdout.strip(), None
    except subprocess.TimeoutExpired:
        return None, "claude timed out (>60s)"
    except Exception as e:
        return None, str(e)

# ── web UI HTML ───────────────────────────────────────────────
WEB_PAGE = """<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude × GTNH Chat</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #1a1a2e; color: #e0e0e0;
    font-family: 'Segoe UI', sans-serif;
    display: flex; flex-direction: column; height: 100vh;
  }
  header {
    background: #16213e; padding: 14px 20px;
    border-bottom: 2px solid #0f3460;
    display: flex; align-items: center; gap: 12px;
  }
  header h1 { font-size: 1.1rem; color: #00d4ff; }
  #status {
    margin-left: auto; font-size: 0.75rem;
    color: #888; display: flex; align-items: center; gap: 6px;
  }
  #logsLink {
    font-size: 0.8rem; color: #00d4ff; text-decoration: none;
    padding: 4px 10px; border: 1px solid #0f3460; border-radius: 8px;
  }
  #logsLink:hover { background: #0f3460; }
  #dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #00ff88; animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100% { opacity:1; } 50% { opacity:0.3; }
  }
  #log {
    flex: 1; overflow-y: auto;
    padding: 16px 20px;
    display: flex; flex-direction: column; gap: 12px;
  }
  .msg { display: flex; flex-direction: column; gap: 4px; max-width: 80%; }
  .msg.player { align-self: flex-end; align-items: flex-end; }
  .msg.claude  { align-self: flex-start; }
  .msg.error   { align-self: center; }
  .bubble {
    padding: 10px 14px; border-radius: 14px;
    line-height: 1.55; white-space: pre-wrap; word-break: break-word;
    font-size: 0.95rem;
  }
  .player .bubble {
    background: #0f3460; color: #e0f0ff;
    border-bottom-right-radius: 4px;
  }
  .claude .bubble {
    background: #16213e; color: #e0e0e0;
    border: 1px solid #0f3460;
    border-bottom-left-radius: 4px;
  }
  .error .bubble {
    background: #3a0f0f; color: #ff8888;
    font-size: 0.85rem;
  }
  .msg.diag { align-self: stretch; }
  .diag .bubble {
    background: #1a1a1a; color: #aaffaa;
    font-family: monospace; font-size: 0.82rem;
    border: 1px solid #2a2a2a;
    white-space: pre-wrap;
  }
  .diag .label { color: #aaffaa; }
  .msg.recipe_pending { align-self: stretch; }
  .recipe_pending .bubble {
    background: #1a2416; color: #d9ffb8;
    border: 1px solid #3a5a1e;
    font-family: monospace; font-size: 0.82rem;
    white-space: pre-wrap;
  }
  .recipe_pending .label { color: #b8ff5a; }
  .recipeActions { display: flex; gap: 8px; margin-top: 8px; }
  .recipeActions button {
    padding: 6px 14px; border-radius: 8px; border: none;
    font-size: 0.8rem; cursor: pointer; font-family: 'Segoe UI', sans-serif;
  }
  .btnConfirm { background: #00ff88; color: #0b1220; font-weight: 600; }
  .btnDiscard { background: #3a1a1a; color: #ff8888; }
  .recipeActions button:disabled { opacity: 0.5; cursor: default; }
  .meta {
    font-size: 0.72rem; color: #555;
    padding: 0 4px;
  }
  .label { font-weight: 600; font-size: 0.78rem; margin-bottom: 2px; }
  .player .label { color: #00d4ff; }
  .claude  .label { color: #00ff88; }
  #empty {
    flex: 1; display: flex; align-items: center; justify-content: center;
    color: #444; font-size: 0.9rem;
  }
  #inputBar {
    display: flex; gap: 8px;
    padding: 12px 20px;
    background: #16213e; border-top: 2px solid #0f3460;
  }
  #chatInput {
    flex: 1; padding: 10px 14px; border-radius: 10px;
    border: 1px solid #0f3460; background: #1a1a2e; color: #e0e0e0;
    font-size: 0.95rem; font-family: inherit;
  }
  #chatInput:disabled { opacity: 0.5; }
  #sendBtn {
    padding: 10px 18px; border-radius: 10px; border: none;
    background: #00d4ff; color: #0b1220; font-weight: 600;
    cursor: pointer; font-size: 0.9rem;
  }
  #sendBtn:disabled { opacity: 0.5; cursor: default; }
  #matchHint {
    font-size: 0.72rem; color: #666; padding: 0 20px 4px;
    min-height: 1em;
  }
  #uploadBar {
    display: flex; gap: 8px; align-items: center;
    padding: 0 20px 10px;
  }
  #dropZone {
    position: relative; /* containing block for the covering file input below */
    display: flex; align-items: center; gap: 10px;
    padding: 6px 12px; flex: 1.4;
    border: 1px dashed #2a4a6a; border-radius: 10px;
    transition: background 0.15s, border-color 0.15s;
  }
  #dropZone.dragging { background: #16213e; border-color: #00d4ff; }
  #dropHint { font-size: 0.72rem; color: #666; pointer-events: none; }
  /* The file input is stretched invisibly over the ENTIRE drop zone (instead
     of a tiny visually-hidden input that JS proxies a synthetic .click() to).
     Clicking anywhere in the zone -- including "on" the button graphic below,
     since this sits above it in stacking order -- opens the native file
     picker directly, which sidesteps any browser quirk around synthetic
     clicks not being trusted to open file dialogs. */
  #recipeImageInput {
    position: absolute; inset: 0; width: 100%; height: 100%;
    opacity: 0; cursor: pointer; z-index: 2;
  }
  #uploadBtn {
    padding: 8px 14px; border-radius: 10px; border: 1px solid #0f3460;
    background: #16213e; color: #00d4ff; font-size: 0.82rem;
    cursor: pointer; font-family: inherit; white-space: nowrap;
    pointer-events: none; /* purely visual now -- the input above handles clicks */
  }
  #uploadBtn:hover { background: #0f3460; }
  #uploadBtn:disabled { opacity: 0.5; cursor: default; }
  #recipeNoteInput {
    flex: 1; padding: 8px 12px; border-radius: 10px;
    border: 1px solid #0f3460; background: #1a1a2e; color: #e0e0e0;
    font-size: 0.82rem; font-family: inherit;
  }
</style>
</head>
<body>
<header>
  <div>⛏</div>
  <h1>Claude × GTNH Chat</h1>
  <div id="status"><div id="dot"></div><span id="statusText">Connecting...</span></div>
  <a id="logsLink" href="/logs" target="_blank">🖥 View Logs</a>
</header>
<div id="log">
  <div id="empty">Waiting for messages from in-game...</div>
</div>
<div id="matchHint"></div>
<div id="uploadBar">
  <div id="dropZone">
    <input id="recipeImageInput" type="file" accept="image/*">
    <button id="uploadBtn">📷 Browse image</button>
    <span id="dropHint">or drag &amp; drop / paste (Ctrl+V) a screenshot here</span>
  </div>
  <input id="recipeNoteInput" type="text" placeholder="optional note (e.g. item name)" autocomplete="off">
</div>
<div id="inputBar">
  <input id="chatInput" type="text" placeholder="Ask Claude, or ask about a craft (e.g. how do I make redstone alloy dust)..." autocomplete="off">
  <button id="sendBtn">Send</button>
</div>
<script>
  // Recipe-from-image upload is hidden/disabled for now (kept in the code,
  // not deleted, in case it's wanted again later) -- flip this back to
  // true to fully restore the browse/drag/paste upload bar and its paste
  // listener with no other changes needed.
  const RECIPE_IMAGE_UPLOAD_ENABLED = false;
  if (!RECIPE_IMAGE_UPLOAD_ENABLED) {
    document.getElementById('uploadBar').style.display = 'none';
  }

  let lastCount = 0;

  function addMessage(entry) {
    const log = document.getElementById('log');
    const empty = document.getElementById('empty');
    if (empty) empty.remove();

    const wrap = document.createElement('div');
    wrap.className = 'msg ' + entry.role;

    const label = document.createElement('div');
    label.className = 'label';
    label.textContent = entry.role === 'player'         ? '🎮 Player' :
                        entry.role === 'claude'          ? '🤖 Claude' :
                        entry.role === 'diag'            ? '🖥 OC Log' :
                        entry.role === 'recipe_pending'  ? '📋 Recipe pending review' : '⚠ Error';
    wrap.appendChild(label);

    const bubble = document.createElement('div');
    bubble.className = 'bubble';

    if (entry.role === 'recipe_pending') {
      let payload;
      try { payload = JSON.parse(entry.text); } catch (e) { payload = null; }
      if (!payload) {
        bubble.textContent = entry.text;
      } else {
        bubble.textContent = 'Item: ' + payload.item + '  (' + payload.type + ')\\n\\n' + payload.pretty;

        const actions = document.createElement('div');
        actions.className = 'recipeActions';

        const confirmBtn = document.createElement('button');
        confirmBtn.className = 'btnConfirm';
        confirmBtn.textContent = '✓ Confirm & Save';
        const discardBtn = document.createElement('button');
        discardBtn.className = 'btnDiscard';
        discardBtn.textContent = '✗ Discard';

        const disableBoth = () => { confirmBtn.disabled = true; discardBtn.disabled = true; };

        confirmBtn.addEventListener('click', async () => {
          disableBoth();
          confirmBtn.textContent = 'Saving...';
          try {
            await fetch('/confirm_recipe', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ pending_id: payload.pending_id })
            });
            confirmBtn.textContent = '✓ Saved';
          } catch (e) {
            confirmBtn.textContent = 'Failed: ' + e;
            confirmBtn.disabled = false; discardBtn.disabled = false;
          }
        });

        discardBtn.addEventListener('click', async () => {
          disableBoth();
          discardBtn.textContent = 'Discarding...';
          try {
            await fetch('/discard_recipe', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ pending_id: payload.pending_id })
            });
            discardBtn.textContent = '✗ Discarded';
          } catch (e) {
            discardBtn.textContent = 'Failed: ' + e;
            confirmBtn.disabled = false; discardBtn.disabled = false;
          }
        });

        actions.appendChild(confirmBtn);
        actions.appendChild(discardBtn);
        wrap.appendChild(bubble);
        wrap.appendChild(actions);

        const meta2 = document.createElement('div');
        meta2.className = 'meta';
        meta2.textContent = entry.time;
        wrap.appendChild(meta2);

        log.appendChild(wrap);
        log.scrollTop = log.scrollHeight;
        return;
      }
    } else {
      bubble.textContent = entry.text;
    }
    wrap.appendChild(bubble);

    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = entry.time;
    wrap.appendChild(meta);

    log.appendChild(wrap);
    log.scrollTop = log.scrollHeight;
  }

  async function poll() {
    try {
      const res = await fetch('/history?since=' + lastCount);
      if (!res.ok) throw new Error('bad response');
      const data = await res.json();
      document.getElementById('statusText').textContent = 'Live';
      document.getElementById('dot').style.background = '#00ff88';
      for (const entry of data.entries) {
        addMessage(entry);
        lastCount++;
      }
    } catch(e) {
      document.getElementById('statusText').textContent = 'Disconnected';
      document.getElementById('dot').style.background = '#ff4444';
    }
    setTimeout(poll, 1500);
  }

  poll();

  // ── web chat input ─────────────────────────────────────────
  // Lets you talk to Claude straight from the browser, without the
  // Minecraft server/OC terminal needing to be up. Not connected to
  // a live AE2 network, so it can only advise using recipe_db.json --
  // actual crafting still has to happen in-game via the OC terminal.

  const WEB_SYSTEM = 'You are a GTNH (GregTech: New Horizons) crafting ' +
    'assistant. You may be given a [Recipe DB] block containing a ' +
    'verified crafting recipe -- use it if present, and say so plainly ' +
    'if no recipe was found (note that GTNH recipes often differ from ' +
    'vanilla Minecraft). This conversation is running from a web ' +
    'browser with no live connection to the player\\'s in-game inventory ' +
    'or AE2 network -- you cannot check what they have in stock and ' +
    'cannot trigger an actual craft from here. If they want to execute ' +
    'a craft for real, tell them to do it from the in-game OC terminal. ' +
    'Reply conversationally and concisely.';

  let convHistory = []; // {role:'user'|'assistant', content:string}

  async function lookupRecipeContext(text) {
    const words = (text.toLowerCase().match(/[a-z]{3,}/g) || []);
    const hint = words.join('_');
    if (!hint) return { context: '(no recipe DB match)', item: null };
    try {
      const sres = await fetch('/search?q=' + encodeURIComponent(hint) + '&limit=3');
      const sdata = await sres.json();
      if (!sdata.results || sdata.results.length === 0) {
        return { context: '(no recipe DB match)', item: null };
      }
      const item = sdata.results[0];
      const rres = await fetch('/recipe?item=' + encodeURIComponent(item));
      const rdata = await rres.json();
      if (!rdata.found) return { context: '(no recipe DB match)', item: null };
      return {
        context: '[Recipe DB]\\nItem: ' + item + '\\n' + JSON.stringify(rdata.recipes),
        item: item
      };
    } catch (e) {
      return { context: '(recipe lookup failed: ' + e + ')', item: null };
    }
  }

  async function sendMessage() {
    const inputEl = document.getElementById('chatInput');
    const btn = document.getElementById('sendBtn');
    const hint = document.getElementById('matchHint');
    const text = inputEl.value.trim();
    if (!text) return;

    inputEl.value = '';
    inputEl.disabled = true;
    btn.disabled = true;
    btn.textContent = '...';
    hint.textContent = 'looking up recipe...';

    const { context, item } = await lookupRecipeContext(text);
    hint.textContent = item ? ('matched: ' + item) : 'no recipe DB match';

    convHistory.push({ role: 'user', content: text + '\\n\\n' + context });

    try {
      const res = await fetch('/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          messages: convHistory,
          display: text,
          system: WEB_SYSTEM,
          source: 'web'
        })
      });
      const data = await res.json();
      if (data.reply) {
        convHistory.push({ role: 'assistant', content: data.reply });
      }
      // rendering happens via the normal poll() cycle picking up the
      // shared server-side log, so we don't append here ourselves.
    } catch (e) {
      hint.textContent = 'send failed: ' + e;
    }

    inputEl.disabled = false;
    btn.disabled = false;
    btn.textContent = 'Send';
    inputEl.focus();
  }

  document.getElementById('sendBtn').addEventListener('click', sendMessage);
  document.getElementById('chatInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') sendMessage();
  });

  // ── recipe-from-image upload ───────────────────────────────
  // Three ways to get an image in: click-to-browse (hidden file input),
  // drag & drop onto #dropZone, or paste (Ctrl+V) anywhere on the page.
  // All three end up calling uploadRecipeFile() with a File/Blob, which
  // reads it as base64 in the browser and POSTs it to the server. The
  // server saves it to disk and hands the file path to a `claude -p`
  // subprocess for extraction -- the resulting pending recipe (or error)
  // shows up via the normal poll() cycle, same as any other log entry.
  function fileToBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result); // data:*/*;base64,....
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }

  async function uploadRecipeFile(file) {
    if (!file) return;
    const uploadBtn = document.getElementById('uploadBtn');
    const dropHint  = document.getElementById('dropHint');
    const note = document.getElementById('recipeNoteInput').value.trim();
    uploadBtn.disabled = true;
    const prevHint = dropHint.textContent;
    dropHint.textContent = 'Uploading & reading "' + (file.name || 'pasted image') + '"...';
    try {
      const b64 = await fileToBase64(file);
      const res = await fetch('/upload_recipe_image', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ image_b64: b64, filename: file.name || 'pasted.png', note: note })
      });
      const data = await res.json();
      if (!res.ok || data.error) {
        alert('Recipe extraction failed: ' + (data.error || 'unknown error'));
      } else if (data.recognized === false) {
        alert('Claude could not confidently read a recipe from that image' +
              (data.reason ? (': ' + data.reason) : '.'));
      }
      // on success, the pending_recipe card appears via the normal poll()
    } catch (err) {
      alert('Upload failed: ' + err);
    }
    uploadBtn.disabled = false;
    dropHint.textContent = prevHint;
  }

  // -- method 1: click anywhere in the drop zone -- the file input is
  // stretched invisibly over the whole zone (see CSS), so the click lands
  // directly on it and opens the native picker with no JS involved.
  document.getElementById('recipeImageInput').addEventListener('change', (e) => {
    const file = e.target.files[0];
    e.target.value = ''; // reset so picking the same file again still fires change
    uploadRecipeFile(file);
  });

  // -- method 2: drag & drop onto the drop zone --
  const dropZone = document.getElementById('dropZone');
  ['dragenter', 'dragover'].forEach(evt => {
    dropZone.addEventListener(evt, (e) => {
      e.preventDefault();
      dropZone.classList.add('dragging');
    });
  });
  ['dragleave', 'dragend'].forEach(evt => {
    dropZone.addEventListener(evt, (e) => {
      e.preventDefault();
      dropZone.classList.remove('dragging');
    });
  });
  dropZone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('dragging');
    const file = e.dataTransfer.files && e.dataTransfer.files[0];
    if (file) uploadRecipeFile(file);
  });

  // -- method 3: paste (Ctrl+V) anywhere on the page --
  // Only intercepts the paste when the clipboard actually contains an
  // image -- otherwise falls through to normal text pasting (e.g. into
  // chatInput or recipeNoteInput) untouched.
  document.addEventListener('paste', (e) => {
    if (!RECIPE_IMAGE_UPLOAD_ENABLED) return;
    const items = e.clipboardData && e.clipboardData.items;
    if (!items) return;
    for (const item of items) {
      if (item.type && item.type.startsWith('image/')) {
        e.preventDefault();
        const file = item.getAsFile();
        if (file) uploadRecipeFile(file);
        return;
      }
    }
  });
</script>
</body>
</html>"""

# ── dedicated logs viewer (separate tab, no chat clutter) ───────
# The in-game OC screen is tiny and can't show long crash traces or
# multi-line diagnostic dumps readably. This page shows ONLY the
# diag/error entries from the same shared log (nothing new to POST --
# it reuses /log and /history), in a big scrollable monospace console
# meant to be kept open in its own browser tab while playing.
LOGS_PAGE = """<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OC Logs — Claude × GTNH</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #0d0d0d; color: #aaffaa;
    font-family: 'Consolas', 'Courier New', monospace;
    display: flex; flex-direction: column; height: 100vh;
  }
  header {
    background: #16213e; padding: 14px 20px;
    border-bottom: 2px solid #0f3460;
    display: flex; align-items: center; gap: 12px;
    font-family: 'Segoe UI', sans-serif;
  }
  header h1 { font-size: 1.1rem; color: #00d4ff; }
  header a {
    margin-left: auto; font-size: 0.8rem; color: #00d4ff; text-decoration: none;
    padding: 4px 10px; border: 1px solid #0f3460; border-radius: 8px;
  }
  header a:hover { background: #0f3460; }
  #status { font-size: 0.75rem; color: #888; display: flex; align-items: center; gap: 6px; }
  #dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #00ff88; animation: pulse 2s infinite;
  }
  @keyframes pulse { 0%,100% { opacity:1; } 50% { opacity:0.3; } }
  #log {
    flex: 1; overflow-y: auto; padding: 16px 20px;
    display: flex; flex-direction: column; gap: 10px;
  }
  .entry {
    position: relative;
    border: 1px solid #2a2a2a; border-radius: 6px;
    padding: 10px 14px; background: #131313;
  }
  .entry.error { border-color: #5a1a1a; background: #1a0f0f; color: #ff8888; }
  .entry .head {
    display: flex; gap: 10px; font-size: 0.75rem; color: #666;
    margin-bottom: 6px; font-family: 'Segoe UI', sans-serif;
  }
  .entry.error .head { color: #cc6666; }
  .entry .time { color: #555; }
  .entry pre {
    white-space: pre-wrap; word-break: break-word;
    font-size: 0.92rem; line-height: 1.5;
  }
  .copyBtn {
    position: absolute; top: 8px; right: 10px;
    opacity: 0; transition: opacity 0.15s;
    background: #2a2a2a; color: #ccc; border: 1px solid #3a3a3a;
    border-radius: 6px; padding: 3px 9px; font-size: 0.72rem;
    cursor: pointer; font-family: 'Segoe UI', sans-serif;
  }
  .entry:hover .copyBtn { opacity: 1; }
  .copyBtn:hover { background: #3a3a3a; color: #fff; }
  .copyBtn.copied { opacity: 1; background: #0f3460; color: #00d4ff; border-color: #00d4ff; }
  #empty {
    flex: 1; display: flex; align-items: center; justify-content: center;
    color: #444; font-size: 0.9rem; font-family: 'Segoe UI', sans-serif;
  }
  #controls {
    padding: 8px 20px; background: #16213e; border-top: 1px solid #0f3460;
    display: flex; gap: 10px; align-items: center;
    font-family: 'Segoe UI', sans-serif;
  }
  #controls label { font-size: 0.8rem; color: #aaa; display: flex; gap: 6px; align-items: center; }
  #clearBtn {
    margin-left: auto; padding: 6px 12px; border-radius: 8px; border: none;
    background: #2a2a2a; color: #ccc; cursor: pointer; font-size: 0.8rem;
  }
</style>
</head>
<body>
<header>
  <div>🖥</div>
  <h1>OC Logs</h1>
  <div id="status"><div id="dot"></div><span id="statusText">Connecting...</span></div>
  <a href="/">💬 Back to Chat</a>
</header>
<div id="log"><div id="empty">Waiting for OC log output...</div></div>
<div id="controls">
  <label><input type="checkbox" id="autoscroll" checked> Auto-scroll</label>
  <button id="clearBtn">Clear view</button>
</div>
<script>
  let lastCount = 0;

  // works over plain http (LAN/Hamachi, not just localhost) -- the
  // Clipboard API is restricted to secure contexts, so fall back to
  // the old hidden-textarea + execCommand trick when it's unavailable.
  function copyToClipboard(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise((resolve, reject) => {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      try {
        document.execCommand('copy');
        resolve();
      } catch (e) {
        reject(e);
      } finally {
        document.body.removeChild(ta);
      }
    });
  }

  function addEntry(entry) {
    if (entry.role !== 'diag' && entry.role !== 'error') return;
    const log = document.getElementById('log');
    const empty = document.getElementById('empty');
    if (empty) empty.remove();

    const div = document.createElement('div');
    div.className = 'entry ' + (entry.role === 'error' ? 'error' : 'diag');

    const head = document.createElement('div');
    head.className = 'head';
    head.innerHTML = '<span>' + (entry.role === 'error' ? '⚠ Error' : '🖥 OC Log') + '</span>' +
                      '<span class="time">' + entry.time + '</span>';
    div.appendChild(head);

    const pre = document.createElement('pre');
    pre.textContent = entry.text;
    div.appendChild(pre);

    const copyBtn = document.createElement('button');
    copyBtn.className = 'copyBtn';
    copyBtn.textContent = '📋 Copy';
    copyBtn.addEventListener('click', () => {
      copyToClipboard(entry.text).then(() => {
        copyBtn.textContent = '✓ Copied';
        copyBtn.classList.add('copied');
        setTimeout(() => {
          copyBtn.textContent = '📋 Copy';
          copyBtn.classList.remove('copied');
        }, 1200);
      }).catch(() => {
        copyBtn.textContent = '✗ Failed';
        setTimeout(() => { copyBtn.textContent = '📋 Copy'; }, 1200);
      });
    });
    div.appendChild(copyBtn);

    log.appendChild(div);
    if (document.getElementById('autoscroll').checked) {
      log.scrollTop = log.scrollHeight;
    }
  }

  async function poll() {
    try {
      const res = await fetch('/history?since=' + lastCount);
      if (!res.ok) throw new Error('bad response');
      const data = await res.json();
      document.getElementById('statusText').textContent = 'Live';
      document.getElementById('dot').style.background = '#00ff88';
      for (const entry of data.entries) {
        addEntry(entry);
        lastCount++;
      }
    } catch(e) {
      document.getElementById('statusText').textContent = 'Disconnected';
      document.getElementById('dot').style.background = '#ff4444';
    }
    setTimeout(poll, 1500);
  }
  poll();

  document.getElementById('clearBtn').addEventListener('click', () => {
    document.getElementById('log').innerHTML = '<div id="empty">Cleared -- new logs will still appear below.</div>';
  });
</script>
</body>
</html>"""

# ── HTTP handler ──────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[req] {self.address_string()} — {fmt % args}")

    def send_json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html):
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    # ── GET ───────────────────────────────────────────────────
    def do_GET(self):
        if self.path == "/":
            self.send_html(WEB_PAGE)

        elif self.path == "/logs":
            self.send_html(LOGS_PAGE)

        elif self.path.startswith("/history"):
            # ?since=N  returns entries from index N onward
            since = 0
            if "since=" in self.path:
                try: since = int(self.path.split("since=")[1])
                except: since = 0
            with log_lock:
                entries = chat_log[since:]
            self.send_json(200, {"entries": entries})

        elif self.path == "/ping":
            self.send_json(200, {"status": "ok"})

        elif self.path.startswith("/recipe"):
            # /recipe?item=gregtech:gt.metaitem.01:810
            item = None
            if "item=" in self.path:
                item = self.path.split("item=")[1].split("&")[0]
                item = item.replace("%3A", ":").replace("+", " ")
            if not item:
                self.send_json(400, {"error": "missing ?item= parameter"})
            elif not recipe_db:
                self.send_json(503, {"error": "recipe DB not loaded"})
            else:
                recipes = recipe_db.get(item, [])
                self.send_json(200, {
                    "item"   : item,
                    "found"  : len(recipes) > 0,
                    "count"  : len(recipes),
                    "recipes": recipes,
                })

        elif self.path.startswith("/search"):
            # /search?q=iron_ingot&limit=10
            query = ""
            limit = 10
            if "q=" in self.path:
                query = self.path.split("q=")[1].split("&")[0]
                query = query.replace("%3A", ":").replace("+", " ")
            if "limit=" in self.path:
                try: limit = int(self.path.split("limit=")[1].split("&")[0])
                except: limit = 10
            results = search_items(query, limit) if query else []
            self.send_json(200, {"query": query, "results": results})

        elif self.path.startswith("/oredict"):
            # /oredict?tag=ore:dustRedstone
            # Entries are returned as "id:meta" strings (meta="*" for an
            # OreDictionary wildcard) -- same "id:meta"/"id:*" text format
            # the original /mt oredicts dump used, and the exact shape the
            # OC scripts' existing splitItemId()/extractArr() helpers
            # already parse elsewhere in this project, so no new Lua-side
            # JSON-array-of-arrays parsing is needed for this endpoint.
            tag = None
            if "tag=" in self.path:
                tag = self.path.split("tag=")[1].split("&")[0]
                tag = tag.replace("%3A", ":").replace("+", " ")
            if not tag:
                self.send_json(400, {"error": "missing ?tag= parameter"})
            elif not ore_dict:
                self.send_json(503, {"error": "ore dictionary not loaded"})
            else:
                raw_entries = ore_dict.get(tag, [])
                entries = [
                    f'{item_id}:{"*" if meta is None else meta}'
                    for item_id, meta in raw_entries
                ]
                self.send_json(200, {
                    "tag"    : tag,
                    "found"  : len(entries) > 0,
                    "count"  : len(entries),
                    "entries": entries,
                })

        elif self.path.startswith("/craft_plan"):
            # /craft_plan?item=minecraft:stick&qty=8
            # Phase 1 of the craft-tree planner (see build_craft_tree()'s
            # module comment) -- static recipe_db.json/ore_dict.json only,
            # no live AE2 stock check, nothing is written or requested.
            # Returns the full tree plus a flattened leaf shopping-list and
            # ordered craft-step sequence, for inspection/testing ahead of
            # phase 2 (the live, stateful execution loop).
            item, qty = None, 1
            if "item=" in self.path:
                item = self.path.split("item=")[1].split("&")[0]
                item = item.replace("%3A", ":").replace("+", " ")
            if "qty=" in self.path:
                try: qty = max(1, int(self.path.split("qty=")[1].split("&")[0]))
                except: qty = 1
            if not item:
                self.send_json(400, {"error": "missing ?item= parameter"})
            elif not recipe_db:
                self.send_json(503, {"error": "recipe DB not loaded"})
            else:
                tree = build_craft_tree(item, qty)
                leaves, steps = flatten_craft_tree(tree)
                flagged = find_flagged_nodes(tree)
                if flagged:
                    # surface it in the chat log too, not just the raw JSON --
                    # this is the "AI calls it out and tells the player to
                    # choose" behavior, so it's visible without anyone having
                    # to go read a /craft_plan response by hand.
                    append_log("claude", describe_flagged_nodes_for_chat(item, qty, flagged))
                self.send_json(200, {
                    "item": item, "qty": qty,
                    "tree": tree,
                    "leaves": leaves,
                    "steps": steps,
                    "needs_player_input": flagged,
                })

        else:
            self.send_json(404, {"error": "not found"})

    # ── POST ──────────────────────────────────────────────────
    def do_POST(self):
        if self.path == "/ping":
            length = int(self.headers.get("Content-Length", 0))
            if length: self.rfile.read(length)
            self.send_json(200, {"status": "ok"})
            return

        if self.path == "/log":
            # accepts {"role": "diag", "text": "..."} from OC scripts
            length = int(self.headers.get("Content-Length", 0))
            if length:
                try:
                    body = self.rfile.read(length)
                    data = json.loads(body.decode("utf-8"))
                    role = data.get("role", "diag")
                    text = data.get("text", "")
                    print(f"[{role}] {text[:80]}")
                    append_log(role, text)
                    self.send_json(200, {"status": "ok"})
                except Exception as e:
                    self.send_json(400, {"error": str(e)})
            else:
                self.send_json(400, {"error": "empty body"})
            return

        if self.path == "/upload_recipe_image":
            self.handle_upload_recipe_image()
            return

        if self.path == "/confirm_recipe":
            self.handle_confirm_recipe()
            return

        if self.path == "/discard_recipe":
            self.handle_discard_recipe()
            return

        if self.path == "/report_pattern":
            self.handle_report_pattern()
            return

        if self.path != "/chat":
            self.send_json(404, {"error": "use POST /chat"})
            return

        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json(400, {"error": "empty body"})
            return

        try:
            body = self.rfile.read(length)
            data = json.loads(body.decode("utf-8"))
        except Exception as e:
            self.send_json(400, {"error": f"bad JSON: {e}"})
            return

        messages = data.get("messages", [])
        system   = data.get("system", None)
        source   = data.get("source", "web")  # "oc" or "web"
        # optional: what to show in the chat log, if different from the
        # full message content sent to Claude (e.g. web client strips out
        # a big recipe-DB context blob before displaying the bubble)
        display  = data.get("display", None)

        if not messages:
            self.send_json(400, {"error": "no messages"})
            return

        # log player message
        last = messages[-1].get("content", "")
        shown = display if display is not None else last
        print(f"[player] {shown}")
        append_log("player", shown)

        reply, err = ask_claude(messages, system)
        if err:
            print(f"[err] {err}")
            append_log("error", err)
            self.send_json(500, {"error": err})
            return

        print(f"[claude] {reply}")
        append_log("claude", reply)

        # If the reply contains CJK and the client is OC terminal,
        # send a safe ASCII notice instead of the raw reply.
        # Web clients always get the full reply.
        if source == "oc" and contains_cjk(reply):
            oc_reply = make_oc_notice(reply)
            self.send_json(200, {"reply": oc_reply, "has_cjk": True})
        else:
            self.send_json(200, {"reply": reply, "has_cjk": False})

    # ── recipe-from-image endpoints ─────────────────────────────
    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return None, "empty body"
        try:
            body = self.rfile.read(length)
            return json.loads(body.decode("utf-8")), None
        except Exception as e:
            return None, f"bad JSON: {e}"

    def handle_upload_recipe_image(self):
        data, err = self._read_json_body()
        if err:
            self.send_json(400, {"error": err})
            return

        image_b64 = data.get("image_b64", "")
        filename  = data.get("filename", "recipe.png")
        note      = data.get("note", "")
        if not image_b64:
            self.send_json(400, {"error": "no image data"})
            return

        # sanitize filename, then prefix a timestamp so repeated uploads
        # (even of the same filename) never collide or overwrite each other
        safe_name = "".join(c for c in filename if c.isalnum() or c in "._-") or "recipe.png"
        saved_name = time.strftime("%Y%m%d_%H%M%S_") + safe_name
        saved_path = os.path.join(UPLOAD_DIR, saved_name)

        try:
            raw_b64 = image_b64.split(",", 1)[-1]  # strip "data:image/png;base64," prefix if present
            img_bytes = base64.b64decode(raw_b64)
            with open(saved_path, "wb") as f:
                f.write(img_bytes)
        except Exception as e:
            self.send_json(400, {"error": f"failed to decode/save image: {e}"})
            return

        shown = f"[uploaded recipe image: {saved_name}]" + (f" — {note}" if note else "")
        print(f"[recipe-image] {shown}")
        append_log("player", shown)

        abs_path = os.path.abspath(saved_path)
        print(f"[recipe-image] extracting from {abs_path} ...")
        reply, err = ask_claude_vision(abs_path)
        if err:
            print(f"[recipe-image][err] {err}")
            append_log("error", f"recipe image extraction failed: {err}")
            self.send_json(500, {"error": err})
            return

        obj, perr = extract_json_object(reply)
        if perr or obj is None:
            print(f"[recipe-image][err] {perr}")
            append_log("error", f"could not parse a recipe from Claude's reply: {perr}\n\nRaw reply:\n{reply}")
            self.send_json(200, {"recognized": False, "error": perr, "raw_reply": reply})
            return

        if not obj.get("recognized", True):
            reason = obj.get("reason", "(no reason given)")
            append_log("claude", "Couldn't confidently identify a recipe from that image: " + str(reason))
            self.send_json(200, {"recognized": False, "reason": reason})
            return

        rtype = obj.get("type")
        item  = obj.get("item")
        if rtype not in ("crafting_shaped", "crafting_shapeless", "gt_machine") or not item:
            append_log("error", f"extracted JSON missing required type/item fields: {json.dumps(obj, ensure_ascii=False)}")
            self.send_json(200, {"recognized": False, "error": "missing type/item in extracted JSON"})
            return

        pid = uuid.uuid4().hex[:10]
        with pending_lock:
            pending_recipes[pid] = {
                "item": item,
                "recipe": obj,
                "image_path": saved_path,
                "time": time.strftime("%H:%M:%S"),
            }

        pretty = json.dumps(obj, ensure_ascii=False, indent=2)
        append_log("recipe_pending", json.dumps(
            {"pending_id": pid, "item": item, "type": rtype, "pretty": pretty},
            ensure_ascii=False
        ))

        self.send_json(200, {"recognized": True, "pending_id": pid, "item": item, "recipe": obj})

    def handle_confirm_recipe(self):
        data, err = self._read_json_body()
        if err:
            self.send_json(400, {"error": err})
            return
        pid = data.get("pending_id")

        with pending_lock:
            entry = pending_recipes.pop(pid, None)
        if not entry:
            self.send_json(404, {"error": "unknown or already-resolved pending_id"})
            return

        # strip the staging-only fields, keep the rest as the stored recipe
        recipe_obj = dict(entry["recipe"])
        item = recipe_obj.pop("item")
        recipe_obj.pop("recognized", None)
        recipe_obj.pop("reason", None)

        with recipe_db_lock:
            recipe_db.setdefault(item, []).append(recipe_obj)
            try:
                save_recipe_db()
            except Exception as e:
                # write failed -- roll back the in-memory add and restore the
                # pending entry so the recipe isn't silently lost
                recipe_db[item].remove(recipe_obj)
                if not recipe_db[item]:
                    del recipe_db[item]
                with pending_lock:
                    pending_recipes[pid] = entry
                print(f"[recipe-image][err] failed to save recipe_db.json: {e}")
                append_log("error", f"failed to save recipe_db.json: {e}")
                self.send_json(500, {"error": str(e)})
                return

        print(f"[recipe-image] saved recipe for {item}")
        append_log("claude", f"✅ Recipe for {item} saved to the database.")
        self.send_json(200, {"status": "saved", "item": item})

    def handle_discard_recipe(self):
        data, err = self._read_json_body()
        if err:
            self.send_json(400, {"error": err})
            return
        pid = data.get("pending_id")

        with pending_lock:
            entry = pending_recipes.pop(pid, None)
        if entry:
            append_log("diag", f"Discarded pending recipe for {entry['item']}.")
        self.send_json(200, {"status": "discarded"})

    # ── ME interface pattern scanner endpoint ───────────────────
    def handle_report_pattern(self):
        """Receives one occupied ME-interface pattern slot from
        scan_patterns_oc.lua:
            {
              "interface_address": "<uuid>",
              "interface_label":   "<optional friendly name>",
              "pattern_index":     0-8,
              "inputs":  [{"index":0,"id":"...","damage":0,"count":1,"label":"..."}, ...],
              "outputs": [{"index":0,"id":"...","damage":0,"count":1,"label":"..."}, ...]
            }
        Only logs to the player-visible chat log when the slot is new or its
        contents changed since last scan -- a full scan reports every
        occupied slot every time, and we don't want to spam the log with
        the same 40 patterns every few minutes.
        """
        data, err = self._read_json_body()
        if err:
            self.send_json(400, {"error": err})
            return

        addr = data.get("interface_address")
        idx  = data.get("pattern_index")
        if not addr or idx is None:
            self.send_json(400, {"error": "missing interface_address or pattern_index"})
            return

        label   = data.get("interface_label") or addr[:8]
        inputs  = data.get("inputs", [])
        outputs = data.get("outputs", [])
        key     = f"{addr}#{idx}"
        sig     = pattern_signature(inputs, outputs)
        now     = time.strftime("%Y-%m-%d %H:%M:%S")

        with known_patterns_lock:
            prev = known_patterns.get(key)
            is_new     = prev is None
            is_changed = (prev is not None) and (prev.get("signature") != sig)

            known_patterns[key] = {
                "interface_address": addr,
                "interface_label"  : label,
                "pattern_index"    : idx,
                "inputs"           : inputs,
                "outputs"          : outputs,
                "signature"        : sig,
                "first_seen"       : prev["first_seen"] if prev else now,
                "last_seen"        : now,
            }
            try:
                save_known_patterns()
            except Exception as e:
                print(f"[pattern-scan][err] failed to save known_patterns.json: {e}")
                append_log("error", f"failed to save known_patterns.json: {e}")
                self.send_json(500, {"error": str(e)})
                return

        if is_new or is_changed:
            in_desc  = ", ".join(describe_item(e) for e in inputs)  or "(none)"
            out_desc = ", ".join(describe_item(e) for e in outputs) or "(none)"
            verb = "New" if is_new else "Changed"
            msg = (f"{verb} pattern found on interface \"{label}\" slot {idx}:\n"
                   f"  in:  {in_desc}\n"
                   f"  out: {out_desc}")
            print(f"[pattern-scan] {msg}")
            append_log("diag", msg)

        self.send_json(200, {"status": "ok", "new": is_new, "changed": is_changed})

# ── main ──────────────────────────────────────────────────────
if __name__ == "__main__":
    if not check_claude():
        sys.exit(1)

    load_chat_log()
    load_recipe_db()
    load_known_patterns()
    load_ore_dict()

    # ThreadingHTTPServer, not plain HTTPServer: handle_upload_recipe_image()
    # blocks on a `claude -p` subprocess for up to 120s (vision extraction is
    # slow). A single-threaded server would freeze EVERYTHING else -- including
    # the page's own /history polling -- for that whole window, which looks
    # exactly like "nothing is happening" even though extraction is running
    # fine in the background. Shared state (chat_log, pending_recipes,
    # recipe_db) is already guarded by locks (log_lock/pending_lock/
    # recipe_db_lock), so it's safe to let requests run concurrently.
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[ok] Listening on 0.0.0.0:{PORT}")
    print(f"     OC endpoint : http://26.89.137.125:{PORT}")
    print(f"     Web viewer  : http://26.89.137.125:{PORT}/   (open in browser)")
    print(f"     Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[ok] Stopped.")