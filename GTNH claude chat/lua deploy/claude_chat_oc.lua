-- =============================================
--  claude_chat_oc.lua  (v2 - local server)
--  Talks to claude_server.py on your PC.
--  Requires: Internet Card only
-- =============================================

local DISK = "/mnt/e10"   -- where scripts + config live

-- ── libs ─────────────────────────────────────
local component = require("component")
local computer  = require("computer")
local term      = require("term")
local io        = require("io")
local os        = require("os")
local serial    = require("serialization")

-- ── hardware check ────────────────────────────
if not component.isAvailable("internet") then
  print("ERROR: No Internet Card found.")
  print("Insert one and restart.")
  io.read(); os.exit()
end

-- ── local config (NOT tracked in git) ─────────
-- Copy config.example.lua to DISK.."/config.lua" and set your
-- real SERVER ip there. Keeping it out of git means pulling
-- script updates never clobbers your local server IP.
local function loadConfig()
  local path = DISK.."/config.lua"
  local f = io.open(path, "r")
  if not f then
    print("ERROR: Missing config file: "..path)
    print("       Copy config.example.lua to "..path)
    print("       and set your SERVER ip there.")
    io.read(); os.exit()
  end
  f:close()
  local ok, cfg = pcall(dofile, path)
  if not ok or type(cfg) ~= "table" or not cfg.SERVER then
    print("ERROR: "..path.." must return a table with a SERVER field.")
    io.read(); os.exit()
  end
  return cfg
end

local SERVER = loadConfig().SERVER
if SERVER:find("YOUR_HAMACHI_IP") then
  print("ERROR: Set SERVER in "..DISK.."/config.lua to your PC's LAN/Hamachi IP.")
  print("Example: http://26.89.137.125:11434")
  io.read(); os.exit()
end

local net = component.internet

-- ── HTTP POST ─────────────────────────────────
local function post(path, tbl)
  -- OC serialization → JSON-like; server accepts it
  -- We encode manually: only needs strings + tables of strings
  local function enc(v)
    local t = type(v)
    if t=="string" then
      return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')
                   :gsub('\n','\\n'):gsub('\r','\\r')..'"'
    end
    if t=="number" or t=="boolean" then return tostring(v) end
    if t=="table" then
      if #v>0 then
        local p={}
        for _,x in ipairs(v) do p[#p+1]=enc(x) end
        return "["..table.concat(p,",").."]"
      else
        local p={}
        for k,x in pairs(v) do p[#p+1]='"'..k..'":'..enc(x) end
        return "{"..table.concat(p,",").."}"
      end
    end
    return "null"
  end

  local body = enc(tbl)
  local req, err = net.request(
    SERVER..path, body,
    {["Content-Type"]="application/json"}
  )
  if not req then return nil, err end

  local dl = computer.uptime()+20
  while computer.uptime()<dl do
    local ok,e2 = req.finishConnect()
    if ok then break end
    if ok==nil then req.close(); return nil, e2 end
    os.sleep(0.05)
  end

  local r=""
  while true do
    local chunk=req.read(8192)
    if not chunk then break end
    r=r..chunk
  end
  req.close()
  return r, nil
end

-- ── decode server reply ───────────────────────
local function getReply(raw)
  if not raw then return nil end
  -- pull "reply":"..." out of JSON without a full parser
  local r = raw:match('"reply"%s*:%s*"(.-[^\\])"')
  if r then
    return r:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\\\','\\')
  end
  local e = raw:match('"error"%s*:%s*"(.-[^\\])"')
  if e then return nil, e end
  return nil, "unreadable response: "..raw
end

-- ── word wrap ─────────────────────────────────
local function wrap(text, width)
  local lines={}
  for para in (text.."\n"):gmatch("(.-)\n") do
    local line=""
    for word in para:gmatch("%S+") do
      if #line+#word+1>width then lines[#lines+1]=line; line=word
      else line=line==""and word or line.." "..word end
    end
    lines[#lines+1]=line
  end
  return lines
end

-- ── colour helpers ────────────────────────────
local gpu = component.isAvailable("gpu") and component.gpu or nil
local W   = gpu and select(1, gpu.getResolution()) or 50

local function fg(col)
  if gpu then pcall(gpu.setForeground,col) end
end

local function printWrapped(col, prefix, text)
  local ind = string.rep(" ",#prefix)
  for i,line in ipairs(wrap(text, W-#prefix)) do
    fg(col); io.write(i==1 and prefix or ind)
    fg(0xFFFFFF); io.write(line.."\n")
  end
end

-- ── ping server ───────────────────────────────
local function pingServer()
  fg(0x888888); io.write("[~] Connecting to server... ")
  local raw, err = post("/ping", {})
  if not raw then
    fg(0xFF4444); print("FAILED")
    fg(0xFFFFFF); print("    ".. (err or "?"))
    print("    Is claude_server.py running on your PC?")
    return false
  end
  fg(0x00FF00); print("OK"); fg(0xFFFFFF)
  return true
end

-- ── main ─────────────────────────────────────
term.clear(); term.setCursor(1,1)
fg(0x00FFFF); print("╔══════════════════════════════╗")
fg(0x00FFFF); print("║   Claude Chat  [OC + LAN]    ║")
fg(0x00FFFF); print("╚══════════════════════════════╝")
fg(0x888888); print("Server: "..SERVER)
print()

if not pingServer() then
  io.read(); os.exit()
end

fg(0x888888); print("Type 'quit' to exit.\n")
fg(0xFFFFFF)

local history = {}

while true do
  fg(0xFFFF00); io.write("> "); fg(0xFFFFFF)
  local input = io.read()
  if not input then break end
  input = input:match("^%s*(.-)%s*$")
  if input=="" then goto continue end
  if input:lower()=="quit" then fg(0xFFFF00); print("Bye!"); break end

  history[#history+1] = {role="user", content=input}

  fg(0x888888); io.write("[~] Thinking...\n"); fg(0xFFFFFF)

  local raw, err = post("/chat", {messages=history, source="oc"})
  if not raw then
    fg(0xFF4444); print("[ERR] "..(err or "?")); fg(0xFFFFFF)
    history[#history]=nil
    goto continue
  end

  local reply, rerr = getReply(raw)
  if not reply then
    fg(0xFF4444); print("[ERR] "..(rerr or raw)); fg(0xFFFFFF)
    history[#history]=nil
    goto continue
  end

  -- check if server flagged CJK content
  local hasCJK = raw:find('"has_cjk":%s*true') ~= nil
  if hasCJK then
    fg(0xFFAA00); print("[!] Full reply on web viewer (contains non-ASCII).")
    fg(0xFFFFFF)
  end

  history[#history+1] = {role="assistant", content=reply}
  printWrapped(0x00FFFF, "Claude: ", reply)

  ::continue::
end
