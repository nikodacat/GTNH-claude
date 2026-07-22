-- =============================================
--  init_oc.lua
--  Run this ONCE per physical OC computer -- the
--  intended FIRST script on a brand-new computer,
--  before update_oc.lua even exists on its disk.
--
--  Asks which ROLE this computer plays in the
--  project (currently: "craft" or "scan") and
--  saves the answer to a small local file,
--  role.lua -- NOT tracked in git, same spirit as
--  config.lua (local-only, per-machine). Then
--  fetches update_oc.lua fresh from GitHub (a
--  brand-new computer won't have it yet) and runs
--  it immediately, so this one script fully
--  bootstraps a new machine: pick a role, and
--  every file that role needs gets pulled and
--  you're ready to configure config.lua and go --
--  no separate manual update_oc step required.
--
--  Safe to re-run any time: just overwrites role.lua
--  with whatever you pick, then re-fetches +
--  re-runs update_oc as usual.
-- =============================================

local component = require("component")
local computer  = require("computer")
local io        = require("io")
local os        = require("os")

local DISK      = "/mnt/dc6"
local HOME      = "/home"
local ROLE_FILE = DISK.."/role.lua"
local REPO_RAW  = "https://raw.githubusercontent.com/nikodacat/GTNH-claude/main/GTNH%20claude%20chat/lua%20deploy/"

-- Keep this in sync with update_oc.lua's ROLE_FILES table -- the
-- descriptions here are just for the player choosing at the prompt,
-- update_oc.lua is the one place that actually decides what gets fetched.
local ROLES = {
  { key = "craft", label = "craft -- crafting dispatch + status/search terminal (runs craft_oc.lua)" },
  { key = "scan",  label = "scan  -- ME interface pattern scanner, background poller (runs scan_patterns_oc.lua)" },
}

local function readCurrentRole()
  local f = io.open(ROLE_FILE, "r")
  if not f then return nil end
  f:close()
  local ok, cfg = pcall(dofile, ROLE_FILE)
  if ok and type(cfg) == "table" and cfg.ROLE then return cfg.ROLE end
  return nil
end

local function writeRole(roleKey)
  local f, err = io.open(ROLE_FILE, "w")
  if not f then
    print("[FAIL] couldn't write "..ROLE_FILE..": "..tostring(err))
    io.read()
    return false
  end
  f:write("return { ROLE = \""..roleKey.."\" }\n")
  f:close()
  return true
end

print("=== init_oc: choose this computer's role ===")
local current = readCurrentRole()
if current then
  print("Currently set to: "..current)
  print("(re-picking below will overwrite this)")
end
print("")
for i, r in ipairs(ROLES) do
  print("  "..i..") "..r.label)
end
io.write("Enter a number: ")
local choice = io.read()
local picked = ROLES[tonumber(choice or "")]

if not picked then
  print("[FAIL] not a valid choice: "..tostring(choice))
  io.read()
  os.exit()
end

if not writeRole(picked.key) then
  return  -- writeRole already printed the failure + waited for a keypress
end
print("")
print("[OK] role.lua written -- this computer is now set up as: "..picked.key)

-- ── fetch + run update_oc.lua ──────────────────
-- A brand-new computer won't have update_oc.lua on disk yet -- this is
-- the one place that needs its own minimal fetch logic (update_oc.lua
-- can't be dofile()'d before it exists). Once it's written, update_oc.lua
-- itself takes over: it reads the role.lua we just wrote and fetches
-- exactly that role's files (including re-fetching itself and this
-- script -- both are in update_oc.lua's COMMON_FILES, harmless).
if not component.isAvailable("internet") then
  print("[FAIL] No Internet Card -- can't fetch update_oc.lua.")
  print("       Add an Internet Card, then run init_oc again.")
  io.read()
  return
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

print("")
io.write("Fetching update_oc.lua ... ")
local body, ferr = fetch(REPO_RAW.."update_oc.lua")
if not body or body == "" then
  print("[FAIL] "..tostring(ferr or "empty response"))
  print("       Run init_oc again once your connection/repo access is fixed.")
  io.read()
  return
end

local updatePath = HOME.."/update_oc"
local f, werr = io.open(updatePath, "w")
if not f then
  print("[FAIL] couldn't write "..updatePath..": "..tostring(werr))
  io.read()
  return
end
f:write(body)
f:close()
print("OK ("..#body.." bytes)")

print("")
print("=== Running update_oc now (fetches the rest of this role's files) ===")
local ok, runErr = pcall(dofile, updatePath)
if not ok then
  print("[FAIL] update_oc errored: "..tostring(runErr))
  print("       You can run it again manually: "..updatePath)
end
io.read()
