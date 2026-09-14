local M = {}

M.info = function(...)
  print("[INFO] " .. table.concat({ ... }, " "))
end

M.warn = function(...)
  print("[WARN] " .. table.concat({ ... }, " "))
end

return M

