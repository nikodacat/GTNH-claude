-- =============================================
--  minimal_pattern_test_oc.lua
--  Absolute minimum procedure to encode one AE2
--  pattern (2 planks -> 2 sticks, GTNH's actual
--  ratio) via the OC Pattern Editor. No recipe
--  server call, no ore-dict resolution, no
--  ingredient loop -- just the raw API calls,
--  hardcoded, so there's nowhere left for a bug in
--  the surrounding scaffolding to hide.
--
--  Requires:
--    - oc_pattern_editor with an ALREADY-PRIMED
--      pattern (any real recipe, from a real Pattern
--      Terminal) sitting in slot 1 -- and it MUST be
--      a pattern that has never failed to validate
--      before (see poisoning note below). If in doubt,
--      grab a completely FRESH blank pattern.
--    - database (any tier)
--
--  ROOT CAUSE FOUND 2026-07-14, v2: the first attempt
--  wrote "2x minecraft:planks:0" into a SINGLE grid
--  index with count=2. Wrong -- Minecraft's shapeless
--  matcher checks one non-empty grid slot per required
--  ingredient entry, never stack count. v2 fixed this
--  (2 separate 1-plank slots) but STILL failed --
--  because v1's failed match already permanently
--  poisoned that physical pattern item.
--
--  ROOT CAUSE, v3 (this version): fetched the real
--  source (PatternHelper.java, GTNewHorizons/Applied-
--  Energistics-2-Unofficial). Its constructor's very
--  FIRST check is:
--    if (nbt == null || nbt.getBoolean("InvalidPattern"))
--      throw new IllegalArgumentException("No pattern here!");
--  Any failed match sets nbt.setBoolean("InvalidPattern", true)
--  PERMANENTLY on that physical item's NBT -- and nothing
--  in the OC Pattern Editor driver ever clears it. Every
--  future attempt on that SAME item -- even a perfectly
--  correct one -- gets silently rejected before AE2 even
--  looks at the current in/out data. If v2 failed using
--  the same physical pattern item that v1 already ran
--  against, this is almost certainly why: v1's broken
--  arrangement poisoned it on its very first run.
--
--  FIX: this script cannot detect or clear that flag
--  (nothing in the OC API exposes it) -- the only fix is
--  a genuinely FRESH pattern item that has never failed
--  a match before. Re-prime a brand new blank pattern at
--  a real Pattern Terminal with a real recipe (anything
--  that actually works, e.g. 2 planks -> 2 sticks itself)
--  before running this.
--
--  Also confirmed from source: getPatternForItem() catches
--  ALL exceptions from PatternHelper's constructor and
--  returns null instead of propagating -- so getOutput()
--  (which validPattern()/getInterfaceConfiguration rely on)
--  never throws on failure, it just returns null silently.
--  getInterfaceConfiguration NOT throwing = FAILURE (no
--  valid recipe found). It throwing "Not Fluid Encoded
--  pattern!" = SUCCESS (AE2 found a real match).
--
--  Also confirmed: for a crafting-type pattern, whatever
--  we write via setInterfacePatternItemOutput is IGNORED
--  by validation -- PatternHelper computes the real output
--  itself from the matched recipe. We still write it (so
--  the physical item displays/behaves correctly), but it
--  has zero bearing on whether the pattern validates. This
--  version writes 2 sticks (GTNH's real ratio) instead of
--  vanilla's 4, purely for display accuracy.
-- =============================================

local component = require("component")
local computer   = require("computer")
local io         = require("io")

local DISK = "/home"   -- was /mnt/dc6 -- moved to /home, stable across disk swaps
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

-- ── buffered logging: collect every line, send ONE consolidated post
-- at the end (or at meaningful checkpoints), instead of firing an
-- individual HTTP request per line -- that was cluttering the web
-- viewer with dozens of separate single-line cards. ──
local debugLines = {}
local function dbg(text)
  print(text)
  debugLines[#debugLines+1] = text
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

if not component.isAvailable("oc_pattern_editor") then dbg("[FAIL] no oc_pattern_editor found."); flushDebug("hw-fail"); return end
if not component.isAvailable("database") then dbg("[FAIL] no database found."); flushDebug("hw-fail"); return end
local editor = component.oc_pattern_editor
local db = component.database
local SLOT = 1

dbg("=== Minimal Pattern Test v3: 2 planks -> 2 sticks (GTNH ratio) ===")
dbg("If this still fails, the pattern item itself is likely poisoned")
dbg("from an earlier failed attempt -- try a completely FRESH one.")

local okChk, existing = pcall(editor.getInterfacePattern, SLOT)
if not okChk or not existing then
  dbg("[FAIL] no item in editor slot "..SLOT.." -- put a primed pattern there first.")
  flushDebug("no-blank-pattern")
  return
end
dbg("[OK] found item in slot "..SLOT..": "..tostring(existing.label or existing.name or "?"))

dbg("Checking whether this pattern is editable BEFORE clearing (diagnostic)...")
-- Log the exact outcome of getInterfaceConfiguration on the UNTOUCHED,
-- freshly-primed pattern, before we touch anything. This tells us what
-- validPattern() actually returns for a pattern we believe has a real,
-- valid recipe already on it -- if it's ALREADY "did not throw" here,
-- that's a strong signal something about getOutput()/world-context is
-- not behaving the way the AE2 source implies it should in this exact
-- runtime, rather than anything about our own clear/write logic.
local okPre, errPre = pcall(editor.getInterfaceConfiguration, SLOT)
if okPre then
  dbg("  [PRE-CHECK] getInterfaceConfiguration did NOT throw on the untouched")
  dbg("              pattern -- AE2 already sees no valid output here, BEFORE")
  dbg("              we've cleared or written anything.")
else
  dbg("  [PRE-CHECK] getInterfaceConfiguration threw: "..tostring(errPre))
end

dbg("Clearing any existing entries (logging each result, not discarding)...")
for i=1,9 do
  local ok, err = pcall(editor.clearInterfacePatternInput, SLOT, i)
  if not ok then dbg("  clearInput("..i..") failed: "..tostring(err)) end
end
for o=1,4 do
  local ok, err = pcall(editor.clearInterfacePatternOutput, SLOT, o)
  if not ok then dbg("  clearOutput("..o..") failed: "..tostring(err)) end
end

dbg("Writing input: 1x minecraft:planks:0 at index 1...")
local ok1, e1 = pcall(db.set, 1, "minecraft:planks", 0)
if not ok1 then dbg("[FAIL] db.set (input 1) failed: "..tostring(e1)); flushDebug("write-fail"); return end
local ok2, e2 = pcall(editor.setInterfacePatternItemInput, SLOT, db.address, 1, 1, 1)
if not ok2 then dbg("[FAIL] setInterfacePatternItemInput (index 1) failed: "..tostring(e2)); flushDebug("write-fail"); return end
dbg("[OK] input 1 written.")

dbg("Writing input: 1x minecraft:planks:0 at index 2 (separate slot, not stacked)...")
local ok1b, e1b = pcall(db.set, 2, "minecraft:planks", 0)
if not ok1b then dbg("[FAIL] db.set (input 2) failed: "..tostring(e1b)); flushDebug("write-fail"); return end
local ok2b, e2b = pcall(editor.setInterfacePatternItemInput, SLOT, db.address, 2, 1, 2)
if not ok2b then dbg("[FAIL] setInterfacePatternItemInput (index 2) failed: "..tostring(e2b)); flushDebug("write-fail"); return end
dbg("[OK] input 2 written.")

-- mid-point diagnostic: check BEFORE writing output, so we can tell
-- whether the recipe is already recognized from inputs alone (crafting-
-- type patterns don't need a written output for findMatchingRecipe to
-- succeed -- the output write is purely cosmetic per the header notes).
local okMid, errMid = pcall(editor.getInterfaceConfiguration, SLOT)
if okMid then
  dbg("  [MID-CHECK] did NOT throw -- still no valid output recognized")
  dbg("              with just the 2 planks written (before output write).")
else
  dbg("  [MID-CHECK] threw: "..tostring(errMid))
end

dbg("Writing output: 2x minecraft:stick:0 at index 1 (GTNH ratio, display only)...")
local ok3, e3 = pcall(db.set, 3, "minecraft:stick", 0)
if not ok3 then dbg("[FAIL] db.set (output) failed: "..tostring(e3)); flushDebug("write-fail"); return end
local ok4, e4 = pcall(editor.setInterfacePatternItemOutput, SLOT, db.address, 3, 2, 1)
if not ok4 then dbg("[FAIL] setInterfacePatternItemOutput failed: "..tostring(e4)); flushDebug("write-fail"); return end
dbg("[OK] output written.")

dbg("Verifying AE2 actually accepts this as a real recipe...")
-- getInterfaceConfiguration -> validPattern() -> iep.getOutput(pattern) == null.
-- getOutput() NEVER throws (getPatternForItem catches everything internally
-- and returns null on any failure) -- so the two real outcomes are:
--   - throws "Not Fluid Encoded pattern!" -> getOutput() returned a REAL
--     output -> validPattern()==false -> SUCCESS, AE2 accepted the recipe.
--   - does NOT throw at all -> getOutput() returned null -> validPattern()
--     ==true -> FAILURE, AE2 still doesn't see a valid recipe here (this
--     is also what happens if the item is InvalidPattern-poisoned from an
--     earlier failed attempt -- see header comment).
local okCfg, cfgErr = pcall(editor.getInterfaceConfiguration, SLOT)
if okCfg then
  dbg("[FAIL] getInterfaceConfiguration did NOT throw -- AE2's getOutput()")
  dbg("       returned nil, i.e. it still does NOT consider this a valid")
  dbg("       recipe. If this same pattern item was used in an earlier")
  dbg("       failed test, it's very likely permanently poisoned (see")
  dbg("       header comment) -- grab a genuinely FRESH pattern, prime it")
  dbg("       at a real Pattern Terminal with a real recipe, and retry.")
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
flushDebug("minimal-test-done")
