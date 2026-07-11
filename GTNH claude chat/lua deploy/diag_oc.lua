-- =============================================
--  diag_oc.lua
--  Quick hardware diagnostic — run this first
--  to see exactly what's missing
-- =============================================

local component = require("component")
local computer  = require("computer")
local io        = require("io")

print("=== OC Hardware Diagnostic ===")
print()

-- Internet card
if component.isAvailable("internet") then
  print("[OK]   Internet Card")
else
  print("[FAIL] Internet Card -- not found")
end

-- ME controller / adapter
if component.isAvailable("me_controller") then
  print("[OK]   AE2 ME Controller/Adapter")
else
  print("[FAIL] AE2 ME Adapter -- not found")
  print("       Place ME Adapter block touching this computer")
end

-- GPU
if component.isAvailable("gpu") then
  local gpu = component.gpu
  local w, h = gpu.getResolution()
  print(string.format("[OK]   GPU (%dx%d)", w, h))
else
  print("[WARN] No GPU -- text only mode")
end

-- Filesystem (real disk vs tmpfs)
print()
print("Filesystems:")
for addr, ctype in component.list("filesystem") do
  local proxy = component.proxy(addr)
  local lbl   = (proxy.getLabel and proxy.getLabel()) or "(no label)"
  local space  = proxy.spaceTotal and
                 string.format("%.0fKB", proxy.spaceTotal()/1024) or "?"
  print(string.format("  %s  label=%s  size=%s", addr:sub(1,8), lbl, space))
end

-- All connected components
print()
print("All components:")
for addr, ctype in component.list() do
  print(string.format("  %-30s %s", ctype, addr:sub(1,8)))
end

print()
print("=== Done ===")
io.read()
