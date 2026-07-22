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

local DISK      = "/home"   -- was /mnt/dc6 (secondary disk mount) -- moved to /home since disk mount labels change when the physical disk is swapped (2026-07-23, T3 disk upgrade); DISK and HOME are now the same path, kept as two names since HOME_FILES below still needs to distinguish "goes in HOME regardless of role" from "goes wherever DISK points"
local HOME      = "/home"
local REPO_RAW  = "https://raw.githubusercontent.com/nikodacat/GTNH-claude/main/GTNH%20claude%20chat/lua%20deploy/"

-- files to pull -- add new ones here as the project grows. Just the base
-- name, no ".lua" -- it's appended below. config is deliberately NOT in
-- either list below (config.lua stays local-only).
--
-- Split by ROLE (see init_oc.lua): every computer fetches COMMON_FILES
-- regardless of role, plus whichever ROLE_FILES[role] entry matches
-- role.lua's saved choice on THIS disk. This exists so a lean,
-- purpose-built second computer (e.g. the pattern-scanning one) doesn't
-- end up with every test/debug script from this project's history
-- cluttering its disk -- it only needs scan_patterns_oc, nothing else.
--
-- Backward-compat / safety net: if role.lua doesn't exist yet (a
-- computer that predates this system, or init_oc hasn't been run on it
-- yet), this falls back to fetching EVERY file across every role --
-- exactly the old, pre-role behavior -- so nothing breaks on an
-- already-set-up computer just because it hasn't opted into a role yet.
local COMMON_FILES = {
  "after_update_oc",
  "config.example",
  "update_oc",
  "init_oc",
  "diag_oc",       -- generic hardware diagnostic, useful on any computer
}
local ROLE_FILES = {
  craft = {
    "craft_oc",
    "claude_chat_oc",
    "lookup_item_name_oc",
    "test_craft_oc",
    "test_pattern_write_oc",
    "test_pattern_write_direct_oc",
    "diag_pattern_editor_oc",
    "minimal_pattern_test_oc",
  },
  scan = {
    "scan_patterns_oc",
  },
}

local function readRole()
  local f = io.open(DISK.."/role.lua", "r")
  if not f then return nil end
  f:close()
  local ok, cfg = pcall(dofile, DISK.."/role.lua")
  if ok and type(cfg) == "table" and cfg.ROLE then return cfg.ROLE end
  return nil
end

