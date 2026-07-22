-- =============================================
--  test_pattern_write_direct_oc.lua
--  Tests writing an AE2 crafting pattern DIRECTLY
--  into a real me_interface's own pattern slot --
--  no OC Pattern Editor, no physical pattern item,
--  no priming step.
--
--  WHY THIS EXISTS (read before running):
--  test_pattern_write_oc.lua (the OTHER script in
--  this folder) deliberately went through the OC
--  Pattern Editor block instead of me_interface
--  directly, because me_interface.setInterface-
--  PatternInput/Output() writes NBT straight into a
--  live network pattern slot with NO backing physical
--  item -- the same class of issue GTNH issue #20730
--  covers, and exactly why AE2FluidCraft-Rework's
--  changelog (v1.3.5-gtnh-pre) REMOVED the equivalent
--  method from the OC Pattern Editor: it lets items be
--  fabricated ("spawned") out of thin air with no real
--  pattern item ever existing.
--
--  This script exists anyway because the user manually
--  tested these exact calls in-game (2026-07-22) and
--  confirmed they return `true` with no error, and made
--  an explicit, informed call to use this method for the
--  production on-demand craft loop instead of the OC
--  Pattern Editor route (whose own validation mystery was
--  never solved -- see project history). That said: a
--  call returning `true` has been proven, repeatedly, in
--  this exact project, to NOT mean AE2 actually accepted
--  the result as a real pattern (see test_pattern_write_
--  oc.lua's whole sanity-check-#2 section and the several
--  false-positive bugs documented alongside it). So THIS
--  script adds the one check none of the earlier scripts
--  ever got to: after writing, it queries
--  me_controller.getCraftables() and reports whether the
--  output item genuinely shows up as craftable -- that is
--  the actual proof, not the write calls' own return value.
--
--  Requires (all connected via separate OC Adapters,
--  or directly adjacent to the computer):
--    - me_controller : your existing full-network link
--                      (resolves ore: tags, and is THE
--                      real validation check at the end)
--    - me_interface   : the actual ME Interface block whose
--                      pattern slot you're overwriting.
--                      IMPORTANT: point this at a spare/
--                      test interface, or a slot you don't
--                      mind clearing -- unlike the OC
--                      Pattern Editor route (which only
--                      ever edits a spare physical item),
--                      this writes straight into a live
--                      slot with nothing to protect an
--                      existing real pattern there.
--    - database       : a Database Upgrade (any tier)
--
--  IMPORTANT CAVEAT discovered from recipe_db.json:
--  many "grid"/"ingredients" entries are OreDictionary
--  tags (e.g. "ore:dustRedstone"), not concrete item
--  IDs. AE2 patterns need a CONCRETE item+damage, so
--  this script resolves ore: tags via the server's
--  /oredict endpoint -- an authoritative table built
--  from a real /mt oredicts dump (ore_dict.json), not a
--  fuzzy label search. Among the tag's real candidate
--  items, it picks whichever one you currently have the
--  most of in your ME network (falling back to the
--  table's first candidate if you have none in stock).
--  It prints a NOTE line for every ore: resolution so you
--  can sanity-check it -- the craft will request exactly
--  the item printed there.
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
local SCRIPT_NAME = "test_pattern_write_direct_oc"
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
if not component.isAvailable("me_interface") then
  dbg("[FAIL] no me_interface component found.")
  dbg("       Connect an OC Adapter to (or place directly adjacent to)")
  dbg("       the ME Interface whose pattern slot you want to overwrite.")
  flushDebug("hw-fail")
  return
end
if not component.isAvailable("database") then
  dbg("[FAIL] no database component found.")
  dbg("       Connect an OC Adapter to a Database Upgrade (any tier).")
  flushDebug("hw-fail")
  return
end

local me   = component.me_controller
local mei  = component.me_interface
local db   = component.database
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

-- ── resolve an ore:xxx tag to a concrete item via the authoritative
-- ore_dict.json table on the server (built from a real /mt oredicts dump),
-- instead of fuzzy-matching item labels/names in the live ME network. The
-- old word-matching approach could pick a same-word-but-wrong item (e.g.
-- "dust" matching any item whose label happens to contain "dust", not
-- necessarily a real member of the ore:xxx tag). The candidate SET now
-- comes from the real OreDictionary registration; the live network is only
-- consulted afterward, to break ties among the (already-correct)
-- candidates by picking whichever one you actually have the most of.
local function resolveOreTag(tag)
  local encoded = tag:gsub(":", "%%3A")
  local raw, err = get("/oredict?tag="..encoded)
  if not raw then return nil, "oredict lookup failed: "..tostring(err) end
  if not raw:find('"found":%s*true') then
    return nil, "no oredict entries for "..tag.." (tag not in ore_dict.json)"
  end

  local entries = extractArr(raw, "entries")
  if not entries or #entries == 0 then
    return nil, "oredict lookup returned no entries for "..tag
  end

  -- index live network stock by "id:damage" for quick lookup per candidate
  local ok, items = pcall(me.getItemsInNetwork, {})
  local stockByKey = {}
  if ok and items then
    for _, it in ipairs(items) do
      stockByKey[(it.name or "")..":"..tostring(it.damage or 0)] = it
    end
  end

  -- pick the candidate you have the most of; if you have none of any
  -- candidate in stock, fall back to the first one in the table (still a
  -- real, correct member of the tag -- just nothing to prefer among them)
  local bestId, bestDmg, bestStock, bestSize = nil, nil, nil, -1
  for _, e in ipairs(entries) do
    -- e is "modid:name:meta" or "modid:name:*" (wildcard -> treated as
    -- damage 0 here, since a single AE2 pattern slot needs one concrete
    -- damage value -- splitItemId's tonumber("*") is nil, defaulting to 0)
    local id, dmg = splitItemId(e)
    local stocked = stockByKey[id..":"..tostring(dmg)]
    local size = stocked and (stocked.size or 0) or 0
    if size > bestSize then
      bestId, bestDmg, bestStock, bestSize = id, dmg, stocked, size
    end
  end

  if not bestId then return nil, "no candidates resolved for "..tag end
  if bestSize > 0 then
    dbg(string.format("  [NOTE] resolved %s -> %s:%d (from ore_dict.json, label=%s, you have %d)",
      tag, bestId, bestDmg, (bestStock and bestStock.label) or "?", bestSize))
  else
    dbg(string.format("  [NOTE] resolved %s -> %s:%d (from ore_dict.json, none currently in stock -- using first candidate)",
      tag, bestId, bestDmg))
  end
  return bestId, bestDmg
end

local function resolveEntry(entry)
  if entry:sub(1,4)=="ore:" then
    return resolveOreTag(entry)
  else
    local id,dmg = splitItemId(entry)
    return id,dmg
  end
end

-- ── on wrapping risky calls: some component methods throw a hard Lua
-- error instead of returning (false, err). An uncaught throw skips right
-- past our own dbg()/flushDebug() error handling and crashes the whole
-- script -- OC's own crash handler prints a traceback to the LOCAL
-- terminal only, so it never reaches the web viewer. Every risky call
-- below is wrapped in plain pcall(fn, ...) so any thrown failure gets
-- caught and reported.
--
-- IMPORTANT: use pcall(fn, ...) directly, NOT a custom wrapper that
-- reshuffles return values -- see test_pattern_write_oc.lua's own comment
-- on this (the old safeCall() bug) for the full story. pcall's own
-- success flag is always a genuine boolean independent of what the
-- wrapped function returns, so calling it directly avoids that whole
-- class of bug.

-- ── the target me_interface's own pattern slot to overwrite. Confirmed
-- 1-indexed in-game (2026-07-22): the user's manual test used
-- setInterfacePatternInput(1, dbAddr, dbSlot, count, inputIndex) and
-- storeInterfacePatternInput(1, 2, dbAddr, dbSlot) successfully, i.e.
-- both patternIndex and inputIndex start at 1 here, not 0 -- unlike the
-- OC Pattern Editor route (1-indexed slot, but 0-indexed old me_interface
-- GRID slots, a different and older API surface entirely).
local PATTERN_INDEX = 1

-- ── clear whatever is currently in PATTERN_INDEX before rewriting.
-- Tolerant of errors either way (an already-empty slot may or may not
-- throw depending on this API's exact behavior -- pcall absorbs either).
-- Unlike the OC Pattern Editor route, there is no "needs priming" concept
-- here: this API writes NBT directly into the live slot with no backing
-- physical item, so there's nothing that needs to pre-exist first. That
-- ease of use is exactly what makes this route the fabrication-exploit
-- concern described at the top of this file -- keep PATTERN_INDEX pointed
-- at a slot you don't mind blowing away.
local function clearPattern(maxIn, maxOut)
  for i=1,maxIn do
    local ok, err = pcall(mei.clearInterfacePatternInput, PATTERN_INDEX, i)
    if not ok then
      dbg("  [NOTE] clearInterfacePatternInput("..i..") failed: "..tostring(err))
    end
  end
  for o=1,maxOut do
    local ok, err = pcall(mei.clearInterfacePatternOutput, PATTERN_INDEX, o)
    if not ok then
      dbg("  [NOTE] clearInterfacePatternOutput("..o..") failed: "..tostring(err))
    end
  end
end

-- ── main ──────────────────────────────────────
print("=== Pattern Writer Test (DIRECT me_interface write) ===")
dbg("Target: me_interface pattern slot "..PATTERN_INDEX.." (direct write -- see file header)")

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
  -- one grid index PER occurrence (count=1 each) -- do NOT aggregate
  -- duplicates into one slot with a count>1, that's a real, confirmed
  -- bug elsewhere in this project's history (Minecraft's shapeless
  -- matcher checks one non-empty slot per required ingredient, not
  -- stack size -- see test_pattern_write_oc.lua's project memory notes)
  for i,v in ipairs(ing) do
    if v then ingredientEntries[#ingredientEntries+1] = {index=i, entry=v} end
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

-- ── clear + rewrite the pattern directly on the live me_interface ──
print()
dbg("Clearing pattern slot "..PATTERN_INDEX.." on the me_interface...")
clearPattern(9, 4)

dbg("Staging + writing "..#resolved.." input(s)...")
-- NOTE: database upgrade slots are 1-indexed in OC (like most OC
-- inventory-style slot APIs -- robot.select, transposer slots, etc.).
local dbSlot = 1
for _, r in ipairs(resolved) do
  local ok, err2 = pcall(db.set, dbSlot, r.id, r.damage)
  if not ok then
    dbg("[FAIL] database.set failed (slot "..dbSlot.."): "..tostring(err2)); flushDebug("write-fail"); return
  end
  -- setInterfacePatternInput(patternIndex, dbAddress, dbIndex, count, inputIndex)
  -- -- confirmed signature order + 1-based indices from the user's own
  -- in-game test (2026-07-22): setInterfacePatternInput(1,datadd,1,1,1)
  local ok2, err3 = pcall(mei.setInterfacePatternInput,
    PATTERN_INDEX, db.address, dbSlot, r.count, r.index)
  if not ok2 then
    dbg("[FAIL] setInterfacePatternInput failed (db slot "..dbSlot..", index "..r.index.."): "..tostring(err3)); flushDebug("write-fail"); return
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
-- setInterfacePatternOutput(patternIndex, dbAddress, dbIndex, count, outputIndex)
local ok5, err5 = pcall(mei.setInterfacePatternOutput,
  PATTERN_INDEX, db.address, dbSlot, 1, 1)
if not ok5 then
  dbg("[FAIL] setInterfacePatternOutput failed (slot "..dbSlot.."): "..tostring(err5)); flushDebug("write-fail"); return
end

dbg("[OK] setInterfacePatternInput/Output calls all returned true (slot "..PATTERN_INDEX..").")
dbg("     Per this project's history, that alone does NOT confirm AE2 accepted")
dbg("     this as a real pattern -- see the getCraftables() check below for that.")
print()

-- ── sanity check #1: read the raw pattern back ──
-- getInterfacePattern just returns whatever's in the slot, no validation
-- gate -- so it can succeed even for a pattern AE2 doesn't consider real.
local okFinal, finalPattern = pcall(mei.getInterfacePattern, PATTERN_INDEX)
if okFinal and finalPattern then
  local nIn  = finalPattern.inputs  and #finalPattern.inputs  or 0
  local nOut = finalPattern.outputs and #finalPattern.outputs or 0
  dbg(string.format("[OK] Raw readback: pattern slot %d now has %d input slot(s), %d output slot(s).",
    PATTERN_INDEX, nIn, nOut))
else
  dbg("[WARN] Couldn't read back the pattern: "..tostring(finalPattern))
end

-- ── sanity check #2 (THE ONE THAT ACTUALLY MATTERS): does the output
-- item genuinely show up in me_controller.getCraftables()? This is the
-- real, independent, network-level proof -- not the raw write calls'
-- own return value, which every earlier script in this project could
-- already get to `true`/[OK] without the pattern being real. If this
-- reports FAIL, do not trust the "someone tested it and it works" claim
-- any further without this check passing.
dbg("")
dbg("Checking me_controller.getCraftables() for "..outId..":"..outDmg.." ...")
local okCraft, craftables = pcall(me.getCraftables, {})
if not okCraft or not craftables then
  dbg("[WARN] getCraftables() call failed: "..tostring(craftables))
  dbg("       Cannot confirm validity this way -- check in-game manually")
  dbg("       (open the ME Interface's pattern slot and look at its tooltip,")
  dbg("       or check whether "..outId.." is requestable from a terminal).")
else
  local found = nil
  for _, c in ipairs(craftables) do
    local okStack, stack = pcall(c.getItemStack)
    if okStack and stack and stack.name == outId and (stack.damage or 0) == outDmg then
      found = stack
      break
    end
  end
  if found then
    dbg("[OK] CONFIRMED: "..outId..":"..outDmg.." now appears in me.getCraftables().")
    dbg("     This is real, independent proof AE2 accepted the pattern --")
    dbg("     not just that the write calls above returned true.")
  else
    dbg("[FAIL] "..outId..":"..outDmg.." does NOT appear in me.getCraftables().")
    dbg("       The write calls above all returned true, but per this project's")
    dbg("       whole history that has never meant AE2 accepted the pattern --")
    dbg("       this check is the actual test, and right now it says no.")
    dbg("       Possible causes: wrong item/damage in one of the resolved")
    dbg("       ingredients (double-check the '-> writing X:Y' lines above")
    dbg("       against the real recipe), or this direct-write API genuinely")
    dbg("       doesn't produce a network-recognized pattern the way the")
    dbg("       in-game console test suggested (recall: that test only")
    dbg("       showed the calls returning true, same gap as here).")
  end
end

flushDebug("pattern-write-complete")
