-- Monitoring server: the single authoritative store of open events.
--
-- Emitters raise and resolve events over rednet; clients pull a snapshot
-- when they start and follow numbered deltas after that. Every mutation
-- bumps `rev`, so a client that missed a broadcast - out of modem range,
-- in another dimension, or simply logged out - sees the gap and asks for
-- a fresh snapshot instead of quietly drifting. Nothing about who is
-- online is tracked here; there is nothing to track.
--
-- Run this on a computer in a chunk that stays loaded. It has to keep
-- state while nobody is nearby, which is exactly when it matters.

local HERE = fs.getDir(shell.getRunningProgram())
local mon  = dofile(fs.combine(HERE, "protocol.lua"))

-- State lives outside /app: the loader rewrites that whole tree on every
-- sync, and open events must survive a code update.
local STATE_DIR  = "/state"
local STATE_FILE = fs.combine(STATE_DIR, "events.lua")

local LOG_LIMIT      = 50   -- resolved events kept for `log`
local SWEEP_INTERVAL = 10   -- seconds between ttl checks
local SOURCE_LIMIT   = 25   -- open events one computer may hold at once

local state = { rev = 0, events = {}, log = {} }
local dirty = false  -- state changed in a way that can wait for the next flush

-- Persistence --------------------------------------------------------------

local function save()
    if not fs.exists(STATE_DIR) then fs.makeDir(STATE_DIR) end
    local file = fs.open(STATE_FILE, "w")
    if not file then return end
    file.write("return " .. textutils.serialize(state))
    file.close()
    dirty = false
end

local function restore()
    if not fs.exists(STATE_FILE) then return end
    local ok, loaded = pcall(dofile, STATE_FILE)
    if not ok or type(loaded) ~= "table" or type(loaded.events) ~= "table" then
        print("[warn] could not read " .. STATE_FILE .. ", starting empty")
        return
    end
    state = {
        rev    = tonumber(loaded.rev) or 0,
        events = loaded.events,
        log    = type(loaded.log) == "table" and loaded.log or {},
    }
end

-- Reporting ----------------------------------------------------------------

local MARK = { raised = "+", updated = "~", resolved = "-" }

local function report(kind, event, by)
    term.setTextColor(colors.gray)
    term.write(textutils.formatTime(os.time(), true) .. " ")
    term.setTextColor(mon.COLOR[event.severity] or colors.white)
    term.write(string.format("%s %-4s ", MARK[kind] or "?", mon.SHORT[event.severity] or "?"))
    term.setTextColor(colors.white)
    term.write(event.id)
    term.setTextColor(colors.lightGray)
    print(by and (" (" .. by .. ")") or (" - " .. event.message))
    term.setTextColor(colors.white)
end

-- Mutations ----------------------------------------------------------------

-- Every state change goes through here: bump the revision, tell everyone,
-- then write to disk. Clients key entirely off `rev`.
local function publish(kind, event)
    state.rev = state.rev + 1
    rednet.broadcast({ op = "delta", rev = state.rev, kind = kind, event = event }, mon.PROTOCOL)
    save()
end

local function raise(msg, sender)
    local event, err = mon.normalise(msg, sender)
    if not event then return { op = "error", message = err } end

    local now = mon.now()
    local open = state.events[event.id]

    if open then
        -- A polling emitter re-raising the same condition every cycle must
        -- not re-alert anybody; only a genuine change is worth a delta.
        local changed = open.message ~= event.message or open.severity ~= event.severity
        open.message   = event.message
        open.severity  = event.severity
        open.topics    = event.topics
        open.label     = event.label or open.label
        open.ttl       = event.ttl
        open.updatedAt = now
        open.count     = (open.count or 1) + 1
        if changed then
            publish("updated", open)
            report("updated", open)
        else
            -- Nothing anybody can see changed, so this costs one timestamp
            -- and no disk write: with a dozen scripts polling every few
            -- seconds, saving here would be the busiest thing on the
            -- computer. The sweep flushes it.
            dirty = true
        end
        return { op = "ok", rev = state.rev, id = open.id }
    end

    -- A script that forgets to set a stable id opens a fresh event every
    -- time its message changes ("Battery at 43%", "at 42%", ...). Cap it
    -- per source so one careless emitter can't bury everyone's HUD.
    local mine = 0
    for _, other in pairs(state.events) do
        if other.source == event.source then mine = mine + 1 end
    end
    if mine >= SOURCE_LIMIT then
        return { op = "error", message = ("#%d already has %d open events - give them a stable id")
            :format(event.source, mine) }
    end

    event.raisedAt  = now
    event.updatedAt = now
    event.count     = 1
    state.events[event.id] = event
    publish("raised", event)
    report("raised", event)
    return { op = "ok", rev = state.rev, id = event.id }
