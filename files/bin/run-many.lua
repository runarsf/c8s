-- run several shell commands in parallel, with a small GUI
-- (list of running programs on the left, output of the selected one on
-- the right).
--
-- Usage:
--   run-many <command> [<command> ...]
--
-- Each argument is one command; quote commands containing spaces. A
-- semi-colon also separates commands, so both of these launch two programs:
--   run-many "a.lua" "b.lua"
--   run-many "a.lua; b.lua"
--
-- Multitasking is cooperative: a program that never yields will block
-- everything else, exactly as with the parallel/multishell APIs.

local unpack = table.unpack or unpack
local colours = colours or colors

local function pad(s, w)
  if #s >= w then return s:sub(1, w) end
  return s .. string.rep(" ", w - #s)
end

-- Split a string into a list of commands; each command is a list of words.
-- Semi-colons separate commands, quotes group words (and let a word contain
-- spaces or semi-colons).
local function parseCommands(line)
  local commands, words = {}, {}
  local word, quote = "", nil
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif c == "\\" and i < n then
        i = i + 1
        word = word .. line:sub(i, i)
      else
        word = word .. c
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == ";" then
      if #word > 0 then words[#words + 1] = word; word = "" end
      if #words > 0 then commands[#commands + 1] = words; words = {} end
    elseif c == " " or c == "\t" then
      if #word > 0 then words[#words + 1] = word; word = "" end
    else
      word = word .. c
    end
    i = i + 1
  end
  if #word > 0 then words[#words + 1] = word end
  if #words > 0 then commands[#commands + 1] = words end
  return commands
end

--------------------------------------------------------------------------
-- Parse arguments
--------------------------------------------------------------------------

local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
  print("Usage: run-many <command> [<command> ...]")
  print("Runs each command in parallel and shows their output.")
  print([[Example: run-many "sleep 5" "sleep 10"]])
  return
end

local commands = {}
for _, arg in ipairs(args) do
  for _, words in ipairs(parseCommands(arg)) do
    commands[#commands + 1] = words
  end
end
if #commands == 0 then
  print("run-many: no commands given")
  return
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------

local root = term.current()

local layout
local function computeLayout()
  local w, h = root.getSize()
  local listW = math.floor(w * 0.3)
  if listW < 8 then listW = 8 end
  if listW > 20 then listW = 20 end
  if listW > w - 4 then listW = math.max(4, w - 4) end
  layout = {
    W = w, H = h,
    listX = 1, listY = 2, listW = listW, listH = h - 2,
    divX = listW + 1,
    logX = listW + 2, logY = 2, logW = w - listW - 1, logH = h - 2,
  }
end
computeLayout()

if layout.W < 20 or layout.H < 5 or layout.logW < 1 or layout.listH < 1 then
  print("run-many: terminal too small")
  return
end

--------------------------------------------------------------------------
-- Processes, each with its own invisible terminal (a window)
--------------------------------------------------------------------------

local processes = {}
for i, words in ipairs(commands) do
  processes[i] = {
    index = i,
    name = table.concat(words, " "),
    words = words,
    status = "queued",
  }
end

for _, p in ipairs(processes) do
  -- The capture window is never shown; we read its lines back with getLine.
  p.win = window.create(root, layout.logX, layout.logY, layout.logW, layout.logH, false)
end

-- Cursor / writing helpers that work directly on a window object.
local function winNextLine(win)
  local _, h = win.getSize()
  local _, y = win.getCursorPos()
  if y >= h then
    win.scroll(1)
    win.setCursorPos(1, h)
  else
    win.setCursorPos(1, y + 1)
  end
end

local function winPrint(win, text, colour)
  local x, y = win.getCursorPos()
  if x > 1 then
    winNextLine(win)
    x, y = win.getCursorPos()
  end
  win.setCursorPos(1, y)
  win.setTextColor(colour or colours.white)
  win.write(text)
  winNextLine(win)
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

local selected = 1

local function listOffset()
  local visible = layout.listH
  if #processes <= visible or selected <= visible then return 0 end
  return math.min(selected - visible, #processes - visible)
end

local function statusChar(p)
  if p.status == "running" then return "*", colours.yellow
  elseif p.status == "done" then return "+", colours.lime
  elseif p.status == "error" then return "!", colours.red
  elseif p.status == "stopped" then return "o", colours.orange
  else return "?", colours.grey end
end

local function render()
  term.redirect(root)
  local l = layout

  local running = 0
  for _, p in ipairs(processes) do
    if p.status == "running" then running = running + 1 end
  end

  term.setBackgroundColor(colours.black)
  term.setTextColor(colours.white)
  term.clear()

  -- Header
  term.setBackgroundColor(colours.grey)
  term.setTextColor(colours.white)
  term.setCursorPos(1, 1)
  term.write(pad(" run-many   " .. running .. "/" .. #processes .. " running", l.W))

  -- Divider between list and logs
  term.setBackgroundColor(colours.black)
  term.setTextColor(colours.grey)
  for y = l.listY, l.listY + l.listH - 1 do
    term.setCursorPos(l.divX, y)
    term.write("|") -- \179
  end

  -- Program list
  local offset = listOffset()
  for row = 1, l.listH do
    local idx = offset + row
    local p = processes[idx]
    local y = l.listY + row - 1
    term.setCursorPos(l.listX, y)
    if p then
      local ch, col = statusChar(p)
      local prefix = string.format("%2d %s ", idx, ch)
      local nameW = math.max(1, l.listW - #prefix)
      local name = p.name:sub(1, nameW)
      local filler = string.rep(" ", math.max(0, nameW - #name))
      if idx == selected then
        term.setBackgroundColor(colours.lightGrey)
        term.setTextColor(colours.black)
        term.write(prefix .. name .. filler)
      else
        term.setBackgroundColor(colours.black)
        term.setTextColor(col)
        term.write(prefix)
        term.setTextColor(colours.white)
        term.write(name .. filler)
      end
    else
      term.setBackgroundColor(colours.black)
      term.write(string.rep(" ", l.listW))
    end
  end

  -- Logs of the selected program, painted from its (hidden) window
  local p = processes[selected]
  if p then
    for i = 1, l.logH do
      local text, fg, bg = p.win.getLine(i)
      term.setCursorPos(l.logX, l.logY + i - 1)
      term.blit(text, fg, bg)
    end
  end

  -- Footer
  term.setBackgroundColor(colours.grey)
  term.setTextColor(colours.white)
  term.setCursorPos(1, l.H)
  term.write(pad(" up/down or click: select   X: stop   Q: quit", l.W))
end

--------------------------------------------------------------------------
-- Cooperative scheduler: one coroutine per command, each with its own
-- terminal redirect that is installed right before it is resumed and
-- removed afterwards (so parallel coroutines don't stomp on each other).
--------------------------------------------------------------------------

local function resumeProcess(p, ...)
  if coroutine.status(p.co) == "dead" then return end
  term.redirect(p.win)
  local ok, err = coroutine.resume(p.co, ...)
  term.redirect(root)
  if not ok then
    p.status = "error"
    winPrint(p.win, "run-many: " .. tostring(err), colours.red)
  elseif coroutine.status(p.co) == "dead" and p.status == "running" then
    p.status = "done"
  end
end

for _, p in ipairs(processes) do
  p.co = coroutine.create(function()
    winPrint(p.win, "$ " .. p.name, colours.lightBlue)
    local ok = shell.run(unpack(p.words))
    if p.status == "stopped" then return end
    p.status = ok and "done" or "error"
  end)
end

--------------------------------------------------------------------------
-- Re-layout on terminal resize (keeps as much of the logs as possible)
--------------------------------------------------------------------------

local function doResize()
  local old = layout
  computeLayout()
  if layout.logW < 1 or layout.listH < 1 then return end
  for _, p in ipairs(processes) do
    local oldWin = p.win
    local newWin = window.create(root, layout.logX, layout.logY, layout.logW, layout.logH, false)
    for i = 1, math.min(layout.logH, old.logH) do
      local text, fg, bg = oldWin.getLine(i)
      newWin.setCursorPos(1, i)
      newWin.blit(text:sub(1, layout.logW), fg:sub(1, layout.logW), bg:sub(1, layout.logW))
    end
    newWin.setCursorPos(1, math.min(layout.logH, old.logH + 1))
    p.win = newWin
  end
end

--------------------------------------------------------------------------
-- Main event loop
--------------------------------------------------------------------------

local timer = os.startTimer(0.25)
render()

for _, p in ipairs(processes) do
  p.status = "running"
  resumeProcess(p)
end
render()

local quit = false
while not quit do
  local ev = { os.pullEvent() }
  local name = ev[1]
  local changed = false

  -- Forward the event to every still-running process
  for _, p in ipairs(processes) do
    if p.status == "running" and coroutine.status(p.co) == "suspended" then
      resumeProcess(p, unpack(ev))
      changed = true
    end
  end

  if name == "timer" then
    if ev[2] == timer then timer = os.startTimer(0.25) end
    changed = true
  elseif name == "key" then
    local k = ev[2]
    if k == keys.up then
      selected = math.max(1, selected - 1)
      changed = true
    elseif k == keys.down then
      selected = math.min(#processes, selected + 1)
      changed = true
    elseif k == keys.x then
      local p = processes[selected]
      if p and p.status == "running" then
        p.status = "stopped"
        winPrint(p.win, "[stopped by user]", colours.orange)
      end
      changed = true
    elseif k == keys.q then
      quit = true
    end
  elseif name == "mouse_click" or name == "monitor_touch" then
    local x, y = ev[3], ev[4]
    if x and y and x >= layout.listX and x < layout.divX
       and y >= layout.listY and y < layout.listY + layout.listH then
      local idx = listOffset() + (y - layout.listY + 1)
      if processes[idx] then selected = idx end
    end
    changed = true
  elseif name == "term_resize" then
    doResize()
    changed = true
  end

  if changed then render() end
end

term.redirect(root)
term.setBackgroundColor(colours.black)
term.setTextColor(colours.white)
term.clear()
term.setCursorPos(1, 1)
