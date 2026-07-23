-- =============================================
--  scan_patterns_oc.lua
--  Scans every connected AE2 ME Interface's pattern
--  slots and reports each occupied one (exact item
--  id/damage/count for every input+output) to the PC
--  server, which remembers "which interface + which
--  slot" a recipe physically lives at so it can be
--  replicated later.
--
--  READ-ONLY: this script never writes to any pattern.
--  It only calls getInterfacePattern (a plain read) and
--  storeInterfacePatternInput/Output, which copy an
--  EXISTING pattern's contents into a database slot --
--  it cannot create or alter a pattern. That means none
--  of the fabrication-exploit risk that direct
--  me_interface pattern WRITES carry applies here -- see
--  test_pattern_write_oc.lua's header for that story.
--
--  Requires:
--    - internet card
--    - one or more me_interface components (each ME
--      Interface you want scanned needs its own OC
--      Adapter touching it, or must be directly adjacent
--      to this computer)
--    - database  : a Database Upgrade (any tier), used as
--                  scratch space -- storeInterfacePattern-
--                  Input/Output only accept a database
--                  slot as their destination, not a plain
--                  return value, so we stash one item at a
--                  time there and immediately read it back
--                  with database.get()
--
--  INDEXING CAVEAT: the OC/AE2 Lua bindings are not
--  consistently 0- or 1-indexed across all their methods
--  (confirmed inconsistent even within this same mod's OC
--  driver -- see test_pattern_write_oc.lua's clearPattern()
--  comment: the OC Pattern Editor is 1-indexed, but the
--  OLD me_interface grid slots were 0-indexed). Neither
--  this script's target hardware nor the official docs
--  pin down getInterfacePattern's patternIndex base, or
--  storeInterfacePatternInput/Output's inputIndex/
--  outputIndex base. Rather than guess and risk silently
--  scanning the wrong slots forever, this script PROBES:
--    - pattern discovery tries patternIndex 0 through 9,
--      a strict superset of both a 0-based 0-8 range and a
--      1-based 1-9 range (9 pattern slots per interface).
--    - each individual slot read tries both a k and a k-1
--      index, verified by actually checking the scratch
--      database slot got populated (not just that the call
--      returned true without throwing).
--  Whichever convention is wrong for your setup will simply
--  and safely find nothing there, ever -- see storeSlot().
-- =============================================

local component = require("component")
local computer  = require("computer")
local io        = require("io")
local os        = require("os")

local DISK = "/home"   -- where scripts + config live (was /mnt/dc6 -- moved to /home, stable across disk swaps)

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
local SCRIPT_NAME = "scan_patterns_oc"

if not component.isAvailable("internet") then
  print("[FAIL] no internet card")
  io.read(); return
end
local net = component.internet

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

