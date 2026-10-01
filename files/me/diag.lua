-- Which export targets the bridge accepts.
--
--   me/diag.lua [item] [count]
--
-- Detail goes to /diag.txt because a CC terminal has no scrollback; the
-- screen gets only what fits on it. Really exports, one item per target by
-- default, so give it something cheap.

local HERE   = fs.getDir(shell.getRunningProgram())
local bridge = dofile(fs.combine(HERE, "bridge.lua"))

local args  = { ... }
local ITEM  = args[1] or "minecraft:cobblestone"
local COUNT = math.max(1, math.floor(tonumber(args[2]) or 1))

local log = fs.open("/diag.txt", "w")

local function describe(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, inner in pairs(value) do
        parts[#parts + 1] = tostring(key) .. "="
            .. (type(inner) == "table" and "{...}" or tostring(inner))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, " ") .. "}"
end

local names = peripheral.getNames()

log.writeLine("peripherals")
for _, name in ipairs(names) do
    local kinds = table.pack(peripheral.getType(name))
    local list = {}
    for index = 1, kinds.n do list[#list + 1] = tostring(kinds[index]) end
    log.writeLine("  " .. name .. "  (" .. table.concat(list, ", ") .. ")")
end

bridge.attach(nil)
local me = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not me then
    log.close()
    printError("no ME Bridge found (type me_bridge or meBridge)")
    error("", 0)
end

local methods = bridge.methods() or {}
local okName, bridgeName = pcall(peripheral.getName, me)
local stock, serr = bridge.item{ name = ITEM }

log.writeLine("")
log.writeLine("bridge " .. (okName and tostring(bridgeName) or "?"))
log.writeLine("methods " .. table.concat(methods, " "))
log.writeLine("stock " .. (stock and tostring(stock.count) or tostring(serr)))

local targets = {}
for _, name in ipairs(names) do targets[#targets + 1] = name end
for _, side in ipairs({ "@up", "@down", "@north", "@south", "@east", "@west" }) do
    targets[#targets + 1] = side
end

-- Errors are grouped rather than listed: twenty peripherals answering
-- INVENTORY_NOT_FOUND is one fact, not twenty lines.
local worked, counts, order = {}, {}, {}

log.writeLine("")
log.writeLine(("exportItem(target, {name=%s, count=%d})"):format(ITEM, COUNT))
for _, target in ipairs(targets) do
    local packed = table.pack(pcall(me.exportItem, target, { name = ITEM, count = COUNT }))
    local text, good

    if not packed[1] then
        text = "threw: " .. tostring(packed[2])
    elseif packed[2] == nil or packed[2] == false then
        text = tostring(packed[3] or "refused")
    else
        text, good = describe(packed[2]), true
    end

    log.writeLine("  " .. target .. "  " .. text)

    if good then
        worked[#worked + 1] = target
    else
        if not counts[text] then
            counts[text] = 0
            order[#order + 1] = text
        end
        counts[text] = counts[text] + 1
    end
end

log.close()

-- Summary ------------------------------------------------------------------

local function say(text, color)
    term.setTextColor(color or colors.white)
    print(text)
    term.setTextColor(colors.white)
end

say("bridge " .. (okName and tostring(bridgeName) or "?"))
say("exportItem " .. (type(me.exportItem) == "function" and "yes" or "MISSING"),
    type(me.exportItem) == "function" and colors.white or colors.red)
say("stock " .. (stock and (ITEM .. " x" .. tostring(stock.count))
    or (ITEM .. " - " .. tostring(serr))),
    stock and colors.white or colors.red)

if #worked > 0 then
    say(#worked .. " worked:", colors.lime)
    for _, target in ipairs(worked) do say("  " .. target, colors.lime) end
else
    say("nothing accepted " .. #targets .. " targets:", colors.red)
end

for _, text in ipairs(order) do
    say("  " .. counts[text] .. "x " .. text, colors.red)
end

say("detail in /diag.txt", colors.lightGray)
