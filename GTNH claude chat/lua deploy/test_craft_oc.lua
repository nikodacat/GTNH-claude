-- =============================================
--  test_craft_oc.lua
--  Minimal standalone AE2 autocraft test.
--  Bypasses the Claude/chat/recipe-DB pipeline
--  entirely so you can confirm target.request()
--  actually works before trusting craft_oc.lua.
-- =============================================

local component = require("component")
local computer  = require("computer")

local DISK = "/mnt/e10"
local SCRIPT_NAME = "test_craft_oc"

-- ── optional remote logging (best-effort, never blocks the test) ──
-- If config.lua + an internet card are present, mirror output to the
-- web viewer. If not, this script still works exactly as before --
-- it's a standalone AE2 test and shouldn't require the server.
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

if not component.isAvailable("me_controller") then
  dbg("[FAIL] No me_controller component."); flushDebug("hw-fail"); return
end
local me = component.me_controller

dbg("=== AE2 Craftables ===")
local ok, craftables = pcall(me.getCraftables)
if not ok or not craftables then
  dbg("[FAIL] getCraftables() failed: "..tostring(craftables)); flushDebug("hw-fail"); return
end
dbg("Found "..#craftables.." craftable pattern(s).")
print()
print("Listing all craftable item names (may scroll off-screen):")
for i, c in ipairs(craftables) do
  print(string.format("  [%d] %s", i, c.name or "?"))
end
flushDebug("craftables-list")

print()
io.write("Enter EXACT item name to test-craft (e.g. minecraft:stick): ")
local itemName = io.read()
if not itemName or itemName == "" then print("Cancelled."); return end

io.write("Amount to craft (default 1): ")
local amtStr = io.read()
local amount = tonumber(amtStr) or 1

local target = nil
for _, c in ipairs(craftables) do
  if c.name == itemName then target = c; break end
end
if not target then
  dbg("[FAIL] No craftable pattern found for exact name: "..itemName)
  dbg("       Check spelling/case against the list above --")
  dbg("       this is the #1 cause of silent 'explain' fallback.")
  flushDebug("no-pattern")
  return
end

dbg("[OK] Pattern found. Requesting "..amount.."x "..itemName.."...")
local ok2, job = pcall(function() return target.request(amount) end)
if not ok2 then
  dbg("[FAIL] request() threw: "..tostring(job)); flushDebug("request-fail"); return
end
dbg("[OK] Job submitted. Polling (up to 60s)...")
flushDebug("job-submitted")

local deadline = computer.uptime() + 60
while computer.uptime() < deadline do
  os.sleep(1)
  io.write(".")
  local ok3, done = pcall(function() return job.isDone() end)
  local ok4, cancelled = pcall(function() return job.isCanceled() end)
  if ok3 and done then
    print(); dbg("[SUCCESS] Craft finished."); flushDebug("craft-success"); return
  end
  if ok4 and cancelled then
    print()
    dbg("[FAIL] Job cancelled by AE2 -- usually means missing")
    dbg("       ingredients in the network, or no free Crafting CPU.")
    flushDebug("craft-cancelled")
    return
  end
end
print()
dbg("[TIMEOUT] Job didn't finish in 60s -- check Crafting CPU status")
dbg("          and ingredient stock in-game.")
flushDebug("craft-timeout")
