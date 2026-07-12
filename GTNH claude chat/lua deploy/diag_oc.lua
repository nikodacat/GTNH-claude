-- =============================================
--  diag_oc.lua
--  Quick hardware diagnostic — run this first
--  to see exactly what's missing
-- =============================================

local component = require("component")
local computer  = require("computer")
local io        = require("io")

local DISK = "/mnt/dc6"
local SCRIPT_NAME = "diag_oc"

-- ── optional remote logging (best-effort) ──────
-- diag_oc.lua is meant to run with zero setup (it's the first thing
-- you run to check hardware), so config.lua/SERVER is optional here.
-- If it's available, the full report also gets mirrored to the web
-- viewer; if not, this just behaves exactly as before.
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

-- ── recover + push any log left over from a crashed previous run ──
local function recoverPreviousLog()
  local f = io.open(LOG_FILE, "r")
  if not f then return end
  local prev = f:read("*a")
  f:close()
  local wf = io.open(LOG_FILE, "w")
  if wf then wf:close() end
  if not prev or prev == "" or not net then return end
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

dbg("=== OC Hardware Diagnostic ===")
dbg("")

-- Internet card
if component.isAvailable("internet") then
  dbg("[OK]   Internet Card")
else
  dbg("[FAIL] Internet Card -- not found")
end

-- ME controller / adapter
if component.isAvailable("me_controller") then
  dbg("[OK]   AE2 ME Controller/Adapter")
else
  dbg("[FAIL] AE2 ME Adapter -- not found")
  dbg("       Place ME Adapter block touching this computer")
end

-- GPU
if component.isAvailable("gpu") then
  local gpu = component.gpu
  local w, h = gpu.getResolution()
  dbg(string.format("[OK]   GPU (%dx%d)", w, h))
else
  dbg("[WARN] No GPU -- text only mode")
end

-- Filesystem (real disk vs tmpfs)
dbg("")
dbg("Filesystems:")
for addr, ctype in component.list("filesystem") do
  local proxy = component.proxy(addr)
  local lbl   = (proxy.getLabel and proxy.getLabel()) or "(no label)"
  local space  = proxy.spaceTotal and
                 string.format("%.0fKB", proxy.spaceTotal()/1024) or "?"
  dbg(string.format("  %s  label=%s  size=%s", addr:sub(1,8), lbl, space))
end

-- All connected components
dbg("")
dbg("All components:")
for addr, ctype in component.list() do
  dbg(string.format("  %-30s %s", ctype, addr:sub(1,8)))
end

dbg("")
dbg("=== Done ===")
flushDebug("full-report")
io.read()