local debugLines = {}
local function dbg(text)
  local t = string.format("[%.1fs] %s", computer.uptime(), text)
  print(t)
  debugLines[#debugLines+1] = t
  local lf = io.open(LOG_FILE, "a")
  if lf then lf:write(t.."\n"); lf:close() end
end

local function flushDebug(label)
  if #debugLines == 0 then return end
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
  if not prev or prev == "" then return end
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

-- ── manual JSON string/object builders ─────────
-- (not craft_oc.lua's generic enc(v) table encoder -- that one can't
-- tell an empty Lua array {} apart from an empty object {}, since Lua
-- tables don't distinguish the two, and #v==0 either way. This script
-- always knows exactly which fields are strings/numbers/arrays, so it
-- builds the JSON by hand instead and sidesteps that ambiguity.)
local function jsonStr(s)
  return '"'..tostring(s):gsub('\\','\\\\'):gsub('"','\\"')
              :gsub('\n','\\n'):gsub('\r','\\r')..'"'
end

local function encodeItem(item)
  return string.format('{"index":%d,"id":%s,"damage":%d,"count":%d,"label":%s}',
    item.index, jsonStr(item.id), item.damage, item.count, jsonStr(item.label))
end

local function encodeItemsArray(items)
  local parts = {}
  for _, it in ipairs(items) do parts[#parts+1] = encodeItem(it) end
  return "["..table.concat(parts, ",").."]"
end

local function encodeReport(addr, label, patternIndex, inputs, outputs)
  return string.format(
    '{"interface_address":%s,"interface_label":%s,"pattern_index":%d,"inputs":%s,"outputs":%s}',
    jsonStr(addr), jsonStr(label), patternIndex,
    encodeItemsArray(inputs), encodeItemsArray(outputs))
end

-- ── HTTP helpers (connect, wait, read whole response) ──
local function postJson(path, bodyStr)
  local req, err = net.request(SERVER..path, bodyStr, {["Content-Type"]="application/json"})
  if not req then return nil, err end
  local dl = computer.uptime()+15
  while computer.uptime()<dl do
    local ok, e2 = req.finishConnect()
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

-- plain GET, same connect/read shape as postJson but no request body --
-- needed for polling /next_scan (this file never needed a GET before,
-- since scanning used to be purely fire-and-forget POST reports)
local function getJson(path)
  local req, err = net.request(SERVER..path)
  if not req then return nil, err end
  local dl = computer.uptime()+15
  while computer.uptime()<dl do
    local ok, e2 = req.finishConnect()
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

-- minimal JSON field extractor -- mirrors craft_oc.lua's extractStr, kept
-- as its own copy here since these are separate standalone scripts
local function extractStr(raw, key)
  local p = raw:match('"'..key..'":%s*"(.-[^\\])"')
  if p then return p:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\\\','\\') end
  return nil
end

-- ── hardware checks ─────────────────────────────
if not component.isAvailable("database") then
  dbg("[FAIL] no database component found.")
  dbg("       Connect an OC Adapter to a Database Upgrade (any tier).")
  flushDebug("hw-fail")
  io.read(); return
end
local db = component.database

-- BUG FIX 2026-07-24: this used to be captured ONCE here at script
-- startup and never touched again, so `runFullScan()` kept scanning the
-- exact same address list for the script's entire lifetime -- any
-- me_interface added to the network (new Adapter wired up, new machine
-- brought online) AFTER this script last started was invisible to every
-- scan until the script itself was restarted. Confirmed live: a player
-- added a new interface (address b6b51d77) and it never once showed up
-- in any scan, while the two interfaces present at startup kept getting
-- scanned normally scan after scan. Fixed by making this a function,
-- called fresh at the top of every runFullScan() (see below) instead of
-- a value computed once and reused forever -- still used here too, for
-- the one-time startup hardware sanity check.
local function getInterfaceList()
  local list = {}
  for addr in component.list("me_interface") do
    list[#list+1] = addr
  end
  return list
end

local interfaces = getInterfaceList()
if #interfaces == 0 then
  dbg("[FAIL] no me_interface components found.")
  dbg("       Each ME Interface you want scanned needs its own OC")
  dbg("       Adapter touching it (or must be directly adjacent to")
  dbg("       this computer).")
  flushDebug("hw-fail")
  io.read(); return
end
dbg(string.format("[OK] found %d me_interface component(s) at startup", #interfaces))
flushDebug("hw-ok")

-- ── scratch database slot used to read one item at a time ──
local SCRATCH_SLOT = 1

-- Does item.label (from database.get, exact but only known AFTER a
-- store) plausibly match expectedName (from MEPatternSlot.name, a
-- localized display name we already got for free from
-- getInterfacePattern -- no extra call). Loose containment match in
-- both directions since exact string formatting can differ (e.g.
-- "Redstone Dust" vs "redstone dust").
local function namesRoughlyMatch(label, expectedName)
  if not expectedName or expectedName == "" then return true end
  local a = tostring(label or ""):lower()
  local b = tostring(expectedName):lower()
  if a == "" then return false end
  return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

-- Try storing one input/output slot into the scratch DB slot at both a
-- k and a k-1 index (see INDEXING CAVEAT above). Returns the resulting
-- {id,damage,count,label} table, or nil if neither convention produced
-- a real, correctly-matching item in the scratch slot.
--
-- Two failure modes this specifically guards against (both found by
-- simulating this script against a mock 0-/1-indexed AE2 network
-- before ever running it in-game -- see the project's history of
-- "write/read succeeds but the result is subtly wrong" false
-- positives with this same AE2 OC API surface):
--   1. STALE SCRATCH DATA: the scratch DB slot is reused across every
--      probe. If storeFn's own boolean return says "no such index"
--      (correctly reporting a wrong-convention guess) but we only
--      checked "did the call throw", a match found by an EARLIER,
--      unrelated probe would still be sitting in the scratch slot and
--      get misread as this probe's result. Fixed by clearing the
--      scratch slot before every attempt AND requiring storeFn's own
--      return value to be true, not just "didn't throw".
--   2. WRONG-BUT-VALID SLOT: if the real convention is 0-based, a
--      probe at raw index k (meant for canonical slot k+1) can still
--      return a real item -- just the WRONG one for canonical slot k.
--      Both probe attempts can "succeed" in the sense of returning
--      *an* item, silently picking whichever happens first. Fixed by
--      cross-checking the returned item's label against the
--      MEPatternSlot name already returned for this canonical slot by
--      getInterfacePattern -- a mismatch means we hit a real item, but
--      the wrong one, so we keep trying rather than accepting it.
-- Returns (item, nil) on success, or (nil, lastErr) on failure -- lastErr is
-- a short human-readable reason for the LAST candidate tried, kept purely
-- for diagnostics (see scanInterface()'s dbg call below). Previously this
-- discarded pcall's error entirely, so a genuine engine-side failure and a
-- simple wrong-index guess were indistinguishable in the log -- this cost
-- real time on 2026-07-23 when 6 of 9 input slots on a large recipe failed
-- to read back with no clue why.
local function storeSlot(storeFn, patternIndex, k, expectedName)
  local candidates = {k}
  if k - 1 >= 0 then candidates[#candidates+1] = k - 1 end
  local lastErr = nil
  for _, idx in ipairs(candidates) do
    pcall(db.clear, SCRATCH_SLOT)
    local callOk, stored = pcall(storeFn, patternIndex, idx, db.address, SCRATCH_SLOT)
    if callOk and stored then
      local okGet, item = pcall(db.get, SCRATCH_SLOT)
      if okGet and item and namesRoughlyMatch(item.label, expectedName) then
        return {
          id     = item.name,
          damage = item.damage or 0,
          count  = item.size or 1,
          label  = item.label or item.name,
        }
      elseif okGet and item then
        lastErr = "name mismatch (got \""..tostring(item.label).."\")"
      else
        lastErr = "db.get failed: "..tostring(item)
      end
    elseif not callOk then
      lastErr = "storeFn threw: "..tostring(stored)
    else
      lastErr = "storeFn returned false (no such index)"
    end
  end
  return nil, lastErr
end

-- ── scan one interface ───────────────────────────
local function scanInterface(addr)
  local ok, proxy = pcall(component.proxy, addr)
  if not ok or not proxy then
    dbg("[WARN] could not get proxy for "..addr:sub(1,8))
    return
  end

  local label = addr:sub(1,8)
  if proxy.getLabel then
    local ok3, lbl = pcall(proxy.getLabel)
    if ok3 and lbl and lbl ~= "" then label = lbl end
  end

  local foundAny = false
  local occupiedCount = 0
  -- DIAGNOSTIC 2026-07-24: this used to only check "did getInterfacePattern
  -- return something truthy" and silently discarded WHY it didn't --
  -- indistinguishable in the log between "this slot genuinely has no
  -- pattern" (the normal, expected case for most of the 0-9 sweep) and
  -- "the call actually threw an exception trying to read it" (a real
  -- problem worth knowing about). Confirmed live 2026-07-24: a player
  -- reported two interfaces (with real Encoded Patterns placed in their
  -- pattern slots, fully channeled, no stocking-config confusion) still
  -- scanning as "no occupied pattern slots found" -- with the old code
  -- there was no way to tell whether AE2 genuinely saw no pattern there
  -- or whether something was silently erroring on every probe. Now
  -- captures pcall's actual error text per index and, if the interface
  -- ends up reporting zero occupied slots AND at least one probe threw a
  -- real error (as opposed to cleanly returning nil/false), logs those
  -- errors explicitly instead of staying silent.
  local probeErrors = {}
  -- see INDEXING CAVEAT: 0..9 is a superset of both a 0-based 0-8
  -- range and a 1-based 1-9 range (9 pattern slots per interface).
  for patternIndex = 0, 9 do
    local ok2, pattern = pcall(proxy.getInterfacePattern, patternIndex)
    if not ok2 then
      -- pcall's second return value is the error message when the call itself threw
      probeErrors[#probeErrors+1] = string.format("index %d: threw %s", patternIndex, tostring(pattern))
    end
    if ok2 and pattern then
      foundAny = true
      occupiedCount = occupiedCount + 1
      local rawInputs  = pattern.inputs  or {}
      local rawOutputs = pattern.outputs or {}
      dbg(string.format("  interface %s pattern[%d]: %d input slot(s), %d output slot(s)",
        label, patternIndex, #rawInputs, #rawOutputs))

      -- MEPatternSlot (what rawInputs[k]/rawOutputs[k] each are, from
      -- getInterfacePattern) has a real `.count` field -- "the amount
      -- set in the slot" -- confirmed against GTNH-OCLuaDocumentation's
      -- MEPatternSlot.lua type def. storeSlot()'s own `count` (sourced
      -- from db.get()'s `.size` on the SCRATCH DB readback) is NOT that:
      -- a Database Upgrade slot is an item-identity filter/descriptor,
      -- not a real stack, and its size reads back 0 for every entry --
      -- that's why every ingredient was showing up as "0x" regardless
      -- of the pattern's real amount. Use the pattern slot's own
      -- .count as the real quantity; only fall back to storeSlot's
      -- value (then 1) if it's missing for some reason.
      -- os.sleep(0) after every slot probe below: storeSlot() burns up to 2
      -- real component calls' worth of db.clear/storeFn/db.get per index
      -- candidate it tries, with zero yields in between. OC enforces a
      -- per-tick direct-call budget before it forces (or breaks) a yield;
      -- a 9-input pattern probed back-to-back can plausibly exhaust that
      -- budget partway through, silently failing every storeFn call for
      -- the rest of the synchronous loop -- which matches exactly what was
      -- observed on 2026-07-23: input slots 1-3 read fine, 4-9 all failed,
      -- then output slot 3 (the first output probed after 9 input probes)
      -- also failed. Yielding once per slot resets the budget so it can't
      -- accumulate across a whole pattern. Cheap: sleep(0) yields without
      -- an enforced real-time delay.
      local inputs, outputs = {}, {}
      for k = 1, #rawInputs do
        local slotData = rawInputs[k]
        local expected = slotData and slotData.name
        local item, probeErr = storeSlot(proxy.storeInterfacePatternInput, patternIndex, k, expected)
        if item then
          item.index = k
          local realCount = slotData and slotData.count
          if realCount and realCount > 0 then
            item.count = realCount
          elseif not (item.count and item.count > 0) then
            item.count = 1
          end
          inputs[#inputs+1] = item
        else
          dbg("    [WARN] could not read back input slot "..k.." (tried both index conventions"
              ..(expected and (", expected name ~= \""..tostring(expected).."\"") or "")
              ..(probeErr and (" -- "..tostring(probeErr)) or "")..")")
        end
        os.sleep(0)
      end
      for k = 1, #rawOutputs do
        local slotData = rawOutputs[k]
        local expected = slotData and slotData.name
        local item, probeErr = storeSlot(proxy.storeInterfacePatternOutput, patternIndex, k, expected)
        if item then
          item.index = k
          local realCount = slotData and slotData.count
          if realCount and realCount > 0 then
            item.count = realCount
          elseif not (item.count and item.count > 0) then
            item.count = 1
          end
          outputs[#outputs+1] = item
        else
          dbg("    [WARN] could not read back output slot "..k.." (tried both index conventions"
              ..(expected and (", expected name ~= \""..tostring(expected).."\"") or "")
              ..(probeErr and (" -- "..tostring(probeErr)) or "")..")")
        end
        os.sleep(0)
      end
      if #inputs < #rawInputs or #outputs < #rawOutputs then
        dbg(string.format("    [WARN] pattern reported INCOMPLETE: got %d/%d input(s), %d/%d output(s) -- "
          .."recipe saved will be missing ingredients, re-scan or fix manually if this recurs",
          #inputs, #rawInputs, #outputs, #rawOutputs))
      end

      if #inputs == 0 and #outputs == 0 then
        dbg("    [WARN] pattern present but couldn't read any slot contents -- skipping report")
      else
        local body = encodeReport(addr, label, patternIndex, inputs, outputs)
        local resp, err = postJson("/report_pattern", body)
        if not resp then
          dbg("    [FAIL] report_pattern failed: "..tostring(err))
        elseif resp:find('"new":true', 1, true) then
          dbg("    [NEW] reported (new pattern)")
        elseif resp:find('"changed":true', 1, true) then
          dbg("    [CHANGED] reported (pattern contents changed)")
        else
          dbg("    already known, no change")
        end
      end
    end
  end
  if not foundAny then
    dbg("  interface "..label..": no occupied pattern slots found")
    if #probeErrors > 0 then
      dbg(string.format("    [DIAG] getInterfacePattern threw a real error on %d of the 10 probed indices "
        .."(not just \"no pattern here\" -- something is actually failing):", #probeErrors))
      for _, e in ipairs(probeErrors) do
        dbg("      "..e)
      end
    end
  end

  -- Report presence unconditionally (occupied or not) -- see the
  -- 2026-07-24 bug note above getInterfaceList(): the pattern-report
  -- pipeline (POST /report_pattern) only ever tells the server about an
  -- interface once it has an actual encoded pattern, so a real,
  -- connected, powered interface with nothing encoded in it yet was
  -- completely invisible server-side -- indistinguishable from "not
  -- wired up at all," which led to guessing about cables/power/channels
  -- when the real answer was just "no pattern placed yet." This is
  -- silent bookkeeping only -- no chat prompt, no machine-identity
  -- logic -- just presence + occupied-pattern-count so a status/
  -- dashboard tool call can tell the two situations apart.
  local seenBody = string.format('{"interface_address":%s,"interface_label":%s,"occupied":%s,"pattern_count":%d}',
    jsonStr(addr), jsonStr(label), foundAny and "true" or "false", occupiedCount)
  local seenResp, seenErr = postJson("/report_interface_seen", seenBody)
  if not seenResp then
    dbg("  [WARN] report_interface_seen failed for "..label..": "..tostring(seenErr))
  end
end

-- ── scan-request background poll ─────────────────
-- This computer's sole job is scanning -- chat/crafting live entirely on
-- the other OC computer (craft_oc.lua, see that file's "chat moved out of
-- OC" history), so there's no interactive command loop to preserve here
-- (unlike craft_oc.lua's job-poll timer, which had to piggyback on an
-- existing io.read() loop without rewriting it -- no such constraint on
-- this computer, so a plain infinite loop is simplest).
--
-- Polls a SEPARATE queue from craft_oc.lua's crafting job queue (user's
-- explicit call: a scan request and a craft job are different shapes of
-- thing) -- Claude queues one via tools/request_scan.py -> POST
-- /request_scan, this polls GET /next_scan for one, and reports back via
-- POST /report_scan_result once done.
local SCAN_POLL_INTERVAL = 10  -- seconds between checking for a scan request

local function runFullScan()
  dbg("=== ME Interface Pattern Scan ===")
  -- Re-enumerate fresh every run (see getInterfaceList()'s 2026-07-24 bug
  -- note above) instead of the stale startup-only `interfaces` list --
  -- picks up any me_interface added to the network since the script
  -- started, without needing a restart.
  local current = getInterfaceList()
  if #current ~= #interfaces then
    dbg(string.format("  (me_interface count changed since startup: %d -> %d)", #interfaces, #current))
  end
  for _, addr in ipairs(current) do
    scanInterface(addr)
  end
  dbg("=== Scan complete ===")
end

-- Repeat-suppression for persistent poll failures -- 2026-07-23: a stale
-- server process (missing the /next_scan endpoint entirely, or some other
-- sustained outage) had this dbg-ing an identical "malformed"/"failed"
-- line every ~10s for ~17 hours straight, same class of spam already fixed
-- for craft_oc.lua's /next_job poll (that fix only silenced the routine
-- per-request HTTP tracing via a `quiet` flag though -- it never covered a
-- SUSTAINED identical failure, which would spam there too if it recurred).
-- Logs the first occurrence immediately, then only every 100th repeat
-- after that (so a real outage still leaves a trail, just not a flood),
-- and resets the moment a healthy response comes back.
local lastPollProblem = nil
local lastPollProblemCount = 0
local function reportPollProblem(msg)
  if msg == lastPollProblem then
    lastPollProblemCount = lastPollProblemCount + 1
    if lastPollProblemCount % 100 == 0 then
      dbg("scan-poll: (still failing, "..lastPollProblemCount.." consecutive) "..msg)
      flushDebug("scan-poll-repeat")
    end
    return
  end
  lastPollProblem = msg
  lastPollProblemCount = 1
  dbg("scan-poll: "..msg)
  flushDebug("scan-poll-problem")
end

local function checkForScanRequest()
  local raw, err = getJson("/next_scan")
  if not raw then
    reportPollProblem("/next_scan failed: "..(err or "?"))
    return
  end
  if raw:find('"scan"%s*:%s*null') then
    lastPollProblem, lastPollProblemCount = nil, 0  -- healthy -- next failure logs immediately
    return  -- nothing queued right now
  end

  local scanId = extractStr(raw, "id")
  if not scanId then
    reportPollProblem("malformed /next_scan response: "..raw:sub(1,200))
    return
  end

  lastPollProblem, lastPollProblemCount = nil, 0
  dbg("scan-poll: claimed scan request "..scanId)
  runFullScan()
  flushDebug("scan-complete")

  local resp, perr = postJson("/report_scan_result",
    '{"scan_id":'..jsonStr(scanId)..',"success":true,"details":"scan complete"}')
  if not resp then
    dbg("scan-poll: report_scan_result failed: "..tostring(perr))
    flushDebug("report-fail")
  end
end

-- ── main ─────────────────────────────────────────
dbg("[OK] scan_patterns_oc ready -- polling every "..SCAN_POLL_INTERVAL.."s for scan requests.")
flushDebug("ready")
while true do
  local ok, tickErr = pcall(checkForScanRequest)
  if not ok then
    dbg("scan-poll tick errored: "..tostring(tickErr))
    flushDebug("tick-error")
  end
  os.sleep(SCAN_POLL_INTERVAL)
end
