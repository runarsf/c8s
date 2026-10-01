-- What the ME system can send things to, discovered rather than declared.
--
-- The first version of this read a list of { name, container } pairs out of
-- roles.lua, which made every new machine a controller edit plus a version
-- bump before anyone could send to it - and the container in that list was a
-- peripheral name somebody had to go and look up with a probe first. None of
-- that was necessary: the network already knows what is wired into it.
--
-- Nothing here matches block ids against a table of machines it knows about.
-- That is the point: an ultimate smelting factory nobody had heard of when
-- this was written turns up on the list anyway, and a list of the ones
-- somebody did think of is exactly the thing that goes stale.

local M = {}

-- Everything on the network is a destination except what is named here.
--
-- This started out the other way round - accept what claims CC:Tweaked's
-- generic "inventory" type, or failing that what exposes list() and size() -
-- and it found nothing on a network with a smelting factory plainly wired
-- into it. Advanced Peripherals claims a Mekanism machine before CC's own
-- inventory provider gets to it, so the factory is type
-- "ultimateSmeltingFactory" with no inventory type and none of those
-- methods. It is still a perfectly good export target: the bridge resolves
-- the name itself and pushes through the block's item handler, not through
-- anything CC exposes. Testing for an interface the export never uses is how
-- you get told there are no stations when there plainly is one.
--
-- So the test is inverted, and this table only has to name what cannot hold
-- an item. It stays short and fixed because all of it comes from CC:Tweaked
-- itself plus the bridge, not from any mod's machines. Guessing wrong in
-- this direction costs one error message from exportItem, which the server
-- already reports and raises; guessing wrong in the other direction costs
-- you a machine you cannot use and no way to find out why.
local NOT_A_DESTINATION = {
    modem   = true,
    monitor = true,
    speaker = true,
    drive   = true,
    computer = true,
    -- Exporting the system's contents back into the system.
    me_bridge = true,
    meBridge  = true,
}

