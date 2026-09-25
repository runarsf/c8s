if not smartglasses.modules['advancedperipherals:night_vision'] then
    error('Night vision module is not equipped')
end

while true do
  local event, keyBind, keyPressDuration = os.pullEvent("glasses_key_pressed")

  local nightVision = smartglasses.modules['advancedperipherals:night_vision']
  nightVision.enableNightVision(not nightVision.isNightVisionEnabled())

  sleep(1)
end
