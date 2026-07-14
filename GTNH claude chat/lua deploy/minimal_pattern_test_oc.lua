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
--  ROOT CAUSE FOUND 2026-07-14 (this is the fixed
--  version): the first attempt at this test wrote
--  "2x minecraft:planks:0" into a SINGLE grid index
--  with count=2. That's wrong. Fetched the real,
--  current source (PatternHelper.java, GTNewHorizons/
--  Applied-Energistics-2-Unofficial) and confirmed
--  Minecraft's own shapeless-recipe matcher checks
--  ONE NON-EMPTY GRID SLOT PER REQUIRED INGREDIENT
--  ENTRY -- it never looks at stack count. Sticks'
--  real recipe has TWO separate "1 plank" ingredient
--  entries, so it needs TWO separate occupied grid
--  slots, each holding 1 plank -- a single slot with
--  a stack of 2 never matches, no matter what count
--  we write. This version writes plank #1 to grid
--  index 1 and plank #2 to grid index 2, both count=1.
--
--  Also confirmed from source: getPatternForItem()
--  catches ALL exceptions from PatternHelper's
--  constructor and returns null instead of letting
--  them propagate -- so getOutput() (which the OC
--  driver's validPattern()/getInterfaceConfiguration
--  rely on) never throws on failure, it just silently
--  returns null. That means getInterfaceConfiguration
--  NOT throwing is the FAILURE signal (pattern has no
--  valid output AE2 recognizes), and it throwing
--  "Not Fluid Encoded pattern!" is actually the SUCCESS
--  signal (AE2 found a real, matching output). This
--  script's final check reflects that corrected
--  understanding.
--
--  Also confirmed: for a crafting-type pattern (which
--  this is, since it was primed as one), whatever we
--  write via setInterfacePatternItemOutput is IGNORED
--  by AE2's validation -- PatternHelper computes the
--  real output itself from the matched recipe
--  (standardRecipe.getCraftingResult(...)), not from
--  our "out" NBT. We still write it (needed for the
--  physical item to display/behave correctly), but it
--  has no bearing on whether the pattern validates.
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

dbg("=== Minimal Pattern Test v2: 2 planks -> 4 sticks ===")
dbg("(fixed: 2 separate 1-plank slots, not 1 slot with count=2)")

local okChk, existing = pcall(editor.getInterfacePattern, SLOT)
if not okChk or not existing then
  dbg("[FAIL] no item in editor slot "..SLOT.." -- put a primed pattern there first.")
  return
end
dbg("[OK] found item in slot "..SLOT..": "..tostring(existing.label or existing.name or "?"))

dbg("Clearing any existing entries first (in case of leftovers from earlier tests)...")
for i=1,9 do pcall(editor.clearInterfacePatternInput, SLOT, i) end
for o=1,4 do pcall(editor.clearInterfacePatternOutput, SLOT, o) end

dbg("Writing input: 1x minecraft:planks:0 at index 1...")
local ok1, e1 = pcall(db.set, 1, "minecraft:planks", 0)
if not ok1 then dbg("[FAIL] db.set (input 1) failed: "..tostring(e1)); return end
local ok2, e2 = pcall(editor.setInterfacePatternItemInput, SLOT, db.address, 1, 1, 1)
if not ok2 then dbg("[FAIL] setInterfacePatternItemInput (index 1) failed: "..tostring(e2)); return end
dbg("[OK] input 1 written.")

dbg("Writing input: 1x minecraft:planks:0 at index 2 (separate slot, not stacked)...")
local ok1b, e1b = pcall(db.set, 2, "minecraft:planks", 0)
if not ok1b then dbg("[FAIL] db.set (input 2) failed: "..tostring(e1b)); return end
local ok2b, e2b = pcall(editor.setInterfacePatternItemInput, SLOT, db.address, 2, 1, 2)
if not ok2b then dbg("[FAIL] setInterfacePatternItemInput (index 2) failed: "..tostring(e2b)); return end
dbg("[OK] input 2 written.")

dbg("Writing output: 4x minecraft:stick:0 at index 1...")
local ok3, e3 = pcall(db.set, 3, "minecraft:stick", 0)
if not ok3 then dbg("[FAIL] db.set (output) failed: "..tostring(e3)); return end
local ok4, e4 = pcall(editor.setInterfacePatternItemOutput, SLOT, db.address, 3, 4, 1)
if not ok4 then dbg("[FAIL] setInterfacePatternItemOutput failed: "..tostring(e4)); return end
dbg("[OK] output written.")

dbg("Verifying AE2 actually accepts this as a real recipe...")
-- getInterfaceConfiguration -> validPattern() -> iep.getOutput(pattern) == null.
-- getOutput() NEVER throws (getPatternForItem catches everything internally
-- and returns null on any failure) -- so the two real outcomes are:
--   - throws "Not Fluid Encoded pattern!" -> getOutput() returned a REAL
--     output -> validPattern()==false -> SUCCESS, AE2 accepted the recipe.
--   - does NOT throw at all -> getOutput() returned null -> validPattern()
--     ==true -> FAILURE, AE2 still doesn't see a valid recipe here.
local okCfg, cfgErr = pcall(editor.getInterfaceConfiguration, SLOT)
if okCfg then
  dbg("[FAIL] getInterfaceConfiguration did NOT throw -- this means AE2's")
  dbg("       getOutput() returned nil, i.e. it still does NOT consider this")
  dbg("       a valid recipe. Something is still wrong with the ingredients")
  dbg("       or this physical pattern item.")
elseif tostring(cfgErr):find("Not Fluid Encoded pattern", 1, true) then
  dbg("[OK] CONFIRMED: AE2 accepts this as a real, valid recipe!")
  dbg("     If the item still looks unchanged in-game, take it out of the")
  dbg("     editor and back in (or reopen the GUI) -- that's a render-cache")
  dbg("     issue, not a data issue, since AE2 itself just confirmed it's valid.")
else
  dbg("[WARN] getInterfaceConfiguration threw something unexpected: "..tostring(cfgErr))
end

dbg("")
dbg("=== Done ===")