-- All of a peripheral's types, not just the first: CC:Tweaked returns the
-- extra ones as further return values, and a block can be a monitor and
-- something else at once.
local function typesOf(name)
    local ok, packed = pcall(function() return table.pack(peripheral.getType(name)) end)
    if not ok or type(packed) ~= "table" then return {} end

    local out = {}
    for index = 1, (packed.n or #packed) do
        if type(packed[index]) == "string" then out[#out + 1] = packed[index] end
    end
    return out
end

-- Lua patterns, matched against the peripheral name as given. Not lowercased
-- first: folding the case of a pattern turns %D into %d and silently means
-- something else. Names from a wired modem arrive in whatever case the mod
-- registered, which is why the AP ones are camelCase.
local function ignored(name, patterns)
    for _, pattern in ipairs(patterns) do
        if type(pattern) == "string" then
            local ok, found = pcall(string.find, name, pattern)
            if ok and found then return pattern end
        end
    end
end

-- "mekanism:ultimate_smelting_factory_3" -> "Ultimate Smelting Factory", 3
-- "ultimateSmeltingFactory_0"            -> "Ultimate Smelting Factory", 0
-- "minecraft:chest_0"                    -> "Chest", 0
-- "back"                                 -> "Back", nil
--
-- Both spellings, because which one a machine has depends on which mod
-- registered the peripheral: CC's own provider uses the block id, Advanced
-- Peripherals uses its own camelCase name. The namespace goes because this
-- lands on a 26-column pocket screen and which mod a machine came from has
-- never been the question.
--
-- The trailing index comes off separately rather than being left in the
-- label: it is only worth showing when there is more than one of something,
-- and it is the part a truncated label would otherwise lose - "Ultimate
-- Smelting Fac..." twice over is worse than no number at all.
local function describe(peripheralName)
    local bare = peripheralName:match("^[^:]*:(.+)$") or peripheralName
    local stem, index = bare:match("^(.-)_(%d+)$")
    if not stem or stem == "" then stem, index = bare, nil end

    local spaced = stem:gsub("_", " ")
                       :gsub("(%l)(%u)", "%1 %2")    -- camelCase -> camel Case
                       :gsub("(%u)(%u%l)", "%1 %2")  -- MEBridge  -> ME Bridge

    local words = {}
    for word in spaced:gmatch("%S+") do
        words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
    end

    local label = table.concat(words, " ")
    if label == "" then label = bare end
    return label, index and tonumber(index) or nil
end

-- Every peripheral on the network with a verdict on each: what it would be
-- called, or why it is not on the list. Discovery is the filtered version of
-- this; the command line below prints all of it, because "my machine isn't
-- there" is the question this module exists to answer.
function M.inspect(options)
    options = options or {}
    local ignore = type(options.ignore) == "table" and options.ignore or {}

    local exclude = {}
    for _, name in ipairs(type(options.exclude) == "table" and options.exclude or {}) do
        if type(name) == "string" then exclude[name] = true end
    end

    local rows = {}
    for _, name in ipairs(peripheral.getNames()) do
        local kinds = typesOf(name)
        local row = { container = name, types = kinds }

        local blocked
        for _, kind in ipairs(kinds) do
            if NOT_A_DESTINATION[kind] then blocked = kind end
        end

        local pattern = ignored(name, ignore)

        if exclude[name] then
            row.skipped = "excluded"
        elseif blocked then
            row.skipped = "a " .. blocked
        elseif pattern then
            row.skipped = "ignore pattern '" .. pattern .. "'"
        else
            row.label, row.index = describe(name)
        end

        rows[#rows + 1] = row
    end
    return rows
end

-- Every destination on the network, labelled, sorted, and with only the
-- duplicates numbered.
--
--   options.ignore  - patterns for peripherals that are not destinations
--   options.exclude - exact peripheral names to leave out
function M.discover(options)
    local found = {}
    for _, row in ipairs(M.inspect(options)) do
        if not row.skipped then found[#found + 1] = row end
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
    for _, row in ipairs(found) do
        kinds[row.label] = (kinds[row.label] or 0) + 1
    end

    local out, counter, used = {}, {}, {}
    for _, row in ipairs(found) do
        local name = row.label
        if kinds[row.label] > 1 then
            -- The index the network gave it, which holds as long as the modem
            -- does, and a plain running number for anything that had none.
            counter[row.label] = (counter[row.label] or 0) + 1
            name = name .. " " .. tostring(row.index or counter[row.label])
        end
        -- Two mods can produce the same label and the same index. The
        -- peripheral name is the one thing that cannot collide, so that is
        -- what a collision falls back to - a list with two identical rows on
        -- it is a send to the wrong machine waiting to happen.
        if used[name:lower()] then name = row.container end
        used[name:lower()] = true

        out[#out + 1] = { name = name, container = row.container }
    end

    return out
end

-- Command line -------------------------------------------------------------
--
--   me/stations.lua list [ignore-pattern ...]
--
-- Prints the list the client would be handed - the label, and the peripheral
-- name behind it - and then everything on the network that did not make it,
-- with the reason and its types. Run it on the server computer after wiring
-- a new machine in. Loaded with no arguments - which is how the server loads
-- it - this is just the library.

local args = { ... }
if #args == 0 then return M end

if args[1] ~= "list" then
    printError("usage: stations.lua list [ignore-pattern ...]")
    error("", 0)
end

local patterns = {}
for index = 2, #args do patterns[#patterns + 1] = args[index] end

local rows = M.inspect{ ignore = patterns }
local list = M.discover{ ignore = patterns }

print(#list .. " station" .. (#list == 1 and "" or "s") .. ":")
for _, dest in ipairs(list) do
    print("  " .. dest.name .. "  (" .. dest.container .. ")")
end

local skipped = {}
for _, row in ipairs(rows) do
    if row.skipped then skipped[#skipped + 1] = row end
end

if #skipped > 0 then
    print("")
    print(#skipped .. " skipped:")
    for _, row in ipairs(skipped) do
        print("  " .. row.container .. " - " .. row.skipped)
    end
end

return M
