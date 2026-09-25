-- monitor.lua: receive events over rednet, log them, and surface them as
-- HUD notifications + sounds on Advanced Peripherals smart glasses.

local PROTOCOL = "monitor"

-- Enums -------------------------------------------------------------------

-- Turns a list of names into an enum: each entry becomes a distinct table
-- that compares by identity and prints nicely via its .name field.
local function enum(keys)
    local Enum = {}
    for _, name in ipairs(keys) do
        Enum[name] = { name = name }
    end
    return Enum
end

local Severity = enum { "Info", "Warning", "Critical" }

-- Case-insensitive lookup: "WARNING", "warning", ... -> Severity.Warning
local function asSeverity(value)
    if type(value) ~= "string" or #value == 0 then return nil end
    return Severity[value:sub(1, 1):upper() .. value:sub(2):lower()]
end

-- Options (settings-backed, with defaults) --------------------------------

-- Small helper: returns a getter for a settings option that falls back to
-- `default` when the option is unset or invalid. `parse` (optional) coerces
-- or validates the stored value, e.g. tonumber for durations.
local function option(name, default, parse)
    return function()
        local value = settings.get(name)
        if type(value) == "string" and #value == 0 then return default end
        if parse and value ~= nil then value = parse(value) end
        if value == nil then return default end
        return value
    end
end

-- "monitoring.sounds.<level>" (dfpwm path)
local SOUND_PATH = {
    -- [Severity.Critical] = option("monitoring.sounds.critical", "sounds/critical.dfpwm", tostring),
    -- [Severity.Warning] = option("monitoring.sounds.warning", "sounds/critical.dfpwm", tostring),
    -- [Severity.Info] = option("monitoring.sounds.info", "sounds/critical.dfpwm", tostring),
}
for _, severity in pairs(Severity) do
    local key = severity.name:lower()
    SOUND_PATH[severity] = option("monitoring.sounds." .. key, "sounds/" .. key .. ".dfpwm", tostring)
end

-- "monitoring.timeouts.<level>" (seconds)
-- 0 keeps the notification up until a key is pressed in the terminal.
local DEFAULT_TIMEOUT = { info = 10, warning = 30, critical = 0 }
local TIMEOUT = {}
for _, severity in pairs(Severity) do
    local key = severity.name:lower()
    TIMEOUT[severity] = option("monitoring.timeouts." .. key, DEFAULT_TIMEOUT[key], tonumber)
end

-- "energy, security" -> { energy = true, security = true }; nil when unset.
local function loadTags()
    local raw = settings.get("monitoring.tags")
    if type(raw) ~= "string" then return nil end
    local tags = {}
    for tag in raw:gmatch("[^,%s]+") do
        tags[tag:lower()] = true
    end
    return next(tags) and tags or nil
end

-- HUD (overlay module) ------------------------------------------------------

local overlay  -- assigned at startup; nil -> HUD disabled, everything else works

-- Run an overlay call, swallowing failures (no overlay, glasses unequipped
-- mid-run, unexpected API): better a silent miss than a dead monitor.
local function tryOverlay(action)
    if not overlay then return end
    return pcall(action)
end

-- The overlay's exact access path varies between AP builds, so probe for it
-- instead of hardcoding names: prefer the documented module table, then any
-- attached peripheral that exposes createText directly.
local function findOverlay()
    if type(smartglasses) == "table" and type(smartglasses.modules) == "table" then
        local mod = smartglasses.modules["advancedperipherals:overlay"]
            or smartglasses.modules.overlay
        if type(mod) == "table" and type(mod.createText) == "function" then
            return mod
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        local modules = p.modules or (type(p.getModules) == "function" and p.getModules())
        if type(modules) == "table" then
            for _, mod in pairs(modules) do
                if type(mod) == "table" and type(mod.createText) == "function" then
                    return mod
                end
            end
        end
        if type(p.createText) == "function" then
            return p
        end
    end
end

-- Layout of the notification stack, top-left. Units are screen pixels;
-- tweak these if entries overlap or sit too low on your setup.
local BASE_X, BASE_Y, LINE_HEIGHT = 4, 10, 12

local SEVERITY_HEX = {
    [Severity.Info]     = 0x55FF55,
    [Severity.Warning]  = 0xFFFF55,
    [Severity.Critical] = 0xFF5555,
}

local notifications = {}  -- visible entries: { obj = <TextObject>, timerId = <number>? }

-- Keep the stack tight: entry i renders at BASE_Y + (i-1) * LINE_HEIGHT.
-- Mutating existing objects (not recreating) avoids client-side flicker.
local function relayout()
    for i, entry in ipairs(notifications) do
        local y = BASE_Y + (i - 1) * LINE_HEIGHT
        tryOverlay(function() entry.obj.setPos(BASE_X, y, 0) end)
    end
end

local function dismiss(entry)
    for i, e in ipairs(notifications) do
        if e == entry then
            table.remove(notifications, i)
            break
        end
    end
    tryOverlay(function() overlay.removeObject(entry.obj.getId()) end)
    relayout()
end

