-- =============================================
--  lookup_item_name_oc.lua
--  Translates a raw modid:name:meta into its
--  human-readable label, using your own ME
--  network as the source of truth (checks both
--  stored items and known craftables).
-- =============================================

local component = require("component")

if not component.isAvailable("me_controller") then
  print("[FAIL] no me_controller"); return
end
local me = component.me_controller

io.write("Item id (e.g. gregtech:gt.metaitem.01:2381): ")
local input = io.read()
if not input or input=="" then print("cancelled"); return end

local parts={}
for p in input:gmatch("[^:]+") do parts[#parts+1]=p end
local id, dmg
if #parts>=3 then id=parts[1]..":"..parts[2]; dmg=tonumber(parts[3]) or 0
elseif #parts==2 then id=parts[1]..":"..parts[2]; dmg=0
else print("[FAIL] couldn't parse id"); return end

print("Searching stored items...")
local ok1, items = pcall(me.getItemsInNetwork, {})
local found = false
if ok1 and items then
  for _, it in ipairs(items) do
    if it.name==id and (it.damage or 0)==dmg then
      print(string.format("[FOUND in storage] %s:%d = \"%s\"  (you have %d)",
        id, dmg, it.label or "?", it.size or 0))
      found = true
    end
  end
end

print("Searching craftables...")
local ok2, craftables = pcall(me.getCraftables)
if ok2 and craftables then
  for _, c in ipairs(craftables) do
    local ok3, stack = pcall(c.getItemStack)
    if ok3 and stack and stack.name==id and (stack.damage or 0)==dmg then
      print(string.format("[FOUND in craftables] %s:%d = \"%s\"",
        id, dmg, stack.label or "?"))
      found = true
    end
  end
end

if not found then
  print("[NOT FOUND] Item isn't currently stored or craftable in your network.")
  print("            Try holding one and checking NEI/JEI's tooltip instead,")
  print("            or if you have it in a chest, scan it with an")
  print("            Inventory Controller adapter.")
end
