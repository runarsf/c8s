-- Shared vocabulary for the monitoring system: the rednet protocol, the
-- severity scale, and the handful of formatting and filtering rules the
-- server, the client and the HUD all have to agree on.
--
-- Severities are plain lowercase strings rather than the identity-compared
-- enum tables an earlier version used: these travel over rednet, and table
-- identity does not survive serialisation.

local M = {}

M.PROTOCOL = "monitor"
M.HOSTNAME = "monitor-server"

-- Least to most urgent; the index is the comparison rank.
M.SEVERITIES = { "info", "warning", "critical" }

M.RANK = {}
for rank, name in ipairs(M.SEVERITIES) do M.RANK[name] = rank end

M.COLOR = { info = colors.lime, warning = colors.yellow, critical = colors.red }
M.HEX   = { info = 0x55FF55,    warning = 0xFFFF55,      critical = 0xFF5555 }
M.SHORT = { info = "INFO",      warning = "WARN",        critical = "CRIT" }

function M.now()
    return os.epoch("utc")
end

-- Case-insensitive, nil for anything that isn't a known severity.
function M.severity(value)
    if type(value) ~= "string" then return nil end
    value = value:lower()
    return M.RANK[value] and value or nil
end

-- Returns a getter for a settings option that falls back to `default`
-- when the option is unset, empty, or fails `parse`.
function M.option(name, default, parse)
    return function()
        local value = settings.get(name)
        if value == nil or value == "" then return default end
        if parse then value = parse(value) end
        if value == nil then return default end
        return value
    end
end

-- Accepts a string or a list, always yields a (possibly empty) list of
-- lowercase topics: what an event is tagged with.
function M.topicList(value)
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" then return {} end
    local out = {}
    for _, topic in ipairs(value) do
        if type(topic) == "string" and #topic > 0 then
            out[#out + 1] = topic:lower()
        end
    end
    return out
end

-- Coerces whatever an emitter sent into a well-formed event, or returns
-- nil plus a reason. `source` comes from the rednet layer rather than the
-- message body, so an event can never lie about where it came from.
function M.normalise(msg, source)
    if type(msg) ~= "table" then return nil, "not a table" end

    local message = msg.message
    if type(message) ~= "string" or #message == 0 then
        return nil, "missing message"
    end

    -- An emitter that doesn't pick an id still gets deduplicated, it just
    -- can't change the wording without opening a second event.
    local id = msg.id
    if type(id) ~= "string" or #id == 0 then
        id = source .. "/" .. message
    end

    local ttl = tonumber(msg.ttl)
    if ttl and ttl <= 0 then ttl = nil end

    return {
        id       = id,
        message  = message,
        severity = M.severity(msg.severity) or "info",
        topics   = M.topicList(msg.topics),
        source   = source,
        label    = type(msg.label) == "string" and msg.label or nil,
        ttl      = ttl,
    }
end

-- The topics this client subscribes to, as a set:
-- "energy, security" -> { energy = true, security = true }. nil when unset,
-- which means "subscribed to everything".
function M.loadTopics()
    local raw = settings.get("monitoring.topics")
    if type(raw) ~= "string" then return nil end
    local subscribed = {}
    for topic in raw:gmatch("[^,%s]+") do
        subscribed[topic:lower()] = true
    end
    return next(subscribed) and subscribed or nil
end

-- Nothing subscribed -> everything comes through; events with no topics
-- always come through.
function M.isSubscribed(event, subscribed)
    if not subscribed then return true end
    local topics = event.topics
    if type(topics) ~= "table" or #topics == 0 then return true end
    for _, topic in ipairs(topics) do
        if subscribed[topic] then return true end
    end
    return false
end

-- Most urgent first, oldest first within a severity: the order both the
-- HUD and the terminal list render in.
function M.byUrgency(a, b)
    local ra, rb = M.RANK[a.severity] or 0, M.RANK[b.severity] or 0
    if ra ~= rb then return ra > rb end
    return (a.raisedAt or 0) < (b.raisedAt or 0)
end

-- Compact age for a column that has to fit on a pocket-sized screen.
function M.age(epoch)
    local seconds = math.max(0, math.floor((M.now() - (epoch or 0)) / 1000))
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 86400) .. "d"
end

function M.openModem()
    if rednet.isOpen() then return true end
    local modem = peripheral.find("modem")
    if not modem then return false, "no modem attached" end
    rednet.open(peripheral.getName(modem))
    return true
end

return M
