local PROTOCOL        = "codehost"
local HOSTNAME         = "controller"
local APP_DIR           = "/app"
local BOOT_RETRIES      = 3
local BOOT_RETRY_WAIT   = 3
local WATCH_MIN_WAIT    = 10
local WATCH_MAX_WAIT    = 60
local ROLE_RETRY_MIN    = 10
local ROLE_RETRY_MAX    = 60

settings.define("role", {
  description = "Which controller role this computer fetches and runs",
})

local function role()
  settings.load()
  local r = settings.get("role")
  if not r then
    error("No role set - run:  set role <role_name>   (e.g. set role turtle_miner)")
  end
  return r
end

local function identity()
  return os.getComputerLabel() or ("#" .. os.getComputerID())
end

local function openModem()
  local modem = peripheral.find("modem")
  if not modem then return nil, "no modem attached" end
  local name = peripheral.getName(modem)
  if not rednet.isOpen(name) then rednet.open(name) end
  return name
end

local function fetch(r)
  local modemName, merr = openModem()
  if not modemName then return nil, merr end
  local controllerId = rednet.lookup(PROTOCOL, HOSTNAME)
  if not controllerId then return nil, "controller not found on network" end
  rednet.send(controllerId, {
    op = "get", role = r, id = os.getComputerID(), label = os.getComputerLabel(),
  }, PROTOCOL)
  local _, msg = rednet.receive(PROTOCOL, 5)
  if not msg then return nil, "controller did not respond" end
  if msg.op == "error" then return nil, msg.message end
  if msg.op ~= "bundle" then return nil, "unexpected response" end
  return msg
end

local function writeRole(bundle)
  for path, content in pairs(bundle.files) do
    local full = fs.combine(APP_DIR, path)
    local dir = fs.getDir(full)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(full, "w")
    f.write(content)
    f.close()
  end
  local f = fs.open(fs.combine(APP_DIR, "_config.lua"), "w")
  f.write("return " .. textutils.serialize(bundle.config or {}))
  f.close()
  local ef = fs.open(fs.combine(APP_DIR, "_entrypoint.lua"), "w")
  ef.write("return " .. textutils.serialize(bundle.entrypoint or "main.lua"))
  ef.close()
  settings.set("sync.role_version", bundle.version)
end

-- What to check for / run as this role's service entry point. Reads
-- the marker writeRole() leaves rather than trusting a live bundle,
-- since a boot can be running purely off a previous sync's cache.
local function entrypointName()
  local path = fs.combine(APP_DIR, "_entrypoint.lua")
  if fs.exists(path) then
    local ok, name = pcall(dofile, path)
    if ok and type(name) == "string" and name ~= "" then
      return name
    end
  end
  return "main.lua"
end

local function writeLoader(loader)
  -- Syntax-check before ever touching the live loader - a broken
  -- update must never be able to take out the boot chain.
  local chunk, err = load(loader.source, "loader.lua")
  if not chunk then
    return false, "new loader failed to compile: " .. tostring(err)
  end
  local f = fs.open("/boot/loader.lua", "w")
  f.write(loader.source)
  f.close()
  settings.set("sync.loader_version", loader.version)
  return true
end

-- A stored version number is only trustworthy if the files it claims
-- to describe are actually still there - if /app or the loader ever
-- got wiped (or a write never finished) without the version marker
-- also being cleared, these force a rewrite regardless of version.
-- Checking every file (rather than one representative name like
-- main.lua) also makes this correct for library roles and custom
-- entrypoints alike, with no special-casing needed.
local function haveRole(bundle)
  if settings.get("sync.role_version") ~= bundle.version then
    return false
  end
  for path in pairs(bundle.files) do
    if not fs.exists(fs.combine(APP_DIR, path)) then
      return false
    end
  end
  return true
end

local function haveLoader(loader)
  return settings.get("sync.loader_version") == loader.version
     and fs.exists("/boot/loader.lua")
end

