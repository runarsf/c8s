-- Serves the ME system to pocket clients: search for an item, list the
-- places it can be sent, send some.
--
-- Clients ask for matches, never for the inventory. getItems() on a real ME
-- system is thousands of entries, and serialising that to a pocket computer
-- once per search is not something you do twice - so the search runs here
-- and only what matched goes over the wire. The listing is cached for a few
-- seconds because one trip through the UI is three requests about the same
-- item.
--
-- Destinations come from this role's config in roles.lua: a name a human
-- picks from, and the peripheral name exportItem needs as its target. Adding a
-- furnace is therefore a controller-side edit, not a visit to the pocket
-- computer.

local HERE   = fs.getDir(shell.getRunningProgram())
local me     = dofile(fs.combine(HERE, "protocol.lua"))
local bridge = dofile(fs.combine(HERE, "bridge.lua"))

-- Monitoring is optional on purpose: a bridge server on a computer that
-- never got bin/alert.lua should still hand out items.
local alert
do
    local path = fs.combine(fs.getDir(HERE), "bin/alert.lua")
    if fs.exists(path) then
        local ok, loaded = pcall(dofile, path)
        if ok and type(loaded) == "table" then alert = loaded end
    end
end

local DEFAULTS = {
    bridge          = "me_bridge",
    destinations    = {},
    search_limit    = 60,
    cache_ttl       = 5,
    health_interval = 30,
}

local function loadConfig()
    local config = {}
    local path = fs.combine(HERE, "_config.lua")
    if fs.exists(path) then
        local ok, loaded = pcall(dofile, path)
        if ok and type(loaded) == "table" then config = loaded end
    end
    for key, value in pairs(DEFAULTS) do
        if type(config[key]) ~= type(value) then config[key] = value end
    end
    return config
end

local config = loadConfig()

local NAME         = me.name()
local BRIDGE_EVENT = "me/" .. NAME .. "/bridge"
local EXPORT_EVENT = "me/" .. NAME .. "/export"

-- Long enough that one missed health cycle can't clear a real problem.
local TTL = config.health_interval * 3

-- A large request is several exports, because each call moves only what fits
-- in the destination right now. The cap bounds how long one request may hold
-- the serve loop: the client gives up after five seconds, so a request bigger
-- than the destination can take is reported as the partial move it was rather
-- than retried until it fits.
local EXPORT_ROUNDS = 16

-- Console -------------------------------------------------------------------

local function report(mark, text, color)
    term.setTextColor(colors.gray)
    term.write(textutils.formatTime(os.time(), true) .. " ")
    term.setTextColor(color or colors.white)
    term.write(("%-7s "):format(mark))
    term.setTextColor(colors.lightGray)
    print(text)
    term.setTextColor(colors.white)
end

-- Monitoring ----------------------------------------------------------------

-- Stateless in the power_monitor sense: ids are stable and carry no live
-- numbers, so re-raising every cycle is free and the server deduplicates.
local function raise(id, severity, message)
    if not alert then return end
    local ok, err = alert.raise{
        id       = id,
        severity = severity,
        message  = message,
        topics   = { "storage" },
        ttl      = TTL,
    }
    if not ok then report("monitor", tostring(err), colors.red) end
end

-- Resolving something that was never raised is a no-op, which is what lets
-- this file keep no memory of what it has reported.
local function resolve(id)
    if alert then alert.resolve(id) end
end

-- Both of the above block on rednet for up to two seconds, so nothing on the
-- request path is allowed to call them: a client waiting for a send must not
-- pay for a monitoring server that has gone away. The health loop owns every
-- event instead, and an export failure reaches it through here.
local exportFailure

-- Destinations --------------------------------------------------------------

local destinations = { list = {}, byName = {} }

