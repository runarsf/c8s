-- Prepares a worker install, either onto a floppy disk (to carry to a
-- new computer/turtle) or directly onto the computer this is run on.
-- Fetches the current loader over rednet, so it needs a running controller.
--
-- Usage:
--   make-worker-disk            - disk mode: uses the only attached drive
--   make-worker-disk left       - disk mode: uses the drive on a specific side
--   make-worker-disk self       - installs directly onto this computer, no disk needed

local PROTOCOL = "codehost"
local HOSTNAME = "controller"

-- The ROM: frozen by design (see README), so its source lives here
-- rather than as a separate file that could drift out of sync.
local ROM_STARTUP = [[
-- startup.lua
-- The ROM: never touched by the sync process. Its only job is to run
-- the updatable loader, and fall back to a known-good copy if that
-- ever fails to run - so a bad update from the controller can never
-- brick a worker outright.
--
-- Uses shell.run rather than dofile: CC:Tweaked only injects the
-- `shell` API into programs launched via shell.run/shell.execute, and
-- the loader needs shell.run itself (to launch the role's program), so
-- it must be launched the same way or shell is nil inside it.

local ok = shell.run("/boot/loader.lua")
if not ok then
  print("[rom] /boot/loader.lua failed, falling back to /boot/loader.default.lua")
  shell.run("/boot/loader.default.lua")
end
]]

-- Runs automatically: CC:Tweaked boots from an inserted disk's
-- startup.lua before it looks at the computer's own root one.
local INSTALLER = [[
-- disk installer: runs automatically when this disk boots in a fresh
-- computer/turtle. Copies the worker files into place, ejects itself,
-- and leaves the computer ready for `label set` / `set role`.

local function installTree(src, dst)
  for _, name in ipairs(fs.list(src)) do
    local s, d = fs.combine(src, name), fs.combine(dst, name)
    if fs.isDir(s) then
      fs.makeDir(d)
      installTree(s, d)
    else
      local inF = fs.open(s, "r")
      local content = inF.readAll()
      inF.close()
      local outF = fs.open(d, "w")
      outF.write(content)
      outF.close()
    end
  end
end

local drive = peripheral.find("drive")
if not drive then error("No disk drive found") end
local side = peripheral.getName(drive)
local mount = disk.getMountPath(side)
if not mount then error("No disk in the drive") end

print("Installing worker files...")
installTree(fs.combine(mount, "payload"), "/")
disk.eject(side)

print("Done. Now run:")
print("  label set <name>")
print("  set role <role_name>")
print("  reboot")
]]

local function describeDrive(side)
  if not disk.isPresent(side) then
    return "empty"
  end
  local label = disk.getLabel(side) or "unlabeled"
  return ("disk \"%s\" (id %s), mounted at %s"):format(
    label, tostring(disk.getID(side)), tostring(disk.getMountPath(side))
  )
end

local function findDrive(wantedSide)
  if wantedSide then
    if peripheral.getType(wantedSide) ~= "drive" then
      error("No disk drive on side '" .. wantedSide .. "'")
    end
    return wantedSide
  end
  local found = { peripheral.find("drive") }
  if #found == 0 then error("No disk drive attached") end
  if #found > 1 then
    print("Multiple disk drives attached:")
    local names = {}
    for _, d in ipairs(found) do
      local name = peripheral.getName(d)
      names[#names + 1] = name
      print("  " .. name .. " - " .. describeDrive(name))
    end
    error("Specify one, e.g. make-worker-disk " .. names[1])
  end
  return peripheral.getName(found[1])
end

local function writeFile(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

local function fetchLoader()
  local modem = peripheral.find("modem")
  if not modem then error("No modem attached") end
  local name = peripheral.getName(modem)
  if not rednet.isOpen(name) then rednet.open(name) end
  local controllerId = rednet.lookup(PROTOCOL, HOSTNAME)
  if not controllerId then error("Controller not found on network") end
  rednet.send(controllerId, { op = "get_loader" }, PROTOCOL)
  local _, msg = rednet.receive(PROTOCOL, 5)
  if not msg then error("Controller did not respond") end
  if msg.op == "error" then error(msg.message) end
  if msg.op ~= "loader" or not msg.loader then error("Unexpected response") end
  return msg.loader.source
end

local function installSelf()
  if fs.exists("/startup.lua") then
    print("This computer already has a /startup.lua - overwrite it? (y/N)")
    local answer = read()
    if answer ~= "y" and answer ~= "Y" then
      print("Aborted.")
      return
    end
  end

  local loaderSource = fetchLoader()
  writeFile("/startup.lua", ROM_STARTUP)
  writeFile("/boot/loader.lua", loaderSource)
  writeFile("/boot/loader.default.lua", loaderSource)

  print("Installed on this computer.")
  print("Now run:")
  print("  label set <name>")
  print("  set role <role_name>")
  print("  reboot")
end

local function makeDisk(wantedSide)
  local side = findDrive(wantedSide)
  if not disk.isPresent(side) then
    error("No disk in the drive on '" .. side .. "' - insert a blank floppy disk first")
  end
  local mount = disk.getMountPath(side)

  if #fs.list(mount) > 0 and disk.getLabel(side) ~= "worker-install" then
    print("This disk already has files on it - overwrite it? (y/N)")
    local answer = read()
    if answer ~= "y" and answer ~= "Y" then
      print("Aborted.")
      return
    end
  end

  local loaderSource = fetchLoader()

  writeFile(fs.combine(mount, "startup.lua"), INSTALLER)
  writeFile(fs.combine(mount, "payload/startup.lua"), ROM_STARTUP)
  writeFile(fs.combine(mount, "payload/boot/loader.lua"), loaderSource)
  writeFile(fs.combine(mount, "payload/boot/loader.default.lua"), loaderSource)
  disk.setLabel(side, "worker-install")

  print("Worker disk ready on '" .. mount .. "'.")
  print("Insert it into a new computer or turtle and turn it on.")
end

-- main --------------------------------------------------------------------

local mode = ...
if mode == "self" then
  installSelf()
else
  makeDisk(mode)
end

