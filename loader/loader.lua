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

local function fromHex(data)
  return (data:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function writeRole(bundle)
  local encodings = bundle.encodings or {}
  for path, content in pairs(bundle.files) do
    local full = fs.combine(APP_DIR, path)
    local dir = fs.getDir(full)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    -- Binary files (dfpwm and anything else the controller marks) arrive as
    -- hex and are written as bytes. Writing them in text mode is what used
    -- to alter them just enough to play as static.
    local binary = encodings[path] == "hex"
    local f = fs.open(full, binary and "wb" or "w")
    f.write(binary and fromHex(content) or content)
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

-- What to check for / run as this role's service entry point, as a list
-- of words: the program followed by any arguments. Reads the marker
-- writeRole() leaves rather than trusting a live bundle, since a boot can
-- be running purely off a previous sync's cache.
--
-- A role may write the entrypoint as a list ({ "bin/run-many.lua", "-r",
-- "app/bin/a.lua" }) or as one string. Only the first word is a path:
-- combining the whole line with APP_DIR was the reason an entrypoint with
-- arguments used to do nothing at all - there is no file called
-- "/app/bin/run-many.lua app/bin/ntfy-consume.lua", so the check below
-- found nothing to run and the loader fell through to the shell without
-- a word of complaint.
local function entrypoint()
  local value
  local path = fs.combine(APP_DIR, "_entrypoint.lua")
  if fs.exists(path) then
    local ok, loaded = pcall(dofile, path)
    if ok then value = loaded end
  end

  -- `explicit` distinguishes "this role declared an entrypoint" from
  -- "nothing was declared, so try main.lua": a provision-only role having
  -- no main.lua is normal, a declared entrypoint that isn't there is not.
  local words = {}
  if type(value) == "table" then
    for _, word in ipairs(value) do
      if type(word) == "string" and word ~= "" then words[#words + 1] = word end
    end
  elseif type(value) == "string" then
    for word in value:gmatch("%S+") do words[#words + 1] = word end
  end
  local explicit = #words > 0
  if not explicit then words = { "main.lua" } end

  words[1] = fs.combine(APP_DIR, words[1])
  return words, explicit
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
  -- The markers writeRole leaves are as necessary as the files: without
  -- _entrypoint.lua the loader falls back to main.lua and, for a role that
  -- has no main.lua, silently runs nothing at all - and would keep doing
  -- so forever, since the version said everything was fine.
  for _, marker in ipairs({ "_entrypoint.lua", "_config.lua" }) do
    if not fs.exists(fs.combine(APP_DIR, marker)) then
      return false
    end
  end
  return true
end

local function haveLoader(loader)
  return settings.get("sync.loader_version") == loader.version
     and fs.exists("/boot/loader.lua")
end

-- Settings the controller wants every machine to have. Declarative rather
-- than one-shot: whatever differs is set on every check-in, so a value
-- edited here reaches a machine without anyone visiting it, and a machine
-- that drifted is pulled back. Only writes when something actually
-- changed, since this runs every 10-60s for the life of the computer.
local function applySettings(values)
  if type(values) ~= "table" then return false end
  local changed = {}
  for name, value in pairs(values) do
    if settings.get(name) ~= value then
      settings.set(name, value)
      changed[#changed + 1] = name
    end
  end
  if #changed == 0 then return false end
  settings.save()
  print("[sync] set " .. table.concat(changed, ", "))
  return true
end

-- Fetches once and applies whatever changed. Returns (true, result) on
-- a successful check-in, or (false, errorMessage) if unreachable.
local function sync(r)
  local bundle, err = fetch(r)
  if not bundle then return false, err end

  local result = { roleChanged = false, loaderChanged = false }

  -- Before the role runs, so its first boot already sees them.
  applySettings(bundle.settings)

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
  local command = entrypoint()
  local entry = command[1]
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
    -- shell.execute does not re-tokenise, so an argument may contain a
    -- space (run-many "sleep 5"); shell.run is the older fallback.
    local run = shell.execute or shell.run
    local ok = run(table.unpack(command))
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

local command, explicit = entrypoint()
if fs.exists(command[1]) then
  parallel.waitForAny(runRole, function() watch(r) end)
elseif explicit then
  -- Silence here is what made a broken entrypoint so hard to spot.
  print("[boot] entrypoint " .. command[1] .. " is missing - dropping to the shell")
end

