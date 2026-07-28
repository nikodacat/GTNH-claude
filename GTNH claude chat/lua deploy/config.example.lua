-- =============================================
--  config.example.lua
--  Template for local, per-machine settings.
--
--  Copy this file to config.lua on your OC disk
--  (same folder as the scripts, e.g. /home/config.lua)
--  and fill in your real server address.
--
--  config.lua itself is NOT tracked in git -- it's
--  local-only. That means pulling script updates
--  from GitHub never overwrites your real server IP,
--  and changing your IP never requires a git push.
-- =============================================

return {
  SERVER = "http://YOUR_HAMACHI_IP:11434",

  -- OPTIONAL (2026-07-24, auto-pattern-write feature). Address of a
  -- dedicated, otherwise-empty ME Interface that craft_oc.lua's
  -- tryAutoWritePattern() is allowed to write newly-discovered CRAFTING-
  -- TABLE patterns onto (crafting_shaped/crafting_shapeless recipes with
  -- no machine of their own to target -- gt_machine patterns instead go
  -- onto that specific machine's own interface, looked up automatically,
  -- no config needed for those). Leave commented out / nil to disable
  -- crafting-table auto-write entirely -- the craft-job failure path just
  -- falls back to today's plain "no pattern found" failure, nothing breaks.
  --
  -- Find the address with the `components` command at any OC terminal on
  -- the same network (look for "me_interface", first 8-ish chars shown are
  -- enough to recognize, but paste the FULL address here). Use a real
  -- spare interface with free pattern slots you don't mind AE2 writing
  -- into automatically -- this feature can and will overwrite whichever
  -- empty slot it finds first, with no physical pattern item involved.
  -- AUTO_CRAFT_SCRATCH_INTERFACE = "put-the-full-interface-address-here",
}
