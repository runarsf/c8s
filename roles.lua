return {
    workstation = {
      version = 1,
      entrypoint = "main.lua",
      files = {
        { src = "bin/",             dest = "bin/" },
        { src = "bin/init_bin.lua", dest = "main.lua" },
      },
    },
  
    gps_node = {
      version = 1,
      files = {
        { src = "gps_node/main.lua", dest = "main.lua" },
      },
      -- resolved per-worker at request time using the worker's label
      -- (falls back to computer id if no label was set)
      config = function(workerId, label)
        local anchors = {
          gps_east_1 = { x = 100, y = 64, z = -32 },
          gps_east_2 = { x = 100, y = 64, z =  32 },
          gps_west_1 = { x = -60, y = 64, z = -32 },
          gps_west_2 = { x = -60, y = 64, z =  32 },
        }
        local key = label or tostring(workerId)
        return anchors[key] or error("no gps anchor configured for '" .. key .. "'")
      end,
    },
  
    presence_detector = {
      version = 1,
      files = {
        { src = "common/log.lua",             dest = "lib/log.lua" },
        { src = "presence_detector/main.lua", dest = "main.lua" },
      },
    },
  }
  
  