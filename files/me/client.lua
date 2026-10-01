-- Ask the ME system for items and send them somewhere: search, pick an
-- amount, pick a destination. Built for a pocket computer, so it assumes 26
-- columns and nothing wider.
--
-- Four screens and one event loop rather than anything concurrent. Requests
-- are synchronous on purpose: there is nothing useful to do while waiting for
-- an answer, and a blocking receive with the footer saying so is easier to
-- trust than a UI that looks ready and isn't.
--
-- The server does the searching. All this knows how to do is show what came
-- back.

local HERE = fs.getDir(shell.getRunningProgram())
local me   = dofile(fs.combine(HERE, "protocol.lua"))

-- Longer than alert.lua's 2s: a cold listItems() on a big ME system is not
-- quick, and timing it out would look like the server is missing.
local TIMEOUT = 5

local server          -- computer id, learned from the last reply

local screen   = "search"
local query    = ""
local results  = {}
local selected = 1
local item             -- the row picked on the results screen
local amount   = "1"
local typed    = false -- has a digit been entered since this screen opened
local dests            -- destination list, fetched from the server on demand
local destPick = 1
local status           -- transient footer line, cleared by the next keystroke

-- Talking to the server -----------------------------------------------------

-- Sends a request and waits for its answer. Not knowing the server is fine:
-- a broadcast reaches it just as well and teaches us its id.
local function request(msg)
    local ok, err = me.openModem()
    if not ok then return nil, err end

    if server then
        rednet.send(server, msg, me.PROTOCOL)
    else
        rednet.broadcast(msg, me.PROTOCOL)
    end

    local deadline = os.clock() + TIMEOUT
    repeat
        local sender, reply = rednet.receive(me.PROTOCOL, math.max(0, deadline - os.clock()))
        if type(reply) == "table" then
            local op = reply.op
            if op == "ok" or op == "items" or op == "destinations" then
                server = sender
                return reply
            elseif op == "error" then
                server = sender
                return nil, reply.message or "rejected"
            end
        end
    until os.clock() >= deadline

    server = nil  -- it may have moved or gone away; rediscover next time
    return nil, "no reply from the ME server"
end

-- Drawing -------------------------------------------------------------------

-- Keeps the selection on screen without ever scrolling past the end of a
-- short list.
local function offsetFor(count, sel, visible)
    if count <= visible or sel <= visible then return 0 end
    return math.min(sel - visible, count - visible)
end

local function row(text, tail, width, marker)
    tail = tail and (" " .. tail) or ""
    return marker .. me.truncate(text, width - #marker - #tail) .. tail
end

local function bar(y, text, width)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, y)
    term.write(me.truncate(text, width))
    term.setBackgroundColor(colors.black)
end

local function line(y, text, width, color)
    term.setTextColor(color or colors.white)
    term.setCursorPos(1, y)
    term.write(me.truncate(text, width))
end

local function stock()
    return (item and item.amount) or 0
end

-- What would actually be asked for: never more than the search said was
-- there, so the screen can't promise something the server will trim.
local function wanted()
    return math.min(math.floor(tonumber(amount) or 0), stock())
end

