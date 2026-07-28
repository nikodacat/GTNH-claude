-- =============================================
--  craft_oc.lua
--  Full AE2 crafting terminal + Claude chat,
--  with debug logging to terminal + web viewer.
-- =============================================

local DISK   = "/home"   -- where scripts + config live (was /mnt/dc6 -- moved to /home, stable across disk swaps)

local component = require("component")
local computer  = require("computer")
local term      = require("term")
local io        = require("io")
local os        = require("os")
local event     = require("event")

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

local cfg = loadConfig()
local SERVER = cfg.SERVER
-- optional (2026-07-24, auto-pattern-write feature) -- address of a spare
-- ME Interface to write newly-discovered CRAFTING-TABLE patterns onto; nil
-- if not configured, in which case that one path just no-ops (see
-- tryAutoWritePattern() below). gt_machine patterns don't need this --
-- they target their own machine's real interface, looked up via the
-- server's /machine_interface endpoint instead.
local AUTO_CRAFT_SCRATCH_INTERFACE = cfg.AUTO_CRAFT_SCRATCH_INTERFACE
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
-- optional (2026-07-24, auto-pattern-write feature) -- a Database Upgrade
-- is only needed to stage item identities for setInterfacePatternInput/
-- Output writes; not required for this script's core craft-job loop, so
-- its absence just disables tryAutoWritePattern() (checked there), not a
-- hard stop here.
local db = component.isAvailable("database") and component.database or nil
dbg("net proxy: " .. tostring(net))
dbg("me proxy : " .. tostring(me))
dbg("db proxy : " .. tostring(db) .. (db and "" or " (auto-pattern-write disabled -- no Database Upgrade connected)"))