end

local function resolve(id, by)
    if type(id) ~= "string" then return { op = "error", message = "missing id" } end

    local event = state.events[id]
    -- Resolving something already handled is normal (an emitter clearing a
    -- condition someone else just resolved by hand), not an error.
    if not event then return { op = "ok", rev = state.rev } end

    state.events[id]  = nil
    event.resolvedAt  = mon.now()
    event.resolvedBy  = by
    table.insert(state.log, 1, event)
    while #state.log > LOG_LIMIT do table.remove(state.log) end

    publish("resolved", event)
    report("resolved", event, by)
    return { op = "ok", rev = state.rev }
end

-- Auto-resolves events whose emitter stopped refreshing them. A role that
-- re-raises a condition every cycle sets `ttl`, so the event clears itself
-- when the condition goes away *or* when the emitter itself disappears.
local function sweep()
    local now = mon.now()
    for id, event in pairs(state.events) do
        if event.ttl and now - (event.updatedAt or 0) > event.ttl * 1000 then
            resolve(id, "expired")
        end
    end
end

-- Requests -----------------------------------------------------------------

local function snapshot()
    local events = {}
    for _, event in pairs(state.events) do events[#events + 1] = event end
    table.sort(events, mon.byUrgency)
    return { op = "snapshot", rev = state.rev, events = events }
end

local function serve(sender, msg)
    if type(msg) ~= "table" then return end

    if msg.op == "raise" then
        rednet.send(sender, raise(msg, sender), mon.PROTOCOL)

    elseif msg.op == "resolve" then
        local by = type(msg.by) == "string" and msg.by or ("#" .. sender)
        rednet.send(sender, resolve(msg.id, by), mon.PROTOCOL)

    elseif msg.op == "sync" then
        -- Clients broadcast this when they don't know us yet, so the reply
        -- doubles as discovery.
        if msg.rev == state.rev then
            rednet.send(sender, { op = "ok", rev = state.rev }, mon.PROTOCOL)
        else
            rednet.send(sender, snapshot(), mon.PROTOCOL)
        end

    elseif msg.op == "log" then
        rednet.send(sender, { op = "log", entries = state.log }, mon.PROTOCOL)
    end
end

-- Main ---------------------------------------------------------------------

local function run()
    local ok, err = mon.openModem()
    if not ok then error(err, 0) end
    -- Best effort: clients find us by broadcasting, but hosting keeps
    -- rednet.lookup working for anything that prefers it.
    pcall(rednet.host, mon.PROTOCOL, mon.HOSTNAME)

    term.clear()
    term.setCursorPos(1, 1)
    restore()

    local open = 0
    for _ in pairs(state.events) do open = open + 1 end
    print(string.format("monitoring server on #%d - %d open event(s), rev %d",
        os.getComputerID(), open, state.rev))

    local function requests()
        while true do
            local sender, msg = rednet.receive(mon.PROTOCOL)
            serve(sender, msg)
        end
    end

    local function expiry()
        while true do
            sleep(SWEEP_INTERVAL)
            sweep()
            if dirty then save() end
        end
    end

    parallel.waitForAny(requests, expiry)
end

run()