do
    for _, entry in ipairs(config.destinations) do
        if type(entry) == "table" and type(entry.name) == "string"
            and type(entry.container) == "string" then
            local dest = { name = entry.name, container = entry.container }
            destinations.list[#destinations.list + 1] = dest
            destinations.byName[dest.name:lower()] = dest
        else
            report("config", "ignoring a malformed destination", colors.red)
        end
    end
end

local function destEvent(dest)
    return "me/" .. NAME .. "/dest/" .. dest.name
end

local function missingMessage(dest)
    return dest.name .. " (" .. dest.container .. ") is not on the network"
end

-- Presence is checked fresh every time rather than remembered: a wired modem
-- that fell off is the whole failure mode this guards against.
local function destinationList()
    local out = {}
    for index, dest in ipairs(destinations.list) do
        out[index] = {
            name      = dest.name,
            container = dest.container,
            missing   = not peripheral.isPresent(dest.container),
        }
    end
    return out
end

-- Search --------------------------------------------------------------------

local cache = { at = 0, items = nil }

local function items()
    if cache.items and me.now() - cache.at < config.cache_ttl * 1000 then
        return cache.items
    end
    local list, err = bridge.items()
    if not list then return nil, err end
    cache.items, cache.at = list, me.now()
    return list
end

local function search(query, limit)
    local match = me.matcher(query)
    if not match then return nil, "nothing to search for" end

    local list, err = items()
    if not list then return nil, err end

    local out = {}
    for _, item in ipairs(list) do
        -- `count` on a stack from the bridge is the whole system's total, not
        -- a stack size. It travels as `amount` to keep that distinction.
        local amount = math.floor(tonumber(item.count) or 0)
        -- Zero-stock rows are patterns the system knows and has none of.
        -- There is nothing to export, and they crowd out the rows there is.
        local score = amount > 0 and match(item) or nil
        if score then
            out[#out + 1] = {
                name        = item.name,
                displayName = item.displayName or item.name,
                amount      = amount,
                nbt         = type(item.nbt) == "string" and item.nbt or nil,
                score       = score,
            }
        end
    end

    table.sort(out, me.byScore)
    -- Only as many as a screen can plausibly be scrolled through.
    while #out > limit do out[#out] = nil end
    return out
end

-- Sending -------------------------------------------------------------------

local function send(msg)
    local item = type(msg.item) == "table" and msg.item or nil
    if not item or type(item.name) ~= "string" or #item.name == 0 then
        return { op = "error", message = "no item given" }
    end

    local requested = math.floor(tonumber(msg.count) or 0)
    if requested <= 0 then
        return { op = "error", message = "count must be a positive number" }
    end

    local dest = destinations.byName[tostring(msg.destination or ""):lower()]
    if not dest then
        return { op = "error", message = "no destination called '"
            .. tostring(msg.destination) .. "'" }
    end

    -- The health loop raises the event for this; the error reply is what the
    -- person standing at the pocket computer actually needs.
    if not peripheral.isPresent(dest.container) then
        return { op = "error", message = dest.name .. " is not on the network" }
    end

    -- What a search reported can be minutes old by the time somebody has
    -- picked an amount, so ask again and export against what the system says
    -- right now. The name and the nbt hash are what stayed stable.
    local fresh, err = bridge.item(me.filter(item))
    if not fresh then return { op = "error", message = err } end

    local stock = math.floor(tonumber(fresh.count) or 0)
    if stock <= 0 then
        return { op = "error", message = "none in stock" }
    end

    local wanted = math.min(requested, stock)
    local moved, reason = 0, nil
    for _ = 1, EXPORT_ROUNDS do
        if moved >= wanted then break end
        local n, eerr = bridge.exportTo(me.filter(fresh, wanted - moved), dest.container)
        if not n then
            reason = eerr
            break
        end
        -- Nothing moved: the destination is full, or the stock went away
        -- while we were working. Either way, another round won't help.
        if n <= 0 then break end
        moved = moved + n
    end

    if reason then
        exportFailure = "Export to " .. dest.name .. " failed: " .. reason
        return { op = "error", message = reason, moved = moved }
    end
    -- A partial move is not a failure: a full furnace is not an incident.
    exportFailure = nil

    return {
        op          = "ok",
        moved       = moved,
        requested   = requested,
        stock       = stock,
        destination = dest.name,
        displayName = fresh.displayName or item.displayName or item.name,
    }
end

-- Serving -------------------------------------------------------------------

local function serve(sender, msg)
    if type(msg) ~= "table" then return end

    if msg.op == "search" then
        local limit = math.floor(tonumber(msg.limit) or config.search_limit)
        limit = math.min(math.max(1, limit), config.search_limit)

        local matches, err = search(msg.query, limit)
        if not matches then
            rednet.send(sender, { op = "error", message = err }, me.PROTOCOL)
            report("search", tostring(msg.query) .. " - " .. err, colors.red)
        else
            rednet.send(sender, { op = "items", items = matches }, me.PROTOCOL)
            report("search", ("'%s' - %d match%s"):format(
                tostring(msg.query), #matches, #matches == 1 and "" or "es"))
        end

    elseif msg.op == "destinations" then
        -- Doubles as discovery and as a liveness check: a client that has
        -- never heard of us broadcasts this and learns our id from the reply.
        rednet.send(sender, { op = "destinations", destinations = destinationList() },
            me.PROTOCOL)

    elseif msg.op == "send" then
        local reply = send(msg)
        rednet.send(sender, reply, me.PROTOCOL)
        if reply.op == "ok" then
            report("send", ("%d/%d %s -> %s"):format(reply.moved, reply.requested,
                reply.displayName, reply.destination), colors.lime)
        else
            report("send", reply.message, colors.red)
        end
    end
end

local function requests()
    while true do
        local sender, msg = rednet.receive(me.PROTOCOL)
        serve(sender, msg)
    end
end

-- Reports the bridge and every destination whether or not anyone is asking,
-- so a chest whose modem fell off is news before somebody tries to use it.
local function health()
    while true do
        if bridge.available() then
            resolve(BRIDGE_EVENT)
        else
            raise(BRIDGE_EVENT, "critical", "No ME Bridge attached")
        end

        for _, dest in ipairs(destinations.list) do
            if peripheral.isPresent(dest.container) then
                resolve(destEvent(dest))
            else
                raise(destEvent(dest), "warning", missingMessage(dest))
            end
        end

        if exportFailure then
            raise(EXPORT_EVENT, "warning", exportFailure)
        else
            resolve(EXPORT_EVENT)
        end

        sleep(config.health_interval)
    end
end

local function run()
    local ok, err = me.openModem()
    if not ok then error(err, 0) end

    bridge.attach(config.bridge)
    -- Best effort: clients find us by broadcasting, but hosting keeps
    -- rednet.lookup working for anything that prefers it.
    pcall(rednet.host, me.PROTOCOL, me.HOSTNAME)

    report("up", ("%s - %d destination%s, %s"):format(NAME, #destinations.list,
        #destinations.list == 1 and "" or "s",
        bridge.available() and "bridge ready" or "no bridge yet"),
        bridge.available() and colors.lime or colors.orange)
    for _, dest in ipairs(destinations.list) do
        report("dest", dest.name .. " -> " .. dest.container,
            peripheral.isPresent(dest.container) and colors.white or colors.red)
    end

    parallel.waitForAny(requests, health)
end

run()
