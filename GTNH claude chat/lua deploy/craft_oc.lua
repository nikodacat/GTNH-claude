-- =============================================
--  craft_oc.lua
--  Full AE2 crafting terminal + Claude chat,
--  with debug logging to terminal + web viewer.
-- =============================================

local DISK   = "/mnt/e10"   -- where scripts + config live

local component = require("component")
local computer  = require("computer")
local term      = require("term")
local io        = require("io")
local os        = require("os")

-- ── local config (NOT tracked in git) ─────────
-- Copy config.example.lua to DISK.."/config.lua" and set your
-- real SERVER ip there. Keeping it out of git means pulling
-- script updates never clobbers your local server IP.
local function loadConfig()
  local path = DISK.."/config.lua"
  local f = io.open(path, "r")
  if not f then
    print("[FAIL] Missing config file: "..path)
    print("       Copy config.example.lua to "..path)
    print("       and set your SERVER ip there.")
    io.read(); os.exit()
  end
  f:close()
  local ok, cfg = pcall(dofile, path)
  if not ok or type(cfg) ~= "table" or not cfg.SERVER then
    print("[FAIL] "..path.." must return a table with a SERVER field.")
    io.read(); os.exit()
  end
  return cfg
end

local SERVER = loadConfig().SERVER
local SCRIPT_NAME = "craft_oc"

-- ── crash-resistant local log file ─────────────
-- flushDebug() only sends what's buffered in memory, and only at a
-- checkpoint that calls it -- a genuinely unexpected crash (an
-- uncaught native error somewhere) skips straight past that and OC's
-- own crash handler prints a traceback to the LOCAL terminal only,
-- never the web viewer. Writing every dbg() line straight to disk as
-- it happens means the log survives even that kind of hard crash, and
-- gets auto-recovered and pushed to the web the *next* time this
-- script starts.
local LOG_FILE = DISK.."/oc_log_"..SCRIPT_NAME..".txt"

-- ── debug logger (mirrors all output to the web viewer + local disk) ─
local debugLines = {}

