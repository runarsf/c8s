-- Shared vocabulary for the ME request system: the rednet protocol, the
-- search rules, and the formatting the server's console and the pocket
-- client both need.
--
-- The search lives here rather than in the client because getItems() on a
-- real ME system is thousands of entries: only the matches cross the wire,
-- so the two sides have to agree on what "matches" means and in what order.

local M = {}

M.PROTOCOL = "me"
M.HOSTNAME = "me-server"

function M.now()
    return os.epoch("utc")
end

function M.name()
    return os.getComputerLabel() or ("#" .. os.getComputerID())
end

-- Search --------------------------------------------------------------------

-- Returns a scoring function for `query`, or nil when there is nothing to
-- search for. Built once and applied to every item in the system, so the
-- folding and the rules happen here rather than ten thousand times.
--
-- Matching is plain, not pattern: an item id is full of characters Lua
-- would otherwise read as a character class, and searching for
-- "minecraft:iron_ingot" has to mean that string.
function M.matcher(query)
    if type(query) ~= "string" then return nil end
    query = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return nil end

    return function(item)
        local name    = type(item.name) == "string" and item.name:lower() or ""
        local display = type(item.displayName) == "string" and item.displayName:lower() or ""

        if name == query or display == query then return 4 end
        if display:sub(1, #query) == query then return 3 end
        -- Against the id with its namespace stripped, so "iron_ingot" reads
        -- as a prefix of "minecraft:iron_ingot" rather than a substring.
        local bare = name:match(":(.*)$") or name
        if bare:sub(1, #query) == query then return 2 end
        if display:find(query, 1, true) or name:find(query, 1, true) then return 1 end
        return nil
    end
end

-- Best match first, most plentiful first within a score: the order the
-- results list renders in, so "iron" puts Iron Ingot above Iron Bars.
function M.byScore(a, b)
    local sa, sb = a.score or 0, b.score or 0
    if sa ~= sb then return sa > sb end
    return (a.amount or 0) > (b.amount or 0)
end

-- The filter the ME Bridge wants for one particular item. There is no
-- fingerprint in AP 0.8: a name plus the nbt hash is what picks out one
-- variant, and note the asymmetry - a returned stack calls that hash `nbt`
-- while a filter calls it `nbtHash`. Omitted rather than passed empty when
-- there is none, so an item with no components still matches.
function M.filter(item, count)
    local out = { name = item.name }
    if type(item.nbt) == "string" and #item.nbt > 0 then
        out.nbtHash = item.nbt
    end
    if count then out.count = count end
    return out
end

-- Formatting ----------------------------------------------------------------

local function scaled(value)
    if value < 10 then
        return (("%.1f"):format(value):gsub("%.0$", ""))
    end
    return tostring(math.floor(value + 0.5))
end

-- Compact stock figure for a column on a 26-wide pocket screen: 64, 1.2K,
-- 340K, 1.4M.
function M.count(n)
    n = math.max(0, math.floor(tonumber(n) or 0))
    if n < 1000 then return tostring(n) end
    if n < 1000000 then return scaled(n / 1000) .. "K" end
    if n < 1000000000 then return scaled(n / 1000000) .. "M" end
    return scaled(n / 1000000000) .. "B"
end

-- Clips and pads in one go, so a row always covers the width it claims and
-- never leaves the previous frame's tail behind it.
function M.truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text .. string.rep(" ", width - #text) end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

function M.openModem()
    if rednet.isOpen() then return true end
    local modem = peripheral.find("modem")
    if not modem then return false, "no modem attached" end
    rednet.open(peripheral.getName(modem))
    return true
end

return M
