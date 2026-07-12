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
  "diag_pattern_editor_oc",
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
dbg("")

local okCount, failCount = 0, 0
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
flushDebug("update-"..(failCount==0 and "success" or "partial-fail"))