local function dbg(text)
  local t = string.format("[%.1fs] %s", computer.uptime(), text)
  print(t)
  debugLines[#debugLines+1] = t
  local lf = io.open(LOG_FILE, "a")
  if lf then lf:write(t.."\n"); lf:close() end
end

local function flushDebug(label)
  if not component.isAvailable("internet") then return end
  local net  = component.internet
  local full = "["..SCRIPT_NAME.."] "..(label or "debug") .. ":\n" .. table.concat(debugLines, "\n")
  debugLines = {}
  local body = '{"role":"diag","text":"'
               .. full:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')
               .. '"}'
  pcall(function()
    local req = net.request(
      SERVER.."/log", body,
      {["Content-Type"]="application/json"}
    )
    if not req then return end
    local dl = computer.uptime()+5
    while computer.uptime()<dl do
      local ok=req.finishConnect()
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
  if not prev or prev == "" then return end
  if not component.isAvailable("internet") then return end
  local net = component.internet
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

-- ── startup ───────────────────────────────────
dbg("=== craft_oc.lua starting ===")
dbg("Lua version: "..((_VERSION) or "?"))
dbg("Uptime: "..string.format("%.1fs", computer.uptime()))

-- ── hardware checks ───────────────────────────
dbg("--- Hardware Check ---")

local hasInternet = component.isAvailable("internet")
dbg("internet card    : " .. tostring(hasInternet))

local hasME = component.isAvailable("me_controller")
dbg("me_controller    : " .. tostring(hasME))

local hasGPU = component.isAvailable("gpu")
dbg("gpu              : " .. tostring(hasGPU))

-- list ALL components for reference
dbg("--- All Components ---")
for addr, ctype in component.list() do
  dbg(string.format("  %-28s %s", ctype, addr:sub(1,8)))
end

-- check SERVER set
dbg("SERVER           : " .. SERVER)
local serverOk = not SERVER:find("YOUR_HAMACHI_IP")
dbg("SERVER configured: " .. tostring(serverOk))

-- flush early so we get hardware info even if we crash below
dbg("--- Flushing initial report ---")
flushDebug("startup")

-- hard stops
if not hasInternet then
  print("[FAIL] No Internet Card."); io.read(); os.exit()
end
if not hasME then
  print("[FAIL] No AE2 ME Adapter (me_controller).")
  print("       Place ME Adapter block touching this computer.")
  io.read(); os.exit()
end
if not serverOk then
  print("[FAIL] SERVER ip not set."); io.read(); os.exit()
end

dbg("Hardware checks passed")

-- ── bind components ───────────────────────────
dbg("Binding components...")
local net = component.internet
local me  = component.me_controller
dbg("net proxy: " .. tostring(net))
dbg("me proxy : " .. tostring(me))

-- ── colour helpers ────────────────────────────
local gpu = hasGPU and component.gpu or nil
local W   = gpu and select(1, gpu.getResolution()) or 50
local function fg(c) if gpu then pcall(gpu.setForeground,c) end end
local function cprint(c,t) fg(c); print(t); fg(0xFFFFFF) end
local function cwrite(c,t) fg(c); io.write(t); fg(0xFFFFFF) end

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

local function printWrapped(col, prefix, text)
  local ind=string.rep(" ",#prefix)
  for i,line in ipairs(wrap(text,W-#prefix)) do
    fg(col); io.write(i==1 and prefix or ind)
    fg(0xFFFFFF); io.write(line.."\n")
  end
end

-- ── JSON encode ───────────────────────────────
local function enc(v)
  local t=type(v)
  if t=="nil"     then return "null" end
  if t=="boolean" then return tostring(v) end
  if t=="number"  then return tostring(v) end
  if t=="string"  then
    return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')
                  :gsub('\n','\\n'):gsub('\r','\\r')..'"'
  end
  if t=="table" then
    if #v>0 then
      local p={}; for _,x in ipairs(v) do p[#p+1]=enc(x) end
      return "["..table.concat(p,",").."]"
    else
      local p={}; for k,x in pairs(v) do
        p[#p+1]='"'..tostring(k)..'":'..enc(x)
      end
      return "{"..table.concat(p,",").."}"
    end
  end
  return "null"
end

-- ── HTTP helpers ──────────────────────────────
local function httpDo(url, body, headers)
  dbg("HTTP ".. (body and "POST" or "GET") .." "..url:sub(1,50))
  local req, err = net.request(url, body, headers)
  if not req then
    dbg("  request() failed: "..(err or "?"))
    return nil, err
  end
  dbg("  waiting for connect...")
  local dl=computer.uptime()+30
  while computer.uptime()<dl do
    local ok,e2=req.finishConnect()
    if ok then dbg("  connected"); break end
    if ok==nil then
      req.close()
      dbg("  connect failed: "..(e2 or "?"))
      return nil, e2
    end
    os.sleep(0.05)
  end
  local r=""
  while true do
    local chunk=req.read(8192)
    if not chunk then break end
    r=r..chunk
  end
  req.close()
  dbg("  response len="..#r)
  if #r > 0 then dbg("  response preview: "..r:sub(1,80)) end
  return r, nil
end

local function post(path, tbl)
  return httpDo(SERVER..path, enc(tbl), {["Content-Type"]="application/json"})
end

local function get(path)
  return httpDo(SERVER..path)
end

-- ── simple JSON field extractor ───────────────
local function extractStr(raw, key)
  local p=raw:match('"'..key..'":%s*"(.-[^\\])"')
  if p then return p:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\\\','\\') end
  return nil
end
local function extractNum(raw, key)
  local p=raw:match('"'..key..'":%s*(%d+)')
  return p and tonumber(p) or nil
end

-- ── ping server ───────────────────────────────
dbg("--- Pinging server ---")
local pong, perr = post("/ping", {})
if not pong then
  dbg("PING FAILED: "..(perr or "?"))
  flushDebug("ping-fail")
  cprint(0xFF4444, "[FAIL] Cannot reach server: "..(perr or "?"))
  io.read(); os.exit()
end
dbg("Ping OK: "..pong:sub(1,50))
flushDebug("ping-ok")

-- ── ME helpers ────────────────────────────────
local function buildInventory()
  dbg("buildInventory() called")
  local ok, items = pcall(me.getItemsInNetwork)
  dbg("  getItemsInNetwork ok="..tostring(ok))
  if not ok or not items then
    dbg("  failed: "..tostring(items))
    return {}
  end
  dbg("  returned "..#items.." items")
  local hash={}
  for _,item in ipairs(items) do
    if item.name then
      hash[item.name]=(hash[item.name] or 0)+(item.size or 1)
    end
  end
  local count=0; for _ in pairs(hash) do count=count+1 end
  dbg("  unique item types: "..count)
  return hash
end

local function getCraftables()
  dbg("getCraftables() called")
  local ok, c = pcall(me.getCraftables)
  dbg("  getCraftables ok="..tostring(ok))
  if not ok or not c then
    dbg("  failed: "..tostring(c))
    return {}
  end
  dbg("  returned "..#c.." craftables")
  local list={}
  for _,x in ipairs(c) do if x.name then list[#list+1]=x.name end end
  return list
end

local ALWAYS={"plank","stick","stone","iron_ingot","gold_ingot",
  "copper","tin","redstone","diamond","coal","glass","rubber","steel"}

local function relevantInventory(userMsg, inv)
  local keywords={}
  for w in userMsg:lower():gmatch("%a+") do
    if #w>=3 then keywords[#keywords+1]=w end
  end
  for _,k in ipairs(ALWAYS) do keywords[#keywords+1]=k end
  local result,seen={},{}
  local function tryAdd(name,amt)
    if not seen[name] and #result<50 then
      seen[name]=true; result[#result+1]=name.." x"..amt
    end
  end
  for name,amt in pairs(inv) do
    for _,kw in ipairs(keywords) do
      if name:lower():find(kw,1,true) then tryAdd(name,amt); break end
    end
  end
  local rest={}
  for name,amt in pairs(inv) do
    if not seen[name] then rest[#rest+1]={name=name,amt=amt} end
  end
  table.sort(rest,function(a,b) return a.amt>b.amt end)
  for _,r in ipairs(rest) do
    if #result>=50 then break end; tryAdd(r.name,r.amt)
  end
  return table.concat(result,"\n")
end

-- ── recipe lookup ─────────────────────────────
local function searchItems(query, limit)
  limit=limit or 8
  local encoded=query:gsub(":"," %%3A"):gsub(" ","+")
  local raw,err=get("/search?q="..encoded.."&limit="..limit)
  if not raw then return {} end
  local results={}
  for name in raw:gmatch('"([^"]+:[^"]+)"') do
    results[#results+1]=name
  end
  return results
end

local function lookupRecipe(itemName)
  local encoded=itemName:gsub(":","%%3A")
  local raw,err=get("/recipe?item="..encoded)
  if not raw then return nil, err end
  local found=raw:find('"found":%s*true')~=nil
  if not found then return nil,nil end
  local gridStr=raw:match('"grid":%s*(%[.-%])')
  local ingStr =raw:match('"ingredients":%s*(%[.-%])')
  local rtype  =raw:match('"type":%s*"([^"]+)"')
  local function parseArr(s)
    if not s then return nil end
    local full={}
    for entry in s:gmatch('([^,%[%]]+)') do
      entry=entry:match("^%s*(.-)%s*$")
      if entry=="null" then full[#full+1]=nil
      elseif entry:sub(1,1)=='"' then
        full[#full+1]=entry:match('"([^"]*)"')
      end
    end
    return full
  end
  return {
    type=rtype,
    grid=gridStr and parseArr(gridStr) or nil,
    ingredients=ingStr and parseArr(ingStr) or nil,
  }, nil
end

-- ── AE2 autocraft ─────────────────────────────
local function triggerAutocraft(itemName, amount)
  dbg("triggerAutocraft("..itemName..", "..amount..")")
  local ok, craftables = pcall(me.getCraftables)
  if not ok or not craftables then
    dbg("  getCraftables failed")
    return false, "cannot query craftables"
  end
  local target=nil
  for _,c in ipairs(craftables) do
    if c.name==itemName then target=c; break end
  end
  if not target then
    dbg("  no pattern found for "..itemName)
    return false, "no AE2 pattern for "..itemName
  end
  dbg("  found craftable, requesting "..amount)
  local job
  ok,job=pcall(function() return target.request(amount) end)
  if not ok then
    dbg("  request() error: "..tostring(job))
    return false, "request() failed: "..tostring(job)
  end
  dbg("  job submitted, polling...")
  cwrite(0x888888,"  [~] Crafting")
  local deadline=computer.uptime()+90
  while computer.uptime()<deadline do
    os.sleep(2); io.write(".")
    local ok2,done=pcall(function() return job.isDone() end)
    local ok3,cancelled=pcall(function() return job.isCanceled() end)
    dbg("  poll: done="..tostring(done).." cancelled="..tostring(cancelled))
    if ok2 and done then print(); return true,nil end
    if ok3 and cancelled then print(); return false,"job cancelled by AE2" end
  end
  print()
  return true,"timed out polling"
end

-- ── main ──────────────────────────────────────
local history={}

local SYSTEM=[[
You are a Minecraft crafting assistant for GTNH connected to an AE2 ME system.
You will receive: player request, ME inventory snapshot, AE2 craftable list,
and optionally a verified recipe from the recipe database.

Always respond with a single JSON object only — no prose, no markdown.

{
  "message": "reply shown to player",
  "action": "craft" | "explain" | "chat",
  "item": "exact:item:id or null",
  "amount": 1,
  "warn": "caveat or null"
}

Action rules:
- "craft"  : item has an AE2 pattern AND materials exist. Use exact item ID.
- "explain": no pattern, or materials missing, or needs GT machine.
- "chat"   : general question, no crafting needed.

Only use "craft" if item appears in the craftable list.
If a verified recipe from the DB is provided, use it.
Otherwise note that GTNH recipes may differ from vanilla.
]]

term.clear(); term.setCursor(1,1)
cprint(0x00FFFF, "=== Claude Crafting ===")
cprint(0x888888, "Commands: status | search <q> | clear | quit | flush")
print()
cprint(0x00FF00, "[OK] Server connected: "..SERVER)
print()

dbg("Entering main loop")

-- drain + log any signals left in the queue before we ever try to read
dbg("--- Draining pending signal queue ---")
local drained = 0
while true do
  local sig = table.pack(computer.pullSignal(0))
  if sig.n == 0 or sig[1] == nil then break end
  drained = drained + 1
  local parts = {}
  for i = 1, sig.n do parts[#parts+1] = tostring(sig[i]) end
  dbg("  stray signal #"..drained..": "..table.concat(parts, ", "))
  if drained > 20 then dbg("  (stopping drain, too many)"); break end
end
dbg("Drained "..drained.." stray signal(s)")
dbg("term.keyboard() right before loop: "..tostring(term.keyboard and term.keyboard() or "term.keyboard n/a"))

flushDebug("init-complete")

while true do
  cwrite(0xFFFFFF,"\n> ")
  dbg("about to call io.read(), uptime="..string.format("%.2f", computer.uptime()))
  dbg("  term.keyboard() = "..tostring(term.keyboard and term.keyboard() or "n/a"))
  local okRead, input = pcall(io.read)
  local afterUptime = computer.uptime()
  dbg("io.read() returned, ok="..tostring(okRead).." value="..tostring(input)..
      " elapsed="..string.format("%.2f", afterUptime).."s")
  flushDebug("read-attempt")
  if not okRead then
    dbg("io.read() THREW an error: "..tostring(input))
    flushDebug("read-error")
    print("[ERR] io.read() error: "..tostring(input))
    break
  end
  if not input then
    dbg("io.read() returned nil — exiting")
    flushDebug("nil-read-exit")
    break
  end
  input=input:match("^%s*(.-)%s*$")
  if input=="" then goto continue end

  if input:lower()=="quit" then
    dbg("quit command")
    flushDebug("quit")
    cprint(0xFFFF00,"Bye!"); break

  elseif input:lower()=="flush" then
    io.write("[~] Flushing debug log... ")
    flushDebug("manual-flush")
    print("done")

  elseif input:lower()=="clear" then
    history={}; debugLines={}
    cprint(0x888888,"[i] History + debug cleared.")

  elseif input:lower()=="status" then
    dbg("status command")
    cwrite(0x888888,"[~] Scanning ME... ")
    local inv=buildInventory(); local c=getCraftables()
    local n=0; for _ in pairs(inv) do n=n+1 end
    cprint(0x00FFFF,string.format(
      "done.\n  ME items   : %d types\n  Craftables : %d patterns",n,#c))
    dbg(string.format("status result: %d item types, %d craftable patterns",n,#c))
    flushDebug("status")

  elseif input:lower():match("^search%s+") then
    local q=input:match("^search%s+(.+)$")
    dbg("search: "..q)
    cwrite(0x888888,"[~] Searching '"..q.."'... ")
    local results=searchItems(q,10)
    if #results==0 then
      cprint(0xFFAA00,"no matches.")
      dbg("search result: no matches")
    else
      cprint(0x00FF00,#results.." result(s):")
      for _,r in ipairs(results) do cprint(0x00FFFF,"  "..r) end
      dbg("search result ("..#results.."): "..table.concat(results,", "))
    end
    flushDebug("search-"..q)

  else
    dbg("craft request: "..input)
    cwrite(0x888888,"[~] Scanning ME... ")
    local inv=buildInventory()
    local craftables=getCraftables()
    local invSummary=relevantInventory(input,inv)
    local craftList=table.concat(craftables,"\n")
    dbg("inv types="..tostring(#invSummary).." craftables="..#craftables)
    cprint(0x888888,"done.")

    -- recipe DB lookup
    local recipeContext="(No recipe DB match)"
    local words={}
    for w in input:gmatch("%S+") do words[#words+1]=w end
    local hint=table.concat(words,"_"):lower()
    dbg("recipe hint: "..hint)
    local searchResults=searchItems(hint,3)
    dbg("search results: "..#searchResults)
    if #searchResults>0 then
      dbg("looking up: "..searchResults[1])
      local r,err=lookupRecipe(searchResults[1])
      if r then
        dbg("recipe found, type="..tostring(r.type))
        if r.type=="crafting_shaped" and r.grid then
          local g=r.grid
          local gs=table.concat((function()
            local t={}
            for _,s in ipairs(g) do t[#t+1]=(s or "null") end
            return t
          end)(),", ")
          recipeContext=string.format(
            "[Recipe DB]\nItem: %s\nType: %s\nGrid: %s",
            searchResults[1],r.type,gs)
        elseif r.type=="crafting_shapeless" and r.ingredients then
          recipeContext=string.format(
            "[Recipe DB]\nItem: %s\nType: shapeless\nIngredients: %s",
            searchResults[1],table.concat(r.ingredients,", "))
        end
      else
        dbg("recipe not found or err: "..tostring(err))
      end
    end

    local context=string.format(
      "%s\n\n[AE2 Craftable]\n%s\n\n[ME Inventory]\n%s",
      recipeContext,
      craftList~=""and craftList or "(none)",
      invSummary)

    history[#history+1]={role="user",content=input.."\n\n"..context}

    dbg("posting to /chat, history len="..#history)
    cwrite(0x888888,"[~] Asking Claude... ")
    local raw,err=post("/chat",{messages=history,system=SYSTEM,source="oc"})

    if not raw then
      dbg("POST failed: "..(err or "?"))
      flushDebug("post-fail")
      cprint(0xFF4444,"\n[ERR] "..(err or "?")); history[#history]=nil
      goto continue
    end

    dbg("response received, len="..#raw)
    local message=extractStr(raw,"message") or raw
    local action =extractStr(raw,"action")  or "chat"
    local item   =extractStr(raw,"item")
    local amount =extractNum(raw,"amount")  or 1
    local warn   =extractStr(raw,"warn")
    local hasCJK =raw:find('"has_cjk":%s*true')~=nil

    dbg("action="..tostring(action).." item="..tostring(item).." hasCJK="..tostring(hasCJK))

    history[#history+1]={role="assistant",content=message}

    if hasCJK then
      cprint(0xFFAA00,"[!] Full reply on web viewer (contains non-ASCII).")
    end

    print()
    printWrapped(0x00FFFF,"Claude: ",message)
    if warn and warn~="null" and warn~="" then
      cprint(0xFFAA00,"[!] "..warn)
    end

    if action=="craft" and item and item~="null" then
      cprint(0xFFFF00,string.format("\n[Autocraft] %s x%d",item,amount))
      dbg("autocraft start: "..item.." x"..amount)
      local ok,aerr=triggerAutocraft(item,amount)
      if ok then
        cprint(0x00FF00,"  [+] Done!")
        dbg("autocraft result: SUCCESS")
      else
        cprint(0xFF4444,"  [!] "..(aerr or "failed"))
        dbg("autocraft result: FAILED - "..(aerr or "failed"))
      end
      flushDebug("autocraft-"..item)
    elseif action=="explain" then
      cprint(0xFFAA00,"\n[No pattern] Cannot autocraft — see recipe above.")
      cprint(0x888888,"  -> Encode a pattern in ME Pattern Terminal to enable.")
      dbg("explain-only response, no AE2 pattern for this item")
    end

    flushDebug("request-"..input:sub(1,20))
  end

  ::continue::
end
