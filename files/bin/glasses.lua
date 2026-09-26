-- smart_glasses entrypoint: runs the monitoring client on the real
-- terminal, with the night-vision toggle and the ntfy listener alongside
-- it on terminals of their own.
--
-- Each task is supervised: one falling over must not take the glasses
-- down with it (ntfy-consume errors out until a topic is configured, and
-- that has to stay harmless). A task that exits cleanly - quitting the
-- monitoring UI with q - is left stopped rather than restarted.
--
-- This is a small cooperative scheduler rather than `parallel`, because
-- term.redirect is global state: the background tasks' redirect has to be
-- installed only while they are actually running, or their output lands
-- on top of the client's UI. run-many does the same thing with a GUI
-- attached; this is the same trick with none.

local APP          = "/app"
local RESTART_WAIT = 10

local TASKS = {
    { path = "monitoring/client.lua", foreground = true },
    { path = "bin/toggle-night-vision.lua" },
    { path = "bin/ntfy-consume.lua" },
}

local root = term.current()
local width, height = root.getSize()

local tasks = {}
for _, spec in ipairs(TASKS) do
    local path = fs.combine(APP, spec.path)
    if fs.exists(path) then
        tasks[#tasks + 1] = {
            path = path,
            -- Background output goes to a window that is never shown.
            out  = spec.foreground and root or window.create(root, 1, 1, width, height, false),
        }
    end
end

if #tasks == 0 then
    error("nothing to run: no task files found under " .. APP, 0)
end

-- shell.run swallows the error and returns false, so a crash is just a
-- restart here; the message has already been printed to the task's own
-- terminal.
local function body(task)
    return function()
        while true do
            if shell.run(task.path) then return end
            print("[glasses] " .. task.path .. " stopped, restarting in " .. RESTART_WAIT .. "s")
            sleep(RESTART_WAIT)
        end
    end
end

-- Honours the filter a coroutine yielded, the way parallel does: CC's
-- os.pullEvent trusts its scheduler to do that and does not re-check.
local function resume(task, event)
    if coroutine.status(task.co) == "dead" then return end
    if event and task.filter and task.filter ~= event[1] and event[1] ~= "terminate" then
        return
    end

    local previous = term.redirect(task.out)
    local ok, result = coroutine.resume(task.co, table.unpack(event or {}))
    term.redirect(previous)

    if ok then
        task.filter = result
    else
        task.filter = nil
        printError("[glasses] " .. task.path .. ": " .. tostring(result))
    end
end

for _, task in ipairs(tasks) do
    task.co = coroutine.create(body(task))
    resume(task)
end

while true do
    local alive = 0
    for _, task in ipairs(tasks) do
        if coroutine.status(task.co) ~= "dead" then alive = alive + 1 end
    end
    if alive == 0 then break end

    local event = { os.pullEventRaw() }
    for _, task in ipairs(tasks) do
        resume(task, event)
    end
    if event[1] == "terminate" then break end
end

term.redirect(root)
