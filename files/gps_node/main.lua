-- Hosts this computer as a GPS anchor at the coordinates the controller assigned to this worker's label.

local config = dofile("/app/_config.lua")

if not (config.x and config.y and config.z) then
  error("No gps anchor coordinates in config for this computer")
end

print(("gps_node up at (%d, %d, %d)"):format(config.x, config.y, config.z))
shell.run("gps", "host", config.x, config.y, config.z)

