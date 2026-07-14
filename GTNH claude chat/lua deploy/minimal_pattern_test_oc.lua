-- =============================================
--  minimal_pattern_test_oc.lua
--  Absolute minimum procedure to encode one AE2
--  pattern (2 planks -> 4 sticks) via the OC Pattern
--  Editor. No recipe server call, no ore-dict
--  resolution, no ingredient loop -- just the raw
--  API calls, hardcoded, so there's nowhere left for
--  a bug in the surrounding scaffolding to hide.
--
--  Requires:
--    - oc_pattern_editor with an ALREADY-PRIMED
--      pattern (any real recipe, from a real Pattern
--      Terminal) sitting in slot 1
--    - database (any tier)
--
--  Hardcoded recipe: 2x minecraft:planks:0 (oak) ->
--  4x minecraft:stick:0. Real, shapeless, vanilla
--  recipe -- if THIS doesn't validate, the bug is in
--  the OC Pattern Editor mechanism itself (or this
--  physical pattern item), not in anything our other
--  scripts were doing on top of it.
-- =============================================

local component = require("component")
local computer   = require("computer")
local io         = require("io")

local DISK = "/mnt/dc6"
local SCRIPT_NAME = "minimal_pattern_test_oc"

-- optional web logging, best-effort (same pattern as diag_oc.lua) --
local net, SERVER
do
  local f = io.open(DISK.."/config.lua", "r")
  if f then
    f:close()
    local ok, cfg = pcall(dofile, DISK.."/config.lua")
    if ok and type(cfg)=="table" and cfg.SERVER and not cfg.SERVER:find("YOUR_HAMACHI_IP") then
      if component.isAvailable("internet") then net = component.internet; SERVER = cfg.SERVER end
    end
  end
end
local function dbg(text)
  print(text)
  if net then
    local body = '{"role":"diag","text":"['..SCRIPT_NAME..'] '
                 ..tostring(text):gsub('\\','\\\\'):gsub('"','\\"')..'"}'
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
end

if not component.isAvailable("oc_pattern_editor") then dbg("[FAIL] no oc_pattern_editor found."); return end
if not component.isAvailable("database") then dbg("[FAIL] no database found."); return end
local editor = component.oc_pattern_editor
local db = component.database
local SLOT = 1

dbg("=== Minimal Pattern Test: 2 planks -> 4 sticks ===")

local okChk, existing = pcall(editor.getInterfacePattern, SLOT)
if not okChk or not existing then
  dbg("[FAIL] no item in editor slot "..SLOT.." -- put a primed pattern there first.")
  return
end
dbg("[OK] found item in slot "..SLOT..": "..tostring(existing.label or existing.name or "?"))

dbg("Clearing any existing entries first (in case of leftovers from earlier tests)...")
for i=1,9 do pcall(editor.clearInterfacePatternInput, SLOT, i) end
for o=1,4 do pcall(editor.clearInterfacePatternOutput, SLOT, o) end

dbg("Writing input: 2x minecraft:planks:0 at index 1...")
local ok1, e1 = pcall(db.set, 1, "minecraft:planks", 0)
if not ok1 then dbg("[FAIL] db.set (input) failed: "..tostring(e1)); return end
local ok2, e2 = pcall(editor.setInterfacePatternItemInput, SLOT, db.address, 1, 2, 1)
if not ok2 then dbg("[FAIL] setInterfacePatternItemInput failed: "..tostring(e2)); return end
dbg("[OK] input written.")

dbg("Writing output: 4x minecraft:stick:0 at index 1...")
local ok3, e3 = pcall(db.set, 2, "minecraft:stick", 0)
if not ok3 then dbg("[FAIL] db.set (output) failed: "..tostring(e3)); return end
local ok4, e4 = pcall(editor.setInterfacePatternItemOutput, SLOT, db.address, 2, 4, 1)
if not ok4 then dbg("[FAIL] setInterfacePatternItemOutput failed: "..tostring(e4)); return end
dbg("[OK] output written.")

dbg("Verifying AE2 actually accepts this as a real recipe...")
local okCfg, cfgErr = pcall(editor.getInterfaceConfiguration, SLOT)
if okCfg then
  dbg("[WARN] getInterfaceConfiguration did not throw -- unexpected.")
  dbg("       AE2's getOutput() returned nil; it thinks there's still no output set.")
elseif tostring(cfgErr):find("Not Fluid Encoded pattern", 1, true) then
  dbg("[OK] CONFIRMED: AE2 accepts this as a real, valid recipe.")
  dbg("     If the item still looks unchanged in-game, take it out of the")
  dbg("     editor and back in (or reopen the GUI) -- that's a render-cache")
  dbg("     issue, not a data issue, since AE2 itself just confirmed it's valid.")
else
  dbg("[FAIL] AE2 rejected the written pattern: "..tostring(cfgErr))
  dbg("       Since this is the simplest possible real vanilla recipe with")
  dbg("       hardcoded concrete IDs, a rejection here means the issue is")
  dbg("       either this specific physical pattern item (try a totally")
  dbg("       fresh one) or something about the OC Pattern Editor driver")
  dbg("       itself/this GTNH build's version of it -- not our resolution")
  dbg("       or recipe-lookup logic, which isn't involved in this test at all.")
end

dbg("")
dbg("=== Done ===")
