-- =============================================
--  init_oc.lua
--  Run this ONCE per physical OC computer, before
--  the first update_oc.lua run (or any time you
--  want to change what a computer is set up for).
--
--  Asks which ROLE this computer plays in the
--  project (currently: "craft" or "scan") and
--  saves the answer to a small local file,
--  role.lua -- NOT tracked in git, same spirit as
--  config.lua (local-only, per-machine). update_oc.lua
--  then reads role.lua and only fetches the files
--  that role actually needs, instead of every
--  script in the whole project landing on every
--  computer regardless of what it's for.
--
--  Safe to re-run any time: just overwrites role.lua
--  with whatever you pick.
-- =============================================

local io = require("io")
local os = require("os")

local DISK = "/mnt/dc6"
local ROLE_FILE = DISK.."/role.lua"

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

if writeRole(picked.key) then
  print("")
  print("[OK] role.lua written -- this computer is now set up as: "..picked.key)
  print("Next: run update_oc to fetch the files this role needs.")
end
io.read()
