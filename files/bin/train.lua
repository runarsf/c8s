-- train.lua : steam locomotive across a 1-block-tall monitor (any width)
-- configure with: set train.carriages 5
settings.define("train.carriages", {
  description = "Number of carriages pulled by the train",
  default = 3,
  type = "number",
})
local CARRIAGES = math.max(0, math.floor(settings.get("train.carriages")))

local mon = peripheral.find("monitor") or error("No monitor attached", 0)
mon.setTextScale(0.5)                 -- 1 block tall = 10 rows at 0.5
local W, H = mon.getSize()

local SKY, RAIL = colors.black, colors.brown
local PAL = { r = colors.red, y = colors.yellow, a = colors.gray,
              g = colors.green, o = colors.orange, l = colors.lightGray,
              b = colors.blue }

local BODY = {                        -- faces right; ' ' = transparent
  "rrrrr     aa   ",
  "r yyr     aa   ",
  "r yyrgggggggg  ",
  "rrrrrgggggggggo",
  "rrrrrrrrrrrrrrr",
}
local WHEELS = { " lal lal   lal ", " ala ala   ala " }

local CAR = {                         -- must be same height as BODY
  "            ",
  "bbbbbbbbbbbb",
  "b yy yy yy b",
  "bbbbbbbbbbbb",
  "rrrrrrrrrrrr",
}
local CAR_WHEELS = { " lal    lal ", " ala    ala " }
local COUPLER_ROW = 5                 -- row that gets the gray coupling link

-- Prepend carriages (plus a 1-cell coupler each) to the loco sprite
for i = 1, #BODY do
  local seg = CAR[i] .. (i == COUPLER_ROW and "a" or " ")
  BODY[i] = seg:rep(CARRIAGES) .. BODY[i]
end
for f = 1, 2 do
  WHEELS[f] = (CAR_WHEELS[f] .. " "):rep(CARRIAGES) .. WHEELS[f]
end

local SW, SH = #BODY[1], #BODY + 1
local CHIMNEY = 10 + CARRIAGES * (#CAR[1] + 1)  -- chimney x offset in sprite

local function draw(tx, t, puffs)
  local bg = {}
  for y = 1, H do
    local row = {}
    for x = 1, W do row[x] = (y == H) and RAIL or SKY end
    bg[y] = row
  end

  for _, p in ipairs(puffs) do
    local x, y = p.x, math.floor(p.y)
    if x >= 1 and x <= W and y >= 1 and y < H then
      bg[y][x] = p.age < 3 and colors.white
              or p.age < 6 and colors.lightGray or colors.gray
    end
  end

  local top = H - SH
  local rows = { table.unpack(BODY) }
  rows[SH] = WHEELS[t % 2 + 1]
  for i, row in ipairs(rows) do
    local y = top + i - 1
    if y >= 1 then
      for j = 1, SW do
        local c, x = row:sub(j, j), tx + j - 1
        if c ~= " " and x >= 1 and x <= W then bg[y][x] = PAL[c] end
      end
    end
  end

  local blank = (" "):rep(W)
  for y = 1, H do
    local s = {}
    for x = 1, W do s[x] = colors.toBlit(bg[y][x]) end
    s = table.concat(s)
    mon.setCursorPos(1, y)
    mon.blit(blank, s, s)
  end
end

while true do
  local puffs, tx, t = {}, 2 - SW, 0
  while tx <= W or #puffs > 0 do
    t = t + 1
    if tx <= W and t % 2 == 0 then
      puffs[#puffs + 1] = { x = tx + CHIMNEY + math.random(0, 1),
                            y = H - SH - 1, age = 0 }
    end
    for i = #puffs, 1, -1 do         -- steam rises, drifts, fades
      local p = puffs[i]
      p.age, p.y = p.age + 1, p.y - 0.5
      if math.random() < 0.3 then p.x = p.x - 1 end
      if p.age > 8 or p.y < 1 then table.remove(puffs, i) end
    end
    draw(tx, t, puffs)
    tx = tx + 1
    sleep(0.1)
  end
  sleep(1)
end
