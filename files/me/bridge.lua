-- Every ME Bridge call the server makes, and nothing else.
--
-- Each one goes through pcall and hands back nil plus a reason, so a bridge
-- that was broken, replaced, or renamed by an Advanced Peripherals update
-- fails one request instead of taking the server down with it. The
-- peripheral is looked up per call rather than captured at startup, for the
-- same reason power_monitor re-finds its induction port every cycle: putting
-- the block back must not need a reboot.

local M = {}

-- Advanced Peripherals has spelled this type both ways across versions, so
-- both are tried rather than making the type a thing you edit this file for.
local TYPES = { "me_bridge", "meBridge" }

local preferred  -- from the role's config: a peripheral name, or a type

function M.attach(name)
    preferred = (type(name) == "string" and #name > 0) and name or nil
end

-- The config value is tried as a name and then as a type, because which one
-- it is depends on how the bridge is wired: a block against the computer is
-- "back", the same block on a wired modem is "me_bridge_0", and either way
-- "me_bridge" is the type. Nothing here checks for a particular method -
-- rejecting a bridge whose methods were renamed is how you get told there is
-- no bridge when there plainly is one.
local function find()
    if preferred then
        if peripheral.isPresent(preferred) then
            return peripheral.wrap(preferred)
        end
        local wrapped = peripheral.find(preferred)
        if wrapped then return wrapped end
    end

    for _, kind in ipairs(TYPES) do
        local wrapped = peripheral.find(kind)
        if wrapped then return wrapped end
    end
end

function M.available()
    return find() ~= nil
end

-- Every method the attached bridge actually exposes, sorted.
function M.methods()
    local bridge = find()
    if not bridge then return nil, "no ME Bridge attached" end
    local names = {}
    for key, value in pairs(bridge) do
        if type(value) == "function" then names[#names + 1] = key end
    end
    table.sort(names)
    return names
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
        -- Name what it does have. Advanced Peripherals has moved these
        -- between versions, and an error that only says what is missing
        -- leaves you editing this file in the dark.
        local names = M.methods() or {}
        return nil, "no " .. method .. "() on this bridge - it has: "
            .. table.concat(names, " ")
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

-- Command line -------------------------------------------------------------
--
--   me/bridge.lua probe [type-or-name]
--
-- Prints what is actually attached and every method it exposes, which is the
-- only way to settle a method that moved between Advanced Peripherals
-- versions. Loaded with no arguments - which is how the server loads it -
-- this is just the library.

local args = { ... }
if #args == 0 then return M end

if args[1] ~= "probe" then
    printError("usage: bridge.lua probe [type-or-name]")
    error("", 0)
end

M.attach(args[2])

for _, name in ipairs(peripheral.getNames()) do
    print(name .. "  (" .. tostring(peripheral.getType(name)) .. ")")
end

local names, err = M.methods()
if not names then
    printError(err)
    error("", 0)
end

print("")
print(#names .. " methods:")
print(table.concat(names, " "))

return M
