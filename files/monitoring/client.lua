-- Monitoring client: shows the server's open events on the smart glasses
-- HUD and in an interactive terminal list.
--
-- State always comes from the server - a snapshot at startup, numbered
-- deltas after that. That is what lets a player who was logged out see
-- exactly the same open events as everyone else the moment they log back
-- in, and it is also the whole of the sound rule:
--
--     a delta can make a noise, a snapshot never does.
--
-- A snapshot is the world as it already was, so nothing in it is news.
-- Resolving is global (the condition is handled, for everybody); snoozing
-- is local (it only hides a line on this player's HUD).

local HERE = fs.getDir(shell.getRunningProgram())
local APP  = fs.getDir(HERE)
local mon  = dofile(fs.combine(HERE, "protocol.lua"))
local hud  = dofile(fs.combine(HERE, "hud.lua"))

-- dofile rather than require: the same reason bin/git.lua does it, one less
-- thing that depends on how this program was started.
local DFPWM_MODULE = "rom/modules/main/cc/audio/dfpwm.lua"
local CHUNK = 16 * 1024

local POLL = 15  -- seconds between sync checks
local TICK = 1   -- seconds between redraws (ages, snooze expiry)

local DEFAULT_SOUND = {
    info     = "minecraft:block.note_block.pling",
    warning  = "minecraft:block.note_block.bit",
    critical = "minecraft:block.bell.use",
}
local PITCH = { info = 1.4, warning = 1.0, critical = 0.7 }

settings.define("monitoring.topics", {
    description = "Comma-separated topics to subscribe to; unset means all",
    type = "string",
})
settings.define("monitoring.snooze_minutes", {
    description = "How long 's' hides an event from your own HUD",
    default = 10, type = "number",
})
settings.define("monitoring.hud_lines", {
    description = "Maximum events drawn on the glasses overlay",
    default = 6, type = "number",
})
settings.define("monitoring.volume", {
    description = "Alert volume, 0 to 3",
    default = 1, type = "number",
})
for _, severity in ipairs(mon.SEVERITIES) do
    settings.define("monitoring.sounds." .. severity, {
        description = "Sound for " .. severity .. " events: a Minecraft sound "
            .. "event, or a .dfpwm file (relative to /app)",
        default = DEFAULT_SOUND[severity], type = "string",
    })
end
settings.load()

local snoozeMinutes = mon.option("monitoring.snooze_minutes", 10, tonumber)
local hudLines      = mon.option("monitoring.hud_lines", 6, tonumber)
local volume        = mon.option("monitoring.volume", 1, tonumber)

-- State --------------------------------------------------------------------

local server         -- computer id, learned from the last reply
local rev      = -1  -- forces a snapshot on the first sync
local events   = {}  -- id -> event, our mirror of the server's open set
local snoozed  = {}  -- id -> epoch at which it comes back
local selected = 1
local status               -- transient footer message
local lastHeard = 0        -- epoch of the last message from the server
local lastSync  = 0
local subscribed = mon.loadTopics()

local function connected()
    return mon.now() - lastHeard < POLL * 2 * 1000
end

local function isSnoozed(id)
    return snoozed[id] ~= nil and snoozed[id] > mon.now()
end

-- The list both views work from: subscribed topics only, most urgent
-- first. The terminal shows snoozed entries (greyed, so you can wake
-- them); the HUD is what snoozing exists to quieten, so it drops them.
local function listed(includeSnoozed)
    local list = {}
    for id, event in pairs(events) do
        if mon.isSubscribed(event, subscribed) and (includeSnoozed or not isSnoozed(id)) then
            list[#list + 1] = event
        end
    end
    table.sort(list, mon.byUrgency)
    return list
end

-- Sound --------------------------------------------------------------------

local dfpwm     -- loaded on first use
local playing   -- { speaker, file, decoder, pending }

local function stopSound()
    if not playing then return end
    pcall(playing.file.close)
    playing = nil
end

-- Feeds the speaker one chunk at a time, driven by the main loop's
-- speaker_audio_empty events. Waiting for those inside a play function
-- instead - as the first version of this script did - throws away every
-- other event that arrives while the sound lasts, deltas included.
local function pump()
    if not playing then return end

    if playing.pending then
        if not playing.speaker.playAudio(playing.pending, volume()) then return end
        playing.pending = nil
    end

    while true do
        local chunk = playing.file.read(CHUNK)
        if not chunk then return stopSound() end
        local buffer = playing.decoder(chunk)
        if not playing.speaker.playAudio(buffer, volume()) then
            playing.pending = buffer
            return
        end
    end
end

-- A speaker unplugged mid-sound must not take the client down with it.
local function feed()
    if not pcall(pump) then stopSound() end
end

local function playFile(speaker, path)
    if dfpwm == nil then
        dfpwm = fs.exists(DFPWM_MODULE) and dofile(DFPWM_MODULE) or false
    end
    if not dfpwm then return end

    local file = fs.open(path, "rb")
    if not file then return end

    stopSound()
    playing = { speaker = speaker, file = file, decoder = dfpwm.make_decoder() }
    feed()
end

local function alert(severity)
    local speaker = peripheral.find("speaker")
    if not speaker then return end

    local sound = mon.option("monitoring.sounds." .. severity, DEFAULT_SOUND[severity])()
    if type(sound) ~= "string" or sound == "" then return end

    -- A .dfpwm name is a file to stream, resolved against /app so it does
    -- not depend on where the program was started from. Anything else is a
    -- Minecraft sound event.
    if sound:lower():match("%.dfpwm$") then
        local path = sound:sub(1, 1) == "/" and sound or fs.combine(APP, sound)
        if fs.exists(path) then playFile(speaker, path) end
    else
        pcall(speaker.playSound, sound, volume(), PITCH[severity] or 1)
    end
end

-- Rendering ----------------------------------------------------------------

local function truncate(text, width)
    if width <= 0 then return "" end
    if #text <= width then return text .. string.rep(" ", width - #text) end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

-- "> CRIT reactor/coolant  Coolant below 20%      2m". The id is dropped
-- first and the message truncated second when the screen is narrow -
-- glasses terminals are only about 26 columns wide.
local function row(event, width, marker)
    local head = marker .. mon.SHORT[event.severity] .. " "
    local tail = " " .. (isSnoozed(event.id) and "z" or "") .. mon.age(event.raisedAt)
    local text = event.message
    if width >= 40 then text = event.id .. "  " .. event.message end
    return head .. truncate(text, width - #head - #tail) .. tail
end

local function drawTerminal()
    local width, height = term.getSize()
    local list = listed(true)
    if selected > #list then selected = math.max(1, #list) end

    term.setBackgroundColor(colors.black)
    term.clear()

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.write(truncate((" %d open"):format(#list)
        .. (connected() and "" or "  server unreachable")
        .. (hud.available() and "" or "  no hud"), width))

    term.setBackgroundColor(colors.black)
    local lines = height - 2
    for i = 1, lines do
        local event = list[i]
        if not event then break end
        term.setCursorPos(1, i + 1)
        if i == selected then
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(isSnoozed(event.id) and colors.gray
                or mon.COLOR[event.severity] or colors.white)
        end
        term.write(row(event, width, i == selected and "> " or "  "))
    end

    if #list == 0 then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 3)
        term.write(connected() and "all clear" or "waiting for the server")
    end

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(truncate(status or " up/down  enter resolve  s snooze  q quit", width))
    term.setBackgroundColor(colors.black)
end

local lastHud  -- signature of what the overlay is currently showing

local function drawHud()
    local list = listed(false)
    local max = math.max(1, math.floor(hudLines()))
    local lines = {}
    for i = 1, math.min(#list, max) do
        local event = list[i]
        lines[i] = {
            text  = ("%s %s (%s)"):format(mon.SHORT[event.severity], event.message,
                mon.age(event.raisedAt)),
            color = mon.HEX[event.severity] or 0xFFFFFF,
        }
    end
    if #list > max then
        lines[#lines + 1] = { text = ("+%d more"):format(#list - max), color = 0xAAAAAA }
    end

    -- Redrawing runs every tick; the overlay only needs to hear about it
    -- when something actually changed.
    local signature = textutils.serialize(lines)
    if signature == lastHud then return end
    lastHud = signature
    hud.render(lines)
end

local function render()
    drawTerminal()
    drawHud()
end

-- Networking ---------------------------------------------------------------

local function send(msg)
    if server then
        rednet.send(server, msg, mon.PROTOCOL)
    else
        -- We don't know the server yet (or lost it): broadcasting gets the
        -- same answer and teaches us its id, with no blocking lookup.
        rednet.broadcast(msg, mon.PROTOCOL)
    end
end

-- Debounced: a burst of gapped deltas must not turn into a burst of
-- snapshot requests.
local function requestSync()
    local now = mon.now()
    if now - lastSync < 1000 then return end
    lastSync = now
    send({ op = "sync", rev = rev })
end

local function applySnapshot(msg)
    events = {}
    for _, event in ipairs(msg.events or {}) do
        if type(event) == "table" and type(event.id) == "string" then
            events[event.id] = event
        end
    end
    rev = msg.rev
end

local function applyDelta(msg)
    local event = msg.event
    if type(event) ~= "table" or type(event.id) ~= "string" then return end

    if msg.kind == "resolved" then
        events[event.id] = nil
        -- If it comes back later it is a new problem, and should be heard.
        snoozed[event.id] = nil
    else
        local previous = events[event.id]
        events[event.id] = event
        local escalated = previous
            and (mon.RANK[event.severity] or 0) > (mon.RANK[previous.severity] or 0)
        if mon.isSubscribed(event, subscribed) and (msg.kind == "raised" or escalated) then
            alert(event.severity)
        end
    end
    rev = msg.rev
end

local function handle(sender, msg)
    if type(msg) ~= "table" then return end
    lastHeard = mon.now()

    if msg.op == "snapshot" then
        server = sender
        applySnapshot(msg)
    elseif msg.op == "delta" then
        server = sender
        if msg.rev == rev + 1 then
            applyDelta(msg)
        elseif msg.rev > rev then
            -- A gap: we were out of range, or asleep. Don't guess.
            requestSync()
        end
    elseif msg.op == "ok" then
        server = sender
        if msg.rev and msg.rev ~= rev then requestSync() end
    end
end

-- Input --------------------------------------------------------------------

local function selectedEvent()
    return listed(true)[selected]
end

local function resolveSelected()
    local event = selectedEvent()
    if not event then return end
    status = " resolving " .. event.id .. "..."
    -- No optimistic removal: the server decides, and if it can't be
    -- reached the event must stay on screen rather than silently vanish.
    send({
        op = "resolve",
        id = event.id,
        by = os.getComputerLabel() or ("#" .. os.getComputerID()),
    })
end

local function snoozeSelected()
    local event = selectedEvent()
    if not event then return end
    if isSnoozed(event.id) then
        snoozed[event.id] = nil
        status = " woke " .. event.id
    else
        local minutes = math.max(1, snoozeMinutes())
        snoozed[event.id] = mon.now() + minutes * 60 * 1000
        status = (" snoozed %s for %dm"):format(event.id, minutes)
    end
end

-- Main ---------------------------------------------------------------------

local function run()
    local ok, err = mon.openModem()
    if not ok then error(err, 0) end

    hud.attach()
    requestSync()
    render()

    local ticker = os.startTimer(TICK)
    while true do
        local event = { os.pullEvent() }
        local name = event[1]

        if name == "rednet_message" and event[4] == mon.PROTOCOL then
            handle(event[2], event[3])
            status = nil
        elseif name == "speaker_audio_empty" then
            feed()
        elseif name == "timer" and event[2] == ticker then
            ticker = os.startTimer(TICK)
            if mon.now() - lastSync >= POLL * 1000 then
                -- Also the recovery path: if the server stopped answering,
                -- forget it and start broadcasting again.
                if not connected() then server = nil end
                requestSync()
            end
        elseif name == "key" then
            local key = event[2]
            if key == keys.up then
                selected = math.max(1, selected - 1)
            elseif key == keys.down then
                selected = math.min(math.max(1, #listed(true)), selected + 1)
            elseif key == keys.enter then
                resolveSelected()
            elseif key == keys.s then
                snoozeSelected()
            elseif key == keys.q then
                return
            end
        end

        render()
    end
end

local ok, err = pcall(run)
stopSound()
hud.clear()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