-- Fetches once and applies whatever changed. Returns (true, result) on
-- a successful check-in, or (false, errorMessage) if unreachable.
local function sync(r)
  local bundle, err = fetch(r)
  if not bundle then return false, err end

  local result = { roleChanged = false, loaderChanged = false }

  if not haveRole(bundle) then
    writeRole(bundle)
    result.roleChanged = true
  end

  if bundle.loader and not haveLoader(bundle.loader) then
    local ok, lerr = writeLoader(bundle.loader)
    if ok then
      result.loaderChanged = true
    else
      print("[sync] " .. lerr .. " - keeping current loader")
    end
  end

  if result.roleChanged or result.loaderChanged then
    settings.save()
  end

  return true, result
end

-- A few quick attempts at boot so a momentarily-busy controller
-- doesn't get treated as permanently gone. If the loader itself was
-- updated, reboot immediately so the role always runs under current
-- code; a role-only update just falls through into running it.
local function initialSync(r)
  for attempt = 1, BOOT_RETRIES do
    local ok, result = sync(r)
    if ok then
      print("[boot] " .. identity() .. " synced role '" .. r .. "'")
      if result.loaderChanged then
        print("[boot] loader updated, rebooting to apply")
        os.reboot()
      end
      return
    end
    print("[boot] sync attempt " .. attempt .. " failed (" .. tostring(result) .. ")")
    if attempt < BOOT_RETRIES then sleep(BOOT_RETRY_WAIT) end
  end
  print("[boot] controller unreachable after " .. BOOT_RETRIES ..
        " attempts - continuing with any cached code, will keep retrying in the background")
end

-- Runs for the life of the computer, alongside the role. Keeps trying
-- the controller with backoff while it's unreachable, and resets to
-- the fast interval the moment it answers again.
local function watch(r)
  local wait = WATCH_MIN_WAIT
  while true do
    sleep(wait)
    local ok, result = sync(r)
    if ok then
      wait = WATCH_MIN_WAIT
      if result.roleChanged or result.loaderChanged then
        print("[watch] update applied, rebooting")
        os.reboot()
      end
    else
      print("[watch] controller unreachable (" .. tostring(result) .. "), retrying in " .. wait .. "s")
      wait = math.min(wait * 2, WATCH_MAX_WAIT)
    end
  end
end

-- Runs the role's entry point. Waits (rather than failing) if nothing's
-- been synced yet. If the role crashes, retries with backoff (reset
-- once it's proven it can run for a while) rather than hammering a
-- deterministically broken script forever - either way, a real fix
-- pushed from the controller is picked up on watch()'s own schedule,
-- independent of whatever this backoff is currently doing.
local function runRole()
  local entry = fs.combine(APP_DIR, entrypointName())
  local warned = false
  while not fs.exists(entry) do
    if not warned then
      print("[role] no cached code yet, waiting for controller")
      warned = true
    end
    sleep(5)
  end

  local wait = ROLE_RETRY_MIN
  while true do
    local startedAt = os.epoch("utc")
    local ok = shell.run(entry)
    if ok then return end
    if os.epoch("utc") - startedAt > ROLE_RETRY_MAX * 1000 then
      wait = ROLE_RETRY_MIN
    end
    print("[role] exited with an error, retrying in " .. wait .. "s")
    sleep(wait)
    wait = math.min(wait * 2, ROLE_RETRY_MAX)
  end
end

-- Runs once after every sync, for any role that ships one - arbitrary,
-- role-controlled setup (shell.path, banners, whatever) rather than
-- anything the loader hardcodes. Never retried, never fatal: a role
-- whose whole purpose is a one-shot interactive tool just ships this
-- and no entrypoint file, and gets exactly that - run once, report,
-- no rescue, straight back to the shell.
local function runSetup()
  local setupPath = fs.combine(APP_DIR, "setup.lua")
  if not fs.exists(setupPath) then return end
  if not shell.run(setupPath) then
    print("[setup] setup.lua exited with an error - continuing anyway")
  end
end

-- main ------------------------------------------------------------------

local r = role()
initialSync(r)
runSetup()

if fs.exists(fs.combine(APP_DIR, entrypointName())) then
  parallel.waitForAny(runRole, function() watch(r) end)
end

