-- =============================================
--  after_update_oc.lua
--  Runs automatically every time update_oc.lua
--  finishes an update pass (see its AFTER_UPDATE
--  list + "run after-update hooks" section).
--
--  THIS IS THE EXTENSION POINT for one-time
--  migration/fixup logic that needs to happen
--  whenever scripts change -- e.g. update_oc.lua
--  having just updated ITSELF to a version that
--  assumes some new disk state exists, a config
--  field that needs a default filled in, an old
--  file that should be renamed/removed, etc.
--
--  Since this file is fetched from GitHub and run
--  automatically just like every other script in
--  FILES, you can change what happens after an
--  update at any time just by editing THIS file on
--  GitHub -- no need to touch update_oc.lua itself
--  again for future post-update steps. update_oc.lua
--  wraps this whole file in a pcall, so an error in
--  here is logged but never stops the update process
--  or crashes the caller.
--
--  Currently a template that does one small, real,
--  harmless check (confirms config.lua exists) as a
--  working example -- replace/extend the body below
--  with whatever the next actual migration needs.
-- =============================================

local io = require("io")

local DISK = "/home"   -- was /mnt/dc6 (secondary disk mount) -- moved to /home since disk mount labels aren't stable across disk swaps (2026-07-23, T3 disk upgrade)

print("[after-update] hook running...")

local f = io.open(DISK.."/config.lua", "r")
if f then
  f:close()
  print("[after-update] config.lua present -- OK.")
else
  print("[after-update] [NOTE] no config.lua yet -- copy config.example.lua")
  print("[after-update]        to " .. DISK .. "/config.lua and set SERVER.")
end

-- ── add future one-time migration steps below ──
-- Example pattern for a step that should only ever run once:
--   local MARKER = DISK.."/.after_update_<name>_done"
--   if not io.open(MARKER, "r") then
--     -- ... do the one-time thing ...
--     local mf = io.open(MARKER, "w"); if mf then mf:write("done"); mf:close() end
--   end

print("[after-update] done.")
