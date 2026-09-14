-- Adds /app/bin to PATH
if not shell.path():find("/app/bin", 1, true) then
  shell.setPath(shell.path() .. ":/app/bin")
end
  
  