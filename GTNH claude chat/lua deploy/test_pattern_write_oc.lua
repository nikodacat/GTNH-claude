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
if not component.isAvailable("me_controller") then print("[FAIL] no me_controller"); return end
if not component.isAvailable("me_interface") then
  print("[FAIL] no me_interface component found.")
  print("       Connect an OC Adapter to a spare ME Interface block")
  print("       (not wired to any machine -- this one is a pattern buffer).")
  return
end
if not component.isAvailable("database") then
  print("[FAIL] no database component found.")
  print("       Connect an OC Adapter to a Database Upgrade (any tier).")
  return
end

local net = component.internet
local me  = component.me_controller
local iface = component.me_interface
local db  = component.database

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
  print(string.format("  [NOTE] resolved %s -> %s (damage=%d, label=%s, you have %d)",
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

-- ── clear all input/output slots of a pattern before rewriting ──
local function clearPattern(patternIndex, maxIn, maxOut)
  for i=0,maxIn-1  do pcall(iface.clearInterfacePatternInput,  patternIndex, i) end
  for o=0,maxOut-1 do pcall(iface.clearInterfacePatternOutput, patternIndex, o) end
end

-- ── main ──────────────────────────────────────
print("=== Pattern Writer Test ===")
io.write("Exact output item to craft (e.g. minecraft:stick or gregtech:gt.metaitem.01:810): ")
local itemName = io.read()
if not itemName or itemName=="" then print("cancelled"); return end

print("Looking up recipe from server...")
local encoded = itemName:gsub(":","%%3A")
local raw, err = get("/recipe?item="..encoded)
if not raw then print("[FAIL] server request failed: "..tostring(err)); return end
if not raw:find('"found":%s*true') then print("[FAIL] no recipe found for "..itemName); return end

local rtype = extractStr(raw,"type")
print("Recipe type: "..tostring(rtype))

local ingredientEntries = {}
if rtype=="crafting_shaped" then
  local grid = extractArr(raw,"grid")
  if not grid then print("[FAIL] couldn't parse grid"); return end
  for i,v in ipairs(grid) do
    if v then ingredientEntries[#ingredientEntries+1] = {slot=i-1, entry=v} end
  end
elseif rtype=="crafting_shapeless" then
  local ing = extractArr(raw,"ingredients")
  if not ing then print("[FAIL] couldn't parse ingredients"); return end
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
  print("[FAIL] unsupported recipe type: "..tostring(rtype).." (only crafting_shaped/shapeless handled)")
  return
end

print(#ingredientEntries.." ingredient slot(s) to resolve:")
local resolved = {}
for _,ie in ipairs(ingredientEntries) do
  print("  slot "..ie.slot..": "..ie.entry)
  local id,dmg = resolveEntry(ie.entry)
  if not id then
    print("  [FAIL] could not resolve ingredient: "..ie.entry)
    return
  end
  resolved[#resolved+1] = {slot=ie.slot, id=id, damage=dmg, count=ie.count or 1}
end

-- ── write into pattern slot 0 of the buffer interface ──
local PATTERN_INDEX = 0
print()
print("Clearing pattern slot "..PATTERN_INDEX.." on buffer interface...")
clearPattern(PATTERN_INDEX, 9, 4)

print("Staging + writing "..#resolved.." input(s)...")
local dbSlot = 0
for _, r in ipairs(resolved) do
  local ok, err2 = db.set(dbSlot, r.id, r.damage)
  if not ok then print("[FAIL] database.set failed: "..tostring(err2)); return end
  local ok2, err3 = iface.setInterfacePatternInput(PATTERN_INDEX, db.address, dbSlot, r.count, r.slot)
  if not ok2 then print("[FAIL] setInterfacePatternInput failed: "..tostring(err3)); return end
  dbSlot = dbSlot + 1
end

print("Staging + writing output...")
local outId, outDmg = splitItemId(itemName)
local ok4 = db.set(dbSlot, outId, outDmg)
if not ok4 then print("[FAIL] database.set (output) failed"); return end
local ok5, err5 = iface.setInterfacePatternOutput(PATTERN_INDEX, db.address, dbSlot, 1, 0)
if not ok5 then print("[FAIL] setInterfacePat