local function everyFile()
  local all = {}
  for _, f in ipairs(COMMON_FILES) do all[#all+1] = f end
  for _, files in pairs(ROLE_FILES) do
    for _, f in ipairs(files) do all[#all+1] = f end
  end
  return all
end

-- Returns (fileList, roleNameOrNil, warningMessageOrNil):
--   - a known role in role.lua -> (that role's files, role name, nil)
--   - no role.lua at all        -> (everything, nil, nil)              [normal, not a warning]
--   - role.lua names an unknown role -> (everything, nil, warning text) [worth telling the player]
local function buildFileList()
  local role = readRole()
  if not role then
    return everyFile(), nil, nil
  end
  if not ROLE_FILES[role] then
    return everyFile(), nil, "unknown role \""..role.."\" in role.lua -- fetched everything instead"
  end
  local list = {}
  for _, f in ipairs(COMMON_FILES) do list[#list+1] = f end
  for _, f in ipairs(ROLE_FILES[role]) do list[#list+1] = f end
  return list, role, nil
end

local FILES, ACTIVE_ROLE, ROLE_WARNING = buildFileList()

-- ── after-update hooks ─────────────────────────
-- Base names (must also appear in FILES above, so they get fetched to
-- disk like everything else) that get dofile()'d automatically right
-- after every update pass finishes -- see the "run after-update hooks"
-- section near the bottom of this file. This is the extension point for
-- one-time migration/fixup logic that needs to run whenever scripts
-- change (e.g. after this same script updates ITSELF to a newer
-- version): put that logic in one of these files instead of editing
-- update_oc.lua's own core loop again. Since these hook files are pulled
-- from GitHub exactly like everything else, what runs post-update can be
-- changed at any time just by editing the hook script on GitHub -- this
-- list only needs a new entry the first time a given hook file is added.
local AFTER_UPDATE = {
  "after_update_oc",
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
local SCRIPT_NAME = "update_oc"

-- ── optional remote logging (best-effort) ──────
-- Reads config.lua (never writes to it -- that stays local-only,
-- see FILES list below) just to find SERVER, so update results can
-- also be seen on the web viewer without needing to read the OC
-- screen. If there's no config yet, this just runs silently local-only.
local SERVER
do
  local f = io.open(DISK.."/config.lua", "r")
  if f then
    f:close()
    local ok, cfg = pcall(dofile, DISK.."/config.lua")
    if ok and type(cfg)=="table" and cfg.SERVER and not cfg.SERVER:find("YOUR_HAMACHI_IP") then
      SERVER = cfg.SERVER
    end
  end
end

-- ── crash-resistant local log file ─────────────
-- Written unconditionally (doesn't need SERVER) so a hard crash still
-- leaves a trail on disk; auto-recovered and pushed to the web the
-- *next* time this script starts, if a server is configured by then.
local LOG_FILE = DISK.."/oc_log_"..SCRIPT_NAME..".txt"

local debugLines = {}
local function dbg(text)
  print(text)
  debugLines[#debugLines+1] = text
  local lf = io.open(LOG_FILE, "a")
  if lf then lf:write(text.."\n"); lf:close() end
end
local function flushDebug(label)
  if not SERVER or #debugLines == 0 then debugLines = {}; return end
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

-- ── recover + push any log left over from a crashed previous run ──
local function recoverPreviousLog()
  local f = io.open(LOG_FILE, "r")
  if not f then return end
  local prev = f:read("*a")
  f:close()
  local wf = io.open(LOG_FILE, "w")
  if wf then wf:close() end
  if not prev or prev == "" or not SERVER then return end
  local full = "["..SCRIPT_NAME.."] recovered-from-previous-crash:\n"..prev
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
recoverPreviousLog()

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

dbg("=== Updating scripts from GitHub ===")
dbg("Source: " .. REPO_RAW)
if ACTIVE_ROLE then
  dbg("Role: " .. ACTIVE_ROLE .. " (" .. #FILES .. " file(s) -- run init_oc to change)")
elseif ROLE_WARNING then
  dbg("[!] " .. ROLE_WARNING)
else
  dbg("No role.lua found -- fetching every file (run init_oc once to switch to a lean, role-based file set)")
end
dbg("")

local okCount, failCount = 0, 0
local fetchedOk = {}   -- base name -> true if this run's fetch+write succeeded
for _, base in ipairs(FILES) do
  local name = base .. ".lua"
  io.write("  " .. name .. " ... ")
  local body, err = fetch(REPO_RAW .. name)
  if not body or body == "" then
    local msg = "[FAIL] " .. tostring(err or "empty response")
    print(msg)
    debugLines[#debugLines+1] = "  " .. name .. " ... " .. msg
    failCount = failCount + 1
  else
    local path = targetPath(base)
    local f, ferr = io.open(path, "w")
    if not f then
      local msg = "[FAIL] couldn't write " .. path .. ": " .. tostring(ferr)
      print(msg)
      debugLines[#debugLines+1] = "  " .. name .. " ... " .. msg
      failCount = failCount + 1
    else
      f:write(body)
      f:close()
      local msg = "OK (" .. #body .. " bytes)"
      print(msg)
      debugLines[#debugLines+1] = "  " .. name .. " ... " .. msg
      okCount = okCount + 1
      fetchedOk[base] = true
    end
  end
end

dbg("")
dbg(string.format("Done. %d updated, %d failed.", okCount, failCount))
if failCount > 0 then
  dbg("[!] If fetches failed, check the repo is public and the")
  dbg("    filenames in FILES still match what's on GitHub.")
end

local hasConfig = io.open(DISK .. "/config.lua", "r")
if hasConfig then
  hasConfig:close()
  dbg("[i] config.lua left untouched, as intended.")
else
  dbg("[!] No config.lua found -- copy config.example.lua to")
  dbg("    " .. DISK .. "/config.lua and set your SERVER ip")
  dbg("    before running craft_oc.lua / claude_chat_oc.lua.")
end

-- ── run after-update hooks ─────────────────────
-- Runs every entry in AFTER_UPDATE, in order, regardless of whether this
-- specific run re-fetched it (an already-up-to-date file from a prior
-- run is still run) -- only a totally MISSING file (never fetched
-- successfully, ever) is skipped. Each hook is dofile()'d inside its own
-- pcall so one hook throwing an error can't stop the rest from running,
-- or crash update_oc.lua itself right when it's most likely to matter
-- (e.g. update_oc.lua having just updated ITSELF to a version that
-- depends on a hook doing some one-time setup).
dbg("")
dbg("=== Running after-update hooks ===")
for _, base in ipairs(AFTER_UPDATE) do
  local path = targetPath(base)
  local f = io.open(path, "r")
  if not f then
    local msg = "  [SKIP] " .. base .. " -- not found on disk (fetch above may have failed, and no prior copy exists either)"
    print(msg)
    debugLines[#debugLines+1] = msg
  else
    f:close()
    local tag = fetchedOk[base] and "" or " (using existing on-disk copy -- not re-fetched this run)"
    dbg("  running " .. base .. "..." .. tag)
    local ok, hookErr = pcall(dofile, path)
    if ok then
      dbg("  [OK] " .. base .. " completed")
    else
      dbg("  [FAIL] " .. base .. " errored: " .. tostring(hookErr))
    end
  end
end

flushDebug("update-"..(failCount==0 and "success" or "partial-fail"))
