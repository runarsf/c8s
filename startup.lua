-- Central code server that hosts per-role file bundles, and the worker loader source, over rednet.

local PROTOCOL = "codehost"
local HOSTNAME = "controller"

-- Resolve every path relative to wherever this script actually lives,
-- not the computer's root, so it works unmodified whether controller/
-- was copied straight onto the computer, or is sitting on a disk.
local BASE_DIR   = fs.getDir(shell.getRunningProgram())
local ROOT       = fs.combine(BASE_DIR, "files")
local BIN_DIR    = fs.combine(ROOT, "bin")
local ROLES_FILE = fs.combine(BASE_DIR, "roles.lua")
local LOADER_DIR = fs.combine(BASE_DIR, "loader")

local function loadRoles()
  local ok, roles = pcall(dofile, ROLES_FILE)
  if not ok or type(roles) ~= "table" then
    error("Could not load " .. ROLES_FILE .. ": " .. tostring(roles))
  end
  return roles
end

local function loadLoader()
  local srcPath = fs.combine(LOADER_DIR, "loader.lua")
  local verPath = fs.combine(LOADER_DIR, "version.lua")
  if not (fs.exists(srcPath) and fs.exists(verPath)) then return nil end
  local f = fs.open(srcPath, "r")
  local source = f.readAll()
  f.close()
  local ok, version = pcall(dofile, verPath)
  if not ok or type(version) ~= "number" then return nil end
  return { version = version, source = source }
end

local function openModem()
  local modem = peripheral.find("modem")
  if not modem then error("No modem attached to controller") end
  rednet.open(peripheral.getName(modem))
end

-- Adds one src (a file or a whole directory tree) into a flat
-- dest -> content table. For a directory, dest is used as the prefix
-- for everything found inside it, at any depth.
local function collectFiles(root, dest, out)
  if fs.isDir(root) then
    for _, name in ipairs(fs.list(root)) do
      collectFiles(fs.combine(root, name), fs.combine(dest, name), out)
    end
  else
    local f = fs.open(root, "r")
    out[dest] = f.readAll()
    f.close()
  end
end

local function buildBundle(roles, role, workerId, label)
  local def = roles[role]
  if not def then return nil, "unknown role" end

  local files = {}
  for _, entry in ipairs(def.files) do
    local path = fs.combine(ROOT, entry.src)
    if not fs.exists(path) then
      return nil, "missing source: " .. entry.src
    end
    collectFiles(path, entry.dest, files)
  end

  local config = def.config
  if type(config) == "function" then
    local ok, resolved = pcall(config, workerId, label)
    if not ok then return nil, "config error: " .. tostring(resolved) end
    config = resolved
  end

  return {
    op         = "bundle",
    role       = role,
    version    = def.version,
    files      = files,
    config     = config,
    entrypoint = def.entrypoint or "main.lua",
    loader     = loadLoader(),
  }
end

if not shell.path():find(BIN_DIR, 1, true) then
  shell.setPath(shell.path() .. ":" .. BIN_DIR)
end

local roles = loadRoles()
openModem()
rednet.host(PROTOCOL, HOSTNAME)

print("codehost online as '" .. HOSTNAME .. "', roles:")
for name in pairs(roles) do print("  - " .. name) end

while true do
  local senderId, msg = rednet.receive(PROTOCOL)
  if type(msg) ~= "table" then
    -- ignore
  elseif msg.op == "get" and type(msg.role) == "string" then
    -- reload roles.lua (and the loader) on every request so edits take
    -- effect without restarting the controller
    roles = loadRoles()
    local bundle, err = buildBundle(roles, msg.role, senderId, msg.label)
    if bundle then
      rednet.send(senderId, bundle, PROTOCOL)
      local n = 0
      for _ in pairs(bundle.files) do n = n + 1 end
      print(("[serve] %s -> %s (%d files%s)"):format(
        msg.role, msg.label or ("#" .. senderId), n,
        bundle.loader and (", loader v" .. bundle.loader.version) or ""
      ))
    else
      rednet.send(senderId, { op = "error", message = err }, PROTOCOL)
      print(("[warn] %s: %s (requested by #%d)"):format(msg.role, err, senderId))
    end
  elseif msg.op == "get_loader" then
    -- used by tools/make-worker-disk.lua, which doesn't need a role
    local loader = loadLoader()
    if loader then
      rednet.send(senderId, { op = "loader", loader = loader }, PROTOCOL)
    else
      rednet.send(senderId, { op = "error", message = "no loader configured" }, PROTOCOL)
    end
    print("[serve] loader -> #" .. senderId)
  end
end

