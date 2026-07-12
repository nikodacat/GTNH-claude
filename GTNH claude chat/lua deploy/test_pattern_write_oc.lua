-- =============================================
--  test_pattern_write_oc.lua
--  Tests writing an AE2 crafting pattern on the
--  fly, using recipe_db.json data, via the OC
--  Pattern Editor block (from AE2 Fluid Crafting).
--
--  WHY NOT me_interface DIRECTLY:
--  me_interface.setInterfacePatternInput/Output()
--  writes NBT straight into a live network pattern
--  slot with no backing physical item -- this is the
--  same class of bug GTNH issue #20730 covers, and is
--  exactly why AE2FluidCraft-Rework's changelog
--  (v1.3.5-gtnh-pre) REMOVED the equivalent method from
--  the OC Pattern Editor block: it let items be
--  fabricated ("spawned") out of thin air. The sanctioned
--  replacement is this dedicated block, which only lets
--  you encode NBT onto a REAL, physical AE2 pattern item
--  sitting in ITS OWN 16-slot inventory. Nothing touches
--  the live network until you physically move that real,
--  now-encoded pattern item into an actual ME Interface --
--  same as encoding one by hand at a Pattern Terminal.
--
--  Requires (all connected via separate OC Adapters,
--  or directly adjacent to the computer):
--    - me_controller    : your existing full-network link
--                          (only used to resolve ore: tags
--                          and to sanity-check the result)
--    - oc_pattern_editor : the "OC Pattern Editor" block
--                          from AE2 Fluid Crafting. NOT the
--                          same block as a me_interface --
--                          it's a standalone item-only block
--                          with no network connection of its
--                          own. BEFORE running this script,
--                          put an AE2 pattern item into its
--                          first inventory slot that has ALREADY
--                          been encoded with a genuinely valid,
--                          real recipe at a real ME Pattern
--                          Terminal (e.g. 2 planks -> 4 sticks --
--                          content doesn't matter, this script
--                          overwrites it, but it must be a REAL
--                          recipe, not arbitrary items -- see the
--                          needsPriming block below for why).
--    - database          : a Database Upgrade (any tier)
--
--  AFTER this script reports [OK], take the now-encoded
--  pattern item out of the OC Pattern Editor and place it
--  into a real ME Interface's pattern slots yourself -- that
--  final physical move is what actually activates the recipe
--  on your network. This script does not do that move for
--  you (out of scope for this POC test script).
--
--  IMPORTANT CAVEAT discovered from recipe_db.json:
--  many "grid"/"ingredients" entries are OreDictionary
--  tags (e.g. "ore:dustRedstone"), not concrete item
--  IDs. AE2 patterns need a CONCRETE item+damage, so
--  this script resolves ore: tags by searching your
--  live ME network for a matching item and picking the
--  one you have the most of. It prints a NOTE line for
--  every ore: resolution so you can sanity-check it --
--  if it picks the wrong variant, the craft will still
--  request that exact item, not a substitute.
-- =============================================

local component = require("component")
local computer  = require("computer")

local DISK = "/mnt/dc6"   -- where scripts + config live

if not component.isAvailable("internet") then print("[FAIL] no internet card"); return end

-- ── local config (NOT tracked in git) ─────────
-- Copy config.example.lua to DISK.."/config.lua" and set your
-- real SERVER ip there. Keeping it out of git means pulling
-- script updates never clobbers your local server IP.
local function loadConfig()
  local path = DISK.."/config.lua"
  local f = io.open(path, "r")
  if not f then
    print("[FAIL] Missing config file: "..path)
    print("       Copy config.example.lua to "..path)
    print("       and set your SERVER ip there.")
    return nil
  end
  f:close()
  local ok, cfg = pcall(dofile, path)
  if not ok or type(cfg) ~= "table" or not cfg.SERVER then
    print("[FAIL] "..path.." must return a table with a SERVER field.")
    return nil
  end
  return cfg
end

local cfg = loadConfig()
if not cfg then return end
local SERVER = cfg.SERVER
local SCRIPT_NAME = "test_pattern_write_oc"
local net = component.internet

