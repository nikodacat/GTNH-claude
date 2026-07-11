-- =============================================
--  update_oc.lua
--  Pulls the latest scripts from GitHub and
--  overwrites the local copies on this disk.
--
--  NEVER touches config.lua -- that file is local-
--  only (not tracked in git) and deliberately isn't
--  in the FILES list below. Keep it that way.
-- =============================================

local component = require("component")
local computer  = require("computer")
local io        = require("io")
local os        = require("os")

local DISK      = "/mnt/e10"
local REPO_RAW  = "https://raw.githubusercontent.com/nikodacat/GTNH-claude/main/GTNH%20claude%20chat/lua%20deploy/"

-- files to pull -- add new ones here as the project grows.
-- config.lua is deliberately NOT in this list.
local FILES = {
  "craft_oc.lua",
  "claude_chat_oc.lua",
  "diag_oc.lua",
  "lookup_item_name_oc.lua",
  "test_craft_oc.lua",
  "test_pattern_write_oc.lua",
  "config.example.lua",
  "update_oc.lua",
}

if not component.isAvailable("internet") then
  print("[FAIL] No Internet Card."); return
end
local net = component.internet

local function fetch(url)
  local req, err = net.request(url)
  if not req then return nil, err end
  local dl = computer.uptime() + 20
  while computer.uptime() < dl do
    local ok, e2 = req.finishConnect()
    if ok then break end
    if ok == nil then req.close(); return nil, e2 end
    os.sleep(0.05)
  end
  local body = ""
  while true do
    local chunk = req.read(8192)
    if not chunk then break end
    body = body .. chunk
  end
  req.close()
  return body
end

print("=== Updating scripts from GitHub ===")
print("Source: " .. REPO_RAW)
print()

local okCount, failCount = 0, 0
for _, name in ipairs(FILES) do
  io.write("  " .. name .. " ... ")
  local body, err = fetch(REPO_RAW .. name)
  if not body or body == "" then
    print("[FAIL] " .. tostring(err or "empty response"))
    failCount = failCount + 1
  else
    local path = DISK .. "/" .. name
    local f, ferr = io.open(path, "w")
    if not f then
      print("[FAIL] couldn't write " .. path .. ": " .. tostring(ferr))
      failCount = failCount + 1
    else
      f:write(body)
      f:close()
      print("OK (" .. #body .. " bytes)")
      okCount = okCount + 1
    end
  end
end

print()
print(string.format("Done. %d updated, %d failed.", okCount, failCount))
if failCount > 0 then
  print("[!] If fetches failed, check the repo is public and the")
  print("    filenames in FILES still match what's on GitHub.")
end

local hasConfig = io.open(DISK .. "/config.lua", "r")
if hasConfig then
  hasConfig:close()
  print("[i] config.lua left untouched, as intended.")
else
  print("[!] No config.lua found -- copy config.example.lua to")
  print("    " .. DISK .. "/config.lua and set your SERVER ip")
  print("    before running craft_oc.lua / claude_chat_oc.lua.")
end