-- ── colour helpers ────────────────────────────
local gpu = hasGPU and component.gpu or nil
local W   = gpu and select(1, gpu.getResolution()) or 50
local function fg(c) if gpu then pcall(gpu.setForeground,c) end end
local function cprint(c,t) fg(c); print(t); fg(0xFFFFFF) end
local function cwrite(c,t) fg(c); io.write(t); fg(0xFFFFFF) end

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
-- `quiet`, if true, skips every dbg() call in here (URL/connect/response
-- tracing) -- added because the background job-poll timer calls get()
-- every JOB_POLL_INTERVAL (10s) FOREVER, and the routine "nothing queued"
-- case was going through the exact same per-request tracing meant for
-- one-off interactive commands (status/search/scan_labels), which get
-- flushed to chat right after. The poll tick never flushes on its own
-- (nothing interesting happened), so those lines just piled up in
-- debugLines silently -- until any later flush (an unrelated "flush"/
-- "status"/etc. command) dumped the ENTIRE accumulated backlog into chat
-- in one burst (this is exactly what was reported: hundreds of
-- "waiting for connect... connected... {"job": null}" lines flooding the
-- web viewer at once). `quiet` doesn't touch dbg() itself or the
-- meaningful, rare log lines callers add around a quiet call (e.g.
-- "job-poll: /next_job failed") -- only the routine HTTP-level tracing.
local function httpDo(url, body, headers, quiet)
  if not quiet then dbg("HTTP ".. (body and "POST" or "GET") .." "..url:sub(1,50)) end
  local req, err = net.request(url, body, headers)
  if not req then
    if not quiet then dbg("  request() failed: "..(err or "?")) end
    return nil, err
  end
  if not quiet then dbg("  waiting for connect...") end
  local dl=computer.uptime()+30
  while computer.uptime()<dl do
    local ok,e2=req.finishConnect()
    if ok then if not quiet then dbg("  connected") end; break end
    if ok==nil then
      req.close()
      if not quiet then dbg("  connect failed: "..(e2 or "?")) end
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
  if not quiet then
    dbg("  response len="..#r)
    if #r > 0 then dbg("  response preview: "..r:sub(1,80)) end
  end
  return r, nil
end

local function post(path, tbl, quiet)
  return httpDo(SERVER..path, enc(tbl), {["Content-Type"]="application/json"}, quiet)
end

local function get(path, quiet)
  return httpDo(SERVER..path, nil, nil, quiet)
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

-- ── auto-pattern-write (2026-07-24) ───────────
-- When a queued craft job has no matching AE2 craftable pattern,
-- tryAutoWritePattern() below is called BEFORE giving up: it asks the
-- server for a normalized write plan (GET /pattern_write_plan, see that
-- endpoint's own comment in claude_test.py for why the plan is pre-
-- normalized server-side rather than parsed from raw recipe_db.json here),
-- then writes the pattern directly via me_interface.setInterfacePattern-
-- Input/Output -- the same direct-write API confirmed working in-game by
-- the user on 2026-07-22 (see test_pattern_write_direct_oc.lua, this
-- project's proof-of-concept for the crafting-table case). This is the
-- FIRST time that logic has been wired into the live production craft
-- loop rather than a standalone test script.
--
-- Two target surfaces, chosen by the recipe's type:
--   crafting_shaped/crafting_shapeless -> a configured spare scratch
--     interface (AUTO_CRAFT_SCRATCH_INTERFACE in config.lua) -- these
--     recipes have no machine of their own to target.
--   gt_machine -> that machine's OWN dedicated interface, looked up via
--     GET /machine_interface. UNPROVEN PATH: writing a processing pattern
--     (as opposed to a crafting pattern) via this direct API has never
--     been empirically confirmed in this project's history -- only the
--     crafting-table case has real in-game proof. Treat any success here
--     with the same suspicion the getCraftables() check below is designed
--     to catch: a write call returning true has repeatedly, historically,
--     NOT meant AE2 actually accepted the result as a real pattern.
--
-- Also: fluid-requiring gt_machine recipes are cleanly refused (fluid
-- inputs/outputs are not supported by this direct-write API as currently
-- understood -- see file header of test_pattern_write_direct_oc.lua and
-- claude_test.py's /pattern_write_plan comment) rather than attempting a
-- partial, wrong, item-only pattern.

-- ── split "modid:name:meta" or "modid:name" into id,damage ──
local function splitItemId(s)
  local parts={}
  for p in s:gmatch("[^:]+") do parts[#parts+1]=p end
  if #parts>=3 then
    return parts[1]..":"..parts[2], tonumber(parts[3]) or 0
  elseif #parts==2 then
    return parts[1]..":"..parts[2], 0
  end
  return s, 0
end

-- ── tiny JSON array-of-strings extractor (ported from
-- test_pattern_write_direct_oc.lua -- still needed here for /oredict's
-- plain-string "entries" array; the NEW /pattern_write_plan "inputs" array
-- of OBJECTS uses parseInputsArray() below instead, since this one can't
-- handle nested objects) ──
local function extractArr(raw, key)
  local s = raw:match('"'..key..'":%s*(%[.-%])')
  if not s then return nil end
  local out={}
  for entry in s:gmatch('([^,%[%]]+)') do
    entry=entry:match("^%s*(.-)%s*$")
    if entry=="null" then out[#out+1]=false
    elseif entry:sub(1,1)=='"' then out[#out+1]=entry:match('"([^"]*)"') end
  end
  return out
end

-- ── resolve an ore:xxx tag to a concrete item via the authoritative
-- ore_dict.json table on the server (see test_pattern_write_direct_oc.lua's
-- own comment for the full reasoning -- ported verbatim, proven logic) ──
local function resolveOreTag(tag)
  local encoded = tag:gsub(":", "%%3A")
  -- not quiet: auto-write only runs on a genuine job failure (rare), and
  -- this is a brand-new, unproven feature -- the extra HTTP trace is worth
  -- having in the log for debugging, unlike the 10s job-poll loop below.
  local raw, err = get("/oredict?tag="..encoded)
  if not raw then return nil, "oredict lookup failed: "..tostring(err) end
  if not raw:find('"found":%s*true') then
    return nil, "no oredict entries for "..tag.." (tag not in ore_dict.json)"
  end

  local entries = extractArr(raw, "entries")
  if not entries or #entries == 0 then
    return nil, "oredict lookup returned no entries for "..tag
  end

  local ok, items = pcall(me.getItemsInNetwork, {})
  local stockByKey = {}
  if ok and items then
    for _, it in ipairs(items) do
      stockByKey[(it.name or "")..":"..tostring(it.damage or 0)] = it
    end
  end

  local bestId, bestDmg, bestStock, bestSize = nil, nil, nil, -1
  for _, e in ipairs(entries) do
    local id, dmg = splitItemId(e)
    local stocked = stockByKey[id..":"..tostring(dmg)]
    local size = stocked and (stocked.size or 0) or 0
    if size > bestSize then
      bestId, bestDmg, bestStock, bestSize = id, dmg, stocked, size
    end
  end

  if not bestId then return nil, "no candidates resolved for "..tag end
  dbg(string.format("  [NOTE] resolved %s -> %s:%d (%s)",
    tag, bestId, bestDmg, bestSize > 0 and ("you have "..bestSize) or "none in stock -- using first candidate"))
  return bestId, bestDmg
end

local function resolveEntry(entry)
  if entry:sub(1,4)=="ore:" then
    return resolveOreTag(entry)
  else
    return splitItemId(entry)
  end
end

-- ── parse /pattern_write_plan's "inputs" array of {"index","entry","count"}
-- objects. Uses Lua's %b{} balanced-brace pattern to pull out each object
-- (safe here because the server always emits this array flat, no nested
-- braces inside an entry -- see claude_test.py's /pattern_write_plan
-- comment on why it emits this fixed, uniform shape specifically so this
-- side doesn't need a real JSON parser). Tolerant of json.dumps' default
-- ", "/": " spacing via %s* between fields. ──
local function parseInputsArray(raw)
  local arrStr = raw:match('"inputs"%s*:%s*(%[.-%])')
  if not arrStr then return {} end
  local out = {}
  for obj in arrStr:gmatch('%b{}') do
    local idx   = obj:match('"index"%s*:%s*(%d+)')
    local entry = obj:match('"entry"%s*:%s*"(.-)"')
    local cnt   = obj:match('"count"%s*:%s*(%d+)')
    if idx and entry then
      out[#out+1] = {index=tonumber(idx), entry=entry, count=tonumber(cnt) or 1}
    end
  end
  return out
end

-- ── fetch + parse a normalized write plan for one item. Returns
-- (plan, nil) on success, (nil, reason) otherwise -- `reason` is always a
-- human-readable string suitable for a chat failure message. ──
local function fetchWritePlan(item)
  local encoded = item:gsub(":", "%%3A")
  -- not quiet -- see resolveOreTag's comment on why this feature's rare
  -- HTTP calls are worth tracing, unlike the 10s job-poll loop below.
  local raw, err = get("/pattern_write_plan?item="..encoded)
  if not raw then return nil, "pattern_write_plan request failed: "..tostring(err) end
  if not raw:find('"found"%s*:%s*true') then
    return nil, extractStr(raw, "reason") or "no write plan available"
  end
  local inputs = parseInputsArray(raw)
  if #inputs == 0 then
    return nil, "write plan has no resolvable inputs"
  end
  return {
    rtype        = extractStr(raw, "rtype"),
    machine      = extractStr(raw, "machine"),
    outputEntry  = extractStr(raw, "output_entry") or item,
    outputCount  = extractNum(raw, "output_count") or 1,
    requiresFluid= raw:find('"requires_fluid"%s*:%s*true') ~= nil,
    inputs       = inputs,
  }, nil
end

-- ── clear whatever's in a pattern slot before rewriting (tolerant of
-- errors either way, same as test_pattern_write_direct_oc.lua -- no
-- "priming" needed for this direct-write API) ──
local function clearPattern(meiProxy, patternIndex, maxIn, maxOut)
  for i=1,maxIn do
    pcall(meiProxy.clearInterfacePatternInput, patternIndex, i)
  end
  for o=1,maxOut do
    pcall(meiProxy.clearInterfacePatternOutput, patternIndex, o)
  end
end

-- ── sweep a me_interface's pattern slots for an empty one, so auto-write
-- never clobbers an existing real pattern. Confirmed range: 9 pattern
-- slots per interface, 1-indexed for writes (see PATTERN_INDEX comment in
-- test_pattern_write_direct_oc.lua, confirmed live 2026-07-22) -- swept as
-- 1..9 here specifically (NOT scan_patterns_oc.lua's wider 0..9 READ probe
-- range, which exists there only because that script wasn't sure of the
-- base and 0..9 safely supersets both possibilities for a read; writing to
-- an unconfirmed index 0 is not worth the risk here). A slot is "empty" iff
-- getInterfacePattern() succeeds and returns nil/false -- a slot whose read
-- THREW is treated as unknown/unsafe and skipped, not empty. ──
local function findEmptyPatternSlot(meiProxy)
  for i=1,9 do
    local ok, pattern = pcall(meiProxy.getInterfacePattern, i)
    if ok and not pattern then
      return i
    end
  end
  return nil, "no empty pattern slot found (all 9 occupied, or every probe errored)"
end

-- ── write one plan into one pattern slot on one interface. Returns
-- (true, outId, outDmg) on success (write calls all returned true --
-- caller MUST still verify via getCraftables(), see tryAutoWritePattern),
-- or (false, reason) if a resolve/write step failed outright. ──
local function writePatternToInterface(meiProxy, patternIndex, plan)
  clearPattern(meiProxy, patternIndex, 9, 4)

  local dbSlot = 1
  for _, input in ipairs(plan.inputs) do
    local id, dmg = resolveEntry(input.entry)
    if not id then
      return false, "could not resolve ingredient '"..input.entry.."'"
    end
    local okSet = pcall(db.set, dbSlot, id, dmg)
    if not okSet then
      return false, "database.set failed (slot "..dbSlot..") for "..id
    end
    local okWrite, writeErr = pcall(meiProxy.setInterfacePatternInput,
      patternIndex, db.address, dbSlot, input.count, input.index)
    if not okWrite then
      return false, "setInterfacePatternInput failed (db slot "..dbSlot..", grid index "..input.index.."): "..tostring(writeErr)
    end
    dbSlot = dbSlot + 1
  end

  local outId, outDmg = splitItemId(plan.outputEntry)
  local okSetOut = pcall(db.set, dbSlot, outId, outDmg)
  if not okSetOut then
    return false, "database.set (output) failed (slot "..dbSlot..")"
  end
  local okWriteOut, writeOutErr = pcall(meiProxy.setInterfacePatternOutput,
    patternIndex, db.address, dbSlot, plan.outputCount, 1)
  if not okWriteOut then
    return false, "setInterfacePatternOutput failed (slot "..dbSlot.."): "..tostring(writeOutErr)
  end

  return true, outId, outDmg
end

-- ── THE check that actually matters (see test_pattern_write_direct_oc.lua's
-- extensive comment on why): does the output genuinely show up in
-- me_controller.getCraftables()? A write call returning true has, all
-- through this project's history, never been reliable proof by itself. ──
local function verifyCraftable(outId, outDmg)
  local ok, craftables = pcall(me.getCraftables)
  if not ok or not craftables then return false end
  for _, c in ipairs(craftables) do
    local okStack, stack = pcall(c.getItemStack)
    if okStack and stack and stack.name == outId and (stack.damage or 0) == outDmg then
      return true
    end
  end
  return false
end

-- ── top-level orchestrator, called from claimAndStartJobs() when no
-- existing craftable pattern matches a queued job's item. Returns
-- (true, nil) on a VERIFIED success (getCraftables() confirms it), or
-- (false, reason) for every other outcome -- caller falls back to the
-- normal "no pattern found" job failure either way, just with a more
-- specific reason attached. ──
local function tryAutoWritePattern(jobItem)
  if not db then
    return false, "no Database Upgrade connected -- auto-write disabled"
  end

  local plan, planErr = fetchWritePlan(jobItem)
  if not plan then
    return false, "no write plan: "..tostring(planErr)
  end
  if plan.requiresFluid then
    return false, "recipe needs fluid input/output -- direct pattern write doesn't support fluids"
  end

  local meiProxy, targetDesc, slot, slotErr

  if plan.rtype == "gt_machine" then
    if not plan.machine then
      return false, "gt_machine recipe has no machine name on record"
    end
    targetDesc = "machine '"..plan.machine.."'s own interface"
    local encodedMachine = plan.machine:gsub(" ", "+"):gsub(":", "%%3A")
    local miRaw, miErr = get("/machine_interface?machine="..encodedMachine)
    if not miRaw then
      return false, "machine_interface lookup failed: "..tostring(miErr)
    end
    if not miRaw:find('"found"%s*:%s*true') then
      return false, "no dedicated interface for '"..plan.machine.."': "..(extractStr(miRaw, "reason") or "?")
    end
    local addr = extractStr(miRaw, "interface_address")
    if not addr then
      return false, "machine_interface response missing interface_address"
    end
    local okProxy, proxyOrErr = pcall(component.proxy, addr)
    if not okProxy or not proxyOrErr then
      -- NOTE: this fails cleanly (not a crash) if this computer isn't on
      -- the same OC component network as that interface's Adapter -- a
      -- real, unverified assumption for the gt_machine path specifically
      -- (see the big comment block above this section).
      return false, "could not reach interface "..addr.." from this computer: "..tostring(proxyOrErr)
    end
    meiProxy = proxyOrErr
    dbg("auto-write: UNPROVEN gt_machine path -- targeting "..targetDesc.." (addr "..addr:sub(1,8)..")")
  else
    -- crafting_shaped / crafting_shapeless
    if not AUTO_CRAFT_SCRATCH_INTERFACE then
      return false, "no AUTO_CRAFT_SCRATCH_INTERFACE configured in config.lua -- see config.example.lua"
    end
    targetDesc = "the configured scratch interface"
    local okProxy, proxyOrErr = pcall(component.proxy, AUTO_CRAFT_SCRATCH_INTERFACE)
    if not okProxy or not proxyOrErr then
      return false, "could not reach configured scratch interface: "..tostring(proxyOrErr)
    end
    meiProxy = proxyOrErr
  end

  slot, slotErr = findEmptyPatternSlot(meiProxy)
  if not slot then
    return false, "no empty pattern slot on "..targetDesc..": "..tostring(slotErr)
  end

  dbg("auto-write: writing "..plan.rtype.." pattern for "..jobItem.." onto "..targetDesc..", slot "..slot)
  local ok, outIdOrReason, outDmg = writePatternToInterface(meiProxy, slot, plan)
  if not ok then
    return false, "write failed: "..tostring(outIdOrReason)
  end

  -- give AE2 a moment to index the new pattern before checking
  os.sleep(0.5)
  if not verifyCraftable(outIdOrReason, outDmg) then
    return false, "wrote pattern but "..outIdOrReason..":"..outDmg.." still isn't in getCraftables() -- AE2 likely rejected it"
  end

  dbg("auto-write: CONFIRMED -- "..outIdOrReason..":"..outDmg.." now craftable (verified via getCraftables())")
  return true, nil
end

-- ── background craft-job polling ──────────────
-- Claude can queue a craft job (via tools/request_craft.py -> POST
-- /request_craft) from EITHER the web chat or this terminal -- so this
-- can't just be checked when someone happens to be typing here. Instead
-- of rewriting the existing io.read()-based chat loop (proven working
-- after this project's earlier truncation/io.read() debugging saga --
-- not touching it is deliberate), this uses OpenOS's own event.timer(),
-- which fires a callback on a schedule independent of the main loop, as
-- long as the script keeps yielding to the event system somewhere --
-- which io.read() (and every net.request() wait-loop in this file)
-- already does constantly. No change to the chat loop itself is needed.
local JOB_POLL_INTERVAL = 10  -- seconds between queue checks
local activeCraftJobs = {}    -- jobId -> {craftJob=<AECraftingJob>, item=.., qty=.., cpuName=..}

-- Checks every craft job we've already submitted this session for
-- completion/failure and reports back exactly once each way -- cheap,
-- no blocking waits, just a non-blocking status check per job per tick.
local function pollActiveCraftJobs()
  for jobId, info in pairs(activeCraftJobs) do
    local okFail, hasFailed     = pcall(info.craftJob.hasFailed)
    local okCancel, isCanceled  = pcall(info.craftJob.isCanceled)
    local okDone, isDone        = pcall(info.craftJob.isDone)
    if (okFail and hasFailed) or (okCancel and isCanceled) then
      dbg("job "..jobId.." failed/canceled")
      post("/report_job_result", {job_id=jobId, success=false,
        details="AE2 reported the craft as failed or canceled."})
      cprint(0xFF4444, "\n[job] "..info.qty.."x "..info.item.." FAILED (AE2 reported failed/canceled).")
      activeCraftJobs[jobId] = nil
    elseif okDone and isDone then
      dbg("job "..jobId.." finished")
      post("/report_job_result", {job_id=jobId, success=true,
        details="Craft completed on CPU '"..info.cpuName.."'."})
      cprint(0x00FF00, "\n[job] "..info.qty.."x "..info.item.." completed.")
      activeCraftJobs[jobId] = nil
    end
    -- else: still computing -- leave it, check again next tick
  end
end

-- Claims and submits as many queued jobs as there are CURRENTLY FREE AE2
-- CPUs, once per tick -- previously this claimed at most ONE job per
-- JOB_POLL_INTERVAL tick even if several CPUs sat idle simultaneously,
-- throttling a deep backlog to one new job per 10s no matter how much
-- spare capacity existed. Now: snapshot free CPUs ONCE at the top of the
-- tick, then walk that list assigning one still-queued job per free CPU
-- (oldest-first, same FIFO /next_job already enforced) -- so N idle CPUs
-- can pick up N jobs in the same tick. The CPU check still happens HERE,
-- immediately before submitting, not when Claude originally queued the
-- job (explicit design requirement: check right before executing) -- it
-- just now covers every CPU at once instead of only the first free one.
--
-- Because we never claim more jobs than we've already confirmed free
-- CPUs for, the old "claimed a job, then discovered no CPU was free"
-- situation can no longer happen here -- the retryable/no-free-CPU path
-- in handle_report_job_result (server side) is left in place as generic,
-- harmless infrastructure (still exercised by its own test), just not
-- reachable from this particular loop anymore.
local function claimAndStartJobs()
  local okCpus, cpus = pcall(me.getCpus)
  if not okCpus or not cpus then
    dbg("job-poll: getCpus failed: "..tostring(cpus))
    return  -- nothing claimed yet, nothing to report -- try again next tick
  end

  local freeCpus = {}
  for _, c in ipairs(cpus) do
    if not c.busy then freeCpus[#freeCpus+1] = c end
  end
  if #freeCpus == 0 then
    return  -- every CPU busy -- queue untouched, no log spam, try again next tick
  end

  local okCraftables, craftables = pcall(me.getCraftables)
  if not okCraftables or not craftables then
    dbg("job-poll: getCraftables failed: "..tostring(craftables))
    return  -- can't match anything this tick without this list -- try again next tick
  end

  for _, freeCpu in ipairs(freeCpus) do
    local raw, err = get("/next_job", true)  -- quiet: this fires every ~10s forever, don't trace it
    if not raw then
      dbg("job-poll: /next_job failed: "..(err or "?"))
      break  -- server hiccup -- stop for this tick, next tick retries
    end
    if raw:find('"job"%s*:%s*null') then
      break  -- queue is empty -- nothing left to hand to the remaining free CPUs
    end

    local jobId   = extractStr(raw, "id")
    local jobItem = extractStr(raw, "item")
    local jobQty  = extractNum(raw, "qty")
    if not jobId or not jobItem or not jobQty then
      dbg("job-poll: malformed job response: "..raw:sub(1,200))
      break
    end

    cprint(0x00FFFF, "\n[job] Picked up craft job: "..jobQty.."x "..jobItem.." (job "..jobId..") -> cpu "..freeCpu.name)
    dbg("job-poll: claimed "..jobId..": "..jobQty.."x "..jobItem.." -> cpu "..freeCpu.name)

    -- NOTE: this file's existing getCraftables() (above) reads `.name`
    -- directly off each craftable, but the official AECraftable API docs
    -- only document `.getItemStack()` (which returns a stack with `.name`)
    -- -- not a bare `.name` field. Unclear which is actually right for
    -- this GTNH version without a real in-game check, so this tries both:
    -- direct `.name` first (matching the existing convention elsewhere in
    -- this file), falling back to `.getItemStack().name` if that's absent.
    local target = nil
    for _, c in ipairs(craftables) do
      local candidateName = c.name
      if not candidateName then
        local okStack, stack = pcall(c.getItemStack)
        if okStack and stack then candidateName = stack.name end
      end
      if candidateName == jobItem then
        target = c
        break
      end
    end
    if not target then
      dbg("job-poll: no craftable pattern found for "..jobItem..", attempting auto-write...")
      cprint(0x888888, "[job] No pattern found for "..jobItem.." -- attempting to auto-write one...")

      local wrote, writeErr = tryAutoWritePattern(jobItem)
      if wrote then
        dbg("job-poll: auto-write CONFIRMED for "..jobItem..", re-checking craftables for this job")
        cprint(0x00FF00, "[job] Auto-write succeeded and was verified -- retrying this job.")
        local okRecheck, recraftables = pcall(me.getCraftables)
        if okRecheck and recraftables then
          for _, c in ipairs(recraftables) do
            local candidateName = c.name
            if not candidateName then
              local okStack, stack = pcall(c.getItemStack)
              if okStack and stack then candidateName = stack.name end
            end
            if candidateName == jobItem then
              target = c
              break
            end
          end
        end
      else
        dbg("job-poll: auto-write did not produce a usable pattern for "..jobItem..": "..tostring(writeErr))
      end

      if not target then
        local reason = "no AE2 craftable pattern found for "..jobItem.." -- is a pattern encoded for it? "
          ..(wrote and "(auto-write reported success but the pattern still isn't usable)"
                    or ("(auto-write attempt: "..tostring(writeErr)..")"))
        post("/report_job_result", {job_id=jobId, success=false, details=reason})
        cprint(0xFF4444, "[job] FAILED -- no craftable pattern found for "..jobItem..".")
        -- this CPU slot goes unused this tick (deliberately simple: move on
        -- to the NEXT free cpu / next queued job rather than retrying this
        -- same slot against another job -- the skipped job will just be
        -- picked up on a later free-cpu slot, this tick or a later one)
        goto continue_loop
      end

      cprint(0x00FFFF, "[job] Auto-written pattern found -- proceeding with "..jobQty.."x "..jobItem.." on cpu "..freeCpu.name)
    end

    do
      local okReq, craftJob = pcall(target.request, jobQty, false, freeCpu.name)
      if not okReq or not craftJob then
        dbg("job-poll: request() failed: "..tostring(craftJob))
        post("/report_job_result", {job_id=jobId, success=false,
          details="AE2 request() call failed: "..tostring(craftJob)})
        cprint(0xFF4444, "[job] FAILED -- AE2 request() call errored.")
        goto continue_loop
      end

      activeCraftJobs[jobId] = {craftJob=craftJob, item=jobItem, qty=jobQty, cpuName=freeCpu.name}
      dbg("job-poll: "..jobId.." submitted on cpu "..freeCpu.name)
      cprint(0x888888, "[job] Submitted on CPU '"..freeCpu.name.."' -- will report back once it finishes.")
    end

    ::continue_loop::
  end
end

-- ── item-label scan (shared by the manual "scan_labels" command AND ──
-- the background label-scan-request poll below) ───────────────────────
-- Extracted 2026-07-24 (user's ask: "the server claude can't seem to run
-- [scan_labels]") -- this used to be inline in the manual command only,
-- reachable exclusively by a player physically typing "scan_labels" at
-- this terminal. Claude has no access to the live game world at all
-- (see claude_test.py's pending_label_scans.json comment for the full
-- explanation), so making this genuinely "server-side" isn't possible --
-- instead this same logic is now callable from a background poll too,
-- so Claude can QUEUE a request that this computer picks up on its own,
-- no typing required. Returns
-- (ok, entryCount, newCount, changedCount, totalCount, errMsg):
--   ok=false -> getItemsInNetwork() or the /report_labels POST itself
--               failed; errMsg has the reason, other numbers are 0
--   ok=true  -> counts are meaningful (newCount/changedCount/totalCount
--               default to 0/entryCount if the server's response didn't
--               parse cleanly, which shouldn't normally happen)
local function runLabelScan()
  local ok, items = pcall(me.getItemsInNetwork)
  if not ok or not items then
    return false, 0, 0, 0, 0, "getItemsInNetwork failed: "..tostring(items)
  end

  local entries = {}
  for _, it in ipairs(items) do
    if it.name and it.label then
      entries[#entries+1] = {id = it.name, damage = it.damage or 0, label = it.label}
    end
  end

  local raw, perr = post("/report_labels", {entries=entries})
  if not raw then
    return false, #entries, 0, 0, 0, "report failed: "..(perr or "?")
  end

  local newCount     = extractNum(raw, "new") or 0
  local changedCount = extractNum(raw, "changed") or 0
  local totalCount   = extractNum(raw, "total") or #entries
  return true, #entries, newCount, changedCount, totalCount, nil
end

-- ── background item-label-scan request poll ───
-- Claude queues one via tools/request_label_scan.py -> POST
-- /request_label_scan; this polls GET /next_label_scan for one, on the
-- SAME jobPollTick() cadence as the craft-job poll below (piggybacked
-- onto the existing timer rather than a second one -- label scans are
-- rare, no need for their own schedule). Repeat-suppression on
-- persistent poll failures follows the exact pattern already fixed in
-- scan_patterns_oc.lua's checkForScanRequest() (see that file's
-- 2026-07-24 history) -- first occurrence logs immediately, then only
-- every 100th repeat, resetting the moment a healthy response comes back.
local lastLabelScanPollProblem = nil
local lastLabelScanPollProblemCount = 0
local function reportLabelScanPollProblem(msg)
  if msg == lastLabelScanPollProblem then
    lastLabelScanPollProblemCount = lastLabelScanPollProblemCount + 1
    if lastLabelScanPollProblemCount % 100 == 0 then
      dbg("label-scan-poll: (still failing, "..lastLabelScanPollProblemCount.." consecutive) "..msg)
      flushDebug("label-scan-poll-repeat")
    end
    return
  end
  lastLabelScanPollProblem = msg
  lastLabelScanPollProblemCount = 1
  dbg("label-scan-poll: "..msg)
  flushDebug("label-scan-poll-problem")
end

local function checkForLabelScanRequest()
  local raw, err = get("/next_label_scan", true)  -- quiet: fires every JOB_POLL_INTERVAL forever, don't trace routine HTTP
  if not raw then
    reportLabelScanPollProblem("/next_label_scan failed: "..(err or "?"))
    return
  end
  if raw:find('"scan"%s*:%s*null') then
    lastLabelScanPollProblem, lastLabelScanPollProblemCount = nil, 0  -- healthy -- next failure logs immediately
    return  -- nothing queued right now
  end

  local scanId = extractStr(raw, "id")
  if not scanId then
    reportLabelScanPollProblem("malformed /next_label_scan response: "..raw:sub(1,200))
    return
  end

  lastLabelScanPollProblem, lastLabelScanPollProblemCount = nil, 0
  dbg("label-scan-poll: claimed label scan request "..scanId)
  cprint(0x888888, "\n[label-scan] Running a queued item-label scan (requested by Claude)...")

  local ok, entryCount, newCount, changedCount, totalCount, errMsg = runLabelScan()
  if not ok then
    dbg("label-scan-poll: "..tostring(errMsg))
    cprint(0xFF4444, "[label-scan] FAILED: "..tostring(errMsg))
    post("/report_label_scan_result", {scan_id=scanId, success=false, details=tostring(errMsg)})
  else
    local details = string.format("%d new, %d changed, %d total known (from %d labeled item(s) found)",
      newCount, changedCount, totalCount, entryCount)
    dbg("label-scan-poll: "..details)
    cprint(0x00FF00, "[label-scan] done -- "..details)
    post("/report_label_scan_result", {scan_id=scanId, success=true, details=details})
  end
  flushDebug("label-scan-poll-complete")
end

local function jobPollTick()
  local ok1, e1 = pcall(pollActiveCraftJobs)
  if not ok1 then dbg("pollActiveCraftJobs errored: "..tostring(e1)) end
  local ok2, e2 = pcall(claimAndStartJobs)
  if not ok2 then dbg("claimAndStartJobs errored: "..tostring(e2)) end
  local ok3, e3 = pcall(checkForLabelScanRequest)
  if not ok3 then dbg("checkForLabelScanRequest errored: "..tostring(e3)) end
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

-- ── main ──────────────────────────────────────
-- NOTE (2026-07-22): this script used to ALSO forward free-typed input to
-- Claude via POST /chat (with its own JSON action-schema SYSTEM prompt)
-- and, on an "action":"craft" reply, call a local triggerAutocraft() that
-- submitted straight to AE2 with no CPU selection or free-CPU check at
-- all (plain target.request(amount)) -- this was exactly the "stucks the
-- CPU, only uses 1 CPU" behavior that motivated the whole job-queue
-- system above. Both the chat-forwarding branch and triggerAutocraft()
-- have been REMOVED, not just disabled: all real conversation with
-- Claude now happens through the web viewer only (which has its own full
-- chat UI), and Claude dispatches crafts via tools/request_craft.py ->
-- the job queue -> claimAndStartOneJob() above, which DOES check for a
-- free CPU before submitting. This terminal now only handles direct
-- commands (status/search/scan_labels) plus the background job poll.

term.clear(); term.setCursor(1,1)
cprint(0x00FFFF, "=== Claude Crafting ===")
cprint(0x888888, "Commands: status | search <q> | scan_labels | clear | quit | flush")
cprint(0x888888, "(chat with Claude now happens from the web viewer -- this terminal just runs commands + crafts)")
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

-- Background job polling starts here -- fires roughly every
-- JOB_POLL_INTERVAL seconds for as long as this script runs, independent
-- of whether anyone is typing (a queued job can come from the web chat
-- with nobody at this terminal at all). Does NOT touch or replace the
-- io.read()-based loop below.
event.timer(JOB_POLL_INTERVAL, jobPollTick, math.huge)
dbg("job-poll timer registered, interval="..JOB_POLL_INTERVAL.."s")

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
    debugLines={}
    cprint(0x888888,"[i] Debug log cleared.")

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

  elseif input:lower()=="scan_labels" then
    -- Manual, explicitly-triggered version of the exact same scan the
    -- background poll can now also run on Claude's behalf (see
    -- runLabelScan()'s comment above, and tools/request_label_scan.py) --
    -- both paths share runLabelScan() so there's exactly one
    -- implementation of the actual scan logic. me.getItemsInNetwork()
    -- with no filter enumerates the WHOLE ME network; buildInventory()
    -- above already calls it every craft request for item counts, but
    -- this additionally captures each item's .label and reports the
    -- id->label pairs to the server so it can build a persistent,
    -- reusable name index (item_labels.json) -- see claude_test.py's
    -- handle_report_labels().
    dbg("scan_labels command")
    cwrite(0x888888,"[~] Scanning ME network for item labels (may take a moment)... ")
    local ok, entryCount, newCount, changedCount, totalCount, errMsg = runLabelScan()
    if not ok then
      cprint(0xFF4444, "failed: "..tostring(errMsg))
      dbg("scan_labels: "..tostring(errMsg))
      flushDebug("scan-labels-fail")
    else
      cprint(0x00FF00, "done. "..entryCount.." labeled item(s) found. Reporting to server...")
      cprint(0x00FFFF, string.format(
        "[OK] label db updated -- %d new, %d changed, %d total known.",
        newCount, changedCount, totalCount))
      dbg("scan_labels: report ok -- "..newCount.." new, "..changedCount.." changed, "..totalCount.." total")
      flushDebug("scan-labels-ok")
    end

  else
    dbg("unknown command: "..input)
    cprint(0xFFAA00, "[?] Unknown command. Commands: status | search <q> | scan_labels | clear | quit | flush")
    cprint(0x888888, "    To chat with Claude or request a craft, use the web viewer.")
    flushDebug("unknown-command")
  end

  ::continue::
end
