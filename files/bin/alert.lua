-- Raise and resolve monitoring events. Usable two ways:
--
--   command:  alert critical "Coolant below 20%" --id reactor/coolant --topic energy
--             alert resolve reactor/coolant
--             alert list
--             alert log
--
--   library:  local alert = dofile("/app/bin/alert.lua")
--             alert.raise{ id = "reactor/coolant", message = "Coolant below 20%",
--                          severity = "critical", topics = { "energy" }, ttl = 60 }
--             alert.resolve("reactor/coolant")
--
-- Deliberately dependency-free, so an emitting role ships this one file
-- and nothing else. Loaded with no arguments it returns the library;
-- with arguments it behaves as a command.

local PROTOCOL = "monitor"
local TIMEOUT  = 2  -- seconds to wait for the server's reply

local M = {}

local server  -- remembered between calls so repeat emitters stop broadcasting

local function connect()
    if rednet.isOpen() then return true end
    local modem = peripheral.find("modem")
    if not modem then return false, "no modem attached" end
    rednet.open(peripheral.getName(modem))
    return true
end

-- Sends a request and waits for its answer. The server's delta broadcasts
-- travel on the same protocol, so anything that isn't a reply is skipped
-- rather than mistaken for one. Not knowing the server is fine: a
-- broadcast reaches it just as well and teaches us its id.
local function request(msg)
    local ok, err = connect()
    if not ok then return nil, err end

    msg.label = os.getComputerLabel()
    if server then
        rednet.send(server, msg, PROTOCOL)
    else
        rednet.broadcast(msg, PROTOCOL)
    end

    local deadline = os.clock() + TIMEOUT
    repeat
        local sender, reply = rednet.receive(PROTOCOL, math.max(0, deadline - os.clock()))
        if type(reply) == "table" then
            local op = reply.op
            if op == "ok" or op == "snapshot" or op == "log" then
                server = sender
                return reply
            elseif op == "error" then
                server = sender
                return nil, reply.message or "rejected"
            end
        end
    until os.clock() >= deadline

    server = nil  -- it may have moved or gone away; rediscover next time
    return nil, "no reply from the monitoring server"
end

-- Raises (or refreshes) an event. Re-raising the same id is free: the
-- server deduplicates, and only alerts again if the wording or severity
-- actually changed.
function M.raise(event)
    if type(event) ~= "table" then return false, "raise expects a table" end
    local reply, err = request({
        op       = "raise",
        id       = event.id,
        message  = event.message,
        severity = event.severity,
        topics   = event.topics,
        ttl      = event.ttl,
    })
    if not reply then return false, err end
    return true, reply.id
end

function M.resolve(id)
    local reply, err = request({ op = "resolve", id = id })
    if not reply then return false, err end
    return true
end

function M.list()
    local reply, err = request({ op = "sync", rev = -1 })
    if not reply then return nil, err end
    return reply.events or {}
end

function M.log()
    local reply, err = request({ op = "log" })
    if not reply then return nil, err end
    return reply.entries or {}
end

-- Command line -------------------------------------------------------------

local args = { ... }
if #args == 0 then return M end

local SEVERITIES = { info = true, warning = true, critical = true }
local COLOR = { info = colors.lime, warning = colors.yellow, critical = colors.red }

local function age(epoch)
    local seconds = math.max(0, math.floor((os.epoch("utc") - (epoch or 0)) / 1000))
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 86400) .. "d"
end

local function usage()
    print("Usage:")
    print("  alert <info|warning|critical> <message> [options]")
    print("  alert resolve <id>")
    print("  alert list | log")
    print("Options: --id <key>  --topic <a,b>  --ttl <seconds>")
end

local function fail(message)
    printError("alert: " .. message)
    error("", 0)
end

local function show(event, resolved)
    term.setTextColor(COLOR[event.severity] or colors.white)
    term.write(("%-8s "):format(event.severity))
    term.setTextColor(colors.white)
    term.write(event.id)
    term.setTextColor(colors.lightGray)
    print(("  %s  %s"):format(event.message, resolved and ("by " .. tostring(event.resolvedBy))
        or age(event.raisedAt)))
    term.setTextColor(colors.white)
end

local command = args[1]

if command == "help" or command == "-h" or command == "--help" then
    usage()

elseif command == "resolve" then
    local id = args[2] or fail("resolve needs an id")
    local ok, err = M.resolve(id)
    if not ok then fail(err) end
    print("resolved " .. id)

elseif command == "list" or command == "log" then
    local entries, err = (command == "list" and M.list or M.log)()
    if not entries then fail(err) end
    if #entries == 0 then
        print(command == "list" and "no open events" or "no resolved events yet")
    end
    for _, event in ipairs(entries) do show(event, command == "log") end

elseif SEVERITIES[command] then
    local message = args[2] or fail("a message is required")
    local event = { severity = command, message = message }
    local i = 3
    while i <= #args do
        local flag, value = args[i], args[i + 1]
        if flag == "--id" then event.id = value or fail("--id needs a value")
        elseif flag == "--ttl" then event.ttl = tonumber(value) or fail("--ttl needs a number")
        elseif flag == "--topic" then
            event.topics = {}
            for topic in (value or ""):gmatch("[^,%s]+") do
                event.topics[#event.topics + 1] = topic
            end
            if #event.topics == 0 then fail("--topic needs a value") end
        else
            fail("unknown option '" .. tostring(flag) .. "'")
        end
        i = i + 2
    end
    local ok, idOrErr = M.raise(event)
    if not ok then fail(idOrErr) end
    print("raised " .. idOrErr)

else
    usage()
    fail("unknown command '" .. tostring(command) .. "'")
end
