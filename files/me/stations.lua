-- What the ME system can send things to, discovered rather than declared.
--
-- The first version of this read a list of { name, container } pairs out of
-- roles.lua, which made every new machine a controller edit plus a version
-- bump before anyone could send to it - and the container in that list was a
-- peripheral name somebody had to go and look up with a probe first. None of
-- that was necessary: anything with an inventory can be exported into, and
-- the peripheral name already says what the block is.
--
-- Nothing here matches block ids against a table of machines it knows about.
-- That is the point: an ultimate smelting factory nobody had heard of when
-- this was written turns up on the list anyway, and a list of the ones
-- somebody did think of is exactly the thing that goes stale.

local M = {}

-- The generic type CC:Tweaked gives every block exposing an item handler, no
-- matter which mod it came from. Asking for it is how this stays free of mod
-- names.
local INVENTORY = "inventory"

-- Not every build answers hasType, and a block can expose the methods
-- without claiming the type, so the fallback asks for what an export
-- actually needs: somewhere with slots to put things in. Deliberately not
-- pushItems/pullItems - the bridge does the moving, and demanding a method
-- nothing here calls is how a usable destination gets left off the list.
local DUCK = { "list", "size" }

local function looksLikeInventory(name)
    if type(peripheral.hasType) == "function" then
        local ok, yes = pcall(peripheral.hasType, name, INVENTORY)
        if ok and yes then return true end
    end

    local ok, wrapped = pcall(peripheral.wrap, name)
    if not ok or type(wrapped) ~= "table" then return false end
    for _, method in ipairs(DUCK) do
        if type(wrapped[method]) ~= "function" then return false end
    end
    return true
end

-- Lua patterns, matched against the peripheral name as given. Not lowercased
-- first: folding the case of a pattern turns %D into %d and silently means
-- something else. Peripheral names arrive lowercase anyway.
local function ignored(name, patterns)
    for _, pattern in ipairs(patterns) do
        if type(pattern) == "string" then
            local ok, found = pcall(string.find, name, pattern)
            if ok and found then return true end
        end
    end
    return false
end

-- "mekanism:ultimate_smelting_factory_3" -> "Ultimate Smelting Factory", 3
-- "minecraft:chest_0"                    -> "Chest", 0
-- "back"                                 -> "Back", nil
--
-- The namespace goes because this lands on a 26-column pocket screen and
-- which mod a machine came from has never been the question. The trailing
-- index comes off separately rather than being left in the label: it is only
-- worth showing when there is more than one of something, and it is the part
-- a truncated label would otherwise lose - "Ultimate Smelting Fac..." twice
-- over is worse than no number at all.
local function describe(peripheralName)
    local bare = peripheralName:match("^[^:]*:(.+)$") or peripheralName
    local stem, index = bare:match("^(.-)_(%d+)$")
    if not stem or stem == "" then stem, index = bare, nil end

    local words = {}
    for word in stem:gmatch("[^_%s]+") do
        words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
    end

    local label = table.concat(words, " ")
    if label == "" then label = bare end
    return label, index and tonumber(index) or nil
end

-- Every inventory on the network, labelled, sorted, and with only the
-- duplicates numbered.
--
--   options.ignore  - patterns for peripherals that are not destinations
--   options.exclude - exact peripheral names to leave out
function M.discover(options)
    options = options or {}
    local ignore = type(options.ignore) == "table" and options.ignore or {}

    local exclude = {}
    for _, name in ipairs(type(options.exclude) == "table" and options.exclude or {}) do
        if type(name) == "string" then exclude[name] = true end
    end

    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if not exclude[name] and not ignored(name, ignore)
            and looksLikeInventory(name) then
            local label, index = describe(name)
            found[#found + 1] = { container = name, label = label, index = index }
        end
    end

    -- By what the label will read as, not by peripheral name: the network
    -- hands out its indices in connection order, so sorting on those makes
    -- the list on the pocket screen reshuffle every time a modem is
    -- replaced.
    table.sort(found, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        if (a.index or -1) ~= (b.index or -1) then return (a.index or -1) < (b.index or -1) end
        return a.container < b.container
    end)

    local kinds = {}
    for _, entry in ipairs(found) do
        kinds[entry.label] = (kinds[entry.label] or 0) + 1
    end

    local out, counter, used = {}, {}, {}
    for _, entry in ipairs(found) do
        local name = entry.label
        if kinds[entry.label] > 1 then
            -- The index the network gave it, which holds as long as the modem
            -- does, and a plain running number for anything that had none.
            counter[entry.label] = (counter[entry.label] or 0) + 1
            name = name .. " " .. tostring(entry.index or counter[entry.label])
        end
        -- Two mods can produce the same label and the same index. The
        -- peripheral name is the one thing that cannot collide, so that is
        -- what a collision falls back to - a list with two identical rows on
        -- it is a send to the wrong machine waiting to happen.
        if used[name:lower()] then name = entry.container end
        used[name:lower()] = true

        out[#out + 1] = { name = name, container = entry.container }
    end

    return out
end

-- Command line -------------------------------------------------------------
--
--   me/stations.lua list [ignore-pattern ...]
--
-- Prints the list the client would be handed: the label, and the peripheral
-- name behind it. Worth running on the server computer after wiring a new
-- machine in - if it is not on this list, the client will not offer it, and
-- the reason is on the network rather than in the config. Loaded with no
-- arguments - which is how the server loads it - this is just the library.

local args = { ... }
if #args == 0 then return M end

if args[1] ~= "list" then
    printError("usage: stations.lua list [ignore-pattern ...]")
    error("", 0)
end

local patterns = {}
for index = 2, #args do patterns[#patterns + 1] = args[index] end

local list = M.discover{ ignore = patterns }
print(#list .. " station" .. (#list == 1 and "" or "s") .. ":")
for _, dest in ipairs(list) do
    print("  " .. dest.name .. "  (" .. dest.container .. ")")
end

return M
