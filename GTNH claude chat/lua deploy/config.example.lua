-- =============================================
--  config.example.lua
--  Template for local, per-machine settings.
--
--  Copy this file to config.lua on your OC disk
--  (same folder as the scripts, e.g. /mnt/e10/config.lua)
--  and fill in your real server address.
--
--  config.lua itself is NOT tracked in git -- it's
--  local-only. That means pulling script updates
--  from GitHub never overwrites your real server IP,
--  and changing your IP never requires a git push.
-- =============================================

return {
  SERVER = "http://YOUR_HAMACHI_IP:11434",
}
