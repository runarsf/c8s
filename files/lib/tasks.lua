-- Cooperative multitasking: several programs at once, each with its own
-- terminal, inside one computer's single Lua thread.
--
-- Why this exists rather than `parallel`: parallel hands every function
-- the same terminal, and term.redirect is global state, so a background
-- program's redirect is still in force when the foreground one draws. The
-- redirect has to be installed around each individual resume instead,
-- which is what this does.
--
-- Event filters are honoured, the way parallel does it and for the same
-- reason: CC's os.pullEvent yields its filter and trusts the scheduler to
-- resume it only for a matching event - it never re-checks. A scheduler
-- that forwards every event makes os.pullEvent("glasses_key_pressed")
-- return on the next timer tick instead.
--
-- Loaded with dofile, so there is no `shell` in scope here: anything that
-- needs to run a program passes its own runner in.

local tasks = {}

-- `out` is the terminal this task draws to: the real one for a task that
-- owns the screen, or window.create(..., false) for one whose output is
-- captured instead.
function tasks.create(name, out, body)
    return { name = name, out = out, body = body, status = "queued" }
end

function tasks.start(task)
    task.co = coroutine.create(task.body)
    task.status = "running"
    tasks.resume(task)
end

-- Resumes one task, with an event or with nothing for the first resume.
-- Statuses go queued -> running -> done | error; a caller may set any
-- other status (run-many uses "stopped") to have the task left alone from
-- then on.
function tasks.resume(task, event)
    if task.status ~= "running" then return end
    if not task.co or coroutine.status(task.co) ~= "suspended" then return end
    if event and task.filter and task.filter ~= event[1] and event[1] ~= "terminate" then
        return
    end

    local previous = term.redirect(task.out)
    local ok, result = coroutine.resume(task.co, table.unpack(event or {}, 1, event and event.n or 0))
    term.redirect(previous)

    task.filter = nil
    if not ok then
        task.status = "error"
        task.error = tostring(result)
    elseif coroutine.status(task.co) == "dead" then
        -- A body that set its own status has already said what happened.
        if task.status == "running" then task.status = "done" end
    else
        task.filter = type(result) == "string" and result or nil
    end
end

function tasks.dispatch(list, event)
    for _, task in ipairs(list) do
        tasks.resume(task, event)
    end
end

function tasks.running(list)
    local count = 0
    for _, task in ipairs(list) do
        if task.status == "running" then count = count + 1 end
    end
    return count
end

-- Body for a task that should come back after a crash. `run` is the
-- caller's runner (shell.execute or shell.run), `command` a list of words.
-- A clean exit is left alone: something that finished on purpose has not
-- failed, and restarting it would be a loop.
function tasks.supervised(run, command, wait)
    return function()
        while true do
            if run(table.unpack(command)) then return end
            print("[restart] " .. command[1] .. " in " .. wait .. "s")
            sleep(wait)
        end
    end
end

return tasks
