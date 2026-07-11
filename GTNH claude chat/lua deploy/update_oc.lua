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
local HOME      = "/home"
local REPO_RAW  = "https://raw.githubusercontent.com/nikodacat/GTNH-claude/main/GTNH%20claude%20chat/lua%20deploy/"

-- files to pull -- add new ones here as the project grows.
-- Just the base name, no ".lua" -- it's appended below.
-- config is deliberately NOT in this list (config.lua stays local-only).
local FILES = {
  "craft_oc",
  "claude_chat_oc",
  "diag_oc",
  "lookup_item_name_oc",
  "test_craft_oc",
  "test_pattern_write_oc",
  "config.example",
  "update_oc",
}

-- files that live in HOME instead of DISK (update_oc itself lives at
-- /home/update_oc -- no .lua suffix, that's where the file already is --
-- so it's easy to run from anywhere on boot; everything else stays on
-- DISK, which has more free space)
local HOME_FILES = { update_oc = true }

-- local files are written without the .lua suffix; the .lua suffix is
-- only used for the GitHub fetch URL, not the on-disk name
local function targetPath(base)
  if HOME_FILES[base] then return HOME .. "/" .. base end
  return DISK .. "/" .. base
end

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
for _, base in ipairs(FILES) do
  local name = base .. ".lua"
  io.write("  " .. name .. " ... ")
  local body, err = fetch(REPO_RAW .. name)
  if not body or body == "" then
    print("[FAIL] " .. tostring(err or "empty response"))
    failCount = failCount + 1
  else
    local path = targetPath(base)
    local f, ferr = io.open(path, "w")
    if not f then
      print("[FAIL] couldn't write " .. path .. ": " .. tostring(ferr))
      failCount = failCount + 1
    else
      f:write(body)
      f:close()
      print("OK (" .. #body