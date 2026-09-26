-- Smart glasses overlay: renders a list of lines, and nothing else.
--
-- Every Advanced Peripherals specific lives in here, behind pcall, so the
-- client runs unchanged on a plain computer - there the whole module
-- quietly turns into a no-op and the terminal UI carries on alone.

local hud = {}

-- Layout of the stack, top-left. Units are screen pixels; tweak these if
-- lines overlap or sit too low on your setup.
local BASE_X, BASE_Y, LINE_HEIGHT = 4, 10, 12

local overlay
local objects = {}  -- pooled text objects, one per rendered line

local function try(action)
    if not overlay then return false end
    local ok, result = pcall(action)
    return ok, result
end

-- The overlay's access path varies between AP builds, so probe for it
-- instead of hardcoding names: prefer the documented module table, then
-- any attached peripheral that exposes createText directly.
local function findOverlay()
    if type(smartglasses) == "table" and type(smartglasses.modules) == "table" then
        local mod = smartglasses.modules["advancedperipherals:overlay"]
            or smartglasses.modules.overlay
        if type(mod) == "table" and type(mod.createText) == "function" then
            return mod
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        local modules = p.modules or (type(p.getModules) == "function" and p.getModules())
        if type(modules) == "table" then
            for _, mod in pairs(modules) do
                if type(mod) == "table" and type(mod.createText) == "function" then
                    return mod
                end
            end
        end
        if type(p.createText) == "function" then
            return p
        end
    end
end

-- Whichever of these names the build happens to use.
local function pick(obj, ...)
    for _, name in ipairs({ ... }) do
        if type(obj[name]) == "function" then return obj[name] end
    end
end

-- Mutating an existing object beats recreating it (no client-side flicker),
-- but only when the build exposes setters for everything that changes.
-- Returns false to tell render() to recreate the line instead.
local function reuse(obj, line, y)
    local setText  = pick(obj, "setText", "setContent")
    local setColor = pick(obj, "setColor", "setColour")
    local setPos   = pick(obj, "setPos", "setPosition")
    if not (setText and setColor and setPos) then return false end

    return (try(function()
        setText(line.text)
        setColor(line.color)
        setPos(BASE_X, y, 0)
    end))
end

local function create(line, y)
    local ok, obj = try(function()
        return overlay.createText({
            content  = line.text,
            color    = line.color,
            fontSize = 1,
            shadow   = true,
            x        = BASE_X,
            y        = y,
        })
    end)
    return ok and obj or nil
end

local function destroy(obj)
    try(function() overlay.removeObject(obj.getId()) end)
end

function hud.available()
    return overlay ~= nil
end

function hud.attach()
    overlay = findOverlay()
    objects = {}
    try(function() overlay.clear() end)  -- drop anything an earlier run left behind
    return overlay ~= nil
end

function hud.clear()
    objects = {}
    try(function() overlay.clear() end)
end

-- `lines` is a list of { text = "...", color = 0xRRGGBB }. Line i reuses
-- pooled object i where it can; leftovers from a longer previous render
-- are removed.
function hud.render(lines)
    if not overlay then return end

    local kept = {}
    for i, line in ipairs(lines) do
        local y = BASE_Y + (i - 1) * LINE_HEIGHT
        local obj = objects[i]
        if obj and reuse(obj, line, y) then
            kept[i] = obj
            objects[i] = nil
        else
            kept[i] = create(line, y)
        end
    end

    for _, obj in pairs(objects) do destroy(obj) end
    objects = kept
end

return hud