-- One list renderer for both the results and the destinations, so their
-- scrolling and selection can't drift apart.
local function drawList(list, sel, width, height, format)
    local visible = height - 2
    local offset = offsetFor(#list, sel, visible)
    for i = 1, visible do
        local entry = list[offset + i]
        if not entry then break end
        local index = offset + i
        local text, color = format(entry, width, index == sel)
        if index == sel then
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(color or colors.white)
        end
        term.setCursorPos(1, i + 1)
        term.write(text)
    end
    term.setBackgroundColor(colors.black)
end

local function render()
    local width, height = term.getSize()

    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    local caret

    if screen == "search" then
        bar(1, " ME  what are you after?", width)
        line(3, "/" .. query, width)
        bar(height, status or " enter search   esc quit", width)
        caret = { math.min(width, #query + 2), 3 }

    elseif screen == "results" then
        bar(1, (" %d for '%s'"):format(#results, query), width)
        if #results == 0 then
            line(3, " nothing matched", width, colors.lightGray)
        else
            drawList(results, selected, width, height, function(entry, w, isSel)
                return row(entry.displayName or entry.name, me.count(entry.amount), w,
                    isSel and "> " or "  ")
            end)
        end
        bar(height, status or " enter pick   bksp search", width)

    elseif screen == "amount" then
        bar(1, " how many?", width)
        line(3, " " .. (item and (item.displayName or item.name) or "?"), width)
        line(4, " in stock " .. me.count(stock()), width, colors.lightGray)
        local over = (tonumber(amount) or 0) > stock()
        line(6, " x " .. amount, width, over and colors.yellow or colors.white)
        if over then
            line(7, " capped at " .. stock(), width, colors.yellow)
        end
        bar(height, status or " digits  a all  enter ok", width)
        caret = { math.min(width, #amount + 4), 6 }

    elseif screen == "dest" then
        bar(1, (" send %d where?"):format(wanted()), width)
        if not dests or #dests == 0 then
            -- Nothing is "set up" any more, so the empty list means the
            -- server found no inventory on its network at all.
            line(3, " no stations found", width, colors.lightGray)
        else
            drawList(dests, destPick, width, height, function(entry, w, isSel)
                return row(entry.name, entry.missing and "gone" or nil, w,
                    isSel and "> " or "  "), entry.missing and colors.gray or colors.white
            end)
        end
        bar(height, status or " enter send   bksp back", width)
    end

    if caret then
        term.setCursorPos(caret[1], caret[2])
        term.setCursorBlink(true)
    end
end

-- Actions -------------------------------------------------------------------

local function fetchDestinations()
    local reply, err = request({ op = "destinations" })
    if not reply then return nil, err end
    dests = reply.destinations or {}
    return dests
end

local function runSearch()
    if query == "" then return end
    -- Drawn before the blocking send, because that is the whole of the
    -- loading state.
    status = " searching..."
    render()

    local reply, err = request({ op = "search", query = query })
    if not reply then
        status = " " .. err
        return
    end

    results  = reply.items or {}
    selected = 1
    screen   = "results"
    status   = nil
end

local function pick()
    item = results[selected]
    if not item then return end
    amount = "1"
    typed  = false
    screen = "amount"
    status = nil
end

local function toDestinations()
    if wanted() <= 0 then
        status = " pick an amount first"
        return
    end

    if not dests then
        status = " asking..."
        render()
        local list, err = fetchDestinations()
        if not list then
            status = " " .. err
            return
        end
    end

    destPick = 1
    screen   = "dest"
    status   = nil
end

local function sendIt()
    local dest = dests and dests[destPick]
    if not dest or not item then return end
    if dest.missing then
        status = " " .. dest.name .. " is not on the network"
        return
    end

    local count = wanted()
    status = " sending..."
    render()

    -- The container name, not the label on screen: labels are derived from
    -- the block on the server side, and the one this list was drawn from can
    -- have been renumbered by the time the send goes out. The container is
    -- what both ends agree on.
    local reply, err = request({
        op          = "send",
        item        = { name = item.name, nbt = item.nbt },
        count       = count,
        destination = dest.container or dest.name,
    })

    -- Back to the results either way: the footer carries the outcome, and a
    -- second helping is two keys away.
    screen = "results"

    -- Kept short enough to survive 26 columns: the destination is the thing
    -- that was just picked, so it only earns a mention when all went well.
    if not reply then
        status = " " .. err
    elseif reply.moved == 0 then
        status = " nothing moved - full?"
    elseif reply.moved < reply.requested then
        status = (" sent %d of %d"):format(reply.moved, reply.requested)
    else
        status = (" sent %d to %s"):format(reply.moved, dest.name)
    end

    if reply and item then
        -- The row on screen would otherwise keep claiming stock that just
        -- left the system.
        item.amount = math.max(0, stock() - (reply.moved or 0))
    end
    -- A destination's presence may have changed while we were away, and the
    -- next send should not be decided by a stale flag.
    dests = nil
end

-- Keys ----------------------------------------------------------------------

-- Whether the keyboard is ours. run-many hands every event to every program
-- it supervises, not only the one on screen, and focus there is a window that
-- was made visible - so without this, an arrow key pressed in the monitoring
-- client walks this list in the background and an enter meant for it sends
-- items. A plain terminal has no isVisible, and is also the case where there
-- is nobody to share the keyboard with.
local function onScreen()
    local current = term.current()
    if type(current.isVisible) ~= "function" then return true end
    local ok, visible = pcall(current.isVisible)
    if not ok then return true end
    return visible ~= false
end

local function onChar(ch)
    if screen == "search" then
        query = query .. ch
        status = nil

    elseif screen == "amount" then
        if ch:match("%d") then
            -- The first digit replaces the prefilled 1 rather than landing
            -- next to it, so "64" is two keys and not three.
            amount = (typed and amount or "") .. ch
            typed  = true
            status = nil
        elseif ch == "a" or ch == "A" then
            amount = tostring(stock())
            typed  = true
            status = nil
        end
    end
end

-- Returns true to quit.
local function onKey(key, height)
    local visible = math.max(1, height - 2)

    if key == keys.escape then return true end

    if screen == "search" then
        if key == keys.backspace then
            query = query:sub(1, -2)
        elseif key == keys.enter or key == keys.numPadEnter then
            runSearch()
        end

    elseif screen == "results" then
        if key == keys.up then
            selected = math.max(1, selected - 1)
        elseif key == keys.down then
            selected = math.min(math.max(1, #results), selected + 1)
        elseif key == keys.pageUp then
            selected = math.max(1, selected - visible)
        elseif key == keys.pageDown then
            selected = math.min(math.max(1, #results), selected + visible)
        elseif key == keys.enter or key == keys.numPadEnter then
            pick()
        elseif key == keys.backspace then
            screen = "search"
            status = nil
        end

    elseif screen == "amount" then
        if key == keys.backspace then
            if typed then
                amount = amount:sub(1, -2)
            else
                screen = "results"
            end
            status = nil
        elseif key == keys.enter or key == keys.numPadEnter then
            toDestinations()
        end

    elseif screen == "dest" then
        if key == keys.up then
            destPick = math.max(1, destPick - 1)
        elseif key == keys.down then
            destPick = math.min(math.max(1, dests and #dests or 1), destPick + 1)
        elseif key == keys.enter or key == keys.numPadEnter then
            sendIt()
        elseif key == keys.backspace then
            screen = "amount"
            status = nil
        end
    end

    return false
end

local function run()
    local ok, err = me.openModem()
    if not ok then error(err, 0) end

    -- Asked for up front so the first screen can say whether the server is
    -- there at all, rather than looking ready and failing on the first search.
    -- Drawn before the asking, or a missing server is five seconds of black.
    status = " looking for the server..."
    render()

    local list, derr = fetchDestinations()
    status = list and nil or (" " .. derr)
    render()

    while true do
        local event = { os.pullEvent() }
        local name = event[1]
        local mine = onScreen()

        if name == "char" and mine then
            onChar(event[2])
        elseif name == "key" and mine then
            local _, height = term.getSize()
            if onKey(event[2], height) then return end
        end

        -- Drawn even when something else has the screen: this is a window
        -- either way, and it should already be right when it is handed over.
        render()
    end
end

local ok, err = pcall(run)
term.setCursorBlink(false)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