-- Adds a notification to the HUD. `severity` is an enum value (default
-- Info); `timeout` overrides the per-severity option, in seconds, with
-- 0 meaning "stay until a key is pressed in the terminal".
local function addNotification(title, body, severity, timeout)
    if not overlay then return end

    severity = severity or Severity.Info
    if timeout == nil then
        local getter = TIMEOUT[severity]
        timeout = getter and getter() or 0
    end

    local ok, obj = tryOverlay(function()
        return overlay.createText({
            content  = string.format("%s %s - %s", severity.name:upper(), title, body),
            color    = SEVERITY_HEX[severity] or -1,
            fontSize = 1,
            shadow   = true,
            x        = BASE_X,
            y        = BASE_Y,
        })
    end)
    if not ok or not obj then return end

    notifications[#notifications + 1] = {
        obj     = obj,
        timerId = timeout > 0 and os.startTimer(timeout) or nil,
    }
    relayout()
end

-- Sound -------------------------------------------------------------------

local function streamChunks(speaker, decoder, file)
    while true do
        local chunk = file.read(16 * 1024)
        if not chunk then break end

        local buffer = decoder(chunk)
        while not speaker.playAudio(buffer) do
            os.pullEvent("speaker_audio_empty")
        end
    end
end

-- No speaker, missing file, or bad data: silently do nothing, never crash.
local function playSound(severity)
    local speaker = peripheral.find("speaker")
    if not speaker then return end

    local path = SOUND_PATH[severity]()
    if type(path) ~= "string" or not fs.exists(path) then return end

    local file = fs.open(path, "rb")
    if not file then return end

    pcall(streamChunks, speaker, require("cc.audio.dfpwm").make_decoder(), file)
    file.close()
end

-- Display -----------------------------------------------------------------

local SEVERITY_COLOR = {
    [Severity.Info]     = colors.lime,
    [Severity.Warning]  = colors.yellow,
    [Severity.Critical] = colors.red,
}

local function printEvent(sender, event, severity)
    term.setTextColor(colors.gray)
    term.write(textutils.formatTime(os.time(), true) .. " ")
    term.setTextColor(severity and SEVERITY_COLOR[severity] or colors.white)
    term.write(string.format("%-8s", severity and severity.name or "UNKNOWN"))
    term.setTextColor(colors.white)
    term.write(string.format("#%d %s", sender, event.title))
    term.setTextColor(colors.lightGray)
    print(" - " .. event.body)
    term.setTextColor(colors.white)
end

-- Topic subscription: no tags configured -> everything comes through;
-- events without a topics list ("untagged") also always come through.
local function isSubscribed(event, tags)
    if not tags then return true end

    local topics = event.topics
    if type(topics) == "string" then topics = { topics } end
    if type(topics) ~= "table" or #topics == 0 then return true end

    for _, topic in ipairs(topics) do
        if type(topic) == "string" and tags[topic:lower()] then return true end
    end
    return false
end

-- Main --------------------------------------------------------------------

local function run()
    peripheral.find("modem", rednet.open)
    if not rednet.isOpen() then
        error("No modem attached", 0)
    end

    -- Best-effort advertisement for sender-side rednet.lookup: the name is
    -- unique per computer, so multiple glasses never collide, and failure
    -- is not fatal -- broadcast reception doesn't depend on registration.
    if not pcall(rednet.host, PROTOCOL, "monitor" .. os.getComputerID()) then
        print("Could not claim a lookup name - continuing")
    end

    overlay = findOverlay()
    tryOverlay(function() overlay.clear() end) -- drop stale objects from an earlier run

    local tags = loadTags()

    term.clear()
    term.setCursorPos(1, 1)
    print(string.format("Listening for '%s' events on #%d", PROTOCOL, os.getComputerID()))
    print("Overlay HUD: " .. (overlay and "active" or "not found (terminal only)"))
    if tags then
        local names = {}
        for tag in pairs(tags) do names[#names + 1] = tag end
        print("Subscribed topics: " .. table.concat(names, ", "))
    else
        print('Subscribed topics: all (opt in with "set monitoring.tags energy,security")')
    end

    -- Receive via rednet.receive(PROTOCOL): it internally filters the raw
    -- "rednet_message" events. (A previous version polled os.pullEvent for
    -- an event literally named "rednet" and silently dropped everything.)
    local function messageLoop()
        while true do
            local sender, event = rednet.receive(PROTOCOL)
            if type(event) == "table"
                and type(event.title) == "string"
                and type(event.body) == "string"
                and isSubscribed(event, tags) then
                local severity = asSeverity(event.severity)
                printEvent(sender, event, severity)
                if severity then
                    addNotification(event.title, event.body, severity)
                    playSound(severity)
                end
            end
        end
    end

    -- Runs alongside messageLoop: parallel hands every event to both loops,
    -- so expiry timers fire and key presses dismiss notifications even
    -- while a sound is playing.
    local function controlLoop()
        while true do
            local ev, p1 = os.pullEvent()
            if ev == "timer" then
                for _, entry in ipairs(notifications) do
                    if entry.timerId == p1 then
                        dismiss(entry)
                        break
                    end
                end
            elseif ev == "key" then
                -- Any key press clears the persistent (highest-severity) entries.
                for i = #notifications, 1, -1 do
                    if notifications[i].timerId == nil then
                        dismiss(notifications[i])
                    end
                end
            end
        end
    end

    parallel.waitForAny(messageLoop, controlLoop)
end

local ok, err = pcall(run)
tryOverlay(function() overlay.clear() end) -- don't leave HUD objects behind
if not ok then error(err, 0) end
