-- Tries every way of naming an export target and prints what each one did.
--
--   me/diag.lua [item] [count]
--
-- Defaults to one cobblestone. Run it on the ME server computer with the
-- server stopped (Ctrl+T). It really does export, so give it something cheap.
--
-- This exists because the question "why does exportItem say
-- INVENTORY_NOT_FOUND" was answered three times with a theory and a thing to
-- go and try, when the computer with the bridge on it could have answered it
-- outright. Every target form the docs describe is attempted here - every
-- peripheral name on the computer's network, and all six "@side" directions
-- relative to the bridge - with the raw result or the raw error next to each.

local HERE   = fs.getDir(shell.getRunningProgram())
local bridge = dofile(fs.combine(HERE, "bridge.lua"))

local args   = { ... }
local ITEM   = args[1] or "minecraft:cobblestone"
local COUNT  = math.max(1, math.floor(tonumber(args[2]) or 1))
local FILTER = { name = ITEM, count = COUNT }

local function head(text)
    term.setTextColor(colors.yellow)
    print("")
    print("== " .. text)
    term.setTextColor(colors.white)
end

local function say(label, text, color)
    term.setTextColor(colors.lightGray)
    write(label .. " ")
    term.setTextColor(color or colors.white)
    print(text)
    term.setTextColor(colors.white)
end

-- What came back, as text: a stack table prints its count and name, anything
-- else prints as itself. The point is to see the shape, not to interpret it.
local function describe(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, inner in pairs(value) do
        if type(inner) ~= "table" then
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(inner)
        else
            parts[#parts + 1] = tostring(key) .. "={...}"
        end
    end
    table.sort(parts)
    return "{ " .. table.concat(parts, " ") .. " }"
end

-- The network --------------------------------------------------------------

head("peripherals")

local names = peripheral.getNames()
for _, name in ipairs(names) do
    local kinds = table.pack(peripheral.getType(name))
    local list = {}
    for index = 1, kinds.n do list[#list + 1] = tostring(kinds[index]) end
    say(name, "(" .. table.concat(list, ", ") .. ")")
end

-- The bridge ---------------------------------------------------------------

head("bridge")

bridge.attach(nil)
if not bridge.available() then
    printError("no ME Bridge found by type me_bridge or meBridge")
    error("", 0)
end

local methods = bridge.methods()
say("methods", table.concat(methods or {}, " "))

local wrapped = peripheral.find("me_bridge") or peripheral.find("meBridge")
local ok, bridgeName = pcall(peripheral.getName, wrapped)
say("named", ok and tostring(bridgeName) or "?")

local stock, serr = bridge.item{ name = ITEM }
if stock then
    say("stock", ITEM .. " x" .. tostring(stock.count))
else
    say("stock", ITEM .. " - " .. tostring(serr), colors.red)
end

-- Every target form --------------------------------------------------------
--
-- Called through the peripheral directly rather than through bridge.exportTo,
-- so what is reported is exactly what the bridge said, with nothing of ours
-- in between.

-- One call per target, never two: a second call to find out what the first
-- returned would export a second time.
local function try(target)
    local packed = table.pack(pcall(wrapped.exportItem, target, FILTER))
    if not packed[1] then return "threw: " .. tostring(packed[2]), colors.red end

    -- The method's own returns: nil plus a reason when it refuses, the moved
    -- stack when it works.
    local value, reason = packed[2], packed[3]
    if value == nil or value == false then
        return tostring(reason or "refused"), colors.red
    end
    return describe(value), colors.lime
end

head("exportItem(name, filter)")

for _, name in ipairs(names) do
    local text, color = try(name)
    say(name, text, color)
end

head("exportItem('@side', filter)")

for _, side in ipairs({ "@up", "@down", "@north", "@south", "@east", "@west" }) do
    local text, color = try(side)
    say(side, text, color)
end

head("done")
print("Green lines are targets that worked.")
