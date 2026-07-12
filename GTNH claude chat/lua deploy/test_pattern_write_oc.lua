-- =============================================
--  test_pattern_write_oc.lua
--  Tests writing an AE2 crafting pattern on the
--  fly, using recipe_db.json data, into a "buffer"
--  ME Interface -- no Pattern Terminal GUI needed.
--
--  Requires (all connected via separate OC Adapters):
--    - me_controller  : your existing full-network link
--    - me_interface   : a spare ME Interface dedicated
--                        as a pattern "buffer" (not wired
--                        to any machine)
--    - database        : a Database Upgrade (any tier)
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

local DISK = "/mnt/e10"   -- where scripts + config live

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

-- ── debug logger (mirrors all output to the web viewer) ───────
local debugLines = {}
local function dbg(text)
  local t = string.format("[%.1fs] %s", computer.uptime(), text)
  print(t)
  debugLines[#debugLines+1] = t
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

if not component.isAvailable("me_controller") then
  dbg("[FAIL] no me_controller"); flushDebug("hw-fail"); return
end
if not component.isAvailable("me_interface") then
  dbg("[FAIL] no me_interface component found.")
  dbg("       Connect an OC Adapter to a spare ME Interface block")
  dbg("       (not wired to any machine -- this one is a pattern buffer).")
  flushDebug("hw-fail")
  return
end
if not component.isAvailable("database") then
  dbg("[FAIL] no database component found.")
  dbg("       Connect an OC Adapter to a Database Upgrade (any tier).")
  flushDebug("hw-fail")
  return
end

local me  = component.me_controller
local iface = component.me_interface
local db  = component.database
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

-- ── safe wrapper: some component methods (e.g. database.set with an
-- out-of-range slot) throw a hard Lua error instead of returning
-- (false, err). An uncaught throw here skips right past our own
-- dbg()/flushDebug() error handling and crashes the whole script --
-- OC's own crash handler prints a traceback to the LOCAL terminal only,
-- so it never reaches the web viewer. Routing every risky call through
-- this wrapper means ANY failure, thrown or returned, gets reported.
local function safeCall(fn, ...)
  local callOk, a, b = pcall(fn, ...)
  if not callOk then
    return false, a  -- a holds the pcall error message
  end
  return a, b
end

-- ── clear all input/output slots of a pattern before rewriting ──
local function clearPattern(patternIndex, maxIn, maxOut)
  for i=0,maxIn-1  do
    local ok, err = safeCall(iface.clearInterfacePatternInput, patternIndex, i)
    if not ok then dbg("  [NOTE] clearInterfacePatternInput("..i..") failed: "..tostring(err)) end
  end
  for o=0,maxOut-1 do
    local ok, err = safeCall(iface.clearInterfacePatternOutput, patternIndex, o)
    if not ok then dbg("  [NOTE] clearInterfacePatternOutput("..o..") failed: "..tostring(err)) end
  end
end

-- ── main ──────────────────────────────────────
print("=== Pattern Writer Test ===")
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
    if v then ingredientEntries[#ingredientEntries+1] = {slot=i-1, entry=v} end
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
    ingredientEntries[#ingredientEntries+1] = {slot=i-1, entry=v, count=counts[v]}
  end
else
  dbg("[FAIL] unsupported recipe type: "..tostring(rtype).." (only crafting_shaped/shapeless handled)")
  flushDebug("unsupported-type")
  return
end

dbg(#ingredientEntries.." ingredient slot(s) to resolve:")
local resolved = {}
for _,ie in ipairs(ingredientEntries) do
  dbg("  slot "..ie.slot..": "..ie.entry)
  local id,dmg = resolveEntry(ie.entry)
  if not id then
    dbg("  [FAIL] could not resolve ingredient: "..ie.entry)
    flushDebug("resolve-fail")
    return
  end
  resolved[#resolved+1] = {slot=ie.slot, id=id, damage=dmg, count=ie.count or 1}
end
flushDebug("ingredients-resolved")

-- ── write into pattern slot 0 of the buffer interface ──
local PATTERN_INDEX = 0
print()
dbg("Clearing pattern slot "..PATTERN_INDEX.." on buffer interface...")
clearPattern(PATTERN_INDEX, 9, 4)

dbg("Staging + writing "..#resolved.." input(s)...")
-- NOTE: database upgrade slots are 1-indexed in OC (like most OC
-- inventory-style slot APIs -- robot.select, transposer slots, etc.),
-- NOT 0-indexed. Starting at 0 throws "invalid slot" immediately.
local dbSlot = 1
for _, r in ipairs(resolved) do
  local ok, err2 = safeCall(db.set, dbSlot, r.id, r.damage)
  if not ok then
    dbg("[FAIL] database.set failed (slot "..dbSlot.."): "..tostring(err2)); flushDebug("write-fail"); return
  end
  local ok2, err3 = safeCall(iface.setInterfacePatternInput, PATTERN_INDEX, db.address, dbSlot, r.count, r.slot)
  if not ok2 then
    dbg("[FAIL] setInterfacePatternInput failed (slot "..dbSlot..", grid "..r.slot.."): "..tostring(err3)); flushDebug("write-fail"); return
  end
  dbSlot = dbSlot + 1
end

dbg("Staging + writing output...")
local outId, outDmg = splitItemId(itemName)
local ok4, err4 = safeCall(db.set, dbSlot, outId, outDmg)
if not ok4 then
  dbg("[FAIL] database.set (output) failed (slot "..dbSlot.."): "..tostring(err4)); flushDebug("write-fail"); return
end
local ok5, err5 = safeCall(iface.setInterfacePatternOutput, PATTERN_INDEX, db.address, dbSlot, 1, 0)
if not ok5 then
  dbg("[FAIL] setInterfacePatternOutput failed (slot "..dbSlot.."): "..tostring(err5)); flushDebug("write-fail"); return
end

dbg("[OK] Pattern written.")
print()

-- ── verify it shows up as craftable ──
dbg("Checking me.getCraftables() for confirmation (may take a moment)...")
os.sleep(1)
local ok6, craftables = pcall(me.getCraftables)
local found = false
if ok6 and craftables then
  for _,c in ipairs(craftables) do
    if c.name==outId then found=true; break end
  end
end
if found then
  dbg("[SUCCESS] "..outId.." now appears in getCraftables().")
else
  dbg("[WARN] "..outId.." not yet showing as craftable.")
  dbg("       Check in-game: does the buffer ME Interface show the")
  dbg("       new pattern in its GUI? Is it connected to the network")
  dbg("       with enough channels, and is a Molecular Assembler or")
  dbg("       Crafting CPU available for the network to use it?")
end
flushDebug("pattern-write-"..(found and "success" or "unconfirmed"))
