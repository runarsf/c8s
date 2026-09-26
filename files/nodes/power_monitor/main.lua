-- Watches a Mekanism induction matrix and keeps the monitoring system's
-- picture of it up to date: one event for "the matrix is low", one for
-- "I can't see the matrix at all", each resolved the moment it stops
-- being true.
--
-- Deliberately stateless. It reports what is true this cycle and lets the
-- server deduplicate, so there is nothing here that can drift out of step
-- with what the glasses are showing - not even across a reboot.
--
-- Thresholds come from this role's config in roles.lua: edit it on the
-- controller and the worker picks it up on its next sync. The defaults
-- below are what it falls back to with no config at all.

local HERE  = fs.getDir(shell.getRunningProgram())
local alert = dofile(fs.combine(HERE, "bin/alert.lua"))

local DEFAULTS = {
    peripheral  = "inductionPort",
    warning_at  = 0.5,
    critical_at = 0.2,
    interval    = 30,
}

local COLOR = { critical = colors.red, warning = colors.yellow }

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

local NAME       = os.getComputerLabel() or ("#" .. os.getComputerID())
local LOW_EVENT  = "power/" .. NAME
local PORT_EVENT = "power/" .. NAME .. "/port"

-- Long enough that one missed cycle can't clear a real problem, short
-- enough that a monitor which died stops asserting stale news.
local TTL = config.interval * 3

local function report(text, color)
    term.setTextColor(colors.gray)
    term.write(textutils.formatTime(os.time(), true) .. " ")
    term.setTextColor(color or colors.white)
    print(text)
    term.setTextColor(colors.white)
end

-- Only raise failures are worth mentioning: a resolve that didn't land
-- costs nothing, because the event's ttl clears it anyway.
local function tell(ok, err)
    if not ok then report("monitoring: " .. tostring(err), colors.red) end
end

-- The message names the band, not the live reading. Crossing 50% is news;
-- 43% -> 42% is not, and a message that doesn't change is exactly what
-- lets the server treat every later cycle in the same band as a duplicate.
local function level(filled)
    if filled <= config.critical_at then
        return "critical", ("Power at or below %d%%"):format(config.critical_at * 100)
    elseif filled <= config.warning_at then
        return "warning", ("Power at or below %d%%"):format(config.warning_at * 100)
    end
end

report(("power monitor on %s - warn %d%%, critical %d%%, every %ds"):format(
    NAME, config.warning_at * 100, config.critical_at * 100, config.interval))

while true do
    local port = peripheral.find(config.peripheral)

    if not port then
        tell(alert.raise{
            id       = PORT_EVENT,
            severity = "critical",
            message  = "No " .. config.peripheral .. " attached",
            topics   = { "energy" },
            ttl      = TTL,
        })
        report("no " .. config.peripheral .. " attached", colors.red)
    else
        alert.resolve(PORT_EVENT)

        local filled = tonumber(port.getEnergyFilledPercentage())
        if not filled then
            report("could not read " .. config.peripheral, colors.red)
        else
            local severity, message = level(filled)
            if severity then
                tell(alert.raise{
                    id       = LOW_EVENT,
                    severity = severity,
                    message  = message,
                    topics   = { "energy" },
                    ttl      = TTL,
                })
            else
                -- Resolving something that isn't open is a no-op, so this
                -- needs no memory of whether we ever raised it.
                alert.resolve(LOW_EVENT)
            end
            report(("%3d%%  %s"):format(math.floor(filled * 100 + 0.5), severity or "ok"),
                COLOR[severity] or colors.lime)
        end
    end

    sleep(config.interval)
end