-- ── crash-resistant local log file ─────────────
-- flushDebug() only sends what's buffered in memory, and only when we
-- reach a checkpoint that calls it -- a genuinely unexpected crash
-- (an uncaught native error firing somewhere we didn't wrap in
-- pcall) skips straight past that and OC's own crash handler prints
-- a traceback to the LOCAL terminal only, never the web viewer. Writing
-- every dbg() line straight to disk as it happens means the log
-- survives even that kind of hard crash, and gets auto-recovered and
-- pushed to the web the *next* time this script starts.
local LOG_FILE = DISK.."/oc_log_"..SCRIPT_NAME..".txt"

-- ── debug logger (mirrors all output to the web viewer + local disk) ─
local debugLines = {}
local function dbg(text)
  local t = string.format("[%.1fs] %s", computer.uptime(), text)
  print(t)
  debugLines[#debugLines+1] = t
  local lf = io.open(LOG_FILE, "a")
  if lf then lf:write(t.."\n"); lf:close() end
end
local function flushDebug(label)
  if #debugLines == 0 then return end
  local full = "["..SCRIPT_NAME.."] "..(label or "log")..":\n"..table.concat(debugLines, "\n")
  debugLines = {}
  local body = '{"role":"diag","text":"'
               ..full:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')
               ..'"}'
  pcall(function()
    local req = net.request(SERVER.."/log", body, {["Content-Type"]="application/json"})
    if not req then return end
    local dl = computer.uptime()+5
    while computer.uptime()<dl do
      local ok = req.finishConnect()
      if ok then break end
      if ok==nil then req.close(); return end
      os.sleep(0.05)
    end
    req.close()
  end)
end

-- ── recover + push any log left over from a crashed previous run ──
-- (runs once, before this run adds anything of its own to LOG_FILE)
local function recoverPreviousLog()
  local f = io.open(LOG_FILE, "r")
  if not f then return end
  local prev = f:read("*a")
  f:close()
  -- clear it now regardless, so a failed recovery push doesn't re-send
  -- the same stale log forever on every future run
  local wf = io.open(LOG_FILE, "w")
  if wf then wf:close() end
  if not prev or prev == "" then return end
  local full = "["..SCRIPT_NAME.."] recovered-from-previous-crash:\n"..prev
  local body = '{"role":"diag","text":"'
               ..full:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')
               ..'"}'
  pcall(function()
    local req = net.request(SERVER.."/log", body, {["Content-Type"]="application/json"})
    if not req then return end
    local dl = computer.uptime()+5
    while computer.uptime()<dl do
      local ok = req.finishConnect()
      if ok then break end
      if ok==nil then req.close(); return end
      os.sleep(0.05)
    end
    req.close()
  end)
end
recoverPreviousLog()

if not component.isAvailable("me_controller") then
  dbg("[FAIL] no me_controller"); flushDebug("hw-fail"); return
end
if not component.isAvailable("oc_pattern_editor") then
  dbg("[FAIL] no oc_pattern_editor component found.")
  dbg("       Connect an OC Adapter to (or place directly adjacent")
  dbg("       to this computer) an OC Pattern Editor block -- from")
  dbg("       AE2 Fluid Crafting. This is NOT a me_interface; it's a")
  dbg("       standalone 16-slot block with no network link of its own.")
  flushDebug("hw-fail")
  return
end
if not component.isAvailable("database") then
  dbg("[FAIL] no database component found.")
  dbg("       Connect an OC Adapter to a Database Upgrade (any tier).")
  flushDebug("hw-fail")
  return
end

local me     = component.me_controller
local editor = component.oc_pattern_editor
local db     = component.database
flushDebug("hw-ok")

-- ── minimal HTTP GET ──────────────────────────
local function get(path)
  local req = net.request(SERVER..path)
  if not req then return nil, "request() failed" end
  local dl = computer.uptime()+15
  while computer.uptime()<dl do
    local ok,e = req.finishConnect()
    if ok then break end
    if ok==nil then req.close(); return nil, e end
    os.sleep(0.05)
  end
  local r=""
  while true do
    local c=req.read(8192)
    if not c then break end
    r=r..c
  end
  req.close()
  return r
end

-- ── tiny JSON string/array extractors (same style as craft_debug_oc.lua) ──
local function extractStr(raw,key)
  local p=raw:match('"'..key..'":%s*"(.-[^\\])"')
  return p and p:gsub('\\"','"') or nil
end
local function extractArr(raw,key)
  local s = raw:match('"'..key..'":%s*(%[.-%])')
  if not s then return nil end
  local out={}
  for entry in s:gmatch('([^,%[%]]+)') do
    entry=entry:match("^%s*(.-)%s*$")
    if entry=="null" then out[#out+1]=false
    elseif entry:sub(1,1)=='"' then out[#out+1]=entry:match('"([^"]*)"') end
  end
  return out
end

-- ── split "modid:name:meta" or "modid:name" into id,damage ──
local function splitItemId(s)
  local parts={}
  for p in s:gmatch("[^:]+") do parts[#parts+1]=p end
  if #parts>=3 then
    return parts[1]..":"..parts[2], tonumber(parts[3]) or 0
  elseif #parts==2 then
    return parts[1]..":"..parts[2], 0
  end
  return s, 0
end

-- ── resolve an ore:xxx tag to a concrete item by searching your ME network ──
local function resolveOreTag(tag)
  local keyword = tag:gsub("^ore:","")
  -- split camelCase-ish tag into lowercase search words, e.g. dustRedstone -> dust, redstone
  local words={}
  for w in keyword:gmatch("%u?%l+") do words[#words+1]=w:lower() end
  if #words==0 then words={keyword:lower()} end

  local ok, items = pcall(me.getItemsInNetwork, {})
  if not ok or not items then return nil, "getItemsInNetwork failed" end

  local best, bestScore, bestSize = nil, 0, 0
  for _, it in ipairs(items) do
    local label=(it.label or ""):lower()
    local name =(it.name  or ""):lower()
    local score=0
    for _,w in ipairs(words) do
      if label:find(w,1,true) or name:find(w,1,true) then score=score+1 end
    end
    if score>0 and (score>bestScore or (score==bestScore and (it.size or 0)>bestSize)) then
      best=it; bestScore=score; bestSize=it.size or 0
    end
  end
  if not best then return nil, "no match in network for "..tag end
  dbg(string.format("  [NOTE] resolved %s -> %s (damage=%d, label=%s, you have %d)",
    tag, best.name, best.damage or 0, best.label or "?", best.size or 0))
  return best.name, best.damage or 0
end

local function resolveEntry(entry)
  if entry:sub(1,4)=="ore:" then
    return resolveOreTag(entry)
  else
    local id,dmg = splitItemId(entry)
    return id,dmg
  end
end

-- ── on wrapping risky calls: some component methods (e.g. database.set
-- with an out-of-range slot) throw a hard Lua error instead of
-- returning (false, err). An uncaught throw skips right past our own
-- dbg()/flushDebug() error handling and crashes the whole script -- OC's
-- own crash handler prints a traceback to the LOCAL terminal only, so it
-- never reaches the web viewer. Every risky call below is wrapped in
-- plain pcall(fn, ...) so any thrown failure gets caught and reported.
--
-- IMPORTANT: use pcall(fn, ...) directly, NOT a custom wrapper that
-- reshuffles return values (an earlier version of this file had a
-- safeCall() helper that did `return a, b` from `local callOk, a, b =
-- pcall(...)` on success). That's broken for any callback whose own
-- legitimate return value can be nil -- e.g. getInterfacePattern()
-- correctly returns nil (no throw) when a slot is empty. Reshuffling
-- made that indistinguishable from a thrown error, and separately made
-- a *present* item register as "empty" (the real stack ended up in the
-- discarded first slot). pcall's own success flag is always a genuine
-- boolean independent of what the wrapped function returns, so calling
-- it directly avoids the whole class of bug.

-- ── the OC Pattern Editor's own 16-slot inventory slot where you
-- physically placed a blank AE2 pattern item before running this
-- script. Slots are 1-indexed (matches database.set() and most other
-- OC inventory-style APIs).
local EDITOR_SLOT = 1

-- ── clear all input/output indices of the pattern in EDITOR_SLOT
-- before rewriting. Indices are also 1-indexed here (1..512), unlike
-- the old me_interface grid slots which were 0-indexed -- confirmed
-- from DriverOCPatternEditor.java's checkSlot()/setPatternSlot(),
-- which both do "args.checkInteger(n) - 1" and require the result
-- to be >= 0, i.e. the caller must pass 1-based numbers.
-- Returns true if the pattern needs to be "primed" first (see below).
local function clearPattern(maxIn, maxOut)
  local needsPriming = false
  for i=1,maxIn  do
    local ok, err = pcall(editor.clearInterfacePatternInput, EDITOR_SLOT, i)
    if not ok then
      dbg("  [NOTE] clearInterfacePatternInput("..i..") failed: "..tostring(err))
      if tostring(err):find("No pattern here", 1, true) then needsPriming = true end
    end
  end
  for o=1,maxOut do
    local ok, err = pcall(editor.clearInterfacePatternOutput, EDITOR_SLOT, o)
    if not ok then
      dbg("  [NOTE] clearInterfacePatternOutput("..o..") failed: "..tostring(err))
      if tostring(err):find("No pattern here", 1, true) then needsPriming = true end
    end
  end
  return needsPriming
end

-- ── main ──────────────────────────────────────
print("=== Pattern Writer Test (via OC Pattern Editor) ===")

dbg("Checking OC Pattern Editor slot "..EDITOR_SLOT.." for a blank pattern...")
local okChk, existing = pcall(editor.getInterfacePattern, EDITOR_SLOT)
if not okChk then
  dbg("[FAIL] getInterfacePattern failed: "..tostring(existing)); flushDebug("editor-check-fail"); return
end
if not existing then
  dbg("[FAIL] No item in OC Pattern Editor slot "..EDITOR_SLOT..".")
  dbg("       Put one blank AE2 pattern item into its first inventory")
  dbg("       slot in-game, then re-run this script.")
  flushDebug("no-blank-pattern")
  return
end
dbg("[OK] Found an item in slot "..EDITOR_SLOT..": "..tostring(existing.label or existing.name or "?"))

io.write("Exact output item to craft (e.g. minecraft:stick or gregtech:gt.metaitem.01:810): ")
local itemName = io.read()
if not itemName or itemName=="" then print("cancelled"); return end
dbg("target item: "..itemName)

dbg("Looking up recipe from server...")
local encoded = itemName:gsub(":","%%3A")
local raw, err = get("/recipe?item="..encoded)
if not raw then
  dbg("[FAIL] server request failed: "..tostring(err)); flushDebug("recipe-fail"); return
end
if not raw:find('"found":%s*true') then
  dbg("[FAIL] no recipe found for "..itemName); flushDebug("recipe-fail"); return
end

local rtype = extractStr(raw,"type")
dbg("Recipe type: "..tostring(rtype))

local ingredientEntries = {}
if rtype=="crafting_shaped" then
  local grid = extractArr(raw,"grid")
  if not grid then dbg("[FAIL] couldn't parse grid"); flushDebug("parse-fail"); return end
  for i,v in ipairs(grid) do
    if v then ingredientEntries[#ingredientEntries+1] = {index=i, entry=v} end
  end
elseif rtype=="crafting_shapeless" then
  local ing = extractArr(raw,"ingredients")
  if not ing then dbg("[FAIL] couldn't parse ingredients"); flushDebug("parse-fail"); return end
  -- aggregate duplicate entries into counts
  local counts, order = {}, {}
  for _,v in ipairs(ing) do
    if v then
      if not counts[v] then counts[v]=0; order[#order+1]=v end
      counts[v]=counts[v]+1
    end
  end
  for i,v in ipairs(order) do
    ingredientEntries[#ingredientEntries+1] = {index=i, entry=v, count=counts[v]}
  end
else
  dbg("[FAIL] unsupported recipe type: "..tostring(rtype).." (only crafting_shaped/shapeless handled)")
  flushDebug("unsupported-type")
  return
end

dbg(#ingredientEntries.." ingredient slot(s) to resolve:")
local resolved = {}
for _,ie in ipairs(ingredientEntries) do
  dbg("  index "..ie.index..": "..ie.entry)
  local id,dmg = resolveEntry(ie.entry)
  if not id then
    dbg("  [FAIL] could not resolve ingredient: "..ie.entry)
    flushDebug("resolve-fail")
    return
  end
  dbg("    -> writing "..id..":"..dmg.." (count="..(ie.count or 1)..")")
  resolved[#resolved+1] = {index=ie.index, id=id, damage=dmg, count=ie.count or 1}
end
flushDebug("ingredients-resolved")

-- ── clear + rewrite the pattern in the OC Pattern Editor's slot ──
print()
dbg("Clearing pattern in editor slot "..EDITOR_SLOT.."...")
local needsPriming = clearPattern(9, 4)
if needsPriming then
  dbg("")
  dbg("[FAIL] This pattern item has never been encoded before -- it has")
  dbg("       no recipe data yet at all, so the OC Pattern Editor can only")
  dbg("       EDIT an existing pattern's entries, not create one from")
  dbg("       nothing (confirmed: its container has no NBT-init logic).")
  dbg("")
  dbg("       Fix: take this pattern to a real ME Pattern Terminal and")
  dbg("       encode a GENUINELY VALID, real recipe onto it there first --")
  dbg("       e.g. 2 wood planks -> 4 sticks. It must be an actual")
  dbg("       registered recipe, NOT arbitrary items -- AE2's PatternHelper")
  dbg("       sets a permanent 'InvalidPattern' NBT flag the first time a")
  dbg("       pattern fails to parse as a real recipe, and every future")
  dbg("       check (tooltip, getOutput(), crafting) short-circuits on")
  dbg("       that flag BEFORE even looking at current in/out data -- so")
  dbg("       an invalid placeholder poisons the item permanently, and")
  dbg("       our later writes here would succeed at the raw-NBT level")
  dbg("       but stay invisible everywhere else. If this pattern has")
  dbg("       already been through an invalid placeholder, grab a FRESH")
  dbg("       one instead of reusing it.")
  dbg("       Then bring the (validly-primed) pattern back to OC Pattern")
  dbg("       Editor slot "..EDITOR_SLOT.." and re-run this script.")
  dbg("")
  dbg("       This is a ONE-TIME cost per physical pattern item -- once")
  dbg("       validly primed, it can be rewritten by this script indefinitely.")
  flushDebug("needs-priming")
  return
end

dbg("Staging + writing "..#resolved.." input(s)...")
-- NOTE: database upgrade slots are 1-indexed in OC (like most OC
-- inventory-style slot APIs -- robot.select, transposer slots, etc.),
-- NOT 0-indexed. Starting at 0 throws "invalid slot" immediately.
local dbSlot = 1
for _, r in ipairs(resolved) do
  local ok, err2 = pcall(db.set, dbSlot, r.id, r.damage)
  if not ok then
    dbg("[FAIL] database.set failed (slot "..dbSlot.."): "..tostring(err2)); flushDebug("write-fail"); return
  end
  local ok2, err3 = pcall(editor.setInterfacePatternItemInput,
    EDITOR_SLOT, db.address, dbSlot, r.count, r.index)
  if not ok2 then
    dbg("[FAIL] setInterfacePatternItemInput failed (db slot "..dbSlot..", index "..r.index.."): "..tostring(err3)); flushDebug("write-fail"); return
  end
  dbSlot = dbSlot + 1
end

dbg("Staging + writing output...")
local outId, outDmg = splitItemId(itemName)
dbg("  -> writing output "..outId..":"..outDmg)
local ok4, err4 = pcall(db.set, dbSlot, outId, outDmg)
if not ok4 then
  dbg("[FAIL] database.set (output) failed (slot "..dbSlot.."): "..tostring(err4)); flushDebug("write-fail"); return
end
local ok5, err5 = pcall(editor.setInterfacePatternItemOutput,
  EDITOR_SLOT, db.address, dbSlot, 1, 1)
if not ok5 then
  dbg("[FAIL] setInterfacePatternItemOutput failed (slot "..dbSlot.."): "..tostring(err5)); flushDebug("write-fail"); return
end

dbg("[OK] Pattern encoded in OC Pattern Editor slot "..EDITOR_SLOT..".")
print()

-- ── sanity check #1: read the resulting pattern item back ──
-- Uses getInterfacePattern, NOT getInterfaceConfiguration -- see the
-- functional-validity check below for why. getInterfacePattern just
-- returns whatever raw stack is in the slot, no validation gate, so
-- it always succeeds if an item is physically there.
local okFinal, finalStack = pcall(editor.getInterfacePattern, EDITOR_SLOT)
if okFinal and finalStack then
  dbg("[OK] Resulting item in editor slot: "..tostring(finalStack.label or finalStack.name or "?"))
else
  dbg("[WARN] Couldn't read back the encoded pattern: "..tostring(finalStack))
end

-- ── sanity check #2: is this actually a REAL, AE2-recognized recipe? ──
-- Everything above only confirms the raw NBT write didn't throw -- it
-- does NOT confirm AE2 itself considers the result a valid recipe.
-- getInterfaceConfiguration() calls the driver's validPattern(), which
-- calls AE2's own ItemEncodedPattern.getOutput(pattern) -- the SAME
-- check the tooltip and actual crafting use. Confirmed from the real
-- driver source (DriverOCPatternEditor.java, fetched 2026-07-13):
--   private boolean validPattern(ItemStack pattern) {
--     ...
--     return iep.getOutput(pattern) == null;
--   }
-- Two distinct outcomes after a completed write:
--   - throws "Not Fluid Encoded pattern!" -> getOutput() returned a
--     REAL non-null output, i.e. validPattern()==false because the
--     pattern is no longer "blank". This is actually the GOOD outcome!
--     It just means AE2 accepted the recipe, so this editor block
--     won't let itself edit it further (by design). If the item still
--     LOOKS unchanged/wrong in-game after this, that's a client-side
--     tooltip/render staleness issue, not a data problem -- try
--     closing/reopening the block's GUI or re-picking-up the item.
--   - throws anything else (e.g. "No pattern here!") -> getOutput()
--     itself threw inside AE2's PatternHelper, meaning the ingredients
--     we just wrote do NOT form a recipe AE2 recognizes. Given the
--     ordering (this fires ONLY on the post-write check, not during
--     the writes themselves -- see setPatternSlot's validPattern()
--     call, which only checks the PRE-write state), this is either an
--     exact item/damage mismatch (compare the "-> writing X:Y" lines
--     above against the real recipe) or a permanently poisoned pattern
--     from an earlier invalid encode on this same physical item.
dbg("Verifying AE2 actually accepts this as a real recipe...")
local okCfg, cfgErr = pcall(editor.getInterfaceConfiguration, EDITOR_SLOT)
if okCfg then
  dbg("[WARN] getInterfaceConfiguration did not throw -- unexpected.")
  dbg("       Means AE2's getOutput() returned nil, i.e. it thinks this")
  dbg("       pattern STILL has no output, even right after we wrote one.")
elseif tostring(cfgErr):find("Not Fluid Encoded pattern", 1, true) then
  dbg("[OK] Confirmed: AE2 accepts this as a real, matching recipe.")
else
  dbg("[FAIL] AE2 rejected the written pattern: "..tostring(cfgErr))
  dbg("       The raw NBT write above succeeded, but this is NOT a")
  dbg("       recipe AE2 recognizes. Check the resolved id:damage lines")
  dbg("       above against the real recipe exactly (wrong meta/variant")
  dbg("       is the most likely cause), or this physical pattern item")
  dbg("       may already be permanently poisoned from an earlier bad")
  dbg("       encode -- if so, grab a fresh blank pattern and re-prime it.")
end

dbg("")
dbg("=== NEXT STEP (manual, in-game) ===")
dbg("This pattern is encoded but NOT yet live -- it only exists as a")
dbg("physical item sitting in the OC Pattern Editor's inventory. Take")
dbg("it out and place it into a real ME Interface's pattern slots to")
dbg("activate it on your network. After that, "..outId.." should show")
dbg("up in me.getCraftables() / the ME Interface's craftable list.")
flushDebug("pattern-encoded")
