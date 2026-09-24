-- Combine with a waterlogged Calibrated Sculk Sensor (frequency 1) to detect player presence with a timeout.
-- TODO: Make these configurable
local DURATION = 300
local OUTPUT_SIDE = "top"
local INPUT_SIDE = "back"

print("Starting presence detector")

redstone.setOutput(OUTPUT_SIDE, true)
local timerid = os.startTimer(DURATION)

while true do
  local event, id = os.pullEvent()
  
  if event == "redstone" and redstone.getInput(INPUT_SIDE) then
    timerId = os.startTimer(DURATION)
    redstone.setOutput(OUTPUT_SIDE, true)
  elseif event == "timer" and id == timerId then
    redstone.setOutput(OUTPUT_SIDE, false)
  end
end

