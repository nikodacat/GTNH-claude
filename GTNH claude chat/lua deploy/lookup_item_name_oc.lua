-- =============================================
--  lookup_item_name_oc.lua
--  Translates a raw modid:name:meta into its
--  human-readable label, using your own ME
--  network as the source of truth (checks both
--  stored items and known craftables).
-- =============================================

local component = require("component")
local computer  = require("computer")

local DISK = "/mnt/e10"
local SCRIPT_NAME = "lookup_item_name_oc"

-- ── optional remote logging (best-effort) ──────
local net, SERVER
do
  local f = io.open(DISK.."/config.lua", "r")
  if f then
    f:close()
    local ok, cfg = pcall(dofile, DISK.."/config.lua")
    if ok and type(cfg)=="table" and cfg.SERVER and not cfg.SERVER:find("YOUR_HAMACHI_IP") then
      if component.isAvailable("internet") then
        net = component.internet
        SERVER = cfg.SERVER
      end
    end
  end
end

-- ── crash-resistant local log file ─────────────
-- Written unconditionally (doesn't need SERVER) so a hard crash still
-- leaves a trail on disk; auto-recovered and pushed to the web the
-- *next* time this script starts, if a server is configured by then.
local LOG_FILE = DISK.."/oc_log_"..SCRIPT_NAME..".txt"

local debugLines = {}
local function dbg(text)
  print(text)
  debugLines[#debugLines+1] = text
  local lf = io.open(LOG_FILE, "a")
  if lf then lf:write(text.."\n"); lf:close() end
end
local function flushDebug(label)
  if not net or #debugLines == 0 then debugLines = {}; return end
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
local function recoverPreviousLog()
  local f = io.open(LOG_FILE, "r")
  if not f then return end
  local prev = f:read("*a")
  f:close()
  local wf = io.open(LOG_FILE, "w")
  if wf then wf:close() end
  if not prev or prev == "" or not net then return end
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
local me = component.me_controller

io.write("Item id (e.g. gregtech:gt.metaitem.01:2381): ")
local input = io.read()
if not input or input=="" then print("cancelled"); return end
dbg("looking up: "..input)

local parts={}
for p in input:gmatch("[^:]+") do parts[#parts+1]=p end
local id, dmg
if #parts>=3 then id=parts[1]..":"..parts[2]; dmg=tonumber(parts[3]) or 0
elseif #parts==2 then id=parts[1]..":"..parts[2]; dmg=0
else
  dbg("[FAIL] couldn't parse id"); flushDebug("parse-fail"); return
end

dbg("Searching stored items...")
local ok1, items = pcall(me.getItemsInNetwork, {})
local found = false
if ok1 and items then
  for _, it in ipairs(items) do
    if it.name==id and (it.damage or 0)==dmg then
      dbg(string.format("[FOUND in storage] %s:%d = \"%s\"  (you have %d)",
        id, dmg, it.label or "?", it.size or 0))
      found = true
    end
  end
end

dbg("Searching craftables...")
local ok2, craftables = pcall(me.getCraftables)
if ok2 and craftables then
  for _, c in ipairs(craftables) do
    local ok3, stack = pcall(c.getItemStack)
    if ok3 and stack and stack.name==id and (stack.damage or 0)==dmg then
      dbg(string.format("[FOUND in craftables] %s:%d = \"%s\"",
        id, dmg, stack.label or "?"))
      found = true
    end
  end
end

if not found then
  dbg("[NOT FOUND] Item isn't currently stored or craftable in your network.")
  dbg("            Try holding one and checking NEI/JEI's tooltip instead,")
  dbg("            or if you have it in a chest, scan it with an")
  dbg("            Inventory Controller adapter.")
end
flushDebug("lookup-"..(found and "found" or "not-found"))
