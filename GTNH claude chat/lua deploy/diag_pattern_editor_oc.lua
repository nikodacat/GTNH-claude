-- =============================================
--  diag_pattern_editor_oc.lua
--  Diagnoses why test_pattern_write_oc.lua reports
--  "No item in OC Pattern Editor slot 1" even after
--  the block's inventory has been filled in-game.
--
--  Reports:
--    - how many oc_pattern_editor components exist
--      (in case more than one is nearby -- component.
--      oc_pattern_editor picks ONE arbitrarily, which
--      may not be the block you actually filled)
--    - the address of the one this script is bound to
--    - the contents of ALL 16 of its internal slots
--      (not just slot 1), so you can see whether items
--      are sitting in a different slot than expected,
--      or whether this component sees no items at all
--      (which would point to a wrong/duplicate block).
-- =============================================

local component = require("component")
local computer  = require("computer")

local DISK = "/mnt/dc6"
local SCRIPT_NAME = "diag_pattern_editor_oc"

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

dbg("=== OC Pattern Editor Diagnostic ===")

if not component.isAvailable("oc_pattern_editor") then
  dbg("[FAIL] no oc_pattern_editor component found at all.")
  dbg("       Is the OC Adapter actually touching the OC Pattern")
  dbg("       Editor block's face (not a different block)?")
  flushDebug("hw-fail")
  return
end

-- ── count how many oc_pattern_editor components exist ──
local count, addrs = 0, {}
for addr, ctype in component.list("oc_pattern_editor") do
  count = count + 1
  addrs[#addrs+1] = addr
end
dbg(string.format("Found %d oc_pattern_editor component(s):", count))
for i, a in ipairs(addrs) do
  dbg("  ["..i.."] "..a)
end
if count > 1 then
  dbg("[WARN] More than one found! component.oc_pattern_editor picks")
  dbg("       ONE of these arbitrarily -- it may not be the block you")
  dbg("       filled in-game. Consider component.proxy(address) with")
  dbg("       the specific address you actually want, once you know")
  dbg("       which one it should be.")
end

local editor = component.oc_pattern_editor
dbg("Bound to address: "..tostring(editor.address))
print()

-- ── scan all 16 slots ──
-- Uses plain pcall(), NOT a wrapper that reshuffles return values -- a
-- prior version here used a safeCall() helper that treated the wrapped
-- function's OWN first return value as a success flag. That's wrong for
-- getInterfacePattern(): it legitimately returns nil (no throw, valid
-- call) when a slot is empty, and a real stack table when one isn't.
-- Shoving that single nullable return through an (ok, data) reshuffle
-- meant: empty slots (fn returns nil) looked like a THROWN error ("ok"
-- ended up nil/falsy), while slots WITH an item (fn returns a table)
-- looked like an empty slot ("ok" absorbed the table, "data" was left
-- nil). Plain pcall(fn, ...) doesn't have this problem -- its own
-- success flag is completely independent of whatever fn itself returns,
-- including a legitimate nil.
dbg("Scanning all 16 internal slots...")
local anyFound = false
for i = 1, 16 do
  local pOk, stack = pcall(editor.getInterfacePattern, i)
  if not pOk then
    dbg(string.format("  slot %2d: [ERROR] %s", i, tostring(stack)))
  elseif not stack then
    dbg(string.format("  slot %2d: (empty)", i))
  else
    anyFound = true
    dbg(string.format("  slot %2d: %s  (name=%s, size=%s, damage=%s)",
      i,
      tostring(stack.label or "?"),
      tostring(stack.name or "?"),
      tostring(stack.size or "?"),
      tostring(stack.damage or "?")))
  end
end

print()
if anyFound then
  dbg("[OK] At least one slot has an item -- see above for which one(s).")
  dbg("     If slot 1 is empty but others aren't, that's just a slot-")
  dbg("     number mismatch (easy fix: point EDITOR_SLOT at the right")
  dbg("     slot in test_pattern_write_oc.lua, or move the item to")
  dbg("     slot 1 in-game).")
else
  dbg("[WARN] ALL 16 slots read as empty on this component, even though")
  dbg("       you filled the block in-game. Most likely explanations:")
  dbg("       1) This computer is bound (via Adapter or direct contact)")
  dbg("          to a DIFFERENT oc_pattern_editor block than the one")
  dbg("          you opened/filled -- check the component count above.")
  dbg("       2) You filled the block's GUI, but some GUIs also show")
  dbg("          your player inventory alongside the block's own 16")
  dbg("          slots -- double check the items actually left your")
  dbg("          inventory and are sitting IN the block, not just")
  dbg("          displayed next to it.")
end

flushDebug("scan-done")
