-- =============================================
--  test_craft_oc.lua
--  Minimal standalone AE2 autocraft test.
--  Bypasses the Claude/chat/recipe-DB pipeline
--  entirely so you can confirm target.request()
--  actually works before trusting craft_oc.lua.
-- =============================================

local component = require("component")
local computer  = require("computer")

if not component.isAvailable("me_controller") then
  print("[FAIL] No me_controller component."); return
end
local me = component.me_controller

print("=== AE2 Craftables ===")
local ok, craftables = pcall(me.getCraftables)
if not ok or not craftables then
  print("[FAIL] getCraftables() failed: "..tostring(craftables)); return
end
print("Found "..#craftables.." craftable pattern(s).")
print()
print("Listing all craftable item names (may scroll off-screen):")
for i, c in ipairs(craftables) do
  print(string.format("  [%d] %s", i, c.name or "?"))
end

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
  print("[FAIL] No craftable pattern found for exact name: "..itemName)
  print("       Check spelling/case against the list above --")
  print("       this is the #1 cause of silent 'explain' fallback.")
  return
end

print("[OK] Pattern found. Requesting "..amount.."x "..itemName.."...")
local ok2, job = pcall(function() return target.request(amount) end)
if not ok2 then
  print("[FAIL] request() threw: "..tostring(job)); return
end
print("[OK] Job submitted. Polling (up to 60s)...")

local deadline = computer.uptime() + 60
while computer.uptime() < deadline do
  os.sleep(1)
  io.write(".")
  local ok3, done = pcall(function() return job.isDone() end)
  local ok4, cancelled = pcall(function() return job.isCanceled() end)
  if ok3 and done then print(); print("[SUCCESS] Craft finished."); return end
  if ok4 and cancelled then
    print()
    print("[FAIL] Job cancelled by AE2 -- usually means missing")
    print("       ingredients in the network, or no free Crafting CPU.")
    return
  end
end
print()
print("[TIMEOUT] Job didn't finish in 60s -- check Crafting CPU status")
print("          and ingredient stock in-game.")
