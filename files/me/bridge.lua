-- Every ME Bridge call the server makes, and nothing else.
--
-- Each one goes through pcall and hands back nil plus a reason, so a bridge
-- that was broken, replaced, or renamed by an Advanced Peripherals update
-- fails one request instead of taking the server down with it. The
-- peripheral is looked up per call rather than captured at startup, for the
-- same reason power_monitor re-finds its induction port every cycle: putting
-- the block back must not need a reboot.

local M = {}

local TYPE = "meBridge"

local preferred  -- peripheral name from the role's config, when it set one

function M.attach(name)
    preferred = (type(name) == "string" and #name > 0) and name or nil
end

local function find()
    if preferred and peripheral.isPresent(preferred) then
        local wrapped = peripheral.wrap(preferred)
        if type(wrapped) == "table" and type(wrapped.listItems) == "function" then
            return wrapped
        end
    end
    return peripheral.find(TYPE)
end

function M.available()
    return find() ~= nil
end

-- Normalises the three ways a bridge call can fail: no bridge at all, a Lua
-- error inside the call, and the (nil, reason) pair the bridge itself
-- returns when the ME system says no. A numeric 0 is a real answer and has
-- to come through, so the test is against nil and false, not truthiness.
local function call(method, ...)
    local bridge = find()
    if not bridge then return nil, "no ME Bridge attached" end

    local fn = bridge[method]
    if type(fn) ~= "function" then
        return nil, "this ME Bridge has no " .. method .. "()"
    end

    local ok, value, err = pcall(fn, ...)
    if not ok then return nil, tostring(value) end
    if value == nil or value == false then
        return nil, tostring(err or "the ME system refused")
    end
    return value
end

-- Every item the system is storing. Expensive: the server caches this.
function M.items()
    local list, err = call("listItems")
    if not list then return nil, err end
    if type(list) ~= "table" then return nil, "listItems did not return a list" end
    return list
end

function M.item(filter)
    local item, err = call("getItem", filter)
    if not item then return nil, err end
    if type(item) ~= "table" then return nil, "getItem did not return an item" end
    return item
end

-- Moves up to filter.count into `container`, and reports how much that
-- actually was.
function M.exportTo(filter, container)
    local moved, err = call("exportItemToPeripheral", filter, container)
    if not moved then return nil, err end
    return math.max(0, math.floor(tonumber(moved) or 0))
end

return M
