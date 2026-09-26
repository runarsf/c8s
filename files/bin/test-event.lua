-- Fires test events at the monitoring server. No interface: the phone is
-- for poking the system from your pocket, the glasses are what show it.
--
-- Everything goes through bin/alert.lua, so this exercises the real
-- emitter path rather than a second copy of it.
--
--   test-event warning              raise one, with a generated id
--   test-event critical "Reactor"   ... with a message of your own
--   test-event burst 8              eight at once, mixed severities
--   test-event up                   escalate the newest one
--   test-event resolve [id]         resolve the newest, or the one named
--   test-event clear                resolve every test event from this phone
--   test-event list                 what this phone has open
--
-- Ids are "test/<phone>/<n>", so clear and list can tell these apart from
-- anything real, and two people can test at once. Events carry no topics,
-- which means they reach every pair of glasses whatever its subscription,
-- and a ttl, so ones you walk away from clean themselves up.

local TTL = 600

local HERE  = fs.getDir(shell.getRunningProgram())
local alert = dofile(fs.combine(HERE, "alert.lua"))

settings.define("test_event.counter", {
    description = "Number given to the next test event raised from here",
    default = 1, type = "number",
})
settings.load()

local SEVERITIES = { "info", "warning", "critical" }
local RANK = {}
for rank, name in ipairs(SEVERITIES) do RANK[name] = rank end

local WHO    = (os.getComputerLabel() or ("#" .. os.getComputerID())):gsub("%s+", "-")
local PREFIX = "test/" .. WHO .. "/"

local function fail(message)
    printError("test-event: " .. message)
    error("", 0)
end

local function nextId()
    local n = settings.get("test_event.counter") or 1
    settings.set("test_event.counter", n + 1)
    settings.save()
    return PREFIX .. n
end

-- Open events raised from this phone, newest first.
local function mine()
    local open, err = alert.list()
    if not open then fail(err) end

    local list = {}
    for _, event in ipairs(open) do
        if event.id:sub(1, #PREFIX) == PREFIX then
            list[#list + 1] = event
        end
    end
    table.sort(list, function(a, b) return (a.raisedAt or 0) > (b.raisedAt or 0) end)
    return list
end

local function newest()
    local list = mine()
    return list[1] or fail("nothing raised from here is open")
end

local function raise(severity, message, id)
    id = id or nextId()
    local ok, err = alert.raise{
        id       = id,
        severity = severity,
        message  = message or (severity .. " test event " .. id),
        ttl      = TTL,
    }
    if not ok then fail(err) end
    print("raised " .. id .. " (" .. severity .. ")")
    return id
end

local function resolve(id)
    local ok, err = alert.resolve(id)
    if not ok then fail(err) end
    print("resolved " .. id)
end

local function usage()
    print("Usage:")
    print("  test-event <info|warning|critical> [message]")
    print("  test-event burst [count]   raise several at once")
    print("  test-event up              escalate the newest one")
    print("  test-event resolve [id]    default: the newest one")
    print("  test-event clear           resolve all of this phone's")
    print("  test-event list")
end

local args = { ... }
local command = args[1]

if command == nil or command == "help" or command == "-h" or command == "--help" then
    usage()

elseif RANK[command] then
    raise(command, args[2])

elseif command == "burst" then
    local count = tonumber(args[2]) or 3
    for i = 1, count do
        raise(SEVERITIES[(i - 1) % #SEVERITIES + 1])
    end

elseif command == "up" then
    -- Re-raising an open id at a higher severity is what makes the glasses
    -- sound a second time, which is the bit worth testing by hand.
    local event = newest()
    local rank = RANK[event.severity] or 1
    if rank >= #SEVERITIES then fail(event.id .. " is already critical") end
    raise(SEVERITIES[rank + 1], event.message, event.id)

elseif command == "resolve" then
    resolve(args[2] or newest().id)

elseif command == "clear" then
    local list = mine()
    for _, event in ipairs(list) do
        resolve(event.id)
    end
    if #list == 0 then print("nothing to resolve") end

elseif command == "list" then
    local list = mine()
    for _, event in ipairs(list) do
        print(("%-8s %s  %s"):format(event.severity, event.id, event.message))
    end
    if #list == 0 then print("nothing raised from here is open") end

else
    usage()
    fail("unknown command '" .. tostring(command) .. "'")
end
