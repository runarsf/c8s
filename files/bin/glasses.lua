-- smart_glasses entrypoint: runs the monitoring client on the real
-- terminal, with the night-vision toggle and the ntfy listener alongside
-- it on terminals of their own.
--
-- This is not run-many, even though it does the same kind of thing, and
-- the difference is the keyboard. run-many owns it - up/down pick a
-- program, x stops one - while also passing every event on to the
-- programs, so anything with its own key-driven interface fights it for
-- the arrow keys. The monitoring client is exactly that, and it wants the
-- whole screen rather than a pane. So: same scheduler (lib/tasks.lua),
-- no interface of its own.
--
-- Each task is supervised, because one falling over must not take the
-- glasses down with it - ntfy-consume errors out until a topic is
-- configured, and that has to stay harmless. A task that exits cleanly
-- (quitting the monitoring UI with q) is left stopped rather than
-- restarted.

local RESTART_WAIT = 10

local HERE = fs.getDir(shell.getRunningProgram())
local APP  = fs.getDir(HERE)

local tasks = dofile(fs.combine(APP, "lib/tasks.lua"))
local execute = shell.execute or shell.run

local WANTED = {
    { path = "monitoring/client.lua", foreground = true },
    { path = "bin/toggle-night-vision.lua" },
    { path = "bin/ntfy-consume.lua" },
}

local root = term.current()
local width, height = root.getSize()

local list = {}
for _, spec in ipairs(WANTED) do
    local path = fs.combine(APP, spec.path)
    if fs.exists(path) then
        -- Background output goes to a window that is never shown, so it
        -- cannot scribble over whatever owns the screen.
        local out = spec.foreground and root
            or window.create(root, 1, 1, width, height, false)
        list[#list + 1] = tasks.create(spec.path, out,
            tasks.supervised(execute, { path }, RESTART_WAIT))
    end
end

if #list == 0 then
    error("nothing to run: no task files found under " .. APP, 0)
end

local function reportCrashes()
    for _, task in ipairs(list) do
        if task.error and not task.reported then
            task.reported = true
            printError("[glasses] " .. task.name .. ": " .. task.error)
        end
    end
end

for _, task in ipairs(list) do
    tasks.start(task)
end
reportCrashes()

while tasks.running(list) > 0 do
    local event = table.pack(os.pullEventRaw())
    tasks.dispatch(list, event)
    reportCrashes()
    if event[1] == "terminate" then break end
end

term.redirect(root)
